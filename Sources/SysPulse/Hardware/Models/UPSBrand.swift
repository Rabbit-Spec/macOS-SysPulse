import Foundation

/// Supported or detected UPS brands.
public enum UPSBrand: String, Codable, CaseIterable, Sendable {
    case santak = "山特 (SANTAK)"
    case eaton = "伊顿 (EATON)"
    case apc = "施耐德 APC"
    case cyberpower = "硕天 (CyberPower)"
    case huawei = "华为 (HUAWEI)"
    case vertiv = "维谛 (Vertiv/Liebert)"
    case omron = "欧姆龙 (OMRON)"
    case generic = "通用 HID UPS"

    public var iconName: String {
        switch self {
        case .santak, .eaton:
            return "bolt.shield.fill"
        case .apc:
            return "shield.lefthalf.filled"
        case .cyberpower:
            return "bolt.badge.automatic.fill"
        case .huawei, .vertiv:
            return "server.rack"
        case .omron, .generic:
            return "powerplug.fill"
        }
    }

    public static func detect(name: String, vendorID: Int? = nil, manufacturer: String? = nil) -> UPSBrand {
        let text = "\(name) \(manufacturer ?? "")".uppercased()

        if text.contains("SANTAK") {
            return .santak
        }
        if text.contains("EATON") || vendorID == 1123 || vendorID == 0x0463 {
            return text.contains("TG-BOX") || text.contains("SANTAK") ? .santak : .eaton
        }
        if text.contains("APC") || text.contains("AMERICAN POWER") || vendorID == 0x051D {
            return .apc
        }
        if text.contains("CYBERPOWER") || vendorID == 0x0764 {
            return .cyberpower
        }
        if text.contains("HUAWEI") {
            return .huawei
        }
        if text.contains("VERTIV") || text.contains("LIEBERT") {
            return .vertiv
        }
        if text.contains("OMRON") {
            return .omron
        }
        return .generic
    }
}
