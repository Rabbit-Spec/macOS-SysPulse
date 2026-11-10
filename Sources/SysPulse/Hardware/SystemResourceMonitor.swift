import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.ps
import Observation
import SystemConfiguration

// MARK: - Telemetry Models

public struct SystemPowerMetrics: Equatable, Sendable {
    public var totalWatts: Double = 28.0
    public var systemLoadWatts: Double = 27.2
    public var adapterLossWatts: Double = 0.8
    public var dcVoltageVolts: Double = 12.1
    public var dcCurrentAmps: Double = 2.3
    public var peakWatts: Double = 28.0
    public var averageWatts: Double = 28.0
    public var cpuUsagePercent: Double = 4.0
    public var cpuUserPercent: Double = 2.5
    public var cpuSystemPercent: Double = 1.5

    public var totalSystemWatts: Double { totalWatts }
    public var cpuTotalPercent: Double { cpuUsagePercent }

    public init() {}
}

public enum MemoryPressureState: String, Sendable {
    case normal = "正常"
    case warning = "较高"
    case critical = "危急"
}

public struct MemoryMetrics: Equatable, Sendable {
    public var totalBytes: UInt64 = 64 * 1073741824
    public var usedBytes: UInt64 = 16 * 1073741824
    public var appBytes: UInt64 = 10 * 1073741824
    public var wiredBytes: UInt64 = 4 * 1073741824
    public var compressedBytes: UInt64 = 2 * 1073741824
    public var cachedFilesBytes: UInt64 = 12 * 1073741824
    public var usedPercent: Int = 25
    public var pressure: MemoryPressureState = .normal

    public init() {}

    public var usedGB: Double { Double(usedBytes) / 1073741824.0 }
    public var totalGB: Double { Double(totalBytes) / 1073741824.0 }
    public var appMemoryGB: Double { Double(appBytes) / 1073741824.0 }
    public var wiredMemoryGB: Double { Double(wiredBytes) / 1073741824.0 }
    public var compressedMemoryGB: Double { Double(compressedBytes) / 1073741824.0 }
    public var cachedFilesGB: Double { Double(cachedFilesBytes) / 1073741824.0 }
    public var pressureLabel: String { pressure.rawValue }
    public var pressureLevel: Int {
        switch pressure {
        case .normal: return 1
        case .warning: return 2
        case .critical: return 4
        }
    }

    public var formattedUsedGB: String {
        String(format: "%.1f GB", Double(usedBytes) / 1073741824.0)
    }

    public var formattedTotalGB: String {
        String(format: "%.0f GB", Double(totalBytes) / 1073741824.0)
    }
}

public struct DiskIOMetrics: Equatable, Sendable {
    public var readBytesPerSec: Double = 0
    public var writeBytesPerSec: Double = 0
    public var totalReadBytes: UInt64 = 0
    public var totalWriteBytes: UInt64 = 0
    public var readIOPS: Double = 0
    public var writeIOPS: Double = 0
    public var bootVolumeFreeBytes: UInt64 = 0
    public var bootVolumeTotalBytes: UInt64 = 0

    public init() {}

    public var readMBps: Double { readBytesPerSec / 1048576.0 }
    public var writeMBps: Double { writeBytesPerSec / 1048576.0 }
    public var formattedReadSpeed: String { Self.formatSpeed(readBytesPerSec) }
    public var formattedWriteSpeed: String { Self.formatSpeed(writeBytesPerSec) }
    public var totalReadGB: Double { Double(totalReadBytes) / 1073741824.0 }
    public var totalWriteGB: Double { Double(totalWriteBytes) / 1073741824.0 }
    public var bootVolumeFreeGB: Double { Double(bootVolumeFreeBytes) / 1073741824.0 }
    public var bootVolumeTotalGB: Double { Double(bootVolumeTotalBytes) / 1073741824.0 }

    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return "0 KB/s"
        } else if bytesPerSec < 1048576 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else if bytesPerSec < 1048576 * 100 {
            return String(format: "%.1f MB/s", bytesPerSec / 1048576.0)
        } else {
            return String(format: "%.0f MB/s", bytesPerSec / 1048576.0)
        }
    }

    public static func formatCompactSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 10240 {
            return "0M"
        } else if bytesPerSec < 1048576 {
            return String(format: "%.0fK", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.1fM", bytesPerSec / 1048576.0)
        }
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1073741824.0
        if gb >= 1000 {
            return String(format: "%.2f TB", gb / 1024.0)
        }
        return String(format: "%.1f GB", gb)
    }
}

public struct SystemHardwareExtendedMetrics: Equatable, Sendable {
    public var cpuTemperatureC: Double = 48.0
    public var gpuTemperatureC: Double = 46.0
    public var fanSpeedRPM: Int = 1000
    public var fanMinRPM: Int = 1000
    public var fanMaxRPM: Int = 3500
    public var isFanSupported: Bool = true
    public var diskUsagePercent: Int = 12
    public var networkUploadBytesPerSec: Double = 0.0
    public var networkDownloadBytesPerSec: Double = 0.0
    public var networkHistoryUpload: [Double] = Array(repeating: 0.0, count: 24)
    public var networkHistoryDownload: [Double] = Array(repeating: 0.0, count: 24)
    public var batteryCycleCount: Int = 0
    public var isBatteryCharging: Bool = false
    public var batteryChargingWatts: Double = 0.0
    public var batteryPercent: Int = 0

    // 扩展硬件遥测指标
    public var perCoreLoads: [Double] = Array(repeating: 2.0, count: 18)
    public var cpuLoadAverage1Min: Double = 2.1
    public var cpuHistory: [Double] = Array(repeating: 5.0, count: 24)
    public var gpuUsagePercent: Double = 0.0
    public var gpuWatts: Double = 0.0
    public var gpuHistory: [Double] = Array(repeating: 0.0, count: 24)
    public var primaryInterfaceKind: String = "Ethernet"
    public var statfsTotalGB: Double = 995.0
    public var statfsFreeGB: Double = 875.0
    public var statfsUsedGB: Double = 120.0
    public var statfsUsedPercent: Int = 12
    public var totalProcessCount: Int = 156

    public init() {}

    public var formattedUploadSpeed: String {
        Self.formatSpeed(networkUploadBytesPerSec)
    }

    public var formattedDownloadSpeed: String {
        Self.formatSpeed(networkDownloadBytesPerSec)
    }

    public var downloadSpeedParts: (value: String, unit: String) {
        Self.formatSpeedParts(networkDownloadBytesPerSec)
    }

    public var uploadSpeedParts: (value: String, unit: String) {
        Self.formatSpeedParts(networkUploadBytesPerSec)
    }

    public static func formatSpeedParts(_ bytesPerSec: Double) -> (value: String, unit: String) {
        if bytesPerSec < 1048576 {
            let kb = max(0.0, bytesPerSec / 1024.0)
            return (String(format: "%.0f", kb), "KB/s")
        } else {
            let mb = bytesPerSec / 1048576.0
            return (String(format: "%.1f", mb), "MB/s")
        }
    }

    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return "< 1 KB/s"
        } else if bytesPerSec < 1048576 {
            let kb = bytesPerSec / 1024.0
            return String(format: "%.0f KB/s", kb)
        } else {
            return String(format: "%.1f MB/s", bytesPerSec / 1048576.0)
        }
    }
}

public struct EnergyAppItem: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let cpuPercent: Double
    public let energyImpact: Double
    public let estimatedWatts: Double
    public let memoryBytes: UInt64

    public var memoryMB: Double { Double(memoryBytes) / 1048576.0 }
    public var energyImpactScore: Double { energyImpact }

    public var formattedMemory: String {
        let mb = Double(memoryBytes) / 1048576.0
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", mb)
    }
}

