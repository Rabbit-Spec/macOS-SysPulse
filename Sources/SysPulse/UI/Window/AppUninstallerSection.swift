import SwiftUI
import AppKit

// MARK: - 应用卸载、CLI 工具与启动项管理视图

public struct AppUninstallerSection: View {
    @Bindable var uninstaller = AppUninstallerEngine.shared
    @Bindable var startupManager = StartupItemManager.shared
    @Bindable var protectionStore = CleanProtectionStore.shared
    @Bindable var navState = StudioWindowNavigationState.shared
    let theme: LiquidGlassTheme
    var canvasWidth: CGFloat = 1200
    var canvasHeight: CGFloat = 822
    @Environment(\.colorScheme) private var colorScheme

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(684, canvasHeight - 79 - 59) }
    private var reviewCardH: CGFloat { max(374, contentH - 52 - 14 - 78 - 14 - 138 - 14) }

    public init(theme: LiquidGlassTheme, canvasWidth: CGFloat = 1200, canvasHeight: CGFloat = 822) {
        self.theme = theme
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    private var hasAnyContent: Bool {
        !uninstaller.installedApps.isEmpty
            || !uninstaller.orphanedResidues.isEmpty
            || !uninstaller.commandLineTools.isEmpty
            || !startupManager.items.isEmpty
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("软件管理")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("深度穿透沙盒容器、命令行工具与 LaunchAgents 启动项，精准识别关联证据、缺失程序与无主残留。")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(width: contentW, height: 52, alignment: .leading)

                primaryActionCard
                    .frame(width: contentW, height: 78)

                section2Group
                    .frame(width: contentW, height: 138)

                if hasAnyContent {
                    appReviewItemsCard
                        .frame(width: contentW, height: reviewCardH)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: contentW, height: contentH)
            .padding(.horizontal, 24)
            .padding(.top, 35)
            .padding(.bottom, 24)
            .onAppear {
                if uninstaller.installedApps.isEmpty && !uninstaller.isScanning {
                    uninstaller.startScan()
                }
                if startupManager.items.isEmpty && !startupManager.isScanning {
                    startupManager.startScan()
                }
            }

            if startupManager.isBtmSheetPresented {
                btmReportOverlay
            }
        }
    }

    // MARK: - 1. 扫描状态与主操作卡片

    private var primaryActionCard: some View {
        cardContainer {
            HStack(spacing: 0) {
                AnimatedModuleArtworkBadgeView(
                    size: 58,
                    isActive: uninstaller.isScanning || uninstaller.isUninstalling || startupManager.isScanning,
                    accentColor: Color(red: 0.45, green: 0.65, blue: 0.98)
                ) {
                    UninstallerArtworkIconView(size: 58, forcedColorScheme: colorScheme)
                }
                .padding(.leading, 24)
                .padding(.trailing, 20)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 8) {
                        Text(primaryStatusTitle)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        if uninstaller.isScanning || uninstaller.isUninstalling || startupManager.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(primaryStatusSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                actionButtonsGroup
                    .padding(.trailing, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var primaryStatusTitle: String {
        if uninstaller.selectedTab == .startupItems {
            if startupManager.isScanning { return "正在检索后台自启项与 LaunchAgents…" }
            let alerts = startupManager.issuesCount
            return alerts > 0
                ? "已发现 \(startupManager.allGroups.count) 款应用的 \(startupManager.items.count) 项启动服务，含 \(alerts) 项缺失/异常"
                : "共检测到 \(startupManager.allGroups.count) 款应用的 \(startupManager.items.count) 项自启服务（\(startupManager.enabledGroupsCount) 款已启用）"
        }
        if uninstaller.selectedTab == .commandLineTools {
            let cliBytes = uninstaller.commandLineTools.reduce(Int64(0)) { $0 + $1.sizeBytes }
            return "已发现 \(uninstaller.commandLineTools.count) 项命令行工具，共占用 \(uninstaller.formatBytes(cliBytes))"
        }
        switch uninstaller.status {
        case .idle:
            return uninstaller.lastUninstallDescription
        case .scanning:
            return "正在全面排查应用、CLI 与残留…"
        case .completed:
            if uninstaller.selectedTab == .orphanedResidues {
                let resCount = uninstaller.visibleOrphanedResidues.count
                let resBytes = uninstaller.visibleOrphanedResidues.reduce(Int64(0)) { $0 + $1.sizeBytes }
                return uninstaller.selectedBytes > 0
                    ? "已发现 \(resCount) 项无主残留，当前选中释放 \(uninstaller.formattedSelectedBytes)"
                    : "已发现 \(resCount) 项无主残留，共占用 \(uninstaller.formatBytes(resBytes))"
            }
            return "已发现 \(uninstaller.installedApps.count) 款应用，当前选中释放 \(uninstaller.formattedSelectedBytes)"
        case .uninstalling:
            return "正在安全卸载选定项目…"
        case .finished(let freed, _):
            return "卸载完成！已释放 \(uninstaller.formatBytes(freed))"
        }
    }

    private var primaryStatusSubtitle: String {
        if uninstaller.selectedTab == .startupItems {
            return startupManager.statusMessage.isEmpty ? "支持实时禁用用户自启代理、清理失效 Plist 或调用系统设置登录项。" : startupManager.statusMessage
        }
        if uninstaller.selectedTab == .commandLineTools {
            return uninstaller.statusMessage.isEmpty ? "覆盖 Homebrew Cellar、~/.local/bin、/usr/local/bin 与 uv/pipx 独立环境。" : uninstaller.statusMessage
        }
        switch uninstaller.status {
        case .idle:
            return "扫描不会删除任何内容，系统核心与白名单目录受永久保护。"
        case .scanning(_, let currentApp):
            return currentApp.isEmpty ? "正在分析应用足迹、共享群组与沙盒残留…" : currentApp
        case .completed:
            if !uninstaller.statusMessage.isEmpty {
                return uninstaller.statusMessage
            }
            return "已选中 \(uninstaller.selectedItemIDs.count) 项，支持展开逐项复核或单独清理应用数据。"
        case .uninstalling(_, let currentApp):
            return currentApp.isEmpty ? "正在注销自启代理并安全清理文件…" : currentApp
        case .finished:
            return "应用及关联残留已彻底清理，系统空间已恢复清爽。"
        }
    }

    private var actionButtonsGroup: some View {
        HStack(spacing: 10) {
            if uninstaller.selectedTab == .startupItems {
                Button {
                    startupManager.loadPrivilegedBtmDump()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 11, weight: .bold))
                        Text("系统 BTM 诊断")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .disabled(startupManager.isBusy)

                Button {
                    startupManager.openSystemLoginItemsSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("系统登录项设置")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8)))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Button {
                    startupManager.startScan()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                        Text("刷新启动项")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8)))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .disabled(startupManager.isScanning)
            } else {
                switch uninstaller.status {
                case .idle:
                    scanButton
                    optionsButton
                case .scanning:
                    Button {
                        uninstaller.cancelScan()
                    } label: {
                        Text("取消")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                case .completed, .finished:
                    Button {
                        uninstaller.startScan()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                            Text("重新扫描")
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    if uninstaller.selectedBytes > 0 {
                        Button {
                            uninstaller.executeUninstall()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("立即卸载 (\(uninstaller.formattedSelectedBytes))")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(
                                Capsule()
                                    .fill(LinearGradient(colors: [Color.cyan, Color(red: 0.35, green: 0.90, blue: 0.85)], startPoint: .leading, endPoint: .trailing))
                                    .shadow(color: Color.cyan.opacity(0.35), radius: 4, y: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                    optionsButton
                case .uninstalling:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var scanButton: some View {
        Button {
            uninstaller.startScan()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.fill").font(.system(size: 12, weight: .bold))
                Text("扫描").font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                    .overlay(Capsule().strokeBorder(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12), lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private var optionsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                navState.openModal(tab: .cleaner)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.pillFill).overlay(Circle().strokeBorder(theme.cardBorder, lineWidth: 0.8)))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    // MARK: - 2. 顶部 4 子视图切换与分类过滤卡片

    private var section2Group: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(UninstallerSubTab.allCases) { tab in
                    subTabPill(tab)
                }
                Spacer()
                Text("支持 launchctl 自动注销 · 白名单保护 · 废纸篓安全回收")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: contentW, height: 28, alignment: .leading)

            categoriesAndSafetyCard
                .frame(width: contentW, height: 100)
        }
    }

    private func subTabPill(_ tab: UninstallerSubTab) -> some View {
        let isSelected = (uninstaller.selectedTab == tab)
        let badgeCount: Int = {
            switch tab {
            case .installedApps: return uninstaller.installedApps.count
            case .commandLineTools: return uninstaller.commandLineTools.count
            case .orphanedResidues: return uninstaller.visibleOrphanedResidues.count
            case .startupItems: return startupManager.allGroups.count
            }
        }()
        let hasIssueBadge = (tab == .startupItems && startupManager.issuesCount > 0)

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                uninstaller.selectedTab = tab
                if tab == .startupItems && startupManager.items.isEmpty && !startupManager.isScanning {
                    startupManager.startScan()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(isSelected ? Color.cyan : theme.secondaryText)
                Text(tab.rawValue)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(hasIssueBadge ? Color.orange : (isSelected ? Color.cyan : theme.secondaryText))
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(hasIssueBadge ? Color.orange.opacity(0.16) : (isSelected ? Color.cyan.opacity(0.14) : theme.pillFill)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.07)) : Color.clear)
                    .overlay(Capsule().strokeBorder(isSelected ? Color.cyan.opacity(0.5) : theme.studioCardBorder, lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private var categoriesAndSafetyCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                if uninstaller.selectedTab == .startupItems {
                    HStack(spacing: 10) {
                        ForEach(StartupFilterOption.allCases) { filter in
                            startupFilterPill(filter)
                        }
                        Spacer()
                    }
                } else if uninstaller.selectedTab == .commandLineTools {
                    HStack(spacing: 18) {
                        guaranteeItem(icon: "shippingbox.circle.fill", title: "自动关联 Homebrew Cellar 公式与版本")
                        guaranteeItem(icon: "terminal.fill", title: "覆盖 ~/.local/bin 与 uv / pipx 独立工具")
                        guaranteeItem(icon: "waveform.path.ecg", title: "实时识别正在运行的 CLI 进程")
                        Spacer()
                    }
                } else if uninstaller.selectedTab == .orphanedResidues {
                    HStack(spacing: 18) {
                        guaranteeItem(icon: "magnifyingglass.circle.fill", title: "涵盖沙盒/群组/HTTP/WebKit/自启代理")
                        guaranteeItem(icon: "eye.slash.fill", title: "误报项支持一键忽略（不再提示）")
                        if !uninstaller.ignoredOrphanPaths.isEmpty {
                            Button {
                                uninstaller.clearIgnoredOrphans()
                            } label: {
                                Text("恢复已忽略残留 (\(uninstaller.ignoredOrphanPaths.count))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.cyan)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.cyan.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                        Spacer()
                    }
                } else {
                    HStack(spacing: 10) {
                        ForEach(AppCategoryFilter.allCases) { cat in
                            categoryPill(cat)
                        }
                    }
                }

                Divider().overlay(theme.dividerColor)

                HStack(spacing: 24) {
                    guaranteeItem(icon: "checkmark.seal", title: "展示关联证据与高置信/复核标签")
                    guaranteeItem(icon: "lock.shield", title: "系统应用防误删")
                    guaranteeItem(icon: "bolt.slash", title: "卸载前自动 bootout 自启代理")
                    guaranteeItem(icon: "trash", title: "默认移至废纸篓")
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func startupFilterPill(_ filter: StartupFilterOption) -> some View {
        let isSelected = (startupManager.selectedFilter == filter)
        let count = startupManager.count(for: filter)
        let tint: Color = (filter == .issues) ? .orange : .cyan

        return Button {
            startupManager.selectedFilter = filter
        } label: {
            HStack(spacing: 6) {
                Text(filter.rawValue)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tint.opacity(0.14)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)) : Color.clear)
                    .overlay(Capsule().strokeBorder(isSelected ? tint.opacity(0.45) : theme.studioCardBorder, lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func categoryPill(_ cat: AppCategoryFilter) -> some View {
        let isSelected = (uninstaller.selectedCategory == cat)
        let count = uninstaller.categoryCount(cat)
        let bytes = uninstaller.categoryBytes(cat)

        return Button {
            withAnimation(.spring(duration: 0.2)) {
                uninstaller.selectedCategory = cat
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: cat.iconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(cat.themeColor)
                Text(cat.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.primaryText.opacity(0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)))
                }
                if bytes > 0 {
                    Text(uninstaller.formatBytes(bytes))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(cat.themeColor.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(cat.themeColor.opacity(0.12)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)) : Color.clear)
                    .overlay(Capsule().strokeBorder(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.10)) : Color.white.opacity(0.05), lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func guaranteeItem(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - 3. 主列表工作区卡片 (4 模式统一对齐列)

    private var appReviewItemsCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                toolbarHeader
                    .padding(.horizontal, 16)
                    .frame(height: 38)

                Divider().overlay(theme.dividerColor)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        switch uninstaller.selectedTab {
                        case .installedApps:
                            ForEach(uninstaller.filteredDisplayItems) { item in
                                uninstallerRow(item: item)
                            }
                        case .commandLineTools:
                            ForEach(uninstaller.filteredCommandLineTools) { tool in
                                cliToolRow(tool)
                            }
                        case .orphanedResidues:
                            ForEach(uninstaller.visibleOrphanedResidues) { res in
                                uninstallerRow(item: .residue(res))
                            }
                        case .startupItems:
                            ForEach(startupManager.filteredGroups) { group in
                                startupAppGroupRow(group)
                            }
                        }
                    }
                    .padding(.vertical, 4.5)
                }
                .frame(height: max(341, reviewCardH - 39))
            }
            .frame(width: contentW, height: reviewCardH)
        }
    }

    private var toolbarHeader: some View {
        HStack(spacing: 16) {
            if uninstaller.selectedTab == .installedApps {
                let displayItems = uninstaller.filteredDisplayItems
                let selectableCount = displayItems.filter { !$0.isSystemApp }.count
                let selectedInCurrent = displayItems.filter { uninstaller.isItemSelected($0.id) && !$0.isSystemApp }.count

                Button {
                    if selectedInCurrent == selectableCount && selectableCount > 0 {
                        uninstaller.deselectAll()
                    } else {
                        uninstaller.selectAll()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: (selectedInCurrent == selectableCount && selectableCount > 0)
                              ? "checkmark.circle.fill"
                              : (selectedInCurrent == 0 ? "circle" : "minus.circle.fill"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selectedInCurrent == 0 ? theme.secondaryText : Color.cyan)
                        Text("全部 (\(displayItems.count))")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            } else if uninstaller.selectedTab == .orphanedResidues {
                let residues = uninstaller.visibleOrphanedResidues
                let totalRes = residues.count
                let selectedRes = residues.filter { uninstaller.isItemSelected($0.id) }.count

                Button {
                    if selectedRes == totalRes && totalRes > 0 {
                        uninstaller.deselectAllResidues()
                    } else {
                        uninstaller.selectAllResidues()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: (selectedRes == totalRes && totalRes > 0)
                              ? "checkmark.circle.fill"
                              : (selectedRes == 0 ? "circle" : "minus.circle.fill"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selectedRes == 0 ? theme.secondaryText : Color.purple)
                        Text("全部无主残留 (\(totalRes))")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            } else if uninstaller.selectedTab == .commandLineTools {
                Text("共 \(uninstaller.filteredCommandLineTools.count) 项已识别命令行工具")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            } else {
                let groups = startupManager.filteredGroups
                let totalServices = groups.reduce(0) { $0 + $1.items.count }
                Text("共 \(groups.count) 款应用（\(totalServices) 项启动服务）")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                if uninstaller.selectedTab == .startupItems {
                    TextField("搜索服务 Label、应用名或可执行路径…", text: $startupManager.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !startupManager.searchQuery.isEmpty {
                        Button { startupManager.searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    TextField("搜索名称、Bundle ID 或命令行工具…", text: $uninstaller.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !uninstaller.searchQuery.isEmpty {
                        Button { uninstaller.searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.pillFill))

            Spacer()

            if uninstaller.selectedTab == .installedApps {
                Menu {
                    ForEach(AppSortOption.allCases) { opt in
                        Button {
                            uninstaller.toggleSort(option: opt)
                        } label: {
                            HStack {
                                Text(opt.rawValue)
                                if uninstaller.sortOption == opt { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(uninstaller.sortOption.rawValue)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: uninstaller.sortOrder == .descending ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(theme.pillFill))
                }
                .menuStyle(.borderlessButton)
                .pointingHandOnHover()
            }
        }
    }

    // MARK: - App & Residue Rows

    @ViewBuilder
    private func uninstallerRow(item: UninstallerRowItem) -> some View {
        let isSelected = uninstaller.isItemSelected(item.id)
        let isHovered = (uninstaller.hoveredItemID == item.id)

        switch item {
        case .app(let app):
            let isExpanded = uninstaller.expandedAppIDs.contains(app.id)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if !app.isSystemApp {
                        Button {
                            uninstaller.toggleSelection(for: app.id)
                        } label: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.cyan : theme.secondaryText)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    } else {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText.opacity(0.4))
                            .frame(width: 20, height: 20)
                    }

                    NativeAppIconThumbnail(bundleURL: app.bundleURL)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(app.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)

                            if app.isRunning {
                                Text("活跃中")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.green.opacity(0.15)))
                            }

                            if app.caskMatch != nil {
                                Text("Brew Cask")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                            }

                            if app.isUnused && !app.isSystemApp {
                                Text("长期未使用")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                            }
                        }

                        HStack(spacing: 6) {
                            Text("v\(app.version)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                            Text("·").foregroundStyle(theme.secondaryText.opacity(0.5))
                            Text(app.formattedLastUsed)
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.secondaryText)
                            Text("·").foregroundStyle(theme.secondaryText.opacity(0.5))
                            Text(app.bundleID)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.secondaryText.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 固定右对齐控制列（保证所有行完全纵向对齐）
                    Text("\(app.components.count) 项关联")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cyan)
                        .frame(width: 82, height: 22)
                        .background(Capsule().fill(Color.cyan.opacity(0.12)))

                    Text(app.formattedTotalSize)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 82, alignment: .trailing)

                    if app.isSystemApp {
                        Text("系统原生")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.purple)
                            .frame(width: 82, height: 22)
                            .background(Capsule().fill(Color.purple.opacity(0.12)))
                    } else {
                        Text("可安全卸载")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.55))
                            .frame(width: 82, height: 22)
                            .background(Capsule().fill(Color(red: 0.25, green: 0.85, blue: 0.55).opacity(0.12)))
                    }

                    Button {
                        uninstaller.toggleAppExpanded(app.id)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    uninstallerLocateButton(for: app.bundleURL)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                // 展开抽屉：逐项关联证据 + 仅清数据模式
                if isExpanded {
                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            Text("本体 \(app.formattedBinarySize) · 数据与关联项 \(app.formattedDataSize)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)

                            Spacer()

                            if !app.isSystemApp && app.dataSizeBytes > 1024 * 64 {
                                Button {
                                    uninstaller.clearDataOnly(for: app)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("仅清理数据 (保留本体)")
                                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(Color.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3.5)
                                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                                }
                                .buttonStyle(.plain)
                                .pointingHandOnHover()
                            }
                        }

                        if !app.uninstallWarnings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(app.uninstallWarnings, id: \.self) { warning in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(Color.orange)
                                            .padding(.top, 1)
                                        Text(warning)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Color.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.08))
                            )
                        }

                        ForEach(app.components) { comp in
                            let isProtected = !comp.isSafeToTrash || protectionStore.isProtected(path: comp.path.path)
                            let included = uninstaller.isComponentIncluded(comp)
                            HStack(spacing: 8) {
                                if comp.type == .appBundle {
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.cyan)
                                        .frame(width: 16)
                                } else {
                                    Button {
                                        uninstaller.toggleComponentIncluded(comp)
                                    } label: {
                                        Image(systemName: included ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 11))
                                            .foregroundStyle(included ? Color.cyan : theme.secondaryText)
                                            .frame(width: 16)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Text(comp.type.rawValue)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(theme.primaryText)
                                    .frame(width: 72, alignment: .leading)

                                Text(comp.path.path)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(comp.confidence.rawValue)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(comp.confidence == .auto ? Color.green : Color.orange)
                                    .frame(width: 54, height: 18)
                                    .background(Capsule().fill((comp.confidence == .auto ? Color.green : Color.orange).opacity(0.13)))

                                Text(comp.formattedSize)
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.cyan)
                                    .frame(width: 74, alignment: .trailing)

                                if isProtected {
                                    Text("清理保护")
                                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.orange)
                                        .frame(width: 60, height: 18)
                                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                                } else {
                                    Button {
                                        protectionStore.addPath(comp.path.path)
                                    } label: {
                                        Text("清理保护")
                                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.cyan)
                                            .frame(width: 60, height: 18)
                                            .background(Capsule().fill(Color.cyan.opacity(0.10)))
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandOnHover()
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3.5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.pillFill))
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.bottom, 6)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)) : Color.clear)
            )
            .onHover { hovering in uninstaller.hoveredItemID = hovering ? app.id : nil }
            .contentShape(Rectangle())
            .contextMenu {
                if !app.isSystemApp && app.dataSizeBytes > 0 {
                    Button {
                        uninstaller.clearDataOnly(for: app)
                    } label: {
                        Label("仅清理数据（保留应用本体）", systemImage: "sparkles")
                    }
                }
                Button {
                    uninstaller.toggleAppExpanded(app.id)
                } label: {
                    Label(isExpanded ? "收起关联文件" : "展开关联文件", systemImage: "list.bullet.indent")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.bundleID, forType: .string)
                } label: {
                    Label("复制 Bundle ID", systemImage: "doc.on.doc")
                }
            }

        case .residue(let res):
            HStack(spacing: 12) {
                Button {
                    uninstaller.toggleSelection(for: res.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.purple : theme.secondaryText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Image(systemName: res.componentType.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.purple.opacity(0.15)))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(res.originalAppName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        Text(res.componentType.rawValue)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.15)))

                        Text(res.evidenceLabel)
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Text(res.path.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(res.confidence.rawValue)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(res.confidence == .auto ? Color(red: 0.95, green: 0.45, blue: 0.45) : Color.orange)
                    .frame(width: 82, height: 22)
                    .background(Capsule().fill((res.confidence == .auto ? Color(red: 0.95, green: 0.45, blue: 0.45) : Color.orange).opacity(0.12)))

                Text(res.formattedSize)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.purple)
                    .frame(width: 82, alignment: .trailing)

                Button {
                    uninstaller.muteOrphanedResidue(res)
                } label: {
                    Text("忽略此项")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 82, height: 22)
                        .background(Capsule().fill(theme.pillFill))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Color.clear.frame(width: 22, height: 22)

                uninstallerLocateButton(for: res.path)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)) : Color.clear)
            )
            .onHover { hovering in uninstaller.hoveredItemID = hovering ? res.id : nil }
            .contentShape(Rectangle())
        }
    }

    // MARK: - 命令行工具卸载行

    private func cliToolRow(_ tool: CommandLineToolItem) -> some View {
        let isHovered = (uninstaller.hoveredCliToolID == tool.id)
        let cliImg = CommandLineToolIconStore.shared.icon(forToolName: tool.name)

        return HStack(spacing: 12) {
            if let cliImg {
                Image(nsImage: cliImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.cyan)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.cyan.opacity(0.14)))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.displayTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    if tool.isRunning {
                        Text("正在运行")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    }

                    if tool.dependentFormulaCount > 0 {
                        Text("被 \(tool.dependentFormulaCount) 个包依赖")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }

                HStack(spacing: 6) {
                    Text("v\(tool.version)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                    Text("·").foregroundStyle(theme.secondaryText.opacity(0.5))
                    Text(tool.installURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(tool.source.rawValue)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.mint)
                .frame(width: 96, height: 22)
                .background(Capsule().fill(Color.mint.opacity(0.12)))

            Text(tool.formattedSize)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .frame(width: 82, alignment: .trailing)

            Button {
                uninstaller.uninstallCommandLineTool(tool)
            } label: {
                Text("卸载")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
                    .frame(width: 68, height: 22)
                    .background(Capsule().fill(Color(red: 0.95, green: 0.45, blue: 0.45).opacity(0.14)))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()

            uninstallerLocateButton(for: tool.installURL)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)) : Color.clear)
        )
        .onHover { hovering in uninstaller.hoveredCliToolID = hovering ? tool.id : nil }
    }

    // MARK: - 启动项管理行（按应用聚合 + 可展开明细）

    private func startupAppGroupRow(_ group: StartupAppGroup) -> some View {
        let isHovered = (startupManager.hoveredGroupID == group.id)
        let isExpanded = startupManager.expandedGroupIDs.contains(group.id)
        let statusColor: Color = {
            if group.hasAlert { return .red }
            if group.isOnlySystemSettingsManaged { return theme.secondaryText }
            if !group.isEnabled { return .gray }
            if group.isPartiallyEnabled { return .orange }
            if group.hasRunning { return .green }
            return .cyan
        }()

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let appURL = group.bundleURL {
                    NativeAppIconThumbnail(bundleURL: appURL)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: group.items.first?.kind.iconName ?? "bolt.circle.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(group.hasAlert ? Color.red : Color.orange)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill((group.hasAlert ? Color.red : Color.orange).opacity(0.14)))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.appName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        Text("\(group.items.count) 项服务")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.cyan.opacity(0.12)))

                        if group.hasDaemon {
                            Text("含守护进程")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.purple.opacity(0.13)))
                        }
                    }

                    Text(group.subtitleSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(group.hasAlert ? Color.red : theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(group.kindBadgeText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 96, height: 22)
                    .background(Capsule().fill(theme.pillFill))

                Text(group.statusBadgeText)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
                    .frame(width: 108, height: 22)
                    .background(Capsule().fill(statusColor.opacity(0.13)))

                Group {
                    if group.isOnlySystemSettingsManaged {
                        Button {
                            startupManager.openSystemLoginItemsSettings()
                        } label: {
                            Text("系统设置")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 56, height: 22)
                                .background(Capsule().fill(theme.pillFill))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { group.isEnabled },
                            set: { _ in startupManager.toggleGroup(group) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(.cyan)
                        .disabled(startupManager.isBusy)
                        .frame(width: 56)
                    }
                }

                Button {
                    startupManager.toggleGroupExpanded(group.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                uninstallerLocateButton(for: group.bundleURL ?? group.items[0].plistURL)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(group.items) { subItem in
                        startupSubItemRow(subItem)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)) : Color.clear)
        )
        .onHover { hovering in startupManager.hoveredGroupID = hovering ? group.id : nil }
    }

    private func startupSubItemRow(_ item: StartupItem) -> some View {
        let statusColor: Color = {
            switch item.runtimeStatus {
            case .running: return .green
            case .loadedIdle: return .cyan
            case .disabled: return .gray
            case .missingBinary, .errorExit: return .red
            }
        }()

        return HStack(spacing: 8) {
            Text(item.kind.rawValue)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(item.kind == .launchDaemon ? Color.purple : Color.cyan)
                .frame(width: 86, height: 20)
                .background(Capsule().fill((item.kind == .launchDaemon ? Color.purple : Color.cyan).opacity(0.12)))

            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(item.plistURL.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.runtimeStatus.label)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor)
                .frame(width: 96, height: 18)
                .background(Capsule().fill(statusColor.opacity(0.13)))

            if item.kind == .embeddedLoginItem {
                Button {
                    startupManager.openSystemLoginItemsSettings()
                } label: {
                    Text("系统设置")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 52, height: 18)
                        .background(Capsule().fill(theme.pillFill))
                }
                .buttonStyle(.plain)
            } else {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { _ in startupManager.toggleItem(item) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(.cyan)
                .disabled(startupManager.isBusy)
                .frame(width: 52)
            }

            if item.kind != .embeddedLoginItem {
                Button {
                    startupManager.trashStartupItem(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
                        .frame(width: 24, height: 18)
                        .background(Capsule().fill(Color(red: 0.95, green: 0.45, blue: 0.45).opacity(0.12)))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("注销服务并移出此启动配置 Plist")
            } else {
                Color.clear.frame(width: 24, height: 18)
            }

            uninstallerLocateButton(for: item.plistURL)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.pillFill))
    }

    // MARK: - BTM 系统诊断弹窗

    private var btmReportOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Label("macOS Background Task Management (BTM) 注册快照", systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Spacer()

                    if !startupManager.btmRecords.isEmpty {
                        Picker("视图", selection: $startupManager.showStructuredBtmView) {
                            Text("结构化列表 (\(startupManager.btmRecords.count))").tag(true)
                            Text("原始日志").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }

                    Button {
                        startupManager.isBtmSheetPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }

                if startupManager.showStructuredBtmView && !startupManager.btmRecords.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(startupManager.btmRecords) { record in
                                btmStructuredRow(record)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.05)))
                } else {
                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        Text(startupManager.btmRawReport)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.05)))
                }
            }
            .padding(20)
            .frame(width: 800, height: 540)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.14, green: 0.15, blue: 0.18) : Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 1))
            )
        }
    }

    private func btmStructuredRow(_ record: BTMDiagnosticRecord) -> some View {
        let dispLower = record.disposition.lowercased()
        let isEnabled = dispLower.contains("enabled")
        let dispColor: Color = isEnabled ? .green : .orange
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(record.name)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Text(record.type)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.cyan.opacity(0.14)))

                Text(record.disposition)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(dispColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(dispColor.opacity(0.14)))

                Spacer()
            }

            HStack(spacing: 8) {
                Text(record.identifier)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                if !record.parentIdentifier.isEmpty {
                    Text("· 上级：\(record.parentIdentifier)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                        .lineLimit(1)
                }
            }

            if record.urlPath != "—" {
                Text(record.urlPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.secondaryText.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
        )
    }

    private func uninstallerLocateButton(for url: URL) -> some View {
        Button {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10.5, weight: .bold))
                Text("定位")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(theme.secondaryText)
            .frame(width: 60, height: 22)
            .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    // MARK: - 通用卡片容器

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.studioCardFill))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Native App Icon Helper

private struct NativeAppIconThumbnail: View {
    let bundleURL: URL

    @MainActor
    private static let iconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    @MainActor
    private static func cachedIcon(for path: String) -> NSImage {
        let key = path as NSString
        if let hit = iconCache.object(forKey: key) {
            return hit
        }
        let raw = NSWorkspace.shared.icon(forFile: path)
        let scaled = AppIconManager.downsampledUIImage(from: raw, maxPixelSize: 64)
        iconCache.setObject(scaled, forKey: key)
        return scaled
    }

    var body: some View {
        Image(nsImage: Self.cachedIcon(for: bundleURL.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
