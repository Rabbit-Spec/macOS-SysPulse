import SwiftUI
import AppKit

// MARK: - 智能清理视图

public struct StorageCleanerSection: View {
    @Bindable var cleaner = SystemCleanerEngine.shared
    @Bindable var protectionStore = CleanProtectionStore.shared
    @Bindable var navState = StudioWindowNavigationState.shared
    let theme: LiquidGlassTheme
    var canvasWidth: CGFloat = 1200
    var canvasHeight: CGFloat = 822
    @Environment(\.colorScheme) private var colorScheme

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(684, canvasHeight - 79 - 59) }
    private var reviewCardH: CGFloat {
        max(340, contentH - 52 - 14 - 78 - 14 - 132 - 14)
    }

    private var selectedBucketFilter: CleanReviewBucket? {
        get { navState.cleanerBucketFilter }
        nonmutating set { navState.cleanerBucketFilter = newValue }
    }

    public init(theme: LiquidGlassTheme, canvasWidth: CGFloat = 1200, canvasHeight: CGFloat = 822) {
        self.theme = theme
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("智能清理")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("一次扫描后完成复核、清理保护核验与结果确认；缓存、日志、卸载残留与废纸篓都会进入统一安全流程。")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(width: contentW, height: 52, alignment: .leading)

                primaryActionCard
                    .frame(width: contentW, height: 78)

                if protectionStore.isWhitelistReadBlocked {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.red)
                        Text(protectionStore.lastErrorMessage ?? "清理保护名单异常且无法读取，为安全起见已强制拦截清理。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.red)
                            .lineLimit(1)
                        Spacer()
                        Button("重新读取") {
                            protectionStore.load()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.14)))
                        .pointingHandOnHover()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(width: contentW)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.red.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.28), lineWidth: 1))
                    )
                }

                if cleaner.queuedCleanAfterCurrentOp {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(cleaner.queuedOperationNotice ?? "当前有另一项操作正在进行，将在完成后自动开始清理…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.cyan)
                            .lineLimit(1)
                        Spacer()
                        Button("取消排队") {
                            cleaner.cancelQueuedClean()
                        }
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.pillFill))
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(width: contentW)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.cyan.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cyan.opacity(0.28), lineWidth: 1))
                    )
                }

                section2Group
                    .frame(width: contentW, height: 132)

                if cleaner.isScanning && cleaner.scannedItems.isEmpty {
                    scanningProgressPanel
                        .frame(width: contentW)
                        .frame(maxHeight: .infinity)
                } else if !cleaner.scannedItems.isEmpty || cleaner.lastExecutionSummary != nil {
                    scannedReviewItemsCard
                        .frame(width: contentW)
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: contentW, height: contentH)
            .padding(.horizontal, 24)
            .padding(.top, 35)
            .padding(.bottom, 24)

            if cleaner.isRunningConflictDialogPresented {
                runningConflictsOverlay
            }
        }
        .onAppear {
            cleaner.startAutoScanIfNeeded()
        }
    }

    // MARK: - 清理说明与残留分类卡片

    private var section2Group: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("清理说明")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("· 检查以下 \(CleanCategory.allCases.count) 类残留")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: contentW, height: 22, alignment: .leading)

            categoriesAndSafetyCard
                .frame(width: contentW, height: 100)
        }
    }

    // MARK: - 1. 扫描状态与主操作卡片

    private var primaryActionCard: some View {
        cardContainer {
            HStack(spacing: 0) {
                AnimatedModuleArtworkBadgeView(
                    size: 58,
                    isActive: cleaner.isScanning || cleaner.isCleaning,
                    accentColor: .cyan
                ) {
                    CleanerArtworkIconView(size: 58, forcedColorScheme: colorScheme)
                }
                .padding(.leading, 24)
                .padding(.trailing, 20)

                VStack(alignment: .leading, spacing: 3.5) {
                    HStack(spacing: 8) {
                        Text(primaryStatusTitle)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        if cleaner.isScanning {
                            Text("阶段 \(min(8, max(1, cleaner.scanStageIndex)))/8 · 已发现 \(cleaner.scanDiscoveredCount) 项")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.cyan.opacity(0.14)))
                        } else if cleaner.isCleaning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(primaryStatusSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)

                    if cleaner.isScanning {
                        cleanerHorizontalProgressBar(progress: cleaner.scanProgressValue)
                            .frame(maxWidth: 360)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                actionButtonsGroup
                    .padding(.trailing, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cleanerHorizontalProgressBar(progress: Double) -> some View {
        let clamped = min(max(progress, 0.02), 1.0)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.gaugeTrack)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .mint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * clamped))
                    .animation(.easeOut(duration: 0.22), value: clamped)
            }
        }
        .frame(height: 5.5)
    }

    private var scanningProgressPanel: some View {
        let stages: [(index: Int, title: String, subtitle: String)] = [
            (1, "用户与通讯缓存", "应用沙盒及聊天媒体临时缓存"),
            (2, "系统与运行日志", "系统诊断日志与三方运行记录"),
            (3, "浏览器网页缓存", "Safari、Chrome 等网页离线缓存"),
            (4, "崩溃诊断报告", "历史应用崩溃转储与 .ips 报告"),
            (5, "开发与闲置依赖", "Xcode 派生数据与构建依赖仓库"),
            (6, "应用卸载残留", "已卸载程序配置、容器及更新包"),
            (7, "废纸篓与安装包", "废纸篓待清理项及历史 DMG 安装包"),
            (8, "手动大体积存储项", "云同步副本、备份及虚拟机映像")
        ]
        let clamped = min(max(cleaner.scanProgressValue, 0.0), 1.0)
        let percent = Int((clamped * 100).rounded())
        let discoveredSize = ByteCountFormatter.string(fromByteCount: cleaner.scanDiscoveredBytes, countStyle: .file)
        let rows = [Array(stages[0..<4]), Array(stages[4..<8])]

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("实时扫描进度")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Text("\(percent)%")
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.cyan)
                    }

                    Text(cleaner.currentScanPath.isEmpty ? "正在排查系统目录与安全白名单路径…" : cleaner.currentScanPath)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 14) {
                    Label("\(cleaner.scanDiscoveredCount) 项", systemImage: "doc.on.doc")
                    Label(discoveredSize, systemImage: "internaldrive")
                }
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
            }

            cleanerHorizontalProgressBar(progress: clamped)

            VStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, rowStages in
                    HStack(spacing: 12) {
                        ForEach(rowStages, id: \.index) { stage in
                            let isDone: Bool = cleaner.scanStageIndex > stage.index
                            let isActive: Bool = cleaner.scanStageIndex == stage.index
                            let accent: Color = isDone ? .mint : (isActive ? .cyan : theme.secondaryText.opacity(0.45))
                            let iconName: String = isDone ? "checkmark.circle.fill" : (isActive ? "circle.dotted" : "circle")
                            let statusLabel: String = isDone ? "已完成" : (isActive ? "扫描中" : "等待中")
                            let statusColor: Color = (isDone || isActive) ? accent : theme.secondaryText.opacity(0.55)
                            let titleColor: Color = (isDone || isActive) ? theme.primaryText : theme.secondaryText.opacity(0.8)
                            let subtitleColor: Color = theme.secondaryText.opacity((isDone || isActive) ? 0.92 : 0.6)
                            let bgColor: Color = isActive
                                ? Color.cyan.opacity(colorScheme == .dark ? 0.12 : 0.08)
                                : (isDone ? Color.mint.opacity(colorScheme == .dark ? 0.07 : 0.05) : theme.pillFill.opacity(0.55))
                            let strokeColor: Color = isActive
                                ? Color.cyan.opacity(0.45)
                                : (isDone ? Color.mint.opacity(0.26) : theme.studioCardBorder.opacity(0.7))
                            let strokeWidth: CGFloat = isActive ? 1.2 : 0.8

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: iconName)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(accent)

                                    Text(String(format: "%02d", stage.index))
                                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(accent.opacity(0.14)))

                                    Spacer(minLength: 0)

                                    Text(statusLabel)
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(statusColor)
                                }

                                Spacer(minLength: 0)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(stage.title)
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundStyle(titleColor)
                                        .lineLimit(1)

                                    Text(stage.subtitle)
                                        .font(.system(size: 11.5, weight: .regular))
                                        .foregroundStyle(subtitleColor)
                                        .lineLimit(2)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(bgColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(strokeColor, lineWidth: strokeWidth)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.studioCardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.studioCardBorder, lineWidth: 1)
        )
    }

    private var primaryStatusTitle: String {
        switch cleaner.status {
        case .idle:
            return cleaner.lastCleanDescription
        case .scanning(let progress, _):
            let percent = Int((min(max(progress, 0.0), 1.0) * 100).rounded())
            return "正在全面排查系统残留… \(percent)%"
        case .completed:
            return "预计可释放 \(cleaner.formattedSelectedBytes)"
        case .cleaning:
            return "正在安全清理选定项目…"
        case .cleaned(let freed, _):
            return "清理完成！已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
        }
    }

    private var primaryStatusSubtitle: String {
        switch cleaner.status {
        case .idle:
            return "扫描不会删除任何内容，所有路径均经过白名单与系统红线双重防护。"
        case .scanning(_, let path):
            return path.isEmpty ? "正在排查用户缓存与系统残留…" : path
        case .completed:
            let selectedCount = cleaner.selectedItemIDs.count
            let excludedCount = cleaner.count(for: .excluded)
            if excludedCount > 0 {
                return "已选中 \(selectedCount) 项 · 另有 \(excludedCount) 项受保护名单/安全策略自动跳过。"
            }
            return "已选中 \(selectedCount) 项安全残留，包含用户缓存、日志与安装包。"
        case .cleaning(_, let item):
            return item
        case .cleaned(_, let itemCount):
            if let summary = cleaner.lastExecutionSummary {
                return "已处理 \(itemCount) 项 · 跳过 \(summary.skippedCount) 项 · 失败 \(summary.failedCount) 项（可在下方查看明细）。"
            }
            return "磁盘空间已成功释放，系统运行更加轻快。"
        }
    }

    private var actionButtonsGroup: some View {
        HStack(spacing: 12) {
            switch cleaner.status {
            case .idle:
                scanButton
                optionsButton

            case .scanning:
                Button {
                    cleaner.cancelScan()
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(
                            Capsule().fill(theme.pillFill)
                                .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

            case .completed, .cleaned:
                Button {
                    cleaner.showExecutionDetails = true
                    cleaner.startScan()
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
                    .background(
                        Capsule().fill(theme.pillFill)
                            .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                if cleaner.selectedBytes > 0 {
                    Button {
                        cleaner.showExecutionDetails = true
                        cleaner.executeClean()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                            Text("立即清理 (\(cleaner.formattedSelectedBytes))")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(
                            Capsule()
                                .fill(LinearGradient(
                                    colors: colorScheme == .dark
                                        ? [Color(red: 0.08, green: 0.52, blue: 0.96), Color(red: 0.10, green: 0.65, blue: 0.88)]
                                        : [Color(red: 0.04, green: 0.46, blue: 0.90), Color(red: 0.07, green: 0.58, blue: 0.86)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .shadow(color: Color(red: 0.04, green: 0.48, blue: 0.90).opacity(colorScheme == .dark ? 0.32 : 0.25), radius: 4, y: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                optionsButton

            case .cleaning:
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var scanButton: some View {
        Button {
            cleaner.startScan()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("扫描")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                    .overlay(
                        Capsule().strokeBorder(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12), lineWidth: 0.8)
                    )
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
                .background(
                    Circle().fill(theme.pillFill)
                        .overlay(Circle().strokeBorder(theme.cardBorder, lineWidth: 0.8))
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    // MARK: - 2. 残留分类与安全说明卡片

    private var categoriesAndSafetyCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CleanCategory.allCases) { cat in
                            categoryPill(cat)
                        }
                    }
                }

                Divider()
                    .overlay(theme.dividerColor)

                HStack(spacing: 24) {
                    guaranteeItem(icon: "eye", title: "先扫描再清理")
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            navState.openModal(tab: .cleaner)
                        }
                    } label: {
                        guaranteeItem(icon: "slider.horizontal.3", title: "已启用 \(CleanProtectionStore.shared.ruleCount) 条保护规则")
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    guaranteeItem(icon: "checkmark.shield", title: "支持列表行内一键「清理保护」")
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            navState.openModal(tab: .cleaner)
                        }
                    } label: {
                        guaranteeItem(icon: "gearshape", title: "当前模式：\(cleaner.deleteMode.title)")
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func categoryPill(_ cat: CleanCategory) -> some View {
        let isSelected = cleaner.isCategorySelected(cat)
        let catBytes = cleaner.categoryBytes(cat)
        let hasItems = catBytes > 0

        return Button {
            cleaner.toggleCategorySelection(cat)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: cat.iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(cat.themeColor)

                Text(cat.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)

                if hasItems {
                    Text(formatBytes(catBytes))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.primaryText.opacity(0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)) : Color.clear)
                    .overlay(
                        Capsule().strokeBorder(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.10)) : Color.white.opacity(0.05), lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help(cat.detailDescription)
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

    // MARK: - 3. 扫描结果复核列表 & 结构化结果回执

    private var filteredItems: [CleanItem] {
        var items = cleaner.scannedItems
        if let bucket = selectedBucketFilter {
            items = items.filter { $0.bucket == bucket }
        }
        let isAscending = (navState.cleanerSortOrder == .ascending)
        switch navState.cleanerSortField {
        case .name:
            items.sort { isAscending ? $0.name < $1.name : $0.name > $1.name }
        case .category:
            items.sort { isAscending ? $0.category.displayName < $1.category.displayName : $0.category.displayName > $1.category.displayName }
        case .size:
            items.sort { isAscending ? $0.sizeBytes < $1.sizeBytes : $0.sizeBytes > $1.sizeBytes }
        }
        return items
    }

    private var scannedReviewItemsCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // 三档选择预设：推荐 / 全选 / 全不选
                    HStack(spacing: 4) {
                        presetButton(.recommended)
                        presetButton(.all)
                        presetButton(.none)
                    }
                    .padding(2.5)
                    .background(Capsule().fill(theme.pillFill))

                    Divider().frame(height: 16)

                    // 分桶过滤胶囊
                    HStack(spacing: 5) {
                        bucketPill(title: "全部", bucket: nil)
                        bucketPill(title: "建议清理", bucket: .suggested)
                        bucketPill(title: "需要复核", bucket: .needsReview)
                        if cleaner.count(for: .manualOnly) > 0 {
                            bucketPill(title: "手动管理", bucket: .manualOnly)
                        }
                        if cleaner.count(for: .excluded) > 0 {
                            bucketPill(title: "保护拦截", bucket: .excluded)
                        }
                    }

                    Spacer()

                    if let notice = cleaner.undoProtectionNotice {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.green)
                            Text("已加入清理保护「\(notice.itemName)」")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                            Button("撤销") {
                                cleaner.undoLastProtection()
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.cyan)
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                    }

                    if let manualNotice = cleaner.manualActionNotice {
                        Text(manualNotice)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.cyan)
                            .lineLimit(1)
                    }

                    Button {
                        navState.toggleCleanerSort(field: .size)
                    } label: {
                        HStack(spacing: 4) {
                            Text("大小")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Image(systemName: navState.cleanerSortOrder == .descending ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(theme.pillFill))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
                .padding(.horizontal, 16)
                .frame(height: 40)

                Divider()
                    .overlay(theme.dividerColor)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        if let summary = cleaner.lastExecutionSummary, cleaner.showExecutionDetails {
                            executionSummaryBanner(summary: summary)
                                .padding(.horizontal, 14)
                                .padding(.top, 6)
                        }

                        ForEach(filteredItems) { item in
                            CleanerReviewRowView(
                                item: item,
                                cleaner: cleaner,
                                navState: navState,
                                theme: theme
                            )
                        }
                    }
                    .padding(.vertical, 4.5)
                }
                .frame(height: max(300, reviewCardH - 41))
            }
            .frame(width: contentW, height: reviewCardH)
        }
    }

    private func presetButton(_ preset: CleanSelectionPreset) -> some View {
        Button {
            cleaner.applySelectionPreset(preset)
        } label: {
            Text(preset.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func bucketPill(title: String, bucket: CleanReviewBucket?) -> some View {
        let isSelected = (selectedBucketFilter == bucket)
        let cnt = cleaner.count(for: bucket)
        return Button {
            withAnimation(.spring(duration: 0.2)) {
                selectedBucketFilter = bucket
            }
        } label: {
            Text("\(title) (\(cnt))")
                .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    // MARK: - 清理执行回执分组卡片

    private func executionSummaryBanner(summary: CleanExecutionSummary) -> some View {
        let grouped = Dictionary(grouping: summary.entries, by: { $0.disposition })
        let orderedKeys = CleanResultDisposition.allCases.filter { !(grouped[$0] ?? []).isEmpty }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: summary.failedCount > 0 ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(summary.failedCount > 0 ? Color.orange : Color.green)
                Text("本次清理结果：释放 \(formatBytes(summary.freedBytes)) · 成功 \(summary.cleanedCount) 项 · 跳过 \(summary.skippedCount) 项 · 失败 \(summary.failedCount) 项")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button("收起") {
                    withAnimation { cleaner.showExecutionDetails = false }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            ForEach(orderedKeys) { disp in
                let rows = grouped[disp] ?? []
                let groupBytes = rows.reduce(0) { $0 + $1.sizeBytes }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(disp.groupTitle)（\(rows.count) 项 · \(formatBytes(groupBytes))）")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(disp.isSuccess ? Color.green : (disp.isSkipped ? Color.orange : Color.red))

                    ForEach(rows.prefix(5)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.name)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                            if let note = entry.note, !note.isEmpty {
                                Text("· \(note)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("复制路径") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.path.path, forType: .string)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.cyan)
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                    if rows.count > 5 {
                        Text("以及另外 \(rows.count - 5) 项…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }

            if !summary.runningAppReclaimHints.isEmpty {
                let topHintsText = summary.runningAppReclaimHints.prefix(4)
                    .map { "退出 \($0.appName) 还可清理 \(formatBytes($0.reclaimableBytes))" }
                    .joined(separator: "；")
                HStack(spacing: 6) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                    Text("部分缓存因应用运行中未清理：\(topHintsText)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    // MARK: - 运行中 App 冲突退出确认浮层

    private var runningConflictsOverlay: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.58 : 0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    cleaner.isRunningConflictDialogPresented = false
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "app.badge.checkmark.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("部分缓存所属 App 正在运行")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("正在运行的客户端可能持有文件锁或内存数据库，先退出后再清理更稳妥。")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cleaner.pendingRunningConflicts) { conflict in
                        HStack {
                            Text(conflict.appName)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Text(conflict.itemNames.joined(separator: "、"))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.pillFill))

                HStack(spacing: 10) {
                    Spacer()

                    Button("取消") {
                        cleaner.isRunningConflictDialogPresented = false
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.pillFill))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Button("跳过占用项继续") {
                        cleaner.resolveRunningConflictsAndClean(quitApps: false)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Button("退出这些 App 并清理") {
                        cleaner.resolveRunningConflictsAndClean(quitApps: true)
                    }
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.cyan))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(20)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.35), radius: 22, y: 10)
            )
        }
    }

    // MARK: - 通用卡片容器

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
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct CleanerReviewRowView: View {
    let item: CleanItem
    @Bindable var cleaner: SystemCleanerEngine
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isSelected = item.isSelectable && cleaner.selectedItemIDs.contains(item.id)
        let isHovered = (navState.hoveredCleanerItemID == item.id)

        HStack(spacing: 12) {
            if item.isSelectable {
                Button {
                    cleaner.toggleSelection(for: item.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.cyan : theme.secondaryText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            } else {
                Image(systemName: item.bucket == .excluded ? "shield.lefthalf.filled" : "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.bucket == .excluded ? Color.purple : Color.blue)
                    .frame(width: 20, height: 20)
            }

            Image(systemName: item.category.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.category.themeColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let installed = item.isInstalledInstaller {
                        Text(installed ? "已安装" : "未安装")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(installed ? Color.green : Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill((installed ? Color.green : Color.orange).opacity(0.14)))
                            .fixedSize()
                    }
                }

                HStack(spacing: 4) {
                    Text("\(purposeText) ·")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText.opacity(0.90))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    CleanerMarqueeText(
                        text: item.path.path,
                        font: .system(size: 11, design: .monospaced),
                        nsFont: .monospacedSystemFont(ofSize: 11, weight: .regular),
                        color: theme.secondaryText.opacity(0.78),
                        lineHeight: 14
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            HStack(spacing: 10) {
                Text(item.category.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(item.category.themeColor)
                    .lineLimit(1)
                    .frame(width: 86, height: 22)
                    .background(
                        Capsule().fill(item.category.themeColor.opacity(0.12))
                    )

                Text(item.formattedSize)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .frame(width: 78, alignment: .trailing)

                bucketBadge

                if item.isSelectable {
                    let protectTint = colorScheme == .dark
                        ? Color(red: 0.30, green: 0.85, blue: 0.92)
                        : Color(red: 0.02, green: 0.50, blue: 0.66)
                    Button {
                        cleaner.protectItem(item)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "shield.badge.plus")
                                .font(.system(size: 10.5, weight: .bold))
                            Text("清理保护")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(protectTint)
                        .frame(width: 76, height: 22)
                        .background(
                            Capsule()
                                .fill(protectTint.opacity(colorScheme == .dark ? 0.16 : 0.12))
                                .overlay(
                                    Capsule().strokeBorder(protectTint.opacity(0.35), lineWidth: 0.8)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("加入清理保护名单 (~/.config/syspulse/whitelist)")
                } else if let manualAction = item.manualActionKind {
                    let isBusy = (cleaner.runningManualActionItemID == item.id)
                    let tint = Color.blue
                    Button {
                        cleaner.executeManualAction(manualAction, for: item)
                    } label: {
                        HStack(spacing: 4) {
                            if isBusy {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(isBusy ? "处理中…" : manualAction.buttonTitle)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(tint)
                        .frame(width: 82, height: 22)
                        .background(
                            Capsule()
                                .fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.12))
                                .overlay(
                                    Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.8)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(cleaner.runningManualActionItemID != nil)
                } else {
                    Color.clear
                        .frame(width: 76, height: 22)
                        .accessibilityHidden(true)
                }

                Button {
                    if item.category == .userTrash || item.path.lastPathComponent == ".Trash" || item.path.path.contains("/.Trashes") {
                        let script = "tell application \"Finder\"\nactivate\nopen trash\nend tell"
                        NSAppleScript(source: script)?.executeAndReturnError(nil)
                    } else {
                        NSWorkspace.shared.selectFile(item.path.path, inFileViewerRootedAtPath: item.path.deletingLastPathComponent().path)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10.5, weight: .bold))
                        Text("定位")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 58, height: 22)
                    .background(
                        Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)) : Color.clear)
        )
        .onHover { hovering in
            navState.hoveredCleanerItemID = hovering ? item.id : nil
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("在访达中显示") {
                NSWorkspace.shared.selectFile(item.path.path, inFileViewerRootedAtPath: item.path.deletingLastPathComponent().path)
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path.path, forType: .string)
            }
            if item.isSelectable {
                Divider()
                Button("加入清理保护名单") {
                    cleaner.protectItem(item)
                }
                let folderName = item.path.lastPathComponent
                if !folderName.isEmpty {
                    Button("永不清理所有同名「\(folderName)」目录") {
                        cleaner.protectFolderName(item)
                    }
                }
            }
        }
    }

    private var purposeText: String {
        if let reason = item.guardReason, !reason.isEmpty {
            return reason
        }
        if let hint = item.recommendedActionHint, !hint.isEmpty {
            return hint
        }
        return item.detail
    }

    @ViewBuilder
    private var bucketBadge: some View {
        switch item.bucket {
        case .suggested:
            badgePill("可安全清理", color: Color(red: 0.25, green: 0.85, blue: 0.55))
        case .needsReview:
            badgePill("建议复核", color: .orange)
        case .manualOnly:
            badgePill("仅手动处理", color: .blue)
        case .excluded:
            badgePill("保护拦截", color: .purple)
        }
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: 78, height: 22)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Smooth auto-scrolling marquee label for long paths and titles without using `@State` macros.
private struct CleanerMarqueeText: View {
    @Bindable var navState = StudioWindowNavigationState.shared
    let text: String
    let font: Font
    let nsFont: NSFont
    let color: Color
    let lineHeight: CGFloat

    private var measuredWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nsFont]).width) + 2
    }

    var body: some View {
        let textWidth = measuredWidth
        GeometryReader { geo in
            let containerWidth = max(1, geo.size.width)
            let overflow = max(0, textWidth - containerWidth)

            if overflow <= 2 || !navState.isMainWindowVisible {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: containerWidth, height: lineHeight, alignment: .leading)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    let offset = Self.pingPongOffset(
                        time: context.date.timeIntervalSinceReferenceDate,
                        overflow: overflow
                    )
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: -offset)
                        .frame(width: containerWidth, height: lineHeight, alignment: .leading)
                        .clipped()
                }
            }
        }
        .frame(maxWidth: textWidth)
        .frame(height: lineHeight)
        .allowsHitTesting(false)
    }

    private static func pingPongOffset(time: TimeInterval, overflow: CGFloat) -> CGFloat {
        let leadPause: TimeInterval = 1.6
        let forwardDuration = max(1.4, Double(overflow) / 34.0)
        let tailPause: TimeInterval = 1.6
        let returnDuration = max(0.9, Double(overflow) / 56.0)
        let cycle = leadPause + forwardDuration + tailPause + returnDuration
        let t = time.truncatingRemainder(dividingBy: cycle)

        if t < leadPause {
            return 0
        } else if t < leadPause + forwardDuration {
            let progress = (t - leadPause) / forwardDuration
            return overflow * CGFloat(progress)
        } else if t < leadPause + forwardDuration + tailPause {
            return overflow
        } else {
            let progress = (t - leadPause - forwardDuration - tailPause) / returnDuration
            return overflow * CGFloat(1.0 - progress)
        }
    }
}