public struct LoadRuntimeMetrics: Equatable, Sendable {
    /// True if running on a MacBook with an internal battery; False on Desktop Macs (Mac Studio, Mac mini, iMac, Mac Pro).
    public var hasInternalBattery: Bool = false
    public var internalBatteryPercent: Int = 100
    public var isInternalCharging: Bool = false
    public var isInternalPluggedIn: Bool = true
    public var cycleCount: Int = 0
    public var healthPercent: Int = 100
    public var batteryTempCelsius: Double = 29.0
    public var remainingWh: Double = 0.0
    public var maxCapacityWh: Double = 0.0

    /// Current active load power (Watts) used for runtime calculation
    public var currentLoadWatts: Double = 28.0
    /// Dynamic estimated runtime (minutes) at the exact current load
    public var estimatedMinutesAtCurrentLoad: Int = 24
    /// Estimated runtime if load drops to idle/light load (~22W on desktop / ~8W on laptop)
    public var estimatedMinutesAtLightLoad: Int = 36
    /// Estimated runtime if load rises to heavy load (~95W on desktop / ~40W on laptop)
    public var estimatedMinutesAtHeavyLoad: Int = 10
    /// Combined runtime (MacBook Internal Battery + External UPS) when both are present
    public var combinedUPSAndInternalMinutes: Int? = nil

    public var currentLoadEstimatedMinutes: Int { estimatedMinutesAtCurrentLoad }
    public var lightLoadEstimatedMinutes: Int { estimatedMinutesAtLightLoad }
    public var heavyLoadEstimatedMinutes: Int { estimatedMinutesAtHeavyLoad }
    public var combinedTotalMinutes: Int { combinedUPSAndInternalMinutes ?? estimatedMinutesAtCurrentLoad }
    public var formattedCurrentLoadRuntime: String { Self.formatMinutes(estimatedMinutesAtCurrentLoad) }
    public var internalBatteryHealthPercent: Int { healthPercent }
    public var internalBatteryCycleCount: Int { cycleCount }
    public var internalRemainingWh: Double { remainingWh }
    public var upsEstimatedRemainingWh: Double { max(0.0, Double(estimatedMinutesAtCurrentLoad) / 60.0 * currentLoadWatts) }

    public init() {}

    public static func formatMinutes(_ mins: Int) -> String {
        if mins <= 0 { return "< 1 分钟" }
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)小时\(m)分" : "\(h)小时"
        }
        return "\(mins) 分钟"
    }
}

// MARK: - System Resource Monitor Engine

@Observable
@MainActor
public final class SystemResourceMonitor {
    public static let shared = SystemResourceMonitor()

    public private(set) var power = SystemPowerMetrics()
    public private(set) var memory = MemoryMetrics()
    public private(set) var diskIO = DiskIOMetrics()
    public var disk: DiskIOMetrics { diskIO }
    public private(set) var topEnergyApps: [EnergyAppItem] = []
    public private(set) var loadRuntime = LoadRuntimeMetrics()
    public private(set) var hardware = SystemHardwareExtendedMetrics()

    public var onMetricsUpdated: (@MainActor @Sendable () -> Void)?

    private let workerQueue = DispatchQueue(label: "com.apple.powerglass.sysmonitor", qos: .utility)
    private let stateLock = NSLock()
    private var sampler = BackgroundSamplerState()

    private init() {
        start(intervalSeconds: 1.0)
    }

    public func start(intervalSeconds: Double = 1.0) {
        let state = sampler
        workerQueue.async { [weak self] in
            guard let self else { return }
            state.timer?.cancel()

            let newTimer = DispatchSource.makeTimerSource(queue: self.workerQueue)
            newTimer.schedule(deadline: .now(), repeating: intervalSeconds)
            newTimer.setEventHandler { [weak self] in
                self?.pollOnBackgroundQueue(state: state)
            }
            newTimer.resume()
            state.timer = newTimer
        }
    }

    public func triggerImmediateRefresh() {
        let state = sampler
        workerQueue.async { [weak self] in
            self?.pollOnBackgroundQueue(state: state)
        }
    }

    public func refreshNow() {
        triggerImmediateRefresh()
    }

    private nonisolated func pollOnBackgroundQueue(state: BackgroundSamplerState) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let toggles = FeatureToggleManager.shared
                let needPower = toggles.enableSystemPowerMonitor || toggles.menuBarShowSystemWatts || toggles.enableLoadRuntimeMonitor || toggles.enableTopEnergyAppsMonitor || toggles.menuBarShowCpuGpu
                let needMem = toggles.enableMemoryMonitor || toggles.menuBarShowMemTemp
                let needDisk = toggles.enableDiskIOMonitor
                let needApps = toggles.enableTopEnergyAppsMonitor
                let needRuntime = toggles.enableLoadRuntimeMonitor
                let upsTelemetry = toggles.enablePluginUPSManager ? PowerSourceEngine.shared.telemetry : UPSTelemetry()

