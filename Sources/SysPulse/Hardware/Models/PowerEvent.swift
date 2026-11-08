import Foundation

public enum PowerEventType: String, Codable, Sendable {
    case powerCut = "市电中断 (切至电池)"
    case powerRestored = "市电恢复 (恢复市电)"
    case voltageDip = "电网欠压波动"
    case voltageSurge = "电网过压跳闸"
    case diskEjected = "外接存储自动安全弹出"
    case networkNotified = "触发局域网 NAS 安全关机"
    case batteryLow = "电池电量过低警告"
    case selfTest = "UPS 电池自检"
}

public struct PowerEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var type: PowerEventType
    public var details: String
    public var batteryLevel: Int?
    public var voltageVolts: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: PowerEventType,
        details: String,
        batteryLevel: Int? = nil,
        voltageVolts: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.details = details
        self.batteryLevel = batteryLevel
        self.voltageVolts = voltageVolts
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}
