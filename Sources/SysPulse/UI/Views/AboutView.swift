import SwiftUI
import AppKit

public struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var engine = PowerSourceEngine.shared
    public var onDone: () -> Void

    private let githubURL = URL(string: "https://github.com/Rabbit-Spec")!

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 7) {
                PowerGlassAppIconView(size: 64)
                    .padding(.bottom, 3)

                Text("SysPulse")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)

                Text("专为 macOS 打造的智能系统管家")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(AppMetadata.fullVersionDisplay)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .nativeSettingsGroup(cornerRadius: 10)

            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    Text("作者")
                        .foregroundStyle(.primary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Rabbit-Spec")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)

                        Button(action: {
                            NSWorkspace.shared.open(githubURL)
                        }) {
                            HStack(spacing: 3) {
                                Text("https://github.com/Rabbit-Spec")
                                    .underline()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(colorScheme == .dark ? Color.cyan : Color.blue)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help("在浏览器中打开 GitHub 主页")
                    }
                }

                Divider()

                LabeledContent("硬件平台", value: MacHardwareInfo.shared.platformName)

                Divider()

                LabeledContent("连接 UPS", value: engine.telemetry.pairedUPSDescription)
            }
            .font(.system(size: 12))
            .padding(14)
            .nativeSettingsGroup(cornerRadius: 10)

            Divider()
                .padding(.top, 2)

            HStack {
                Text("© 2026 Rabbit-Spec. All rights reserved.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onDone) {
                    Text("完成")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 56)
                }
                .buttonStyle(.glassProminent)
                .pointingHandOnHover()
                .tint(.blue)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 408)
        .activeLiquidPanelSubstrate()
    }
}
