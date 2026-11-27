import Foundation
import IOKit

/// CPU 核心性能等级拓扑（适配 M1-M4 Performance/Efficiency、M5 Max Super/Performance 及三簇架构）
public struct CoreTopology: Sendable, Equatable {
    public let level0Name: String
    public let level0Count: Int
    public let level1Name: String
    public let level1Count: Int
    public let level2Name: String
    public let level2Count: Int

    public init(
        level0Name: String,
        level0Count: Int,
        level1Name: String,
        level1Count: Int,
        level2Name: String = "",
        level2Count: Int = 0
    ) {
        self.level0Name = level0Name
        self.level0Count = level0Count
        self.level1Name = level1Name
        self.level1Count = level1Count
        self.level2Name = level2Name
        self.level2Count = level2Count
    }

    public var hasDualTier: Bool {
        level0Count > 0 && level1Count > 0
    }

    public var hasTripleTier: Bool {
        level0Count > 0 && level1Count > 0 && level2Count > 0
    }

    public var totalCores: Int {
        max(1, level0Count + level1Count + level2Count)
    }

    public var primaryTierDisplayName: String {
        Self.localizedTierName(level0Name, fallback: "高性能核")
    }

    public var secondaryTierDisplayName: String {
        Self.localizedTierName(level1Name, fallback: "能效/性能核")
    }

    public var tertiaryTierDisplayName: String {
        Self.localizedTierName(level2Name, fallback: "能效核")
    }

    public var legendText: String {
        if hasTripleTier {
            return "\(level0Count) \(primaryTierDisplayName) · \(level1Count) \(secondaryTierDisplayName) · \(level2Count) \(tertiaryTierDisplayName)"
        }
        guard hasDualTier else {
            return "\(totalCores) 核心"
        }
        return "\(level0Count) \(primaryTierDisplayName) · \(level1Count) \(secondaryTierDisplayName)"
    }

    /// 左侧展示高主频主核心簇（如 Super 超级核，0..<level0Count），右侧展示次级核心簇（如 Performance / Efficiency）
    public func isPrimaryTierCore(at index: Int, coreCount: Int) -> Bool {
        guard hasDualTier, coreCount == level0Count + level1Count + level2Count else {
            return true
        }
        return index < level0Count
    }

    private static func localizedTierName(_ raw: String, fallback: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "super":
            return "超级核"
        case "performance":
            return "性能核"
        case "efficiency":
            return "能效核"
        default:
            return raw.isEmpty ? fallback : raw
        }
    }
}

/// Dynamically queries the host Mac's hardware model and Apple Silicon / CPU chip name via IOKit & sysctl.
public struct MacHardwareInfo: Sendable {
    public static let shared = MacHardwareInfo()

    public let platformName: String
    public let modelIdentifier: String
    public let chipBrand: String
    public let osVersion: String
    public let osBuild: String
    public let coreTopology: CoreTopology
    public let gpuCoreCount: Int

    /// Full macOS display string (e.g. "macOS 27.2.1").
    public var macOSDisplayString: String {
        "macOS \(osVersion)"
    }

    /// 版本与编译号组合（如 "27.2.1 (26B131)"）
    public var osVersionWithBuild: String {
        osBuild == "Unknown" ? osVersion : "\(osVersion) (\(osBuild))"
    }

    public var currentPlatformName: String {
        if UserDefaults.standard.bool(forKey: "SP_Mod_MacBookDemoMode") {
            return "MacBook Pro (16-inch, M4 Max)"
        }
        return platformName
    }

    public var isLaptop: Bool {
        if UserDefaults.standard.bool(forKey: "SP_Mod_MacBookDemoMode") {
            return true
        }
        let lower = (platformName + " " + modelIdentifier).lowercased()
        return lower.contains("book") || lower.contains("macbook")
    }

    /// 识别是否为无风扇被动散热机型（如全系 Apple Silicon MacBook Air 及 12 寸 MacBook）
    public var isPassiveCoolingModel: Bool {
        let lowerName = platformName.lowercased()
        let lowerModel = modelIdentifier.lowercased()
        if lowerName.contains("macbook air") || lowerModel.contains("macbookair") {
            return true
        }
        let fanlessModelIDs: Set<String> = [
            "macbookair10,1",
            "mac14,2", "mac14,15",
            "mac15,12", "mac15,13",
            "mac16,12", "mac16,13",
            "macbook8,1", "macbook9,1", "macbook10,1"
        ]
        return fanlessModelIDs.contains(lowerModel)
    }

    private init() {
        let modelID = Self.readModelIdentifier() ?? "Mac"
        let chip = Self.readChipBrand() ?? "Apple Silicon"
        let productName = Self.readProductName()
        let sysPlist = Self.readSystemVersionPlist()

        self.modelIdentifier = modelID
        self.chipBrand = chip
        self.osVersion = Self.readOSVersion(systemPlist: sysPlist)
        self.osBuild = Self.readOSBuild(systemPlist: sysPlist)
        self.coreTopology = Self.readCoreTopology()
        self.gpuCoreCount = Self.readGPUCoreCount()

        if let prod = productName, !prod.isEmpty {
            if prod.contains("(") {
                self.platformName = prod
            } else if !chip.isEmpty {
                self.platformName = "\(prod) (\(chip))"
            } else {
                self.platformName = prod
            }
        } else if !chip.isEmpty {
            self.platformName = "\(modelID) (\(chip))"
        } else {
            self.platformName = modelID
        }
    }

