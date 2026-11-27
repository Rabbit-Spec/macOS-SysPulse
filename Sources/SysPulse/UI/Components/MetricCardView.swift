import SwiftUI
import AppKit

public struct MetricTile: View {
    public var icon: String
    public var title: String
    public var value: String
    public var unit: String
    public var accentColor: Color = .primary
    public var subtext: String? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let subtext {
                Text(subtext)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 12)
    }
}

public struct MetricCardGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    public var telemetry: UPSTelemetry

    public var body: some View {
        let runtimeInfo = telemetry.runtimeMetricDisplay
        let cyanAccent = LiquidTheme.cyan(for: colorScheme)
        let emeraldAccent = LiquidTheme.emerald(for: colorScheme)
        let amberAccent = LiquidTheme.amber(for: colorScheme)

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            MetricTile(
                icon: "waveform.path.ecg",
                title: "市电电压",
                value: String(format: "%.1f", telemetry.voltageVolts),
                unit: "V",
                accentColor: cyanAccent,
                subtext: telemetry.state.isAC ? "波形平稳 · 50.0 Hz" : "市电断开 (0V)"
            )

            MetricTile(
                icon: "bolt.badge.clock.fill",
                title: "预估续航",
                value: runtimeInfo.value,
                unit: runtimeInfo.unit,
                accentColor: telemetry.state.isAC ? (telemetry.batteryLevel < 15 ? amberAccent : emeraldAccent) : amberAccent,
                subtext: runtimeInfo.subtext
            )

            MetricTile(
                icon: "macstudio.fill",
                title: "Mac 功耗",
                value: String(format: "%.1f", telemetry.loadWatts ?? 27.0),
                unit: "W",
                accentColor: cyanAccent,
                subtext: "UPS 负载 \(Int(telemetry.loadPercent ?? 6))%"
            )

            // 蜂鸣器静音控制按钮
            Button(action: {
                PowerSourceEngine.shared.toggleAudibleAlarm()
                NSSound.beep()
            }) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: telemetry.isAudibleAlarmEnabled ? "bell.fill" : "bell.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(telemetry.isAudibleAlarmEnabled ? amberAccent : .secondary)
                        Text("报警蜂鸣")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Circle()
                            .fill(telemetry.isAudibleAlarmEnabled ? amberAccent : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(telemetry.isAudibleAlarmEnabled ? "开启" : "静音")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)

                        Text(telemetry.isAudibleAlarmEnabled ? "点此静音" : "点此开启")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                    }

                    Text(telemetry.isAudibleAlarmEnabled ? "断电时滴滴报警" : "断电静音防打扰")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassCard(cornerRadius: 12, isInteractive: true)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
    }
}
