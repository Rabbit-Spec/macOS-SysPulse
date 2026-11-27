import SwiftUI
import AppKit

public struct SystemUPSSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var settings = SystemUPSSettingsManager.shared
    @Bindable var engine = PowerSourceEngine.shared
    public var onDone: @MainActor @Sendable () -> Void

    private let minuteStops: [(index: Int, value: Int, label: String, ratio: Double)] = [
        (0, 1,  "1分钟",  0.0),
        (1, 5,  "5分钟",  1.0 / 3.0),
        (2, 10, "10分钟", 2.0 / 3.0),
        (3, 15, "15分钟", 1.0)
    ]

    private let percentStops: [(index: Int, value: Int, label: String, ratio: Double)] = [
        (0, 1,   "1%",   0.0),
        (1, 25,  "25%",  0.25),
        (2, 50,  "50%",  0.50),
        (3, 75,  "75%",  0.75),
        (4, 100, "100%", 1.0)
    ]

    public var body: some View {
        VStack(spacing: 12) {
            // 1. Top Native UPS Model Group Row (matches macOS System Settings)
            HStack {
                Text("UPS型号")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer()
                Text(engine.telemetry.deviceName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .nativeSettingsGroup(cornerRadius: 10)

            // 2. Main 3-Rule Settings Group Box (matches macOS System Settings)
            VStack(spacing: 14) {
                // Rule 1: UPS 电池达到以下使用时间后将 Mac 关机
                VStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("UPS 电池达到以下使用时间后将 Mac 关机：")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        Toggle("", isOn: $settings.haltAfterEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointingHandOnHover()
                    }

                    nativeDiscreteSlider(
                        selectedValue: $settings.haltAfterMinutes,
                        isEnabled: settings.haltAfterEnabled,
                        stops: minuteStops
                    )
                }

                Divider()

                // Rule 2: UPS 电池剩余使用时间达到以下时间时将 Mac 关机
                VStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("UPS 电池剩余使用时间达到以下时间时将 Mac 关机：")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        Toggle("", isOn: $settings.haltRemainEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointingHandOnHover()
                    }

                    nativeDiscreteSlider(
                        selectedValue: $settings.haltRemainMinutes,
                        isEnabled: settings.haltRemainEnabled,
                        stops: minuteStops
                    )
                }

                Divider()

                // Rule 3: UPS 电池电量低于以下水平时将 Mac 关机
                VStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("UPS 电池电量低于以下水平时将 Mac 关机：")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        Toggle("", isOn: $settings.haltLevelEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointingHandOnHover()
                    }

                    nativeDiscreteSlider(
                        selectedValue: $settings.haltLevelPercent,
                        isEnabled: settings.haltLevelEnabled,
                        stops: percentStops
                    )
                }
            }
            .padding(14)
            .nativeSettingsGroup(cornerRadius: 10)

            Divider()
                .padding(.top, 2)

            // Bottom Action Bar (matches macOS native sheet footer)
            HStack {
                Button(action: {
                    settings.commitChangesToSystem {
                        settings.openSystemPreferencesUPS()
                    }
                }) {
                    Label("系统 UPS 设置", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .pointingHandOnHover()
                .controlSize(.regular)

                Spacer()

                Button(action: {
                    settings.commitChangesToSystem {
                        onDone()
                    }
                }) {
                    Text("完成")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 56)
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .pointingHandOnHover()
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 408)
        .activeLiquidPanelSubstrate()
    }

    /// Strict discrete-stop slider: thumb ONLY snaps to the exact labeled stops (e.g. 1/5/10/15 or 1%/25%/50%/75%/100%),
    /// without drawing macOS's 100-line tick comb. Adaptive contrast for both Light and Dark mode.
    @ViewBuilder
    private func nativeDiscreteSlider(
        selectedValue: Binding<Int>,
        isEnabled: Bool,
        stops: [(index: Int, value: Int, label: String, ratio: Double)]
    ) -> some View {
        let maxIndex = Double(max(1, stops.count - 1))

        let indexBinding = Binding<Double>(
            get: {
                if let match = stops.first(where: { $0.value == selectedValue.wrappedValue }) {
                    return Double(match.index)
                }
                let closest = stops.min(by: { abs($0.value - selectedValue.wrappedValue) < abs($1.value - selectedValue.wrappedValue) })
                return Double(closest?.index ?? 0)
            },
            set: { newIndex in
                let snappedIdx = max(0, min(stops.count - 1, Int(newIndex.rounded())))
                let newVal = stops[snappedIdx].value
                if selectedValue.wrappedValue != newVal {
                    selectedValue.wrappedValue = newVal
                }
            }
        )

        VStack(spacing: 3) {
            Slider(value: indexBinding, in: 0...maxIndex)
                .tint(isEnabled ? .blue : .secondary)
                .pointingHandOnHover()

            GeometryReader { geo in
                let trackInset: CGFloat = 10
                let usableWidth = max(1, geo.size.width - trackInset * 2)

                ZStack(alignment: .topLeading) {
                    ForEach(stops, id: \.value) { stop in
                        let isSelected = (selectedValue.wrappedValue == stop.value)
                        let xPos = trackInset + usableWidth * CGFloat(stop.ratio)
                        VStack(spacing: 3) {
                            Circle()
                                .fill(Color.primary.opacity(isSelected ? 0.85 : 0.35))
                                .frame(width: 3, height: 3)

                            Text(stop.label)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .fixedSize()
                        }
                        .position(x: xPos, y: 11)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selectedValue.wrappedValue = stop.value
                            }
                        }
                        .pointingHandOnHover()
                    }
                }
            }
            .frame(height: 22)
        }
    }
}
