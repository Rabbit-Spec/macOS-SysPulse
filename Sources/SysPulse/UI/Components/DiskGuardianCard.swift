import SwiftUI

public struct DiskGuardianCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var guardian = DiskGuardian.shared

    public var body: some View {
        let emeraldAccent = LiquidTheme.emerald(for: colorScheme)
        let amberAccent = LiquidTheme.amber(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Label("外置磁盘安全逃生舱", systemImage: "externaldrive.badge.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Toggle("", isOn: $guardian.isAutoEjectEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .pointingHandOnHover()
            }

            if let countdown = guardian.remainingCountdown {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .foregroundStyle(amberAccent)
                        .font(.system(size: 12, weight: .semibold))
                    Text("断电保护启动：\(countdown) 秒后自动弹出外接硬盘")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(amberAccent)
                    Spacer()
                    Button("立即弹出") {
                        guardian.executeSafeEjection()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(amberAccent)
                    .controlSize(.small)
                    .pointingHandOnHover()
                }
                .padding(8)
                .nativeSettingsGroup(cornerRadius: 8)
            }

            if guardian.externalDisks.isEmpty {
                Text("暂无挂载的外接硬盘")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                Divider()
                VStack(spacing: 6) {
                    ForEach(guardian.externalDisks) { disk in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(disk.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(disk.formattedSize)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(guardian.isAutoEjectEnabled ? "受保护" : "未开启")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(guardian.isAutoEjectEnabled ? emeraldAccent : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    (guardian.isAutoEjectEnabled ? emeraldAccent : Color.secondary)
                                        .opacity(colorScheme == .dark ? 0.16 : 0.12),
                                    in: Capsule()
                                )
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 12)
    }
}
