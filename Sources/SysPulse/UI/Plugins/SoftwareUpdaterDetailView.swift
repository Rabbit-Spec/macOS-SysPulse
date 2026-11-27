import SwiftUI
import AppKit

public struct SoftwareUpdaterDetailView: View {
    @Bindable var manager = SoftwareUpdaterManager.shared
    let theme: LiquidGlassTheme
    @Environment(\.colorScheme) private var colorScheme

    public init(theme: LiquidGlassTheme) {
        self.theme = theme
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 12) {
                headerSummaryCard
                workspaceBody
            }
            .onAppear {
                manager.scanAllIfNeeded()
            }

            if let conflictItem = manager.runningConflictItem {
                runningConflictOverlay(for: conflictItem)
            }
        }
    }

    // MARK: - 顶部概览与操作卡片

    private var headerSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                PluginArtworkIconView(
                    kind: .softwareUpdater,
                    size: 56,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("软件更新中心")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Text(manager.isHomebrewInstalled ? "Sparkle + Electron + Cask + MAS + Brew" : "Sparkle + Electron + Cask + MAS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.cyan)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.cyan.opacity(0.14)))
                    }

                    Text(manager.scanStageMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        manager.startScan(forceRefresh: true)
                    } label: {
                        HStack(spacing: 6) {
                            if manager.isScanning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11.5, weight: .bold))
                            }
                            Text(manager.isScanning ? "检测中…" : "检查全部更新")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isScanning)

                    if !manager.visibleFormulaUpdates.isEmpty {
                        Button {
                            manager.updateAllVisibleFormulas()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("升级全部 CLI (\(manager.visibleFormulaUpdates.count))")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(Color.mint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.mint.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }

                    let directUpdatableCount = manager.visibleAppUpdates.filter {
                        $0.channel != .macAppStore && !$0.isSelfManaged && !$0.isRunning
                    }.count
                    if directUpdatableCount > 0 {
                        Button {
                            manager.updateAllSafeApps()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 11.5, weight: .bold))
                                Text("一键更新非运行应用 (\(directUpdatableCount))")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.cyan))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
            }

            // 筛选与搜索条
            HStack(spacing: 8) {
                ForEach(SoftwareUpdaterFilter.allCases) { filter in
                    let selected = (manager.selectedFilter == filter)
                    let count = manager.count(for: filter)
                    Button {
                        manager.selectedFilter = filter
                        manager.selectedDetailItemID = manager.currentFilteredItems.first?.id
                    } label: {
                        HStack(spacing: 5) {
                            Text(filter.rawValue)
                                .font(.system(size: 11.5, weight: selected ? .bold : .medium, design: .rounded))
                                .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(selected ? Color.cyan : theme.secondaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(selected ? Color.cyan.opacity(0.16) : theme.pillFill))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(selected ? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)) : Color.clear)
                                .overlay(Capsule().strokeBorder(selected ? Color.cyan.opacity(0.45) : theme.studioCardBorder, lineWidth: 0.8))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    TextField("搜索应用、CLI 公式或渠道…", text: $manager.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !manager.searchQuery.isEmpty {
                        Button {
                            manager.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 240)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.pillFill))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    // MARK: - 左右分栏主工作区

    private var workspaceBody: some View {
        HStack(spacing: 12) {
            // 左栏：应用 / 公式列表
            VStack(spacing: 0) {
                if manager.isScanning && manager.currentFilteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView(value: manager.scanProgress)
                            .frame(width: 220)
                        Text(manager.scanStageMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if manager.currentFilteredItems.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.green.opacity(0.8))
                        Text(manager.selectedFilter == .updatesAvailable ? "当前没有待更新项目" : "该分类下暂无记录")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("点击右上角“检查全部更新”可重新拉取官方源与 Homebrew 清单。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 6) {
                            ForEach(manager.currentFilteredItems) { item in
                                updateListRow(item)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.studioCardFill)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            )

            // 右栏：更新详情与安全校验证据面板
            VStack(spacing: 0) {
                if let detail = manager.selectedDetailItem {
                    detailInspector(for: detail)
                } else {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(theme.secondaryText.opacity(0.45))
                        Text("选择左侧任意应用或 CLI 查看更新详情与签名校验状态")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 430)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.studioCardFill)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            )
        }
    }

    private func updateListRow(_ item: SoftwareUpdateItem) -> some View {
        let isSelected = (manager.selectedDetailItem?.id == item.id)
        let isHovered = (manager.hoveredItemID == item.id)
        let channelTint = channelColor(item.channel)

        return HStack(spacing: 12) {
            itemIconView(for: item, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    if item.isRunning {
                        Text("运行中")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                    if item.isSelfManaged {
                        Text("需在 App 内更新")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.teal.opacity(0.14)))
                    }
                }

                HStack(spacing: 6) {
                    Text(item.channel.rawValue)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(channelTint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(channelTint.opacity(0.13)))

                    Text(item.archTag)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 版本对比固定列
            HStack(spacing: 4) {
                Text(item.currentVersion)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)

                if item.hasUpdate, let latest = item.latestVersion {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.cyan)
                    Text(latest)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.cyan)
                        .lineLimit(1)
                }
            }
            .frame(width: 145, alignment: .trailing)

            // 固定操作列
            rowActionPill(for: item)
                .frame(width: 102, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.cyan.opacity(colorScheme == .dark ? 0.14 : 0.10) : (isHovered ? theme.pillFill : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.cyan.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            manager.selectedDetailItemID = item.id
        }
        .onHover { hovering in
            manager.hoveredItemID = hovering ? item.id : nil
        }
    }

    @ViewBuilder
    private func rowActionPill(for item: SoftwareUpdateItem) -> some View {
        switch item.state {
        case .downloading(let p):
            Text("下载 \(Int(p * 100))%")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.cyan)
        case .verifying:
            Text("校验签名…")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.indigo)
        case .installing:
            Text("正在安装…")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.orange)
        case .openedInstaller(let path):
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Text("已打开安装器")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.teal)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.teal.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        case .openedBrowser:
            Text(item.isSelfManaged ? "已打开应用" : "已打开官网")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.teal)
        case .completed:
            Text("已更新")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.green)
        case .failed:
            Button {
                manager.triggerUpdate(item)
            } label: {
                Text("重试")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        case .idle, .waitingAppQuit:
            if item.hasUpdate {
                if manager.ignoredKeys.contains(item.ignoreKey) {
                    Button {
                        manager.unignoreUpdate(item)
                    } label: {
                        Text("恢复提示")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.pillFill))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                } else {
                    Button {
                        manager.triggerUpdate(item)
                    } label: {
                        Text(item.channel == .macAppStore ? "商店更新" : (item.isSelfManaged ? "App 内更新" : "立即更新"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(item.isSelfManaged ? Color.teal : Color.cyan))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            } else {
                Text("最新")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText.opacity(0.75))
            }
        }
    }

    // MARK: - 右栏详情检查器

    private func detailInspector(for item: SoftwareUpdateItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                itemIconView(for: item, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(item.bundleID ?? item.brewToken ?? item.id)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }

            // 版本与安全校验矩阵
            VStack(spacing: 8) {
                inspectorMetaRow(label: "更新渠道", value: item.channel.rawValue)
                inspectorMetaRow(label: "版本变更", value: item.hasUpdate ? "\(item.currentVersion) → \(item.latestVersion ?? "最新")" : item.currentVersion)
                if let minOS = item.minimumOSVersion, !minOS.isEmpty {
                    inspectorMetaRow(label: "系统要求", value: "macOS \(minOS)+")
                }
                if let bytes = item.expectedFileSizeBytes, bytes > 0 {
                    inspectorMetaRow(label: "安装包体积", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
                inspectorMetaRow(
                    label: "安全策略",
                    value: item.channel == .homebrewFormula || item.channel == .homebrewCask
                        ? "Homebrew 校验源升级"
                        : (item.channel == .macAppStore
                            ? "Mac App Store 官方签名"
                            : (item.vendorInstallerAppName != nil ? "官方独立安装器引导安装" : "codesign --strict + Team ID 连续性核验"))
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.pillFill))

            // 更新说明
            Text("更新日志 / 发行说明")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            ScrollView(.vertical, showsIndicators: true) {
                Text(item.releaseNotes.isEmpty ? "发布者未附带详细变更说明。" : item.releaseNotes)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.pillFill))

            // 实时日志输出区
            if !manager.liveLogLines.isEmpty {
                Text("执行与签名校验日志")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(manager.liveLogLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 110)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colorScheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.05)))
            }

            Spacer(minLength: 0)

            if case .failed(let msg) = item.state {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            }

            // 底部按钮栏
            HStack(spacing: 10) {
                if item.hasUpdate {
                    if !manager.ignoredKeys.contains(item.ignoreKey) {
                        Button {
                            manager.ignoreUpdate(item)
                        } label: {
                            Text("忽略此版本")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(theme.pillFill))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    } else {
                        Button {
                            manager.unignoreUpdate(item)
                        } label: {
                            Text("取消忽略")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(theme.pillFill))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }

                    Spacer()

                    Button {
                        if case .openedInstaller(let installerPath) = item.state {
                            NSWorkspace.shared.open(URL(fileURLWithPath: installerPath))
                        } else {
                            manager.triggerUpdate(item)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.channel == .macAppStore ? "bag.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text({
                                if case .openedInstaller = item.state {
                                    return "再次打开安装器"
                                }
                                if item.isSelfManaged {
                                    return "打开 App 内更新"
                                }
                                return item.channel == .macAppStore ? "前往 App Store 更新" : "安全下载并更新"
                            }())
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.cyan))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(item.state.isBusy)
                }
            }
        }
        .padding(16)
    }

    private func inspectorMetaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func itemIconView(for item: SoftwareUpdateItem, size: CGFloat) -> some View {
        if let appURL = item.bundleURL {
            Image(nsImage: AppIconManager.downsampledUIImage(from: NSWorkspace.shared.icon(forFile: appURL.path), maxPixelSize: 64))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if let token = item.brewToken,
                  let cliImg = CommandLineToolIconStore.shared.icon(forToolName: token) {
            Image(nsImage: cliImg)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(channelColor(item.channel).opacity(0.16))
                Image(systemName: item.channel == .homebrewFormula ? "terminal.fill" : "shippingbox.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(channelColor(item.channel))
            }
            .frame(width: size, height: size)
        }
    }

    private func channelColor(_ channel: SoftwareUpdateChannel) -> Color {
        switch channel {
        case .sparkle: return .cyan
        case .electron: return .indigo
        case .website: return .teal
        case .homebrewCask: return .orange
        case .homebrewFormula: return .mint
        case .macAppStore: return .blue
        }
    }

    // MARK: - 运行冲突提示弹窗

    private func runningConflictOverlay(for item: SoftwareUpdateItem) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    Text("「\(item.name)」正在运行中")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }

                Text("替换应用本体前需要平滑退出当前正在运行的进程，否则可能引发文件锁冲突或运行崩溃。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)

                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        manager.runningConflictItem = nil
                    } label: {
                        Text("取消")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(theme.pillFill))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Button {
                        manager.triggerUpdate(item, forceQuitRunning: true)
                    } label: {
                        Text("退出应用并立即更新")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.cyan))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(20)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.14, green: 0.15, blue: 0.18) : Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 1))
            )
        }
    }
}