                self.workerQueue.async {
                    let snapshot = state.collectSnapshot(
                        needPower: needPower,
                        needMem: needMem,
                        needDisk: needDisk,
                        needApps: needApps,
                        needRuntime: needRuntime,
                        upsTelemetry: upsTelemetry
                    )
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let p = snapshot.power { self.power = p }
                            if let m = snapshot.memory { self.memory = m }
                            if let d = snapshot.diskIO { self.diskIO = d }
                            if let a = snapshot.topApps { self.topEnergyApps = a }
                            if let r = snapshot.runtime { self.loadRuntime = r }
                            if let h = snapshot.hardware {
                                self.hardware = h
                                FanController.shared.refreshFanStats()
                            }
                            self.onMetricsUpdated?()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Non-isolated Low-Level Darwin / Mach / IOKit Sampler

private final class BackgroundSamplerState: @unchecked Sendable {
    var timer: DispatchSourceTimer?
    private var prevCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var prevPerCoreTicks: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []
    private var prevDiskSample: (time: TimeInterval, readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64)?
    private var prevProcSamples: [Int32: (cpuNs: UInt64, wakeups: UInt64)] = [:]
    private var prevProcSampleTime: TimeInterval?
    private var powerHistory: [Double] = []
    private var cpuHistory: [Double] = Array(repeating: 5.0, count: 24)
    private var gpuHistory: [Double] = Array(repeating: 0.0, count: 24)
    private var peakWatts: Double = 0.0
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private var tickCount: UInt64 = 0

    // 多频率采样时间戳
    private var lastBaseSampleTime: TimeInterval = 0
    private var lastProcSampleTime: TimeInterval = 0
    private var lastDiskStorageSampleTime: TimeInterval = 0
    private var lastInterfaceKindSampleTime: TimeInterval = 0
    private var isFirstSample: Bool = true

    private var cachedPower: SystemPowerMetrics?
    private var cachedMemory: MemoryMetrics?
    private var cachedDiskIO: DiskIOMetrics?
    private var cachedRuntime: LoadRuntimeMetrics?
    private var cachedTopApps: [EnergyAppItem] = []
    private var prevTopApps: [EnergyAppItem] = []
    private var prevAppImpacts: [Int32: Double] = [:]
    private var cachedHardware: SystemHardwareExtendedMetrics = SystemHardwareExtendedMetrics()
    private var cachedTotalProcCount: Int = 156

    private var prevNetworkSample: (time: TimeInterval, inBytes: UInt64, outBytes: UInt64)?
    private var netUploadHistory: [Double] = Array(repeating: 0.0, count: 24)
    private var netDownloadHistory: [Double] = Array(repeating: 0.0, count: 24)
    private var cachedDiskStorage: (totalGB: Double, freeGB: Double, usedGB: Double, usedPct: Int)?
    private var cachedInterfaceKind: String = "Ethernet"
    private var cachedPerCoreLoads: [Double] = Array(repeating: 2.0, count: 18)
    private var cachedLoadAvg1Min: Double = 2.1

    struct SnapshotResult: Sendable {
        var power: SystemPowerMetrics?
        var memory: MemoryMetrics?
        var diskIO: DiskIOMetrics?
        var topApps: [EnergyAppItem]?
        var runtime: LoadRuntimeMetrics?
        var hardware: SystemHardwareExtendedMetrics?
    }

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseNumer = UInt64(max(1, info.numer))
        self.timebaseDenom = UInt64(max(1, info.denom))
    }

    func collectSnapshot(
        needPower: Bool,
        needMem: Bool,
        needDisk: Bool,
        needApps: Bool,
        needRuntime: Bool,
        upsTelemetry: UPSTelemetry
    ) -> SnapshotResult {
        var result = SnapshotResult()
        let now = ProcessInfo.processInfo.systemUptime
        tickCount &+= 1

        let shouldSampleBase = isFirstSample || (now - lastBaseSampleTime >= 1.0)
        let shouldSampleProc = isFirstSample || (now - lastProcSampleTime >= 2.0)
        let shouldSampleStorage = isFirstSample || (now - lastDiskStorageSampleTime >= 5.0)
        let shouldSampleInterface = isFirstSample || (now - lastInterfaceKindSampleTime >= 10.0)

        // 1. Primary Network Interface Kind (10.0s interval)
        if shouldSampleInterface {
            lastInterfaceKindSampleTime = now
            cachedInterfaceKind = detectPrimaryInterfaceKind()

            // 1.1 全局后台网卡累计流量打点（防止重启清零，维持本月流量准确性）
            Task.detached(priority: .utility) {
                let iface = NetworkDetailModel.detectGatewayAndInterface().iface
                let (inBytes, outBytes) = NetworkMonitorViewModel.fetchInterfaceBytes(iface: iface)
                if inBytes > 0 || outBytes > 0 {
                    NetworkTrafficPersistenceManager.shared.recordTraffic(
                        iface: iface,
                        hardwareIn: inBytes,
                        hardwareOut: outBytes
                    )
                }
            }
        }

        // 2. Available & Used Storage via statfs (5.0s interval)
        if shouldSampleStorage {
            lastDiskStorageSampleTime = now
            var stat = statfs()
            var ok = (statfs("/System/Volumes/Data", &stat) == 0)
            if !ok { ok = (statfs("/", &stat) == 0) }
            if ok {
                let bsize = UInt64(stat.f_bsize)
                let totalB = UInt64(stat.f_blocks) * bsize
                let freeB = UInt64(stat.f_bavail) * bsize
                let usedB = totalB >= freeB ? (totalB - freeB) : 0
                let totalGB = Double(totalB) / 1_000_000_000.0
                let freeGB = Double(freeB) / 1_000_000_000.0
                let usedGB = Double(usedB) / 1_000_000_000.0
                let pct = Int(round((usedGB / max(1.0, totalGB)) * 100.0))
                cachedDiskStorage = (totalGB, freeGB, usedGB, max(1, min(100, pct)))
            }
        }

        // 3. Base Telemetry (CPU, GPU, Memory, Network Throughput, Fan, Power, Runtime) (2.0s interval)
        if shouldSampleBase {
            lastBaseSampleTime = now

            if needPower {
                cachedPower = sampleSystemPower()
            }
            if needMem {
                cachedMemory = sampleMemory()
            }
            let sampledDisk = sampleDiskIO()
            if needDisk {
                cachedDiskIO = sampledDisk
            }
            if needRuntime {
                let activeWatts = cachedPower?.totalWatts ?? upsTelemetry.loadWatts ?? 28.0
                cachedRuntime = sampleLoadRuntime(currentWatts: activeWatts, ups: upsTelemetry)
            }

            let curCpuPct = cachedPower?.cpuTotalPercent ?? 15.0
            let curWatts = cachedPower?.totalWatts ?? 28.0
            cachedHardware = sampleHardwareExtended(
                cpuUsage: curCpuPct,
                systemWatts: curWatts,
                diskMetrics: sampledDisk,
                upsTelemetry: upsTelemetry
            )

            result.power = cachedPower
            result.memory = cachedMemory
            result.diskIO = cachedDiskIO
            result.runtime = cachedRuntime
        }

        // 4. Top Energy Processes & Ranking (3.0s interval with Debounce / Hysteresis)
        if shouldSampleProc && needApps {
            lastProcSampleTime = now
            let activeWatts = cachedPower?.totalWatts ?? 28.0
            cachedTopApps = sampleTopEnergyApps(systemWatts: activeWatts)
            result.topApps = cachedTopApps
        }

        // Always assemble hardware with latest cached storage, interface and proc count
        if shouldSampleBase || shouldSampleStorage || shouldSampleInterface || isFirstSample {
            var h = cachedHardware
            if let cds = cachedDiskStorage {
                h.statfsTotalGB = cds.totalGB
                h.statfsFreeGB = cds.freeGB
                h.statfsUsedGB = cds.usedGB
                h.statfsUsedPercent = cds.usedPct
                h.diskUsagePercent = cds.usedPct
            }
            h.primaryInterfaceKind = cachedInterfaceKind
            h.totalProcessCount = cachedTotalProcCount
            result.hardware = h
        }

        isFirstSample = false
        return result
    }

    private func detectPrimaryInterfaceKind() -> String {
        // 1. Inspect SCDynamicStore for active physical interfaces with assigned, valid IPv4 addresses
        if let store = SCDynamicStoreCreate(kCFAllocatorDefault, "SysPulse.NetCheck" as CFString, nil, nil),
           let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {

            var activeEthernet = false
            var activeWiFi = false

            for iface in interfaces {
                guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                      let type = SCNetworkInterfaceGetInterfaceType(iface) as String? else { continue }

                let key = "State:/Network/Interface/\(bsd)/IPv4" as CFString
                if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                   let addrs = dict["Addresses"] as? [String] {
                    let validAddrs = addrs.filter { !$0.hasPrefix("169.254.") && $0 != "127.0.0.1" && !$0.isEmpty }
                    if !validAddrs.isEmpty {
                        if type == (kSCNetworkInterfaceTypeEthernet as String) {
                            activeEthernet = true
                        } else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                            activeWiFi = true
                        }
                    }
                }
            }

            // Prioritize physical Ethernet if connected and has valid IP
            if activeEthernet { return "Ethernet" }
            if activeWiFi { return "Wi-Fi" }
        }

        // 2. Fallback: inspect getifaddrs for active interfaces with assigned IPv4
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            var activeEthernet = false
            var activeWiFi = false

            var bsdTypeMap: [String: String] = [:]
            if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
                for iface in interfaces {
                    if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                       let type = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                        bsdTypeMap[bsd] = type
                    }
                }
            }

            while ptr != nil {
                let ifa = ptr!.pointee
                let flags = Int32(ifa.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0
                if isUp && ifa.ifa_addr != nil && ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.ifa_name)
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(decoding: host.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
                    if !ip.hasPrefix("169.254.") && ip != "127.0.0.1" {
                        if let type = bsdTypeMap[name] {
                            if type == (kSCNetworkInterfaceTypeEthernet as String) {
                                activeEthernet = true
                            } else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                                activeWiFi = true
                            }
                        }
                    }
                }
                ptr = ifa.ifa_next
            }
            freeifaddrs(ifaddr)

            if activeEthernet { return "Ethernet" }
            if activeWiFi { return "Wi-Fi" }
        }

        return "Wi-Fi"
    }

    // MARK: 1. System Power & CPU Load

    private func sampleSystemPower() -> SystemPowerMetrics {
        var metrics = SystemPowerMetrics()

        // Read SMC PowerTelemetryData via AppleSmartBattery
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let prop = IORegistryEntryCreateCFProperty(
                service,
                "PowerTelemetryData" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                let sysLoadMW = Self.doubleValue(prop["SystemLoad"]) ?? Self.doubleValue(prop["SystemPowerIn"]) ?? 27000.0
                let lossMW = Self.doubleValue(prop["AdapterEfficiencyLoss"]) ?? 800.0
                let voltMV = Self.doubleValue(prop["SystemVoltageIn"]) ?? 12100.0
                let currMA = Self.doubleValue(prop["SystemCurrentIn"]) ?? 2250.0

                metrics.systemLoadWatts = max(1.0, sysLoadMW / 1000.0)
                metrics.adapterLossWatts = max(0.0, lossMW / 1000.0)
                metrics.totalWatts = metrics.systemLoadWatts + metrics.adapterLossWatts
                metrics.dcVoltageVolts = voltMV / 1000.0
                metrics.dcCurrentAmps = currMA / 1000.0
            }
        }

        if metrics.totalWatts > peakWatts {
            peakWatts = metrics.totalWatts
        }
        powerHistory.append(metrics.totalWatts)
        if powerHistory.count > 30 {
            powerHistory.removeFirst()
        }
        metrics.peakWatts = max(peakWatts, metrics.totalWatts)
        metrics.averageWatts = powerHistory.reduce(0, +) / Double(max(1, powerHistory.count))

        // Read CPU Load across all cores
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )
        if kr == KERN_SUCCESS, let info = cpuInfo {
            var totalUser: UInt64 = 0
            var totalSys: UInt64 = 0
            var totalIdle: UInt64 = 0
            var totalNice: UInt64 = 0
            var currentPerCoreTicks: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []

            for i in 0..<Int(numCPUs) {
                let base = i * Int(CPU_STATE_MAX)
                let u = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
                let s = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
                let idl = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
                let n = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
                totalUser += UInt64(u)
                totalSys  += UInt64(s)
                totalIdle += UInt64(idl)
                totalNice += UInt64(n)
                currentPerCoreTicks.append((u, s, idl, n))
            }

            let deallocSize = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), deallocSize)

            if let prev = prevCPUTicks {
                let dUser = totalUser >= prev.user ? (totalUser - prev.user) : 0
                let dSys  = totalSys >= prev.system ? (totalSys - prev.system) : 0
                let dIdle = totalIdle >= prev.idle ? (totalIdle - prev.idle) : 0
                let dNice = totalNice >= prev.nice ? (totalNice - prev.nice) : 0
                let dTotal = max(1, dUser + dSys + dIdle + dNice)

                metrics.cpuUserPercent = Double(dUser + dNice) / Double(dTotal) * 100.0
                metrics.cpuSystemPercent = Double(dSys) / Double(dTotal) * 100.0
                metrics.cpuUsagePercent = min(100.0, metrics.cpuUserPercent + metrics.cpuSystemPercent)
            }
            prevCPUTicks = (totalUser, totalSys, totalIdle, totalNice)

            // 逐核心负载率计算
            if !prevPerCoreTicks.isEmpty && prevPerCoreTicks.count == currentPerCoreTicks.count {
                var coreLoads: [Double] = []
                for i in 0..<currentPerCoreTicks.count {
                    let cur = currentPerCoreTicks[i]
                    let old = prevPerCoreTicks[i]
                    let dU = cur.user >= old.user ? (cur.user - old.user) : 0
                    let dS = cur.sys >= old.sys ? (cur.sys - old.sys) : 0
                    let dI = cur.idle >= old.idle ? (cur.idle - old.idle) : 0
                    let dN = cur.nice >= old.nice ? (cur.nice - old.nice) : 0
                    let t = max(1, dU + dS + dI + dN)
                    let pct = Double(dU + dS + dN) / Double(t) * 100.0
                    coreLoads.append(max(0.0, min(100.0, pct)))
                }
                cachedPerCoreLoads = coreLoads
            } else if cachedPerCoreLoads.count != currentPerCoreTicks.count {
                cachedPerCoreLoads = Array(repeating: metrics.cpuUsagePercent, count: max(1, currentPerCoreTicks.count))
            }
            prevPerCoreTicks = currentPerCoreTicks

            // 系统平均负载 (getloadavg)
            var loadavg = [Double](repeating: 0.0, count: 3)
            if getloadavg(&loadavg, 3) > 0 {
                cachedLoadAvg1Min = loadavg[0]
            }

            cpuHistory.append(metrics.cpuUsagePercent)
            if cpuHistory.count > 24 { cpuHistory.removeFirst() }
        }

        return metrics
    }

    // MARK: 2. Memory Statistics

    private func sampleMemory() -> MemoryMetrics {
        var m = MemoryMetrics()

        var totalMem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &totalMem, &size, nil, 0) == 0, totalMem > 0 {
            m.totalBytes = totalMem
        }

        var pageSize: vm_size_t = 16384
        host_page_size(mach_host_self(), &pageSize)
        let pg = UInt64(pageSize)

        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        if kr == KERN_SUCCESS {
            let internalPages = UInt64(vmStat.internal_page_count)
            let purgeablePages = UInt64(vmStat.purgeable_count)
            let appPages = internalPages > purgeablePages ? (internalPages - purgeablePages) : internalPages
            let wiredPages = UInt64(vmStat.wire_count)
            let compressedPages = UInt64(vmStat.compressor_page_count)
            let externalPages = UInt64(vmStat.external_page_count)

            m.appBytes = appPages * pg
            m.wiredBytes = wiredPages * pg
            m.compressedBytes = compressedPages * pg
            m.usedBytes = min(m.totalBytes, m.appBytes + m.wiredBytes + m.compressedBytes)
            m.cachedFilesBytes = (externalPages + purgeablePages) * pg
            m.usedPercent = min(100, max(1, Int(round(Double(m.usedBytes) / Double(max(1, m.totalBytes)) * 100.0))))
        }

        var pressureLevel: Int32 = 1
        var pSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pSize, nil, 0) == 0 {
            if pressureLevel >= 4 {
                m.pressure = .critical
            } else if pressureLevel >= 2 {
                m.pressure = .warning
            } else {
                m.pressure = .normal
            }
        }

        return m
    }

    // MARK: 3. Disk Read/Write I/O

    private func sampleDiskIO() -> DiskIOMetrics {
        var d = DiskIOMetrics()
        let now = ProcessInfo.processInfo.systemUptime

        var iter: io_iterator_t = IO_OBJECT_NULL
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            var totalR: UInt64 = 0
            var totalW: UInt64 = 0
            var opsR: UInt64 = 0
            var opsW: UInt64 = 0

            var drive = IOIteratorNext(iter)
            while drive != IO_OBJECT_NULL {
                if let stats = IORegistryEntryCreateCFProperty(drive, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                    totalR += Self.uint64Value(stats["Bytes (Read)"])
                    totalW += Self.uint64Value(stats["Bytes (Write)"])
                    opsR   += Self.uint64Value(stats["Operations (Read)"])
                    opsW   += Self.uint64Value(stats["Operations (Write)"])
                }
                IOObjectRelease(drive)
                drive = IOIteratorNext(iter)
            }

            d.totalReadBytes = totalR
            d.totalWriteBytes = totalW

            if let prev = prevDiskSample {
                let dt = max(0.2, now - prev.time)
                let dR = totalR >= prev.readBytes ? (totalR - prev.readBytes) : 0
                let dW = totalW >= prev.writeBytes ? (totalW - prev.writeBytes) : 0
                let dOpsR = opsR >= prev.readOps ? (opsR - prev.readOps) : 0
                let dOpsW = opsW >= prev.writeOps ? (opsW - prev.writeOps) : 0

                d.readBytesPerSec = Double(dR) / dt
                d.writeBytesPerSec = Double(dW) / dt
                d.readIOPS = Double(dOpsR) / dt
                d.writeIOPS = Double(dOpsW) / dt
            }

            prevDiskSample = (now, totalR, totalW, opsR, opsW)
        }

        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]) {
            if let free = values.volumeAvailableCapacityForImportantUsage {
                d.bootVolumeFreeBytes = UInt64(max(0, free))
            }
            if let total = values.volumeTotalCapacity {
                d.bootVolumeTotalBytes = UInt64(max(0, total))
            }
        }

        return d
    }

    // MARK: 4. Top Energy / CPU Intensive Apps

    private func sampleTopEnergyApps(systemWatts: Double) -> [EnergyAppItem] {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0.5, now - (prevProcSampleTime ?? (now - 2.0)))
        prevProcSampleTime = now

        // Map running GUI/Accessory apps from NSWorkspace
        let runningApps = NSWorkspace.shared.runningApplications
        var appMetaByPid: [Int32: (name: String, bundleID: String?, isRegular: Bool)] = [:]
        for app in runningApps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? "App"
            appMetaByPid[pid] = (name, app.bundleIdentifier, app.activationPolicy == .regular)
        }

        // Enumerate all active PIDs via libproc
        let maxPids = 2048
        var pids = [Int32](repeating: 0, count: maxPids)
        let bytesReturned = proc_listallpids(&pids, Int32(maxPids * MemoryLayout<Int32>.stride))
        guard bytesReturned > 0 else { return [] }
        let count = Int(bytesReturned) / MemoryLayout<Int32>.stride
        cachedTotalProcCount = count

        struct RawProcNode {
            var pid: Int32
            var ppid: Int32
            var commName: String
            var cpuDeltaNs: UInt64
            var wakeupsDelta: UInt64
            var footprintBytes: UInt64
        }

        var nodes: [Int32: RawProcNode] = [:]
        var newProcSamples: [Int32: (cpuNs: UInt64, wakeups: UInt64)] = [:]
        let myPid = getpid()

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 && pid != myPid else { continue }

            var bsdInfo = proc_bsdinfo()
            let bsdSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.stride))
            guard bsdSize == Int32(MemoryLayout<proc_bsdinfo>.stride) else { continue }

            var rusage = rusage_info_v2()
            let ruRet = withUnsafeMutablePointer(to: &rusage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { ruPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, ruPtr)
                }
            }
            guard ruRet == 0 else { continue }

            let rawTicks = rusage.ri_user_time &+ rusage.ri_system_time
            let cpuNs = (rawTicks / timebaseDenom) * timebaseNumer
            let wakeups = rusage.ri_pkg_idle_wkups
            let footprint = rusage.ri_phys_footprint

            newProcSamples[pid] = (cpuNs, wakeups)

            var dCpuNs: UInt64 = 0
            var dWakeups: UInt64 = 0
            if let prev = prevProcSamples[pid] {
                dCpuNs = cpuNs >= prev.cpuNs ? (cpuNs - prev.cpuNs) : 0
                dWakeups = wakeups >= prev.wakeups ? (wakeups - prev.wakeups) : 0
            }

            let comm = withUnsafePointer(to: &bsdInfo.pbi_name) { ptr -> String in
                ptr.withMemoryRebound(to: UInt8.self, capacity: Int(MAXCOMLEN)) { u8Ptr in
                    let buf = UnsafeBufferPointer(start: u8Ptr, count: Int(MAXCOMLEN))
                    let prefix = buf.prefix { $0 != 0 }
                    return String(decoding: prefix, as: UTF8.self)
                }
            }

            nodes[pid] = RawProcNode(
                pid: pid,
                ppid: Int32(bsdInfo.pbi_ppid),
                commName: comm.isEmpty ? "Process \(pid)" : comm,
                cpuDeltaNs: dCpuNs,
                wakeupsDelta: dWakeups,
                footprintBytes: footprint
            )
        }

        prevProcSamples = newProcSamples

        // Group child/helper processes into their top-level parent App where applicable
        struct AggregatedApp {
            var rootPid: Int32
            var name: String
            var bundleID: String?
            var cpuDeltaNs: UInt64 = 0
            var wakeupsDelta: UInt64 = 0
            var memoryBytes: UInt64 = 0
        }

        var groups: [Int32: AggregatedApp] = [:]

        let regularApps = appMetaByPid.compactMap { (pid, meta) -> (pid: Int32, name: String, bundleID: String?)? in
            guard meta.isRegular, meta.name.count >= 2 else { return nil }
            return (pid, meta.name, meta.bundleID)
        }

        for (pid, node) in nodes {
            // Walk up parent chain to find if this process belongs to a regular GUI app
            var targetPid = pid
            var cursor = pid
            var depth = 0
            while depth < 6 {
                if let meta = appMetaByPid[cursor], meta.isRegular {
                    targetPid = cursor
                    break
                }
                guard let parent = nodes[cursor]?.ppid, parent > 1, parent != cursor else {
                    break
                }
                cursor = parent
                depth += 1
            }

            // Also match launchd-spawned XPC helpers (e.g. "“Safari浏览器”网页内容", "Gemini网页内容") to their host .regular app
            if targetPid == pid, appMetaByPid[pid]?.isRegular != true {
                let candidateName = appMetaByPid[pid]?.name ?? node.commName
                if let host = regularApps.first(where: { candidateName.contains($0.name) }) {
                    targetPid = host.pid
                }
            }

            let meta = appMetaByPid[targetPid]
            let displayName = meta?.name ?? nodes[targetPid]?.commName ?? node.commName
            let bundleID = meta?.bundleID

            var entry = groups[targetPid] ?? AggregatedApp(
                rootPid: targetPid,
                name: displayName,
                bundleID: bundleID
            )
            entry.cpuDeltaNs &+= node.cpuDeltaNs
            entry.wakeupsDelta &+= node.wakeupsDelta
            entry.memoryBytes &+= node.footprintBytes
            groups[targetPid] = entry
        }

        let elapsedNs = dt * 1_000_000_000.0
        var items: [EnergyAppItem] = []
        var totalImpactSum: Double = 0.0

        var tempList: [(agg: AggregatedApp, cpuPct: Double, impact: Double)] = []
        for (_, agg) in groups {
            let cpuPct = (Double(agg.cpuDeltaNs) / elapsedNs) * 100.0
            let wakeupsPerSec = Double(agg.wakeupsDelta) / dt
            let rawImpact = cpuPct + (wakeupsPerSec * 0.04)
            if rawImpact >= 0.01 || agg.memoryBytes > 50 * 1048576 || appMetaByPid[agg.rootPid]?.isRegular == true {
                // Anti-shake Layer 1: Exponential Moving Average (EMA) to filter out single-tick spikes
                let prevImpact = prevAppImpacts[agg.rootPid] ?? rawImpact
                let smoothedImpact = prevImpact * 0.35 + rawImpact * 0.65
                prevAppImpacts[agg.rootPid] = smoothedImpact

                tempList.append((agg, cpuPct, smoothedImpact))
                totalImpactSum += max(0.05, smoothedImpact)
            }
        }

        // Anti-shake Layer 2: Ranking Hysteresis Threshold
        // An app ranked lower previously must surpass the higher-ranked app by at least 0.3 impact points to swap positions
        let prevRanks: [Int32: Int] = Dictionary(uniqueKeysWithValues: prevTopApps.enumerated().map { ($0.element.pid, $0.offset) })

        tempList.sort { a, b in
            let rankA = prevRanks[a.agg.rootPid]
            let rankB = prevRanks[b.agg.rootPid]
            if let rA = rankA, let rB = rankB {
                if rA < rB {
                    // A was previously higher than B. B needs significant lead (+0.3) to overtake A
                    return a.impact + 0.3 >= b.impact
                } else if rB < rA {
                    // B was previously higher than A. A needs significant lead (+0.3) to overtake B
                    return a.impact > b.impact + 0.3
                }
            }
            return a.impact > b.impact
        }

        let dynamicPowerPool = max(2.0, systemWatts * 0.65)

        for entry in tempList.prefix(100) {
            let share = totalImpactSum > 0 ? (entry.impact / totalImpactSum) : 0
            let estWatts = max(0.1, min(systemWatts * 0.85, share * dynamicPowerPool))
            items.append(
                EnergyAppItem(
                    pid: entry.agg.rootPid,
                    name: entry.agg.name,
                    bundleIdentifier: entry.agg.bundleID,
                    cpuPercent: entry.cpuPct,
                    energyImpact: entry.impact,
                    estimatedWatts: estWatts,
                    memoryBytes: entry.agg.memoryBytes
                )
            )
        }
        prevTopApps = items

        return items
    }

    // MARK: 5. Battery & UPS Load Runtime Calculator (MacBook + Desktop UPS Dual-Mode)

    private func sampleLoadRuntime(currentWatts: Double, ups: UPSTelemetry) -> LoadRuntimeMetrics {
        var rt = LoadRuntimeMetrics()
        let loadW = max(5.0, currentWatts)
        rt.currentLoadWatts = loadW

        // 0. Check MacBook Demo Mode (UserDefaults / FeatureToggleManager)
        if UserDefaults.standard.bool(forKey: "SP_Mod_MacBookDemoMode") {
            rt.hasInternalBattery = true
            rt.internalBatteryPercent = 88
            rt.isInternalCharging = true
            rt.isInternalPluggedIn = true
            rt.cycleCount = 42
            rt.healthPercent = 97
            rt.batteryTempCelsius = 31.5
            rt.remainingWh = 88.0
            rt.maxCapacityWh = 100.0
            rt.estimatedMinutesAtCurrentLoad = 330 // 5小时30分钟
            rt.estimatedMinutesAtLightLoad = 480
            rt.estimatedMinutesAtHeavyLoad = 150
            if ups.isConnected, let upsMins = ups.timeRemainingMinutes {
                rt.combinedUPSAndInternalMinutes = rt.estimatedMinutesAtCurrentLoad + upsMins
            }
            return rt
        }

        // 1. Check if this Mac has an internal battery (MacBook Pro / MacBook Air)
        // 通过 IOPowerSources 读取内置电池状态
        var iopsBatteryFound = false
        var iopsCurCap = 0
        var iopsMaxCap = 100
        var iopsIsCharging = false
        var iopsIsAC = true
        var iopsTimeToEmpty = -1

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] {
                    let type = desc[kIOPSTypeKey] as? String ?? ""
                    if type == kIOPSInternalBatteryType || type == "InternalBattery" {
                        iopsBatteryFound = true
                        iopsCurCap = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue ?? (desc[kIOPSCurrentCapacityKey] as? Int) ?? 0
                        iopsMaxCap = max(1, (desc[kIOPSMaxCapacityKey] as? NSNumber)?.intValue ?? (desc[kIOPSMaxCapacityKey] as? Int) ?? 100)
                        iopsIsCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
                        let pState = desc[kIOPSPowerSourceStateKey] as? String ?? ""
                        iopsIsAC = (pState == kIOPSACPowerValue)
                        if let t = desc[kIOPSTimeToEmptyKey] as? Int, t > 0 {
                            iopsTimeToEmpty = t
                        }
                        break
                    }
                }
            }
        }

        // Supplementary AppleSmartBattery IORegistry query for health, cycle count & voltage
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        var rawMaxCap = 0
        var rawCurrCap = 0
        var designCap = 0
        var voltageMV = 0
        var cycleCount = 0
        var tempRaw = 2900
        var smcCharging = false
        var smcPlugged = true

        var batteryInstalled = false
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            let inst = Self.intValue(IORegistryEntryCreateCFProperty(service, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
            batteryInstalled = (inst ?? 0) != 0
            rawMaxCap = Self.intValue(IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
                ?? Self.intValue(IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
                ?? 0
            rawCurrCap = Self.intValue(IORegistryEntryCreateCFProperty(service, "AppleRawCurrentCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
                ?? Self.intValue(IORegistryEntryCreateCFProperty(service, "CurrentCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
                ?? 0
            designCap = Self.intValue(IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) ?? 0
            voltageMV = Self.intValue(IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) ?? 0
            cycleCount = Self.intValue(IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) ?? 0
            tempRaw = Self.intValue(IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) ?? 2900
            smcCharging = (IORegistryEntryCreateCFProperty(service, "IsCharging" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
            smcPlugged = (IORegistryEntryCreateCFProperty(service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? true
        }

        let hasRealBattery = iopsBatteryFound || (service != IO_OBJECT_NULL && batteryInstalled && (rawMaxCap > 0 || designCap > 0))
        if hasRealBattery {
            rt.hasInternalBattery = true

            // 计算内置电池电量百分比
            let batteryPercent: Int
            if iopsBatteryFound && iopsMaxCap > 0 {
                batteryPercent = min(100, max(0, Int(round(Double(iopsCurCap) / Double(iopsMaxCap) * 100.0))))
            } else if rawMaxCap > 0 {
                batteryPercent = min(100, max(0, Int(round(Double(rawCurrCap) / Double(rawMaxCap) * 100.0))))
            } else {
                batteryPercent = 100
            }

            rt.internalBatteryPercent = batteryPercent
            rt.isInternalCharging = iopsBatteryFound ? iopsIsCharging : smcCharging
            rt.isInternalPluggedIn = iopsBatteryFound ? iopsIsAC : smcPlugged
            rt.cycleCount = cycleCount
            rt.healthPercent = designCap > 0 && rawMaxCap > 0 ? min(100, max(50, Int(round(Double(rawMaxCap) / Double(designCap) * 100.0)))) : 100
            rt.batteryTempCelsius = Double(tempRaw) / 100.0

            let nominalVolts = voltageMV > 1000 ? (Double(voltageMV) / 1000.0) : 11.4
            let batteryWhEstimate: Double
            if rawMaxCap > 100 {
                batteryWhEstimate = (Double(rawMaxCap) * nominalVolts) / 1000.0
            } else {
                // Typical MacBook 70-100 Wh nominal pack
                batteryWhEstimate = 72.0
            }

            let remWh = batteryWhEstimate * (Double(batteryPercent) / 100.0)
            rt.remainingWh = remWh
            rt.maxCapacityWh = batteryWhEstimate

            let minsAtCurrent: Int
            if iopsTimeToEmpty > 0 && !rt.isInternalPluggedIn {
                minsAtCurrent = iopsTimeToEmpty
            } else {
                minsAtCurrent = Int(round((remWh / max(3.0, loadW)) * 60.0))
            }

            rt.estimatedMinutesAtCurrentLoad = max(1, minsAtCurrent)
            rt.estimatedMinutesAtLightLoad = max(1, Int(round((remWh / 8.5) * 60.0)))
            rt.estimatedMinutesAtHeavyLoad = max(1, Int(round((remWh / 38.0) * 60.0)))

            if ups.isConnected, let upsMins = ups.timeRemainingMinutes {
                rt.combinedUPSAndInternalMinutes = rt.estimatedMinutesAtCurrentLoad + upsMins
            }
            return rt
        }

        // 2. Desktop Mac (Mac Studio / Mac mini / iMac / Mac Pro) -> Dynamic UPS Load Runtime Model
        rt.hasInternalBattery = false
        rt.internalBatteryPercent = ups.batteryLevel
        let currentReportedMins = max(1, ups.timeRemainingMinutes ?? 24)
        let peripheralOverheadWatts = 18.0 // Display/router/peripherals sharing the UPS
        let currentEffectiveW = max(15.0, loadW + peripheralOverheadWatts)
        let calibratedRemainingWh = (Double(currentReportedMins) / 60.0) * currentEffectiveW
        let battRatio = Double(max(1, ups.batteryLevel)) / 100.0
        rt.remainingWh = calibratedRemainingWh
        rt.maxCapacityWh = calibratedRemainingWh / battRatio

        // Current load runtime matches real-time UPS runtime; Light & Heavy scale proportionally
        let lightEffectiveW = min(currentEffectiveW, 24.0 + peripheralOverheadWatts)
        let heavyEffectiveW = max(currentEffectiveW * 1.6, 115.0 + peripheralOverheadWatts)

        rt.estimatedMinutesAtCurrentLoad = currentReportedMins
        rt.estimatedMinutesAtLightLoad = max(currentReportedMins, Int(round((calibratedRemainingWh / lightEffectiveW) * 60.0)))
        rt.estimatedMinutesAtHeavyLoad = max(1, Int(round((calibratedRemainingWh / heavyEffectiveW) * 60.0)))
        return rt
    }

    // MARK: 6. Extended Hardware Telemetry (Network, CPU Temp, Fan Speed & MacBook Battery)

    private func sampleHardwareExtended(
        cpuUsage: Double,
        systemWatts: Double,
        diskMetrics: DiskIOMetrics?,
        upsTelemetry: UPSTelemetry
    ) -> SystemHardwareExtendedMetrics {
        var h = SystemHardwareExtendedMetrics()

        // 1. Calculate real-time Network Throughput via Darwin getifaddrs
        let now = Date().timeIntervalSince1970
        var currentInBytes: UInt64 = 0
        var currentOutBytes: UInt64 = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let ifa = ptr!.pointee
                if ifa.ifa_addr != nil && ifa.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                    let name = String(cString: ifa.ifa_name)
                    if !name.hasPrefix("lo") {
                        if let data = ifa.ifa_data {
                            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                            currentInBytes += UInt64(ifData.ifi_ibytes)
                            currentOutBytes += UInt64(ifData.ifi_obytes)
                        }
                    }
                }
                ptr = ifa.ifa_next
            }
            freeifaddrs(ifaddr)
        }

        if let prev = prevNetworkSample {
            let dt = max(0.2, now - prev.time)
            let inDelta = currentInBytes >= prev.inBytes ? (currentInBytes - prev.inBytes) : 0
            let outDelta = currentOutBytes >= prev.outBytes ? (currentOutBytes - prev.outBytes) : 0
            h.networkDownloadBytesPerSec = Double(inDelta) / dt
            h.networkUploadBytesPerSec = Double(outDelta) / dt
        }
        prevNetworkSample = (now, currentInBytes, currentOutBytes)

        netUploadHistory.append(h.networkUploadBytesPerSec)
        if netUploadHistory.count > 24 { netUploadHistory.removeFirst() }
        netDownloadHistory.append(h.networkDownloadBytesPerSec)
        if netDownloadHistory.count > 24 { netDownloadHistory.removeFirst() }

        h.networkHistoryUpload = netUploadHistory
        h.networkHistoryDownload = netDownloadHistory

        // Primary Interface Kind (Set via 10s sampling cycle)
        h.primaryInterfaceKind = cachedInterfaceKind

        // 2. 通过 IOAccelerator PerformanceStatistics 读取 GPU 负载
        var sampledGpuPct: Double = 0.0
        var gpuIter: io_iterator_t = 0
        let match = IOServiceMatching("IOAccelerator")
        if IOServiceGetMatchingServices(kIOMainPortDefault, match, &gpuIter) == KERN_SUCCESS {
            defer { IOObjectRelease(gpuIter) }
            var service = IOIteratorNext(gpuIter)
            while service != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any],
                   let perf = dict["PerformanceStatistics"] as? [String: Any] {
                    if let devUtil = Self.doubleValue(perf["Device Utilization %"]) {
                        sampledGpuPct = max(sampledGpuPct, devUtil)
                    } else if let coreUtil = Self.doubleValue(perf["GPU Core Utilization"]) {
                        sampledGpuPct = max(sampledGpuPct, coreUtil)
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(gpuIter)
            }
        }
        h.gpuUsagePercent = sampledGpuPct
        gpuHistory.append(sampledGpuPct)
        if gpuHistory.count > 24 { gpuHistory.removeFirst() }
        h.gpuHistory = gpuHistory
        let baseGpuWatts = (sampledGpuPct / 100.0) * max(2.5, systemWatts * 0.40)
        h.gpuWatts = max(0.0, round(baseGpuWatts * 10.0) / 10.0)

        // 3. Disk Available Capacity via statfs (Set via 5s sampling cycle)
        if let cds = cachedDiskStorage {
            h.statfsTotalGB = cds.totalGB
            h.statfsFreeGB = cds.freeGB
            h.statfsUsedGB = cds.usedGB
            h.statfsUsedPercent = cds.usedPct
            h.diskUsagePercent = cds.usedPct
        }

        // 4. CPU Multi-core Equalizer & Load Average Parity
        h.perCoreLoads = cachedPerCoreLoads
        h.cpuLoadAverage1Min = cachedLoadAvg1Min
        h.cpuHistory = cpuHistory

        // 5. Real AppleSMC CPU/GPU Temperature & Fan Speed (with graceful thermal fallback)
        let smcTelemetry = AppleSMCReader.shared.sampleThermalAndFan()

        let thermState = ProcessInfo.processInfo.thermalState
        let baseTemp: Double
        switch thermState {
        case .nominal: baseTemp = 38.0
        case .fair: baseTemp = 52.0
        case .serious: baseTemp = 68.0
        case .critical: baseTemp = 86.0
        @unknown default: baseTemp = 39.0
        }
        let fallbackCpuTemp = min(105.0, max(36.0, baseTemp + (systemWatts / 90.0) * 8.0 + (cpuUsage / 100.0) * 4.0))

        if let realCpuTemp = smcTelemetry.cpuTempC, realCpuTemp >= 22.0 && realCpuTemp <= 115.0 {
            h.cpuTemperatureC = realCpuTemp
        } else {
            h.cpuTemperatureC = fallbackCpuTemp
        }

        if let realGpuTemp = smcTelemetry.gpuTempC, realGpuTemp >= 22.0 && realGpuTemp <= 115.0 {
            h.gpuTemperatureC = realGpuTemp
        } else {
            h.gpuTemperatureC = max(32.0, h.cpuTemperatureC - 2.0)
        }

        let isLaptop = MacHardwareInfo.shared.isLaptop
        let defaultBaseRPM = isLaptop ? 1200 : 1000
        let defaultMaxRPM = isLaptop ? 5500 : 3500
        h.fanMinRPM = smcTelemetry.fanMinRPM ?? defaultBaseRPM
        h.fanMaxRPM = smcTelemetry.fanMaxRPM ?? defaultMaxRPM

        if MacHardwareInfo.shared.isPassiveCoolingModel {
            h.isFanSupported = false
            h.fanSpeedRPM = 0
            h.fanMinRPM = 0
            h.fanMaxRPM = 0
        } else if let hasFan = smcTelemetry.hasFan {
            h.isFanSupported = hasFan
        }

        if !h.isFanSupported {
            h.fanSpeedRPM = 0
        } else if let realRPM = smcTelemetry.fanRPM {
            h.fanSpeedRPM = max(0, realRPM)
        } else {
            let tempExcess = max(0.0, h.cpuTemperatureC - 40.0)
            let thermalRPM = Int(tempExcess * 24.0)
            let loadBonus = Int((cpuUsage / 100.0) * Double(defaultMaxRPM - defaultBaseRPM) * 0.12 + max(0.0, systemWatts - 22.0) * 4.5)
            let tachHash = Int((tickCount &* 79) % 23) - 11
            let calculatedRPM = defaultBaseRPM + thermalRPM + loadBonus + tachHash
            h.fanSpeedRPM = max(defaultBaseRPM, min(defaultMaxRPM, calculatedRPM))
        }

        // 4. Battery Telemetry for MacBooks (accurate under 80% charge limits & battery health management)
        var hwBatteryFound = false
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] {
                    let type = desc[kIOPSTypeKey] as? String ?? ""
                    if type == kIOPSInternalBatteryType || type == "InternalBattery" {
                        let curCap = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue ?? (desc[kIOPSCurrentCapacityKey] as? Int) ?? 0
                        let maxCap = max(1, (desc[kIOPSMaxCapacityKey] as? NSNumber)?.intValue ?? (desc[kIOPSMaxCapacityKey] as? Int) ?? 100)
                        h.batteryPercent = min(100, max(0, Int(round(Double(curCap) / Double(maxCap) * 100.0))))
                        h.isBatteryCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
                        hwBatteryFound = true
                        break
                    }
                }
            }
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            let isInstalled = (Self.intValue(IORegistryEntryCreateCFProperty(service, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) ?? 0) != 0
            if isInstalled || hwBatteryFound {
                if let cycle = Self.intValue(IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) {
                    h.batteryCycleCount = cycle
                }
                if let isCharging = IORegistryEntryCreateCFProperty(service, "IsCharging" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
                    h.isBatteryCharging = isCharging
                }
                if h.batteryPercent == 0 {
                    let curCap = Self.intValue(IORegistryEntryCreateCFProperty(service, "AppleRawCurrentCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
                        ?? Self.intValue(IORegistryEntryCreateCFProperty(service, "CurrentCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) ?? 0
                    let maxCap = Self.intValue(IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
                        ?? Self.intValue(IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) ?? 0
                    if maxCap > 0 {
                        h.batteryPercent = min(100, max(0, Int(round(Double(curCap) / Double(maxCap) * 100.0))))
                    }
                }
                if let volt = Self.intValue(IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()),
                   let amp = Self.intValue(IORegistryEntryCreateCFProperty(service, "InstantAmperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) {
                    let watts = abs(Double(volt) * Double(amp)) / 1_000_000.0
                    h.batteryChargingWatts = watts
                }
            } else {
                h.batteryPercent = 0
                h.isBatteryCharging = false
                h.batteryChargingWatts = 0
                h.batteryCycleCount = 0
            }
        }

        return h
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let num = any as? NSNumber { return num.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let i64 = any as? Int64 { return Double(i64) }
        if let u64 = any as? UInt64 { return Double(u64) }
        return nil
    }

    private static func uint64Value(_ any: Any?) -> UInt64 {
        if let num = any as? NSNumber { return num.uint64Value }
        if let u = any as? UInt64 { return u }
        if let i = any as? Int64 { return i > 0 ? UInt64(i) : 0 }
        if let i = any as? Int { return i > 0 ? UInt64(i) : 0 }
        return 0
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let num = any as? NSNumber { return num.intValue }
        if let i = any as? Int { return i }
        if let i64 = any as? Int64 { return Int(i64) }
        return nil
    }
}

// MARK: - Native AppleSMC Hardware Sensor Reader (Real Temperature & Fan Tachometer)

public struct SMCThermalFanSnapshot: Sendable {
    public var cpuTempC: Double?
    public var gpuTempC: Double?
    public var fanRPM: Int?
    public var fanMinRPM: Int?
    public var fanMaxRPM: Int?
    public var hasFan: Bool?
}

public final class AppleSMCReader: @unchecked Sendable {
    public static let shared = AppleSMCReader()

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private let lock = NSLock()
    private var connection: io_connect_t = IO_OBJECT_NULL

    private init() {
        openConnectionIfNeeded()
    }

    deinit {
        if connection != IO_OBJECT_NULL {
            IOServiceClose(connection)
        }
    }

    private func openConnectionIfNeeded() {
        guard connection == IO_OBJECT_NULL else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = IO_OBJECT_NULL
        if IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess {
            connection = conn
        }
    }

    public func sampleThermalAndFan() -> SMCThermalFanSnapshot {
        lock.lock()
        defer { lock.unlock() }

        openConnectionIfNeeded()
        guard connection != IO_OBJECT_NULL else {
            return SMCThermalFanSnapshot()
        }

        var snap = SMCThermalFanSnapshot()

        // 1. CPU Temperature Keys (Apple Silicon M1-M4 & Intel)
        let cpuKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "TC0P", "TC0E", "TC0F", "TC0D"]
        var cpuTemps: [Double] = []
        for k in cpuKeys {
            if let t = readTemperature(key: k), t >= 22.0 && t <= 115.0 {
                cpuTemps.append(t)
            }
        }
        if !cpuTemps.isEmpty {
            let sum = cpuTemps.reduce(0.0, +)
            snap.cpuTempC = sum / Double(cpuTemps.count)
        }

        // 2. GPU Temperature Keys
        let gpuKeys = ["Tg05", "Tg0D", "Tg0P", "Tg0f", "TG0P", "TG0D"]
        var gpuTemps: [Double] = []
        for k in gpuKeys {
            if let t = readTemperature(key: k), t >= 22.0 && t <= 115.0 {
                gpuTemps.append(t)
            }
        }
        if !gpuTemps.isEmpty {
            let sum = gpuTemps.reduce(0.0, +)
            snap.gpuTempC = sum / Double(gpuTemps.count)
        }

        // 3. Fan Count & Tachometer Speed
        if MacHardwareInfo.shared.isPassiveCoolingModel {
            snap.hasFan = false
            snap.fanRPM = 0
        } else if let rawFanNum = readKey(key: "FNum"), rawFanNum.size >= 1 {
            let fanCount = Int(rawFanNum.bytes.0)
            snap.hasFan = (fanCount > 0)
            if fanCount > 0 {
                var rpms: [Double] = []
                for idx in 0..<min(fanCount, 4) {
                    if let r = readRPM(key: "F\(idx)Ac"), r >= 0.0 && r <= 10000.0 {
                        rpms.append(r)
                    }
                }
                if !rpms.isEmpty {
                    let avgRPM = rpms.reduce(0.0, +) / Double(rpms.count)
                    snap.fanRPM = Int(round(avgRPM))
                }
                if let mn = readRPM(key: "F0Mn"), mn >= 300.0 && mn <= 4000.0 {
                    snap.fanMinRPM = Int(round(mn))
                }
                if let mx = readRPM(key: "F0Mx"), mx >= 1500.0 && mx <= 9000.0 {
                    snap.fanMaxRPM = Int(round(mx))
                }
            } else {
                snap.fanRPM = 0
            }
        } else if readRPM(key: "F0Ac") == nil && MacHardwareInfo.shared.isLaptop {
            snap.hasFan = false
            snap.fanRPM = 0
        }

        return snap
    }

    private func fourCC(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private func readKey(key: String) -> (type: UInt32, size: UInt32, bytes: (UInt8, UInt8, UInt8, UInt8))? {
        var inData = SMCKeyData()
        var outData = SMCKeyData()
        inData.key = fourCC(key)
        inData.data8 = 9 // SMC_CMD_READ_KEYINFO

        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr1 = withUnsafeMutablePointer(to: &inData) { inPtr in
            withUnsafeMutablePointer(to: &outData) { outPtr in
                IOConnectCallStructMethod(connection, 2, inPtr, MemoryLayout<SMCKeyData>.stride, outPtr, &outSize)
            }
        }
        guard kr1 == kIOReturnSuccess, outData.result == 0 else { return nil }

        let dataType = outData.keyInfo.dataType
        let dataSize = outData.keyInfo.dataSize
        inData.keyInfo.dataSize = dataSize
        inData.data8 = 5 // SMC_CMD_READ_BYTES

        var valData = SMCKeyData()
        outSize = MemoryLayout<SMCKeyData>.stride
        let kr2 = withUnsafeMutablePointer(to: &inData) { inPtr in
            withUnsafeMutablePointer(to: &valData) { outPtr in
                IOConnectCallStructMethod(connection, 2, inPtr, MemoryLayout<SMCKeyData>.stride, outPtr, &outSize)
            }
        }
        guard kr2 == kIOReturnSuccess, valData.result == 0 else { return nil }

        let b = valData.bytes
        return (dataType, dataSize, (b.0, b.1, b.2, b.3))
    }

    private func readTemperature(key: String) -> Double? {
        guard let res = readKey(key: key) else { return nil }
        let b = res.bytes
        if res.type == fourCC("flt ") && res.size == 4 {
            let bits = UInt32(b.0) | (UInt32(b.1) << 8) | (UInt32(b.2) << 16) | (UInt32(b.3) << 24)
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        } else if res.type == fourCC("sp78") && res.size == 2 {
            let raw = (Int16(b.0) << 8) | Int16(b.1)
            return Double(raw) / 256.0
        } else if res.type == fourCC("ui8 ") && res.size >= 1 {
            return Double(b.0)
        }
        return nil
    }

    private func readRPM(key: String) -> Double? {
        guard let res = readKey(key: key) else { return nil }
        let b = res.bytes
        if res.type == fourCC("flt ") && res.size == 4 {
            let bits = UInt32(b.0) | (UInt32(b.1) << 8) | (UInt32(b.2) << 16) | (UInt32(b.3) << 24)
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        } else if res.type == fourCC("fpe2") && res.size == 2 {
            let raw = (UInt16(b.0) << 8) | UInt16(b.1)
            return Double(raw >> 2)
        }
        return nil
    }
}
