import SwiftUI
import AppKit

// MARK: - 智能清理视图

public struct StorageCleanerSection: View {
    @Bindable var cleaner = SystemCleanerEngine.shared
    @Bindable var navState = StudioWindowNavigationState.shared
    let theme: LiquidGlassTheme
    var canvasWidth: CGFloat = 1200
    var canvasHeight: CGFloat = 822
    @Environment(\.colorScheme) private var colorScheme

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(684, canvasHeight - 79 - 59) }
    private var reviewCardH: CGFloat { max(380, contentH - 52 - 14 - 78 - 14 - 132 - 14) }

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
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("智能清理")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("一次扫描后完成复核、清理与结果确认；缓存、日志、网页残留与废纸篓内容都会进入统一流程。")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: contentW, height: 52, alignment: .leading)

            primaryActionCard
                .frame(width: contentW, height: 78)

            section2Group
                .frame(width: contentW, height: 132)

            if !cleaner.scannedItems.isEmpty {
                scannedReviewItemsCard
                    .frame(width: contentW, height: reviewCardH)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 35)
        .padding(.bottom, 24)
    }

    // MARK: - 清理说明与残留分类卡片

    private var section2Group: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("清理说明")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("· 检查以下 6 类残留")
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
                    size: 50,
                    isActive: cleaner.isScanning || cleaner.isCleaning,
                    accentColor: .cyan
                ) {
                    CleanerArtworkIconView(size: 50, forcedColorScheme: colorScheme)
                }
                .padding(.leading, 24)
                .padding(.trailing, 20)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 8) {
                        Text(primaryStatusTitle)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        if cleaner.isScanning {
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
        switch cleaner.status {
        case .idle:
            return cleaner.lastCleanDescription
        case .scanning:
            return "正在全面排查系统残留…"
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
            return "扫描不会删除任何内容。"
        case .scanning(_, let path):
            return path.isEmpty ? "正在排查用户缓存与系统残留…" : path
        case .completed:
            let selectedCount = cleaner.selectedItemIDs.count
            return "已选中 \(selectedCount) 项安全残留，包含用户缓存、日志与废纸篓。"
        case .cleaning(_, let item):
            return item
        case .cleaned:
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
                        cleaner.executeClean()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                            Text("立即清理 (\(cleaner.formattedSelectedBytes))")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color.cyan, Color(red: 0.35, green: 0.90, blue: 0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .shadow(color: Color.cyan.opacity(0.35), radius: 4, y: 1.5)
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
                HStack(spacing: 10) {
                    ForEach(CleanCategory.allCases) { cat in
                        categoryPill(cat)
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
                        guaranteeItem(icon: "slider.horizontal.3", title: "可设置保护名单")
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    guaranteeItem(icon: "checkmark.shield", title: "系统文件自动跳过")
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            navState.openModal(tab: .cleaner)
                        }
                    } label: {
                        guaranteeItem(icon: "gearshape", title: "删除方式可在设置中更改")
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
            HStack(spacing: 6) {
                Image(systemName: cat.iconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(cat.themeColor)

                Text(cat.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)

                if hasItems {
                    Text(formatBytes(catBytes))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.primaryText.opacity(0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)))
                }
            }
            .padding(.horizontal, 10)
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

    // MARK: - 3. 扫描结果复核列表

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
                HStack(spacing: 16) {
                    Button {
                        if cleaner.selectedItemIDs.count == cleaner.scannedItems.count {
                            cleaner.deselectAll()
                        } else {
                            cleaner.selectAll()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: cleaner.selectedItemIDs.count == cleaner.scannedItems.count ? "checkmark.circle.fill" : (cleaner.selectedItemIDs.isEmpty ? "circle" : "minus.circle.fill"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(cleaner.selectedItemIDs.isEmpty ? theme.secondaryText : Color.cyan)

                            Text("全部 (\(cleaner.scannedItems.count))")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    HStack(spacing: 6) {
                        bucketPill(title: "全部", bucket: nil)
                        bucketPill(title: "建议清理", bucket: .suggested)
                        bucketPill(title: "需要复核", bucket: .needsReview)
                    }

                    Spacer()

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
                .frame(height: 38)

                Divider()
                    .overlay(theme.dividerColor)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredItems) { item in
                            cleanReviewRow(item: item)
                        }
                    }
                    .padding(.vertical, 4.5)
                }
                .frame(height: max(341, reviewCardH - 39))
            }
            .frame(width: contentW, height: reviewCardH)
        }
    }

    private func bucketPill(title: String, bucket: CleanReviewBucket?) -> some View {
        let isSelected = (selectedBucketFilter == bucket)
        return Button {
            withAnimation(.spring(duration: 0.2)) {
                selectedBucketFilter = bucket
            }
        } label: {
            Text(title)
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

    private func cleanReviewRow(item: CleanItem) -> some View {
        let isSelected = cleaner.selectedItemIDs.contains(item.id)
        let isHovered = (navState.hoveredCleanerItemID == item.id)

        return HStack(spacing: 14) {
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

            Image(systemName: item.category.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.category.themeColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Text(item.path.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer()

            Text(item.category.displayName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(item.category.themeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(item.category.themeColor.opacity(0.12))
                )

            Text(item.formattedSize)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .frame(width: 85, alignment: .trailing)

            if item.bucket == .needsReview {
                Text("建议复核")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            } else {
                Text("可安全清理")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.25, green: 0.85, blue: 0.55).opacity(0.12)))
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)) : Color.clear)
        )
        .onHover { hovering in
            navState.hoveredCleanerItemID = hovering ? item.id : nil
        }
        .contentShape(Rectangle())
    }

    // MARK: - 4. Options & Protection Whitelist Popover

    private var cleanerSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("清理设置与安全名单", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                Button {
                    navState.isCleanerOptionsPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            Divider()

            // 删除方式选择器
            VStack(alignment: .leading, spacing: 6) {
                Text("清理删除方式")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Picker("", selection: $cleaner.deleteMode) {
                    ForEach(CleanDeleteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .pointingHandOnHover()

                Text(cleaner.deleteMode.subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }

            Divider()

            // Whitelist Security Summary
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("安全白名单防护")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("已激活 58 条规则")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green)
                }

                Text("系统核心、用户照片、邮件、钥匙串、未提交 Git 仓库及桌面个人文档受到永久防护，所有清理均会自动跳过。")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - 通用卡片容器

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
