import SwiftUI

public struct MenuBarBadgeView: View {
    public var telemetry: UPSTelemetry

    public var body: some View {
        HStack(spacing: 5) {
            if telemetry.state.isAC {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LiquidTheme.mintGreen)
            } else {
                Image(systemName: "battery.50percent")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(telemetry.batteryLevel > 20 ? LiquidTheme.amberWarning : LiquidTheme.crimsonAlert)
            }

            Text(telemetry.menuBarTitle(showVoltage: true, showPercent: true, showTime: true))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 4)
    }
}
