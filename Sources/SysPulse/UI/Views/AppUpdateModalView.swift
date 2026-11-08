import SwiftUI
import AppKit

public struct AppUpdateModalView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var updater = AppUpdateManager.shared
    let theme: LiquidGlassTheme
    let onClose: () -> Void

    public init(theme: LiquidGlassTheme, onClose: @escaping () -> Void) {
        self.theme = theme
        self.onClose = onClose
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                PowerGlassAppIconView(size: 48, forcedColorScheme: colorScheme)

                VStack(alignment: .leading, spacing: 3) {
                    Text("软件版本更新")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("GitHub 开源仓库 · Rabbit-Spec/macOS-SysPulse")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()
                .overlay(theme.dividerColor.opacity(0.5))

            Group {
                switch updater.state {
                case .idle, .checking:
                    checkingView
                case .upToDate(let currentVersion, let checkedAt):
                    upToDateView(currentVersion: currentVersion, checkedAt: checkedAt)
                case .updateAvailable(let release):
                    updateAvailableView(release: release)
                case .downloading(let release, let progress, let downloadedMB, let totalMB):
                    downloadingView(release: release, progress: progress, downloadedMB: downloadedMB, totalMB: totalMB)
                case .installing(let release, let statusMessage):
                    installingView(release: release, statusMessage: statusMessage)
                case .failed(let message):
                    failedView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isDark ? Color(red: 0.14, green: 0.15, blue: 0.18).opacity(0.97) : Color(red: 0.96, green: 0.97, blue: 0.98).opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.9)
                )
                .shadow(color: Color.black.opacity(isDark ? 0.50 : 0.20), radius: 28, y: 12)
        )
    }

    // MARK: - Subviews for States

    private var checkingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
                .scaleEffect(1.15)
            Text("正在连接 GitHub Releases 检查更新…")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("正在查询 Rabbit-Spec/macOS-SysPulse 最新版本标签")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            Spacer()
        }
        .padding(24)
    }

    private func upToDateView(currentVersion: String, checkedAt: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 64, height: 64)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.82, blue: 0.52))
            }

            VStack(spacing: 6) {
                Text("SysPulse 已是最新版本")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("当前运行版本 v\(currentVersion) · 检查时间 \(checkedAt)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(AppUpdateManager.repoWebURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                        Text("访问 GitHub 仓库")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Button {
                    updater.checkForUpdates(userInitiated: false)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .bold))
                        Text("重新检查")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .leading, endPoint: .trailing))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
    }

    private func updateAvailableView(release: GitHubReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("发现新版本 v\(release.version)")
                            .font(.system(size: 15.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Text("NEW")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.cyan))
                    }

                    Text("当前版本 v\(AppMetadata.version)  →  v\(release.version) · 发布于 \(release.publishedAt)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer()

                if let sizeText = release.formattedSize {
                    Text(sizeText)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.pillFill))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDark ? Color.cyan.opacity(0.10) : Color.cyan.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.cyan.opacity(0.28), lineWidth: 0.8)
                    )
            )

            Text("更新日志 (Changelog)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.secondaryText)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(release.title)
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .padding(.bottom, 2)

                    Text(release.releaseNotes)
                        .font(.system(size: 12.5, weight: .regular, design: .rounded))
                        .foregroundStyle(theme.primaryText.opacity(0.92))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                    )
            )

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(release.htmlURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .semibold))
                        Text("在 GitHub 中查看")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Spacer()

                Button {
                    updater.downloadAndInstall(release)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("立即下载并安装更新")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.72, blue: 0.88), Color(red: 0.18, green: 0.52, blue: 0.95)], startPoint: .leading, endPoint: .trailing))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
        .padding(20)
    }

    private func downloadingView(release: GitHubReleaseInfo, progress: Double, downloadedMB: Double, totalMB: Double) -> some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.cyan)

            VStack(spacing: 6) {
                Text("正在下载 SysPulse v\(release.version)…")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text(String(format: "%.1f MB / %.1f MB (%.0f%%)", downloadedMB, totalMB, progress * 100))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }

            ProgressView(value: min(1.0, max(0.0, progress)))
                .progressViewStyle(.linear)
                .tint(.cyan)
                .frame(maxWidth: 360)

            Button {
                updater.cancelDownload()
            } label: {
                Text("取消下载")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.pillFill))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()

            Spacer()
        }
        .padding(24)
    }

    private func installingView(release: GitHubReleaseInfo, statusMessage: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
                .scaleEffect(1.15)
            Text("正在安装 SysPulse v\(release.version)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(statusMessage)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            Spacer()
        }
        .padding(24)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 60, height: 60)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                Text("检查或下载更新时遇到问题")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(AppUpdateManager.releasesWebURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                        Text("前往 GitHub Releases 下载")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Button {
                    updater.checkForUpdates(userInitiated: false)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                        Text("重试")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .leading, endPoint: .trailing))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
    }
}
