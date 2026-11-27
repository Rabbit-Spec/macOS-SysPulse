import SwiftUI

public struct GaugeRingView: View {
    @Environment(\.colorScheme) private var colorScheme
    public var batteryLevel: Int
    public var isCharging: Bool
    public var isAC: Bool
    public var size: CGFloat = 68

    private var progress: Double {
        Double(max(0, min(100, batteryLevel))) / 100.0
    }

    private var ringColor: Color {
        if !isAC {
            return batteryLevel > 25 ? LiquidTheme.amber(for: colorScheme) : LiquidTheme.crimson(for: colorScheme)
        }
        return batteryLevel < 15 ? LiquidTheme.amber(for: colorScheme) : LiquidTheme.emerald(for: colorScheme)
    }

    public var body: some View {
        ZStack {
            // Native Track Ring (adaptive contrast for Light & Dark Mode)
            Circle()
                .stroke(
                    colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.09),
                    style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
                )

            // Smooth Native Progress Ring
            Circle()
                .trim(from: 0.0, to: max(0.02, progress))
                .stroke(
                    ringColor.gradient,
                    style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.4), value: progress)

            // Center Native Telemetry
            VStack(spacing: 1) {
                Image(systemName: isCharging ? "bolt.fill" : (isAC ? "powerplug.fill" : "battery.75percent"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ringColor)
                    .symbolEffect(.pulse, isActive: isCharging && batteryLevel < 95)

                Text("\(batteryLevel)%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
    }
}
