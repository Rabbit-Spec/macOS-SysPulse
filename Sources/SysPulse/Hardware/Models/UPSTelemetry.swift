import Foundation

/// Current operating state of the power source.
public enum PowerSupplyState: String, Codable, Sendable {
    case acPower = "市电供电 (AC Online)"
    case batteryPower = "电池供电 (On Battery)"
    case unknown = "状态检测中"

    public var isBattery: Bool {
        self == .batteryPower
    }

    public var isAC: Bool {
        self != .batteryPower
    }
}

/// Unified telemetry snapshot for any connected UPS.
public struct UPSTelemetry: Equatable, Sendable {
    public var isConnected: Bool
    public var deviceName: String
    public var brand: UPSBrand
    public var state: PowerSupplyState
    public var batteryLevel: Int              // 0 ~ 100%
    public var isCharging: Bool
    public var timeRemainingMinutes: Int?     // Estimated minutes remaining
    public var voltageVolts: Double           // Input voltage, e.g. 230.0V
    public var loadPercent: Double?           // UPS Load percentage, e.g. 18.0%
    public var loadWatts: Double?             // Output active power, e.g. 65W
    public var ratedVA: Int?                  // Hardware-reported nominal VA rating (HID 0x84:0x43)
    public var frequencyHz: Double            // Grid frequency, e.g. 50.0Hz
    public var isAudibleAlarmEnabled: Bool    // Buzzer alarm state
    public var lastUpdated: Date

    public init(
        isConnected: Bool = false,
        deviceName: String = "未连接 UPS",
        brand: UPSBrand = .generic,
        state: PowerSupplyState = .unknown,
        batteryLevel: Int = 0,
        isCharging: Bool = false,
        timeRemainingMinutes: Int? = nil,
        voltageVolts: Double = 220.0,
        loadPercent: Double? = nil,
        loadWatts: Double? = nil,
        ratedVA: Int? = nil,
        frequencyHz: Double = 50.0,
        isAudibleAlarmEnabled: Bool = true,
        lastUpdated: Date = Date()
    ) {
        self.isConnected = isConnected
        self.deviceName = deviceName
        self.brand = brand
        self.state = state
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.timeRemainingMinutes = timeRemainingMinutes
        self.voltageVolts = voltageVolts
        self.loadPercent = loadPercent
        self.loadWatts = loadWatts
        self.ratedVA = ratedVA
        self.frequencyHz = frequencyHz
        self.isAudibleAlarmEnabled = isAudibleAlarmEnabled
        self.lastUpdated = lastUpdated
    }

    /// Dynamically formatted UPS hardware description for About View.
    public var pairedUPSDescription: String {
        guard isConnected else { return "未连接 UPS" }
        let cleanName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let va = ratedVA, va > 0, !cleanName.contains("\(va)") {
            return "\(cleanName) (\(va)VA)"
        }
        return cleanName.isEmpty ? brand.rawValue : cleanName
    }

    /// Formatted remaining time string (e.g. "< 1分钟", "12分钟", "1小时15分")
    public var formattedRemainingTime: String {
        if batteryLevel <= 2 {
            return "< 1 分钟"
        }
        guard let minutes = timeRemainingMinutes, minutes > 0 else {
            return "< 1 分钟"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hours)小时\(mins)分" : "\(hours)小时"
        }
        return "\(minutes) 分钟"
    }

    /// Subtitle for Hero Glass Card explaining current power mode & charging state
    public var heroSubtitle: String {
        if state.isBattery {
            if batteryLevel <= 2 {
                return "电量即将耗尽 · 应急续航不足 1 分钟"
            }
            return "断电应急供电中 · 剩余约 \(formattedRemainingTime)"
        }
        
        if isCharging && batteryLevel < 95 {
            return "充电中 (已充 \(batteryLevel)%) · 应急备电 \(formattedRemainingTime)"
        } else {
            return "市电常供中 · 满电应急备电约 \(formattedRemainingTime)"
        }
    }

    /// 2x2 Metric Card runtime tile content
    public var runtimeMetricDisplay: (value: String, unit: String, subtext: String) {
        if state.isBattery {
            if batteryLevel <= 2 {
                return ("< 1", "分钟", "电量极低 · 准备安全关机")
            }
            return ("\(timeRemainingMinutes ?? 1)", "分钟", "断电逆变供电中")
        }
        
        if isCharging && batteryLevel < 95 {
            let val = (timeRemainingMinutes ?? 0) <= 0 || batteryLevel <= 2 ? "< 1" : "\(timeRemainingMinutes!)"
            return (val, "分钟", "充电中 (已充至 \(batteryLevel)%)")
        } else {
            let val = "\(timeRemainingMinutes ?? 24)"
            return (val, "分钟", "市电常供 · 满电就绪")
        }
    }

    /// Compact badge string for the macOS Menu Bar (e.g. "230V | 100% | 24m")
    public func menuBarTitle(showVoltage: Bool = true, showPercent: Bool = true, showTime: Bool = true) -> String {
        guard isConnected else { return "未检测到 UPS" }

        var items: [String] = []
        if showVoltage && voltageVolts > 50 {
            items.append("\(Int(voltageVolts))V")
        }
        if showPercent {
            items.append("\(batteryLevel)%")
        }
        if showTime, let minutes = timeRemainingMinutes, minutes > 0, state.isBattery {
            items.append("\(minutes)m")
        }

        return items.joined(separator: " · ")
    }
}
