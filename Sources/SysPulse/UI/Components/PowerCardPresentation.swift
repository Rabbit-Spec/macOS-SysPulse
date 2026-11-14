import SwiftUI

/// 主窗口「状态」页与菜单栏弹窗共用的电池 / 供电卡片展示状态
public struct PowerCardPresentation: Sendable, Equatable {
    public enum IconTone: Sendable, Equatable {
        case green
        case amber
        case orange
        case red

        public var color: Color {
            switch self {
            case .green:
                return Color(red: 0.35, green: 0.85, blue: 0.55)
            case .amber:
                return Color(red: 0.95, green: 0.70, blue: 0.25)
            case .orange:
                return Color.orange
            case .red:
                return Color(red: 0.95, green: 0.40, blue: 0.35)
            }
        }
    }

    public let title: String
    public let percent: Int
    public let statusText: String
    public let isOnBattery: Bool
    public let iconName: String
    public let iconTone: IconTone

    public var statusColor: Color {
        isOnBattery ? Color.orange : Color(red: 0.35, green: 0.85, blue: 0.55)
    }

    public var iconColor: Color {
        iconTone.color
    }

    /// 统一解析当前供电模式、电量百分比、状态文案与图标
    public static func resolve(
        upsEnabled: Bool,
        upsTelemetry: UPSTelemetry,
        loadRuntime: LoadRuntimeMetrics,
        hardwareBatteryCharging: Bool,
        isMacBookDemoMode: Bool
    ) -> PowerCardPresentation {
        let upsConnected = upsEnabled && upsTelemetry.isConnected
        let hasInternalBattery = isMacBookDemoMode || loadRuntime.hasInternalBattery
        let internalPercent = loadRuntime.hasInternalBattery
            ? loadRuntime.internalBatteryPercent
            : (isMacBookDemoMode ? 88 : 100)
        let internalCharging = loadRuntime.hasInternalBattery
            ? (loadRuntime.isInternalCharging || hardwareBatteryCharging)
            : isMacBookDemoMode
        let internalPluggedIn = loadRuntime.hasInternalBattery
            ? loadRuntime.isInternalPluggedIn
            : true

        // MacBook 同时连接外置 UPS 且启用 UPS 插件时：
        // 内置电池未充满则优先显示电池状态；电池充满后优先显示 UPS 状态。
        let internalBatteryFull = internalPercent >= 100 && !internalCharging
        let showUPS = upsConnected && (!hasInternalBattery || internalBatteryFull)

        if showUPS {
            let upsPct = min(100, max(0, upsTelemetry.batteryLevel))
            if !upsTelemetry.state.isAC {
                return PowerCardPresentation(
                    title: "UPS 供电",
                    percent: upsPct,
                    statusText: "电池供电",
                    isOnBattery: true,
                    iconName: batteryIconName(for: upsPct),
                    iconTone: upsPct <= 20 ? .red : .orange
                )
            }
            if upsTelemetry.isCharging && upsPct < 100 {
                return PowerCardPresentation(
                    title: "UPS 供电",
                    percent: upsPct,
                    statusText: "充电中",
                    isOnBattery: false,
                    iconName: "battery.100.bolt",
                    iconTone: .green
                )
            }
            return PowerCardPresentation(
                title: "UPS 供电",
                percent: upsPct,
                statusText: "市电在线",
                isOnBattery: false,
                iconName: "bolt.shield.fill",
                iconTone: .green
            )
        }

        if hasInternalBattery {
            let pct = min(100, max(0, internalPercent))
            if internalCharging {
                return PowerCardPresentation(
                    title: "电池",
                    percent: pct,
                    statusText: "充电中",
                    isOnBattery: false,
                    iconName: "battery.100.bolt",
                    iconTone: .green
                )
            }
            // 插电已充满，或开启“优化电池充电”停在 80% 保持，统一显示 AC 适配器供电
            if internalPluggedIn {
                return PowerCardPresentation(
                    title: "电池",
                    percent: pct,
                    statusText: "AC 适配器供电",
                    isOnBattery: false,
                    iconName: "powerplug.fill",
                    iconTone: .green
                )
            }
            let tone: IconTone = pct > 50 ? .green : (pct > 20 ? .amber : .red)
            return PowerCardPresentation(
                title: "电池",
                percent: pct,
                statusText: "电池供电",
                isOnBattery: true,
                iconName: batteryIconName(for: pct),
                iconTone: tone
            )
        }

        return PowerCardPresentation(
            title: "AC 供电",
            percent: 100,
            statusText: "市电在线",
            isOnBattery: false,
            iconName: "powerplug.fill",
            iconTone: .green
        )
    }

    private static func batteryIconName(for percent: Int) -> String {
        if percent > 50 { return "battery.75" }
        if percent > 20 { return "battery.50" }
        return "battery.25"
    }
}
