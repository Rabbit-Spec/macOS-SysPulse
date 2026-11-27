import Foundation
import IOKit
import Darwin

/// 实时苹果芯片频率与模块功耗读取器（基于 libIOReport 与 PMGR 频点表，安全降级无崩溃）
public struct IOReportTelemetrySample: Sendable, Equatable {
    public var cpuPrimaryClusterGHz: Double?
    public var cpuSecondaryClusterGHz: Double?
    public var cpuTertiaryClusterGHz: Double?
    public var gpuFrequencyGHz: Double?
    public var cpuPowerWatts: Double?
    public var gpuPowerWatts: Double?
    public var anePowerWatts: Double?

    public init(
        cpuPrimaryClusterGHz: Double? = nil,
        cpuSecondaryClusterGHz: Double? = nil,
        cpuTertiaryClusterGHz: Double? = nil,
        gpuFrequencyGHz: Double? = nil,
        cpuPowerWatts: Double? = nil,
        gpuPowerWatts: Double? = nil,
        anePowerWatts: Double? = nil
    ) {
        self.cpuPrimaryClusterGHz = cpuPrimaryClusterGHz
        self.cpuSecondaryClusterGHz = cpuSecondaryClusterGHz
        self.cpuTertiaryClusterGHz = cpuTertiaryClusterGHz
        self.gpuFrequencyGHz = gpuFrequencyGHz
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
        self.anePowerWatts = anePowerWatts
    }
}

public final class IOReportMetricsReader: @unchecked Sendable {
    public static let shared = IOReportMetricsReader()

    private typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannelsFn = @convention(c) (CFMutableDictionary, CFTypeRef, CFTypeRef?) -> Void
    private typealias CreateSubFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetGroupFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetSubGroupFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetChanNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetUnitFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleIntFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias IterateFn = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void

    private struct Functions {
        let copyChannelsInGroup: CopyChannelsFn
        let mergeChannels: MergeChannelsFn
        let createSubscription: CreateSubFn
        let createSamples: CreateSamplesFn
        let createSamplesDelta: CreateDeltaFn
        let channelGetGroup: GetGroupFn
        let channelGetSubGroup: GetSubGroupFn
        let channelGetName: GetChanNameFn
        let channelGetUnitLabel: GetUnitFn
        let simpleGetIntegerValue: SimpleIntFn
        let stateGetCount: StateCountFn
        let stateGetNameForIndex: StateNameFn
        let stateGetResidency: StateResFn
        let iterate: IterateFn
    }

    private struct PMGRFrequencyTable {
        let key: String
        let frequenciesGHz: [Double]
        var count: Int { frequenciesGHz.count }
        var maxGHz: Double { frequenciesGHz.max() ?? 0.0 }
        var minPositiveGHz: Double { frequenciesGHz.filter { $0 > 0.05 }.min() ?? 0.0 }
        var hasLeadingZero: Bool { (frequenciesGHz.first ?? -1.0) == 0.0 }
    }

    private let lock = NSLock()
    private var initialized = false
    private var funcs: Functions?
    private var subscription: UnsafeMutableRawPointer?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousSampleTime: TimeInterval = 0
    private var pmgrTables: [PMGRFrequencyTable] = []
    private var lastValidTelemetry = IOReportTelemetrySample()

    private init() {}

