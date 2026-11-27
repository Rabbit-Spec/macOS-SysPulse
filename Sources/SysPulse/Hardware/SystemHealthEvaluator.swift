import Foundation
import AppKit

// MARK: - 系统健康度评估引擎

public enum HealthRating: String, Sendable {
    case excellent = "很好"      // >= 95
    case good = "良好"           // 85 - 94
    case fair = "一般"           // 70 - 84
    case needsAttention = "需要留意" // < 70

    public static func from(score: Int) -> HealthRating {
        switch score {
        case 95...100: return .excellent
        case 85..<95: return .good
        case 70..<85: return .fair
        default: return .needsAttention
        }
    }
}

public struct HealthFactor: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let penalty: Int
    public let detail: String?

    public init(name: String, description: String, penalty: Int, detail: String? = nil) {
        self.name = name
        self.description = description
        self.penalty = penalty
        self.detail = detail
    }
}

public struct SystemHealthSnapshot: Sendable {
    public let score: Int
    public let rating: HealthRating
    public let factors: [HealthFactor]
    public let primarySummary: String
    public let uptimeDays: Int
    public let uptimeHours: Int
    public let formattedUptime: String

    public init(
        score: Int,
        factors: [HealthFactor],
        uptimeDays: Int,
        uptimeHours: Int
    ) {
        self.score = max(50, min(100, score))
        self.rating = HealthRating.from(score: self.score)
        self.factors = factors
        self.uptimeDays = uptimeDays
        self.uptimeHours = uptimeHours
        self.formattedUptime = "已运行 \(uptimeDays)天 \(uptimeHours)小时"

        if let top = factors.max(by: { $0.penalty < $1.penalty }), top.penalty > 0 {
            self.primarySummary = "\(top.description)，影响 \(top.penalty) 分"
        } else {
            self.primarySummary = "当前指标正常"
        }
    }
}

@MainActor
public final class SystemHealthEvaluator {
    public static let shared = SystemHealthEvaluator()

    private init() {}

    public func evaluate() -> SystemHealthSnapshot {
        let monitor = SystemResourceMonitor.shared
        let uptimeSeconds = ProcessInfo.processInfo.systemUptime
        let days = Int(uptimeSeconds) / 86400
        let hours = (Int(uptimeSeconds) % 86400) / 3600

        var factors: [HealthFactor] = []

        // 1. Uptime Factor (很久没重启了)
        // 运行超过一个半月（45 天）再开始计入扣分；开机时间越长扣分越多，最多 8 分
        if days >= 45 {
            let overdueDays = days - 45
            let penalty = min(8, max(1, 1 + Int(round(Double(overdueDays) / 5.0))))
            factors.append(
                HealthFactor(
                    name: "uptime",
                    description: "很久没重启了",
                    penalty: penalty,
                    detail: "已连续开机 \(days) 天"
                )
            )
        }

        // 2. CPU Factor (CPU 负载偏高)
        let cpu = monitor.power.cpuTotalPercent
        if cpu > 75.0 {
            let penalty = min(15, Int((cpu - 75.0) * 0.4) + 3)
            factors.append(
                HealthFactor(
                    name: "cpu",
                    description: "CPU 负载偏高",
                    penalty: penalty,
                    detail: String(format: "当前总占用 %.1f%%", cpu)
                )
            )
        }

        // 3. Memory Pressure Factor (内存压力偏高)
        switch monitor.memory.pressure {
        case .warning:
            factors.append(HealthFactor(name: "memory", description: "内存压力偏高", penalty: 5))
        case .critical:
            factors.append(HealthFactor(name: "memory", description: "内存压力偏高", penalty: 15))
        case .normal:
            break
        }

        // 4. Thermal Factor (温度偏高)
        switch ProcessInfo.processInfo.thermalState {
        case .fair:
            factors.append(HealthFactor(name: "thermal", description: "温度偏高", penalty: 2))
        case .serious:
            factors.append(HealthFactor(name: "thermal", description: "温度偏高", penalty: 6))
        case .critical:
            factors.append(HealthFactor(name: "thermal", description: "温度偏高", penalty: 12))
        case .nominal:
            break
        @unknown default:
            break
        }

        // 5. Disk Free Space Factor (磁盘空间不足)
        let freeGB = monitor.disk.bootVolumeFreeGB
        if freeGB > 0 && freeGB < 15.0 {
            factors.append(HealthFactor(name: "disk", description: "磁盘空间不足", penalty: 10))
        } else if freeGB > 0 && freeGB < 30.0 {
            factors.append(HealthFactor(name: "disk", description: "磁盘空间不足", penalty: 5))
        }

        // 6. Battery Health & Cycles (笔记本内置电池)
        if monitor.loadRuntime.hasInternalBattery {
            let health = monitor.loadRuntime.internalBatteryHealthPercent
            let cycles = monitor.loadRuntime.internalBatteryCycleCount
            if health > 0 && health < 80 {
                factors.append(HealthFactor(name: "batteryHealth", description: "电池健康度偏低", penalty: 6))
            }
            if cycles > 1000 {
                factors.append(HealthFactor(name: "batteryCycles", description: "电池老化", penalty: 4))
            }
        }

        let totalPenalty = factors.reduce(0) { $0 + $1.penalty }
        let finalScore = max(50, 100 - totalPenalty)

        return SystemHealthSnapshot(
            score: finalScore,
            factors: factors,
            uptimeDays: days,
            uptimeHours: hours
        )
    }
}
