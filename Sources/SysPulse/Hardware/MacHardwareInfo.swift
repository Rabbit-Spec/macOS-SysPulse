import Foundation
import IOKit

/// Dynamically queries the host Mac's hardware model and Apple Silicon / CPU chip name via IOKit & sysctl.
public struct MacHardwareInfo: Sendable {
    public static let shared = MacHardwareInfo()

    public let platformName: String
    public let modelIdentifier: String
    public let chipBrand: String

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

        self.modelIdentifier = modelID
        self.chipBrand = chip

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

    private static func readSysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let validBytes = buffer.prefix { $0 != 0 }
        let str = String(decoding: validBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? nil : str
    }
}