    public func sample() -> IOReportTelemetrySample {
        lock.lock()
        defer { lock.unlock() }

        setupIfNeeded()
        guard let fn = funcs,
              let sub = subscription,
              let subCh = subscribedChannels,
              let current = fn.createSamples(sub, subCh, nil)?.takeRetainedValue() else {
            return lastValidTelemetry
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer {
            previousSample = current
            previousSampleTime = now
        }

        guard let prev = previousSample else {
            return lastValidTelemetry
        }
        let dt = max(0.05, now - previousSampleTime)
        guard let delta = fn.createSamplesDelta(prev, current, nil)?.takeRetainedValue() else {
            return lastValidTelemetry
        }

        var cpuEnergiesWatts: [String: Double] = [:]
        var aggregateCPUWatts: Double? = nil
        var aggregateGPUWatts: Double? = nil
        var aneWatts: Double? = nil

        var primaryClusterCandidates: [Double] = []
        var secondaryClusterCandidates: [Double] = []
        var tertiaryClusterCandidates: [Double] = []
        var gpuFreqCandidates: [Double] = []
        let hasTripleTier = MacHardwareInfo.shared.coreTopology.hasTripleTier

        fn.iterate(delta) { channel in
            let group = fn.channelGetGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let subGroup = fn.channelGetSubGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let name = fn.channelGetName(channel)?.takeUnretainedValue() as String? ?? ""

            if group == "Energy Model" {
                let raw = fn.simpleGetIntegerValue(channel, 0)
                guard raw >= 0 else { return 0 }
                let unit = (fn.channelGetUnitLabel(channel)?.takeUnretainedValue() as String? ?? "mJ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let watts = Self.energyToWatts(value: raw, unit: unit, dt: dt)
                guard watts.isFinite, watts >= 0, watts <= 500 else { return 0 }

                if name == "CPU Energy" {
                    aggregateCPUWatts = watts
                } else if name == "GPU Energy" {
                    aggregateGPUWatts = watts
                } else if name == "GPU0" || name == "GPU" {
                    if aggregateGPUWatts == nil {
                        aggregateGPUWatts = watts
                    }
                } else if name.hasPrefix("ANE") {
                    aneWatts = (aneWatts ?? 0.0) + watts
                } else if name == "SCPU" || name == "PCPU" || name == "ECPU" || name == "MCPU0" || name == "MCPU1" || name == "CPU" {
                    cpuEnergiesWatts[name] = watts
                }
                return 0
            }

            if group == "CPU Stats", subGroup == "CPU Complex Performance States" {
                if name.contains("_IDLE") || name.hasSuffix("PM") {
                    return 0
                }
                if hasTripleTier {
                    let isPrimary = name.hasPrefix("SCPU") || name.contains("Super")
                    let isSecondary = name.hasPrefix("PCPU") || name.hasPrefix("MCPU") || name.hasPrefix("P-Core")
                    let isTertiary = name.hasPrefix("ECPU") || name.hasPrefix("E-Core")
                    guard isPrimary || isSecondary || isTertiary else { return 0 }
                    if let freq = self.computeWeightedFrequencyGHz(channel: channel, channelName: name, isGPU: false, isPrimaryCluster: isPrimary || isSecondary, fn: fn) {
                        if isPrimary {
                            primaryClusterCandidates.append(freq)
                        } else if isSecondary {
                            secondaryClusterCandidates.append(freq)
                        } else {
                            tertiaryClusterCandidates.append(freq)
                        }
                    }
                } else {
                    let isPrimary = name.hasPrefix("SCPU") || name.hasPrefix("PCPU") || name.hasPrefix("P-Core") || name.contains("Super")
                    let isSecondary = name.hasPrefix("ECPU") || name.hasPrefix("MCPU") || name.hasPrefix("E-Core")
                    guard isPrimary || isSecondary else { return 0 }

                    if let freq = self.computeWeightedFrequencyGHz(channel: channel, channelName: name, isGPU: false, isPrimaryCluster: isPrimary, fn: fn) {
                        if isPrimary {
                            primaryClusterCandidates.append(freq)
                        } else {
                            secondaryClusterCandidates.append(freq)
                        }
                    }
                }
                return 0
            }

            if group == "GPU Stats", subGroup == "GPU Performance States" || (subGroup.contains("Performance") && name == "GPUPH") {
                if name == "GPUPH" || name == "GPU" || name.hasPrefix("GPU") {
                    if let freq = self.computeWeightedFrequencyGHz(channel: channel, channelName: name, isGPU: true, isPrimaryCluster: true, fn: fn) {
                        gpuFreqCandidates.append(freq)
                    }
                }
                return 0
            }

            return 0
        }

        var result = lastValidTelemetry
        if !primaryClusterCandidates.isEmpty {
            result.cpuPrimaryClusterGHz = primaryClusterCandidates.reduce(0, +) / Double(primaryClusterCandidates.count)
        }
        if !secondaryClusterCandidates.isEmpty {
            result.cpuSecondaryClusterGHz = secondaryClusterCandidates.reduce(0, +) / Double(secondaryClusterCandidates.count)
        }
        if !tertiaryClusterCandidates.isEmpty {
            result.cpuTertiaryClusterGHz = tertiaryClusterCandidates.reduce(0, +) / Double(tertiaryClusterCandidates.count)
        }
        if !gpuFreqCandidates.isEmpty {
            result.gpuFrequencyGHz = gpuFreqCandidates.reduce(0, +) / Double(gpuFreqCandidates.count)
        }

        if let totalCpuW = aggregateCPUWatts {
            result.cpuPowerWatts = totalCpuW
        } else if !cpuEnergiesWatts.isEmpty {
            result.cpuPowerWatts = cpuEnergiesWatts.values.reduce(0, +)
        }

        if let gW = aggregateGPUWatts {
            result.gpuPowerWatts = gW
        }
        if let aW = aneWatts {
            result.anePowerWatts = aW
        }

        lastValidTelemetry = result
        return result
    }

    // MARK: - Private Setup & Frequency Math

    private func setupIfNeeded() {
        guard !initialized else { return }
        initialized = true

        pmgrTables = Self.loadPMGRFrequencyTables()

        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return }

        guard let sCopy = dlsym(handle, "IOReportCopyChannelsInGroup"),
              let sMerge = dlsym(handle, "IOReportMergeChannels"),
              let sSub = dlsym(handle, "IOReportCreateSubscription"),
              let sSamples = dlsym(handle, "IOReportCreateSamples"),
              let sDelta = dlsym(handle, "IOReportCreateSamplesDelta"),
              let sGroup = dlsym(handle, "IOReportChannelGetGroup"),
              let sSubGroup = dlsym(handle, "IOReportChannelGetSubGroup"),
              let sName = dlsym(handle, "IOReportChannelGetChannelName"),
              let sUnit = dlsym(handle, "IOReportChannelGetUnitLabel"),
              let sSimple = dlsym(handle, "IOReportSimpleGetIntegerValue"),
              let sCount = dlsym(handle, "IOReportStateGetCount"),
              let sStateName = dlsym(handle, "IOReportStateGetNameForIndex"),
              let sStateRes = dlsym(handle, "IOReportStateGetResidency"),
              let sIterate = dlsym(handle, "IOReportIterate") else {
            return
        }

        let fn = Functions(
            copyChannelsInGroup: unsafeBitCast(sCopy, to: CopyChannelsFn.self),
            mergeChannels: unsafeBitCast(sMerge, to: MergeChannelsFn.self),
            createSubscription: unsafeBitCast(sSub, to: CreateSubFn.self),
            createSamples: unsafeBitCast(sSamples, to: CreateSamplesFn.self),
            createSamplesDelta: unsafeBitCast(sDelta, to: CreateDeltaFn.self),
            channelGetGroup: unsafeBitCast(sGroup, to: GetGroupFn.self),
            channelGetSubGroup: unsafeBitCast(sSubGroup, to: GetSubGroupFn.self),
            channelGetName: unsafeBitCast(sName, to: GetChanNameFn.self),
            channelGetUnitLabel: unsafeBitCast(sUnit, to: GetUnitFn.self),
            simpleGetIntegerValue: unsafeBitCast(sSimple, to: SimpleIntFn.self),
            stateGetCount: unsafeBitCast(sCount, to: StateCountFn.self),
            stateGetNameForIndex: unsafeBitCast(sStateName, to: StateNameFn.self),
            stateGetResidency: unsafeBitCast(sStateRes, to: StateResFn.self),
            iterate: unsafeBitCast(sIterate, to: IterateFn.self)
        )

        var merged: CFMutableDictionary?
        for group in ["Energy Model", "CPU Stats", "GPU Stats"] {
            if let dict = fn.copyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() {
                if let existing = merged {
                    fn.mergeChannels(existing, dict, nil)
                } else {
                    merged = dict
                }
            }
        }

        guard let desired = merged else { return }
        var subbedUnmanaged: Unmanaged<CFMutableDictionary>?
        guard let sub = fn.createSubscription(nil, desired, &subbedUnmanaged, 0, nil),
              let subbed = subbedUnmanaged?.takeRetainedValue() else {
            return
        }

        self.funcs = fn
        self.subscription = sub
        self.subscribedChannels = subbed
        if let initialSample = fn.createSamples(sub, subbed, nil)?.takeRetainedValue() {
            self.previousSample = initialSample
            self.previousSampleTime = ProcessInfo.processInfo.systemUptime
        }
    }

    private func computeWeightedFrequencyGHz(
        channel: CFDictionary,
        channelName: String,
        isGPU: Bool,
        isPrimaryCluster: Bool,
        fn: Functions
    ) -> Double? {
        let count = Int(fn.stateGetCount(channel))
        guard count > 0 else { return nil }

        var stateEntries: [(name: String, residency: Int64)] = []
        stateEntries.reserveCapacity(count)

        for i in 0..<Int32(count) {
            let sName = (fn.stateGetNameForIndex(channel, i)?.takeUnretainedValue() as String? ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let res = fn.stateGetResidency(channel, i)
            stateEntries.append((sName, res))
        }

        // 筛选非休眠/关闭的活跃工作态
        let activeEntries = stateEntries.filter { entry in
            let upper = entry.name.uppercased()
            return upper != "DOWN" && upper != "IDLE" && upper != "OFF" && upper != "NON_IDLE" && !upper.isEmpty
        }
        guard !activeEntries.isEmpty else { return nil }

        // 1. 若状态名直接自带频率（如 "1800 MHz" / "2.40 GHz"）
        var directFreqs: [Double] = []
        var canParseAllDirect = true
        for entry in activeEntries {
            if let parsed = Self.parseDirectFrequencyGHz(from: entry.name) {
                directFreqs.append(parsed)
            } else {
                canParseAllDirect = false
                break
            }
        }
        if canParseAllDirect && directFreqs.count == activeEntries.count {
            return Self.weightedAverage(entries: activeEntries, frequenciesGHz: directFreqs)
        }

        // 2. 匹配 PMGR 频点表
        if isGPU {
            // GPU P-states: P1, P2... 对应 PMGR table
            let gpuCandidates = pmgrTables.filter { table in
                table.key.contains("voltage-states9") || table.key.contains("voltage-states31")
            }
            let table = gpuCandidates.first(where: { $0.hasLeadingZero && $0.count >= 6 })
                ?? gpuCandidates.first(where: { $0.count >= 6 })
                ?? pmgrTables.first(where: { $0.hasLeadingZero && $0.maxGHz >= 0.8 && $0.maxGHz <= 2.2 })

            if let table {
                let offset = table.hasLeadingZero ? 1 : 0
                var freqs: [Double] = []
                var validEntries: [(name: String, residency: Int64)] = []
                for (pos, entry) in activeEntries.enumerated() {
                    let pIdx = Self.parseStateNumber(prefix: "P", from: entry.name) ?? (pos + 1)
                    let tableIdx = table.hasLeadingZero ? pIdx : max(0, pIdx - 1)
                    let clampedIdx = max(offset, min(table.count - 1, tableIdx))
                    if clampedIdx < table.count {
                        let f = table.frequenciesGHz[clampedIdx]
                        if f > 0.05 {
                            freqs.append(f)
                            validEntries.append(entry)
                        }
                    }
                }
                if !validEntries.isEmpty {
                    return Self.weightedAverage(entries: validEntries, frequenciesGHz: freqs)
                }
            }
            return nil
        }

        // CPU 集群匹配 PMGR 表（activeCount 与 PMGR 表条数精确对齐）
        let activeCount = activeEntries.count
        let cpuTables = pmgrTables.filter { table in
            !table.hasLeadingZero && table.minPositiveGHz >= 0.45 && table.maxGHz >= 1.5
        }
        let matchingTables = cpuTables.filter { $0.count == activeCount }
        let selectedTable: PMGRFrequencyTable?
        if matchingTables.count == 1 {
            selectedTable = matchingTables.first
        } else if matchingTables.count > 1 {
            selectedTable = isPrimaryCluster
                ? matchingTables.max(by: { $0.maxGHz < $1.maxGHz })
                : matchingTables.min(by: { $0.maxGHz < $1.maxGHz })
        } else {
            // 回退按经典 key 匹配
            let preferredKey = isPrimaryCluster ? "voltage-states5-sram" : "voltage-states1-sram"
            selectedTable = cpuTables.first(where: { $0.key == preferredKey })
                ?? (isPrimaryCluster ? cpuTables.max(by: { $0.maxGHz < $1.maxGHz }) : cpuTables.min(by: { $0.maxGHz < $1.maxGHz }))
        }

        guard let table = selectedTable, !table.frequenciesGHz.isEmpty else { return nil }
        var mappedFreqs: [Double] = []
        var mappedEntries: [(name: String, residency: Int64)] = []
        for (pos, entry) in activeEntries.enumerated() {
            let vIdx = Self.parseStateNumber(prefix: "V", from: entry.name) ?? pos
            let clamped = max(0, min(table.count - 1, vIdx))
            let freqGHz = table.frequenciesGHz[clamped]
            if freqGHz > 0.1 {
                mappedFreqs.append(freqGHz)
                mappedEntries.append(entry)
            }
        }
        return Self.weightedAverage(entries: mappedEntries, frequenciesGHz: mappedFreqs)
    }

    private static func weightedAverage(entries: [(name: String, residency: Int64)], frequenciesGHz: [Double]) -> Double? {
        var totalWeight: Double = 0.0
        var weightedSum: Double = 0.0
        for i in 0..<min(entries.count, frequenciesGHz.count) {
            let res = entries[i].residency
            guard res > 0 else { continue }
            let w = Double(res)
            totalWeight += w
            weightedSum += w * frequenciesGHz[i]
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum / totalWeight
    }

    private static func energyToWatts(value: Int64, unit: String, dt: TimeInterval) -> Double {
        let val = Double(value)
        switch unit.lowercased() {
        case "nj":
            return (val / 1_000_000_000.0) / dt
        case "uj", "µj":
            return (val / 1_000_000.0) / dt
        case "mj":
            return (val / 1_000.0) / dt
        case "j":
            return val / dt
        default:
            return (val / 1_000.0) / dt
        }
    }

    private static func parseDirectFrequencyGHz(from stateName: String) -> Double? {
        let lower = stateName.lowercased()
        let digits = lower.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
        guard let num = Double(digits), num > 0 else { return nil }
        if lower.contains("ghz") { return num }
        if lower.contains("mhz") { return num / 1000.0 }
        return nil
    }

    private static func parseStateNumber(prefix: String, from stateName: String) -> Int? {
        guard stateName.hasPrefix(prefix) else { return nil }
        var digits = ""
        for ch in stateName.dropFirst(prefix.count) {
            if ch.isNumber {
                digits.append(ch)
            } else {
                break
            }
        }
        return Int(digits)
    }

    private static func loadPMGRFrequencyTables() -> [PMGRFrequencyTable] {
        let pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
        guard pmgr != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(pmgr) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(pmgr, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return []
        }

        // 优先收集 `-sram` 表，同时兼容不含 `-sram` 的纯表
        let sortedKeys = dict.keys
            .filter { $0.hasPrefix("voltage-states") }
            .sorted { lhs, rhs in
                let ls = lhs.hasSuffix("-sram")
                let rs = rhs.hasSuffix("-sram")
                if ls != rs { return ls }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        var tables: [PMGRFrequencyTable] = []
        for key in sortedKeys {
            guard let data = dict[key] as? Data, data.count >= 8 else { continue }
            let count = data.count / 8
            var rawValues: [UInt32] = []
            rawValues.reserveCapacity(count)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    let freq = raw.load(fromByteOffset: i * 8, as: UInt32.self)
                    rawValues.append(freq)
                }
            }
            let maxRaw = rawValues.max() ?? 0
            // 过滤掉非频率寄存器（例如全 1、或者全为小于 100_000 的微伏电压表）
            guard maxRaw >= 300_000 else { continue }

            // 小于 20_000_000 为 kHz（如 M5 Max CPU 4_608_000 kHz = 4.608 GHz），否则为 Hz（如 338_000_000 Hz）
            let divisor: Double = (maxRaw < 20_000_000) ? 1_000_000.0 : 1_000_000_000.0
            let ghzList = rawValues.map { Double($0) / divisor }

            // 去重高度重合的表，仅保留 -sram 主表（已在排序中置前）
            let baseKey = key.replacingOccurrences(of: "-sram", with: "")
            if !key.hasSuffix("-sram"), tables.contains(where: { $0.key == "\(baseKey)-sram" }) {
                continue
            }
            tables.append(PMGRFrequencyTable(key: key, frequenciesGHz: ghzList))
        }
        return tables
    }
}