    /// Reads the full macOS version string from SystemVersion.plist / sysctl / ProcessInfo (e.g. "27.2.1").
    private static func readOSVersion(systemPlist: [String: Any]?) -> String {
        let procVer = ProcessInfo.processInfo.operatingSystemVersion
        let procString = procVer.patchVersion > 0
            ? "\(procVer.majorVersion).\(procVer.minorVersion).\(procVer.patchVersion)"
            : "\(procVer.majorVersion).\(procVer.minorVersion)"

        let plistVersion = ["ProductUserVisibleVersion", "ProductVersion"]
            .compactMap { systemPlist?[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let raw = plistVersion ?? readSysctlString("kern.osproductversion") {
            let parts = raw.split(separator: ".")
            if parts.count < 3 && procVer.patchVersion > 0 && raw == "\(procVer.majorVersion).\(procVer.minorVersion)" {
                return procString
            }
            return raw
        }

        return procString
    }

    /// Reads the macOS build string from SystemVersion.plist or sysctl (e.g. "26B131").
    private static func readOSBuild(systemPlist: [String: Any]?) -> String {
        if let build = systemPlist?["ProductBuildVersion"] as? String {
            let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return readSysctlString("kern.osversion") ?? "Unknown"
    }

    private static func readSystemVersionPlist() -> [String: Any]? {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// Reads the marketing product name from IORegistry `product` entry (e.g. "Mac Studio (M5 Max)").
    private static func readProductName() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("product"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        for key in ["product-name", "product-description"] {
            if let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let str = decodeIORegistryProperty(prop), !str.isEmpty {
                    return str
                }
            }
        }
        return nil
    }

    /// Reads the Mac model identifier from `IOPlatformExpertDevice` (e.g. "Mac17,14").
    private static func readModelIdentifier() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else {
            return readSysctlString("hw.model")
        }
        defer { IOObjectRelease(service) }

        if let prop = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
           let str = decodeIORegistryProperty(prop), !str.isEmpty {
            return str
        }
        return readSysctlString("hw.model")
    }

    /// Reads the CPU / Apple Silicon brand string via sysctl (e.g. "Apple M5 Max").
    private static func readChipBrand() -> String? {
        return readSysctlString("machdep.cpu.brand_string")
    }

    private static func decodeIORegistryProperty(_ prop: CFTypeRef) -> String? {
        if let str = prop as? String {
            return str.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(["\0"])))
        }
        if let data = prop as? Data {
            let trimmedData = data.prefix { $0 != 0 }
            if let str = String(data: trimmedData, encoding: .utf8) {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func readCoreTopology() -> CoreTopology {
        let nLevels = readSysctlInt32("hw.nperflevels") ?? 0
        if nLevels >= 2 {
            let l0Name = readSysctlString("hw.perflevel0.name") ?? "Performance"
            let l0Count = readSysctlInt32("hw.perflevel0.logicalcpu")
                ?? readSysctlInt32("hw.perflevel0.physicalcpu")
                ?? 0
            let l1Name = readSysctlString("hw.perflevel1.name") ?? "Efficiency"
            let l1Count = readSysctlInt32("hw.perflevel1.logicalcpu")
                ?? readSysctlInt32("hw.perflevel1.physicalcpu")
                ?? 0
            let l2Name: String
            let l2Count: Int
            if nLevels >= 3 {
                l2Name = readSysctlString("hw.perflevel2.name") ?? "Efficiency"
                l2Count = readSysctlInt32("hw.perflevel2.logicalcpu")
                    ?? readSysctlInt32("hw.perflevel2.physicalcpu")
                    ?? 0
            } else {
                l2Name = ""
                l2Count = 0
            }
            if l0Count > 0 || l1Count > 0 {
                return CoreTopology(
                    level0Name: l0Name,
                    level0Count: l0Count,
                    level1Name: l1Name,
                    level1Count: l1Count,
                    level2Name: l2Name,
                    level2Count: l2Count
                )
            }
        }
        let fallbackTotal = max(1, readSysctlInt32("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount)
        let l0Name = readSysctlString("hw.perflevel0.name") ?? "Performance"
        return CoreTopology(level0Name: l0Name, level0Count: fallbackTotal, level1Name: "", level1Count: 0)
    }

    private static func readSysctlInt32(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let validBytes = buffer.prefix { $0 != 0 }
        let str = String(decoding: validBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? nil : str
    }

    /// Reads the GPU core count from IOAccelerator IORegistry property (`gpu-core-count`).
    private static func readGPUCoreCount() -> Int {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iter) }

        var maxCores = 0
        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            if let prop = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                maxCores = max(maxCores, prop.intValue)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return maxCores
    }
}
