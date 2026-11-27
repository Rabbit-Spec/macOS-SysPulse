import SwiftUI
import AppKit

// MARK: - 磁盘空间分析视图

public struct StorageAnalysisSection: View {
    @Bindable var analysis = StorageAnalysisEngine.shared
    @Bindable var navState = StudioWindowNavigationState.shared
    @Bindable var permissions = SystemPermissionManager.shared
    let theme: LiquidGlassTheme
    var canvasWidth: CGFloat = 1200
    var canvasHeight: CGFloat = 822
    @Environment(\.colorScheme) private var colorScheme

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(684, canvasHeight - 79 - 59) }
    private var reviewCardH: CGFloat { max(380, contentH - 52 - 14 - 78 - 14 - 132 - 14) }

    public init(theme: LiquidGlassTheme, canvasWidth: CGFloat = 1200, canvasHeight: CGFloat = 822) {
        self.theme = theme
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("空间分析")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("选择位置逐层探索磁盘占用，无需反复扫描即可毫秒级钻取深层目录与海量大文件。")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(width: contentW, height: 52, alignment: .leading)

                primaryActionCard
                    .frame(width: contentW, height: 78)

                section2Group
                    .frame(width: contentW, height: 132)

                spaceReviewBrowserCard
                    .frame(width: contentW, height: reviewCardH)
            }
            .frame(width: contentW, height: contentH)
            .padding(.horizontal, 24)
            .padding(.top, 35)
            .padding(.bottom, 24)

            // 完全磁盘访问权限引导弹窗
            fdaGuidanceModal
        }
        .onAppear {
            permissions.checkFullDiskAccess()
            analysis.refreshMountedVolumes()
            if analysis.rootNode == nil && !analysis.isScanning {
                analysis.loadCachedSnapshotIfAvailable()
                if analysis.rootNode == nil {
                    if permissions.fullDiskAccessStatus == .authorized {
                        analysis.startScan()
                    } else {
                        // 未开启完全磁盘访问权限时，保持待机状态，避免初次切入空间页即触发一连串系统弹窗
                        analysis.status = .idle
                    }
                }
            } else if !analysis.isScanning {
                analysis.refreshHiddenInsights(for: analysis.selectedLocation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.checkFullDiskAccess()
        }
    }

    // MARK: - 空间概览指标卡片

    private var section2Group: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("空间洞察")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("· 快捷指标与系统空间诊断")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: contentW, height: 22, alignment: .leading)

            spaceInsightsOverviewCard
                .frame(width: contentW, height: 100)
        }
    }

    // MARK: - 1. 扫描状态与目录选择卡片

    private var primaryActionCard: some View {
        cardContainer {
            HStack(spacing: 0) {
                AnimatedModuleArtworkBadgeView(
                    size: 58,
                    isActive: analysis.isScanning,
                    accentColor: Color(red: 0.35, green: 0.85, blue: 0.75)
                ) {
                    SpaceAnalysisArtworkIconView(size: 58, forcedColorScheme: colorScheme)
                }
                .padding(.leading, 24)
                .padding(.trailing, 20)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 8) {
                        Text(primaryStatusTitle)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        if analysis.isShowingCachedSnapshot {
                            snapshotBadgeView
                        }

                        if analysis.isScanning {
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
        switch analysis.status {
        case .idle:
            return "准备分析 · \(analysis.selectedLocation.displayName)"
        case .scanning(let files, let bytes, _):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "正在遍历层级结构… (\(files) 项 · \(formatted))"
        case .completed(let files, let bytes, let duration):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let timeStr = String(format: "%.1fs", duration)
            return "\(analysis.selectedLocation.displayName) · 已完成分析 (\(files) 项 · \(formatted) · 耗时 \(timeStr))"
        case .cancelled:
            return "分析已中止 · \(analysis.selectedLocation.displayName)"
        }
    }

    private var primaryStatusSubtitle: String {
        switch analysis.status {
        case .idle:
            if permissions.fullDiskAccessStatus != .authorized {
                return "未开启完全磁盘访问权限：建议一次性授权以获得无死角全盘透视，并避免 macOS 反复针对各个文件夹单独弹窗。"
            }
            return analysis.selectedLocation.isBuiltInInternalLocation
                ? "仅扫描本机内置磁盘数据（自动隔离外置硬盘与 NAS 挂载卷），支持深层实时钻取与大文件快速透视。"
                : "独立分析所选外部/网络卷宗空间占用，不与本机存储混算。"
        case .scanning(_, _, let currentPath):
            return currentPath.isEmpty ? "正在遍历目录树…" : currentPath
        case .completed:
            return analysis.selectedLocation.isBuiltInInternalLocation
                ? "已隔离外置硬盘与 NAS 挂载卷，仅展示本机数据 · 点击文件夹可直接深层钻取。"
                : "已完成当前外部/网络卷宗空间索引构建，点击文件夹可直接深层钻取。"
        case .cancelled:
            return "已停止扫描，点击重新分析即可恢复。"
        }
    }

    private var actionButtonsGroup: some View {
        HStack(spacing: 12) {
            // 未授予完全磁盘访问权限时显示授权引导按钮
            if permissions.fullDiskAccessStatus != .authorized {
                Button {
                    permissions.openFullDiskAccessSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11.5, weight: .bold))
                        Text("授权完全磁盘访问")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(
                        Capsule().fill(Color.orange.opacity(colorScheme == .dark ? 0.15 : 0.08))
                    )
                    .overlay(
                        Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            locationPickerMenu

            if analysis.isScanning {
                Button {
                    analysis.cancelScan()
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            } else {
                Button {
                    // 分析全盘或主目录前检查完全磁盘访问权限
                    if permissions.fullDiskAccessStatus != .authorized && (analysis.selectedLocation == .home || analysis.selectedLocation == .entireDisk) {
                        analysis.showingFDAGuidance = true
                    } else {
                        analysis.startScan()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: analysis.rootNode == nil ? "sparkle.magnifyingglass" : "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))

                        Text(analysis.rootNode == nil ? "开始分析" : "重新分析")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(
                        Capsule(style: .continuous)
                            .fill(colorScheme == .dark ? Color.white : Color(white: 0.15))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
    }

    private var locationPickerMenu: some View {
        Menu {
            Section("本机存储") {
                Button {
                    analysis.startScan(location: .entireDisk)
                } label: {
                    Label("全盘概览 (/)", systemImage: "internaldrive.fill")
                }

                Button {
                    analysis.startScan(location: .home)
                } label: {
                    Label("个人主目录", systemImage: "house.fill")
                }

                Button {
                    analysis.startScan(location: .downloads)
                } label: {
                    Label("下载文件夹", systemImage: "arrow.down.circle.fill")
                }

                Button {
                    analysis.startScan(location: .documents)
                } label: {
                    Label("文稿文件夹", systemImage: "doc.text.fill")
                }

                Button {
                    analysis.startScan(location: .desktop)
                } label: {
                    Label("桌面", systemImage: "macwindow.on.rectangle")
                }

                Button {
                    analysis.startScan(location: .developer)
                } label: {
                    Label("开发目录 (Developer)", systemImage: "hammer.fill")
                }

                Button {
                    analysis.startScan(location: .applications)
                } label: {
                    Label("应用程序 (/Applications)", systemImage: "app.badge.fill")
                }
            }

            Section("外置硬盘") {
                if analysis.mountedExternalVolumes.isEmpty {
                    Button {} label: {
                        Label("未检测到外置硬盘", systemImage: "externaldrive")
                    }
                    .disabled(true)
                } else {
                    ForEach(analysis.mountedExternalVolumes) { vol in
                        Button {
                            analysis.startScan(location: .externalVolume(url: vol.url, name: vol.name))
                        } label: {
                            Label("\(vol.name)（\(vol.capacitySummary)）", systemImage: "externaldrive.fill")
                        }
                    }
                }
            }

            Section("网络存储 (SMB / NAS)") {
                if analysis.mountedNetworkVolumes.isEmpty {
                    Button {} label: {
                        Label("未连接 SMB / NAS 网络存储", systemImage: "network")
                    }
                    .disabled(true)
                } else {
                    ForEach(analysis.mountedNetworkVolumes) { vol in
                        Button {
                            analysis.startScan(location: .networkVolume(url: vol.url, name: vol.name))
                        } label: {
                            Label("\(vol.name)（\(vol.capacitySummary)）", systemImage: "externaldrive.connected.to.line.below.fill")
                        }
                    }
                }
            }

            Divider()

            Button {
                analysis.refreshMountedVolumes()
            } label: {
                Label("刷新存储设备列表", systemImage: "arrow.clockwise")
            }

            Button {
                selectCustomFolder()
            } label: {
                Label("选择自定文件夹…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: analysis.selectedLocation.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryText.opacity(0.85))

                Text(analysis.selectedLocation.displayName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.8)
            )
        }
        .menuStyle(.borderlessButton)
        .pointingHandOnHover()
        .fixedSize()
    }

    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择一个文件夹进行空间分析"

        if panel.runModal() == .OK, let url = panel.url {
            analysis.startScan(location: .custom(url))
        }
    }

    // MARK: - 2. 空间指标概览卡片

    private var spaceInsightsOverviewCard: some View {
        cardContainer {
            HStack(spacing: 0) {
                let deltaSubtitle: String = {
                    let base = "\(analysis.totalScannedFiles) 个项目"
                    var suffix = ""
                    if analysis.pendingSizingCount > 0 {
                        suffix = " · 后台核算 \(analysis.pendingSizingCount) 项"
                    } else if let delta = analysis.diskTelemetry.scanDeltaBytes {
                        if abs(delta) < 1024 * 1024 {
                            suffix = " · 较上次持平"
                        } else {
                            let sign = delta >= 0 ? "+" : "-"
                            let absStr = ByteCountFormatter.string(fromByteCount: abs(delta), countStyle: .file)
                            suffix = " · 较上次 \(sign)\(absStr)"
                        }
                    }
                    return base + suffix
                }()

                insightStatColumn(
                    icon: "chart.pie.fill",
                    color: Color.cyan,
                    title: analysis.selectedLocation == .entireDisk ? "当前扫描总计" : "当前目录总计",
                    value: analysis.formattedTotalBytes,
                    subtitle: deltaSubtitle
                )

                dividerLine

                let telemetry = analysis.diskTelemetry
                let purgeable = analysis.hiddenInsights.first(where: { $0.id == "purgeable" })?.detectedSize ?? "自动管理"
                let diskUsedText = telemetry.volumeUsedBytes > 0
                    ? ByteCountFormatter.string(fromByteCount: telemetry.volumeUsedBytes, countStyle: .file)
                    : "--"
                let diskTotalText = telemetry.volumeTotalBytes > 0
                    ? ByteCountFormatter.string(fromByteCount: telemetry.volumeTotalBytes, countStyle: .file)
                    : "--"
                let apfsGapSubtitle: String = {
                    guard telemetry.volumeTotalBytes > 0 else { return "APFS 物理块与系统预留" }
                    if analysis.selectedLocation == .entireDisk,
                       analysis.totalScannedBytes > 0,
                       telemetry.volumeUsedBytes > 0 {
                        let diff = telemetry.volumeUsedBytes - analysis.totalScannedBytes
                        if diff > 1024 * 1024 * 512 {
                            let gapStr = ByteCountFormatter.string(fromByteCount: diff, countStyle: .file)
                            return "总 \(diskTotalText) · 系统/快照差异 \(gapStr)"
                        } else if diff < -1024 * 1024 * 512 {
                            let cloneStr = ByteCountFormatter.string(fromByteCount: -diff, countStyle: .file)
                            return "总 \(diskTotalText) · 含 APFS 克隆 \(cloneStr)"
                        }
                    }
                    return "总 \(diskTotalText) · 可清除 \(purgeable)"
                }()
                insightStatColumn(
                    icon: "internaldrive.fill",
                    color: Color.blue,
                    title: analysis.selectedLocation == .entireDisk ? "卷宗已用空间" : "整盘已用空间",
                    value: diskUsedText,
                    subtitle: apfsGapSubtitle
                )
                .help("与 macOS 系统设置口径一致（已扣除可清除空间 \(purgeable)）。底层的 APFS 本地快照与系统可回收缓存将在需要空间时自动释放。")

                dividerLine

                insightStatColumn(
                    icon: "flame.fill",
                    color: Color.orange,
                    title: "最大单项占用",
                    value: analysis.topLargeFiles.first?.formattedSize ?? "--",
                    subtitle: analysis.topLargeFiles.first?.name ?? "未检测到大文件"
                )

                dividerLine

                let snapshot = analysis.hiddenInsights.first(where: { $0.id == "apfs_snapshots" })?.detectedSize ?? "0 个快照"
                insightStatColumn(
                    icon: "clock.arrow.circlepath",
                    color: Color.purple,
                    title: "APFS 本地快照",
                    value: snapshot,
                    subtitle: "时间机器只读镜像"
                )
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func insightStatColumn(
        icon: String,
        color: Color,
        title: String,
        value: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(colorScheme == .dark ? 0.2 : 0.12))
                    .frame(width: 38, height: 38)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)

                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            .frame(width: 1, height: 48)
            .padding(.horizontal, 12)
    }

    // MARK: - 3. 目录层级与大文件浏览卡片

    private var spaceReviewBrowserCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                // 1. Tool Bar Header (高度固定 44 pt)
                browserToolBar
                    .frame(height: 44)
                    .padding(.horizontal, 16)

                if let actionMsg = analysis.lastActionMessage {
                    HStack(spacing: 8) {
                        Image(systemName: actionMsg.contains("拦截") || actionMsg.contains("失败") || actionMsg.contains("无法") ? "exclamationmark.shield.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(actionMsg.contains("拦截") || actionMsg.contains("失败") || actionMsg.contains("无法") ? Color.orange : Color.green)
                        Text(actionMsg)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            analysis.lastActionMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                }

                Divider()
                    .overlay(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))

                ZStack {
                    if analysis.isScanning && analysis.rootNode == nil {
                        scanningProgressView
                    } else if analysis.rootNode == nil {
                        emptyStateView
                    } else {
                        switch analysis.activeViewMode {
                        case .browser:
                            browserHierarchyView
                        case .treemap:
                            StorageTreemapView(analysis: analysis, theme: theme)
                        case .largeFiles:
                            largeFilesRankingView
                        case .insights:
                            hiddenSpaceInsightsView
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var snapshotBadgeView: some View {
        Button {
            analysis.startScan()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .bold))
                Text(snapshotRelativeText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                Text("刷新")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.cyan.opacity(colorScheme == .dark ? 0.16 : 0.1)))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help("当前展示为上次扫描缓存快照，点击刷新实时数据")
    }

    private var snapshotRelativeText: String {
        guard let date = analysis.lastSnapshotDate else { return "上次快照 ·" }
        let mins = max(0, Int(Date().timeIntervalSince(date) / 60))
        if mins < 1 { return "刚刚快照 ·" }
        if mins < 60 { return "\(mins) 分钟前快照 ·" }
        let hours = mins / 60
        if hours < 24 { return "\(hours) 小时前快照 ·" }
        return "\(hours / 24) 天前快照 ·"
    }

    // MARK: - 路径面包屑与视图模式工具栏

    private var browserToolBar: some View {
        HStack(spacing: 12) {
            if analysis.activeViewMode == .browser || analysis.activeViewMode == .treemap {
                HStack(spacing: 6) {
                    Button {
                        analysis.navigateUp()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(analysis.breadcrumbStack.count > 1 ? theme.primaryText : theme.secondaryText.opacity(0.3))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(analysis.breadcrumbStack.count <= 1)
                    .help("返回上一级目录 (⌘↑)")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(analysis.breadcrumbStack.enumerated()), id: \.offset) { index, node in
                                let isLast = (index == analysis.breadcrumbStack.count - 1)
                                Button {
                                    analysis.navigateToBreadcrumb(at: index)
                                } label: {
                                    HStack(spacing: 4) {
                                        if index == 0 {
                                            Image(systemName: analysis.selectedLocation.iconName)
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                        Text(node.name)
                                            .font(.system(size: 12, weight: isLast ? .bold : .medium, design: .rounded))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(isLast ? theme.primaryText : theme.secondaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(isLast ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                                .pointingHandOnHover()

                                if !isLast {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(theme.secondaryText.opacity(0.5))
                                }
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .layoutPriority(-1)
                }
                .layoutPriority(-1)
            } else if analysis.activeViewMode == .largeFiles {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.orange)

                    Text("当前位置下前 100 大文件排行榜")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.cyan)

                    Text("系统空间诊断")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }
            }

            Spacer(minLength: 4)

            if analysis.activeViewMode == .browser && analysis.rootNode != nil {
                HStack(spacing: 6) {
                    if analysis.isMultiSelectMode {
                        Button {
                            analysis.selectUnusedOverYearInCurrentFolder()
                        } label: {
                            Text("选一年未动")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.orange)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()

                        if !analysis.selectedNodeIDs.isEmpty {
                            let selStr = ByteCountFormatter.string(fromByteCount: analysis.selectedNodesBytes, countStyle: .file)
                            Button {
                                analysis.moveSelectedNodesToTrash()
                            } label: {
                                Text("移到废纸篓 (\(analysis.selectedNodeIDs.count) · \(selStr))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .frame(height: 26)
                                    .background(Capsule().fill(Color.red))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            analysis.showHiddenFilesInBrowser.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: analysis.showHiddenFilesInBrowser ? "eye.fill" : "eye.slash")
                                .font(.system(size: 10.5))
                            Text(analysis.hiddenEntriesCountInCurrentFolder > 0 ? "隐藏文件夹(\(analysis.hiddenEntriesCountInCurrentFolder))" : "隐藏文件夹")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(analysis.showHiddenFilesInBrowser ? Color.cyan : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Capsule().fill((analysis.showHiddenFilesInBrowser ? Color.cyan : Color.gray).opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("显示或隐藏 .ollama / .cache / .claude 等以点开头的目录")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            analysis.isMultiSelectMode.toggle()
                            if !analysis.isMultiSelectMode {
                                analysis.clearNodeSelection()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checklist")
                                .font(.system(size: 10.5))
                            Text("多选")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(analysis.isMultiSelectMode ? Color.blue : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Capsule().fill((analysis.isMultiSelectMode ? Color.blue : Color.gray).opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    if let current = analysis.currentNode {
                        Button {
                            analysis.refreshNode(current)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help("仅刷新当前目录（无需整盘重扫）")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }

            HStack(spacing: 2) {
                ForEach(AnalysisViewMode.allCases) { mode in
                    let isSelected = (analysis.activeViewMode == mode)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            analysis.activeViewMode = mode
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(mode.rawValue)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(isSelected ? (colorScheme == .dark ? Color.black : Color.white) : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? (colorScheme == .dark ? Color.white : Color(white: 0.15)) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(3)
            .background(
                Capsule(style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            if analysis.activeViewMode != .insights {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)

                    TextField("过滤名称…", text: $analysis.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 110)

                    if !analysis.searchQuery.isEmpty {
                        Button {
                            analysis.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                )
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
        }
    }

    // MARK: - View Mode 1: Hierarchy Browser View (层级钻取)

    private var browserHierarchyView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("名称")
                    .frame(width: 380, alignment: .leading)

                Text("占用比例")
                    .frame(width: 220, alignment: .leading)

                Text("大小")
                    .frame(width: 120, alignment: .trailing)

                Spacer()

                Text("操作")
                    .frame(width: 140, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 20)
            .frame(height: 28)
            .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))

            Divider()
                .overlay(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))

            let items = analysis.currentFolderChildren
            let currentDirTotalBytes = max(1, analysis.currentNode?.sizeBytes ?? 1)
            let collapseLimit = 20
            let shouldCollapseTail = !analysis.isTailExpanded && items.count > 25 && analysis.searchQuery.isEmpty
            let visibleItems = shouldCollapseTail ? Array(items.prefix(collapseLimit)) : items
            let hiddenTailItems = shouldCollapseTail ? Array(items.dropFirst(collapseLimit)) : []

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 32))
                        .foregroundStyle(theme.secondaryText.opacity(0.5))
                    Text(analysis.searchQuery.isEmpty ? "此文件夹为空" : "未找到匹配的项目")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleItems) { item in
                            browserRow(item: item, totalDirBytes: currentDirTotalBytes)
                            Divider()
                                .overlay(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
                        }

                        if shouldCollapseTail {
                            let tailBytes = hiddenTailItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
                            let tailFormatted = ByteCountFormatter.string(fromByteCount: tailBytes, countStyle: .file)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    analysis.isTailExpanded = true
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "ellipsis.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.secondaryText)
                                    Text("其余 \(hiddenTailItems.count) 个较小项目（合计 \(tailFormatted)）· 点击展开全部")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(theme.secondaryText)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func browserRow(item: AnalysisNode, totalDirBytes: Int64) -> some View {
        let proportion = min(1.0, max(0.0, Double(item.sizeBytes) / Double(totalDirBytes)))
        let percentStr = String(format: "%.1f%%", proportion * 100)
        let isSelected = analysis.selectedNodeIDs.contains(item.id)

        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                if analysis.isMultiSelectMode {
                    Button {
                        analysis.toggleNodeSelection(item)
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.blue : theme.secondaryText.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        if item.isHiddenFolder {
                            Text("隐藏目录")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.cyan.opacity(0.12)))
                        }

                        if item.isCloudPlaceholder {
                            Text("仅在云端")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.teal)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.teal.opacity(0.14)))
                        }

                        if let owner = item.ownerAppName, !owner.isEmpty {
                            Text(owner)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.purple.opacity(0.14)))
                        }

                        if item.isProtectedOrUnreadable {
                            Text("需磁盘访问权限")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        } else if item.isSizingPending {
                            Text("核算中")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.14)))
                        }

                        if !item.isDirectory && item.isUnusedOverYear {
                            Text("一年未动")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                    }

                    if item.isDirectory {
                        if item.isProtectedOrUnreadable {
                            Text("受系统隐私保护 · 开启完全磁盘访问权限后可精确统计")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color.orange.opacity(0.9))
                                .lineLimit(1)
                        } else if let hint = analysis.folderPurposeHint(for: item) {
                            Text("\(item.childCount) 项 · \(hint)")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        } else {
                            Text("\(item.childCount) 项")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(theme.secondaryText)
                        }
                    } else if item.isPackage {
                        Text("应用软件包 · \(item.extensionName)")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.indigo)
                    } else {
                        Text(item.extensionName.isEmpty ? "文件" : "\(item.extensionName) 文件")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .frame(width: 380, alignment: .leading)

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                            .frame(height: 6)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, geo.size.width * CGFloat(proportion)), height: 6)
                    }
                }
                .frame(width: 140, height: 6)

                Text(percentStr)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 50, alignment: .trailing)
            }
            .frame(width: 220, alignment: .leading)

            Text(item.formattedSize)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(item.isProtectedOrUnreadable ? Color.orange : theme.primaryText)
                .frame(width: 120, alignment: .trailing)

            Spacer()

            HStack(spacing: 6) {
                if item.isDirectory && !item.isProtectedOrUnreadable {
                    Button {
                        analysis.navigateTo(node: item)
                    } label: {
                        HStack(spacing: 4) {
                            Text("进入")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                } else if !item.isDirectory {
                    Button {
                        analysis.previewWithQuickLook(url: item.url)
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("快速预览 (Quick Look)")
                }

                Button {
                    analysis.revealInFinder(url: item.url)
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("在访达中显示")

                Button {
                    analysis.moveToTrash(node: item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.red.opacity(colorScheme == .dark ? 0.15 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("移到废纸篓")
            }
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory {
                analysis.navigateTo(node: item)
            } else {
                analysis.revealInFinder(url: item.url)
            }
        }
        .contextMenu {
            if item.isDirectory {
                Button {
                    analysis.navigateTo(node: item)
                } label: {
                    Label("进入目录", systemImage: "arrow.right.circle")
                }
                Button {
                    analysis.refreshNode(item)
                } label: {
                    Label("刷新此目录", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    analysis.previewWithQuickLook(url: item.url)
                } label: {
                    Label("快速预览 (Quick Look)", systemImage: "eye")
                }
                Button {
                    analysis.openItem(url: item.url)
                } label: {
                    Label("打开文件", systemImage: "arrow.up.forward.app")
                }
            }
            Button {
                analysis.revealInFinder(url: item.url)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            Button {
                analysis.copyPath(item.path)
            } label: {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                analysis.moveToTrash(node: item)
            } label: {
                Label("移到废纸篓", systemImage: "trash")
            }
        }
    }

    // MARK: - View Mode 2: Large Files Ranking View (最大文件排行榜)

    private var largeFilesRankingView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("排名 / 文件名称")
                    .frame(width: 420, alignment: .leading)

                Text("所在父目录")
                    .frame(width: 240, alignment: .leading)

                Text("文件大小")
                    .frame(width: 120, alignment: .trailing)

                Spacer()

                Text("操作")
                    .frame(width: 120, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 20)
            .frame(height: 28)
            .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))

            Divider()
                .overlay(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))

            let items = analysis.filteredLargeFiles
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 32))
                        .foregroundStyle(theme.secondaryText.opacity(0.5))
                    Text(analysis.searchQuery.isEmpty ? "未发现超过 50MB 的大型文件" : "未找到匹配的大文件")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            largeFileRow(rank: index + 1, item: item)
                            Divider()
                                .overlay(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func largeFileRow(rank: Int, item: AnalysisLargeFileItem) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(rankBadgeColor(rank: rank).opacity(colorScheme == .dark ? 0.2 : 0.12))
                        .frame(width: 26, height: 20)

                    Text("\(rank)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(rankBadgeColor(rank: rank))
                }

                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        if item.isUnusedOverYear {
                            Text("一年未动")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                    }

                    Text("\(item.extensionName) · \(item.fileKind.rawValue)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(width: 420, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Text(item.parentDirectoryName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 240, alignment: .leading)

            Text(item.formattedSize)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .frame(width: 120, alignment: .trailing)

            Spacer()

            HStack(spacing: 8) {
                Button {
                    analysis.previewWithQuickLook(url: item.url)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("快速预览 (Quick Look)")

                Button {
                    analysis.revealInFinder(url: item.url)
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("在访达中显示")

                Button {
                    analysis.moveToTrash(largeFile: item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.red.opacity(colorScheme == .dark ? 0.15 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("移到废纸篓")
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            analysis.revealInFinder(url: item.url)
        }
        .contextMenu {
            Button {
                analysis.previewWithQuickLook(url: item.url)
            } label: {
                Label("快速预览 (Quick Look)", systemImage: "eye")
            }
            Button {
                analysis.openItem(url: item.url)
            } label: {
                Label("打开文件", systemImage: "arrow.up.forward.app")
            }
            Button {
                analysis.revealInFinder(url: item.url)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            Button {
                analysis.copyPath(item.path)
            } label: {
                Label("复制完整路径", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                analysis.moveToTrash(largeFile: item)
            } label: {
                Label("移到废纸篓", systemImage: "trash")
            }
        }
    }

    private func rankBadgeColor(rank: Int) -> Color {
        switch rank {
        case 1: return Color.orange
        case 2: return Color.purple
        case 3: return Color.cyan
        default: return Color.gray
        }
    }

    // MARK: - View Mode 3: System Space Insights View (系统空间诊断)

    private var hiddenSpaceInsightsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !analysis.ageBuckets.isEmpty || !analysis.sizeBuckets.isEmpty || !analysis.kindBuckets.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        if !analysis.ageBuckets.isEmpty {
                            breakdownCard(
                                title: "文件沉睡时长",
                                icon: "clock.badge.exclamationmark.fill",
                                tint: .orange,
                                buckets: analysis.ageBuckets,
                                totalBytes: max(1, analysis.totalScannedBytes)
                            )
                        }

                        if !analysis.sizeBuckets.isEmpty {
                            breakdownCard(
                                title: "体积分层占比",
                                icon: "chart.bar.fill",
                                tint: .purple,
                                buckets: analysis.sizeBuckets,
                                totalBytes: max(1, analysis.totalScannedBytes)
                            )
                        }

                        if !analysis.kindBuckets.isEmpty {
                            breakdownCard(
                                title: "文件类型构成",
                                icon: "square.grid.2x2.fill",
                                tint: .cyan,
                                buckets: Array(analysis.kindBuckets.prefix(4)),
                                totalBytes: max(1, analysis.totalScannedBytes)
                            )
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !analysis.toolAdvisories.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.mint)
                            Text("CLI 专项工具深度占用建议（Docker / Ollama / Xcode / Homebrew）")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                        }

                        ForEach(analysis.toolAdvisories) { adv in
                            HStack(spacing: 12) {
                                Image(systemName: adv.iconName)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Color.mint)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(Color.mint.opacity(0.14)))

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(adv.toolName)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(theme.primaryText)
                                        Text(adv.formattedSize)
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.mint)
                                    }
                                    Text(adv.summary)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(theme.secondaryText)
                                    Text(adv.cliCommand)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(theme.primaryText.opacity(0.9))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)))
                                }

                                Spacer()

                                Button("复制命令") {
                                    analysis.copyPath(adv.cliCommand)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("打开目录") {
                                    analysis.revealInFinder(url: adv.targetURL)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.mint.opacity(colorScheme == .dark ? 0.06 : 0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.mint.opacity(0.2), lineWidth: 0.8))
                            )
                        }
                    }
                }

                ForEach(analysis.hiddenInsights) { insight in
                    hiddenInsightRow(insight: insight)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func breakdownCard(
        title: String,
        icon: String,
        tint: Color,
        buckets: [AnalysisBucketMetric],
        totalBytes: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }

            ForEach(buckets) { bucket in
                let ratio = min(1.0, max(0.0, Double(bucket.bytes) / Double(totalBytes)))
                let col = badgeColor(name: bucket.tintName)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(bucket.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Text("\(bucket.formattedSize) · \(bucket.count) 项")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06))
                                .frame(height: 5)
                            Capsule()
                                .fill(col)
                                .frame(width: max(4, geo.size.width * CGFloat(ratio)), height: 5)
                        }
                    }
                    .frame(height: 5)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04), lineWidth: 0.8))
        )
    }

    private func hiddenInsightRow(insight: HiddenSpaceInsight) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(badgeColor(name: insight.badgeColorName).opacity(colorScheme == .dark ? 0.2 : 0.12))
                    .frame(width: 38, height: 38)

                Image(systemName: insight.iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(badgeColor(name: insight.badgeColorName))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(insight.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text(insight.badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(badgeColor(name: insight.badgeColorName))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(badgeColor(name: insight.badgeColorName).opacity(colorScheme == .dark ? 0.15 : 0.1))
                        )

                    Spacer()

                    if let detected = insight.detectedSize {
                        Text(detected)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                }

                Text(insight.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText.opacity(0.85))

                Text(insight.detailedExplanation)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04), lineWidth: 0.8)
        )
    }

    private func badgeColor(name: String) -> Color {
        switch name {
        case "blue": return Color.blue
        case "purple": return Color.purple
        case "green": return Color.green
        case "cyan": return Color.cyan
        case "orange": return Color.orange
        case "red": return Color.red
        case "mint": return Color.mint
        case "indigo": return Color.indigo
        case "pink": return Color.pink
        case "teal": return Color.teal
        default: return Color.gray
        }
    }

    // MARK: - Scanning & Empty States

    private var scanningProgressView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)

            Text("正在全面分析 \(analysis.selectedLocation.displayName)…")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            Text("已遍历 \(analysis.totalScannedFiles) 项 · 已发现 \(analysis.formattedTotalBytes)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(theme.secondaryText.opacity(0.6))

            Text("选择一个位置，找出最占空间的文件和文件夹")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            Text("分析后可以逐层点进文件夹查看，不用重新分析。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 通用卡片容器

    @ViewBuilder
    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.studioCardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
            )
    }

    // MARK: - 完全磁盘访问权限引导弹窗

    @ViewBuilder
    private var fdaGuidanceModal: some View {
        if analysis.showingFDAGuidance {
            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.6 : 0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        analysis.showingFDAGuidance = false
                    }

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.18))
                            .frame(width: 54, height: 54)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(.top, 4)

                    Text("需要「完全磁盘访问权限」")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("分析「个人主目录」需要完全磁盘访问权限。若不授权，macOS 将针对桌面、文稿、下载等各个文件夹单独弹出系统授权窗口。\n\n建议前往系统设置直接开启完全磁盘访问，一次授权即可畅通透视整盘空间。")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 380)

                    Divider()
                        .padding(.vertical, 4)

                    HStack(spacing: 10) {
                        Button {
                            analysis.showingFDAGuidance = false
                        } label: {
                            Text("取消")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 70, height: 32)
                                .background(
                                    Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()

                        Button {
                            analysis.showingFDAGuidance = false
                            analysis.selectedLocation = .downloads
                            analysis.startScan(location: .downloads)
                        } label: {
                            Text("仅分析下载文件夹")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(
                                    Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()

                        Button {
                            analysis.showingFDAGuidance = false
                            permissions.openFullDiskAccessSettings()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11))
                                Text("前往设置授权")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(
                                Capsule().fill(Color.orange)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(theme.cardBorder, lineWidth: 1.0)
                        )
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15), radius: 20, y: 10)
                )
                .frame(width: 440)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.snappy(duration: 0.2), value: analysis.showingFDAGuidance)
        }
    }
}
