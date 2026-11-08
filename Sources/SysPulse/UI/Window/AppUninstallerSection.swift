import SwiftUI
import AppKit

// MARK: - 应用卸载视图

public struct AppUninstallerSection: View {
    @Bindable var uninstaller = AppUninstallerEngine.shared
    @Bindable var navState = StudioWindowNavigationState.shared
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
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("卸载应用")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("深度穿透沙盒容器、群组配置、运行缓存与自启项，一次扫描彻底清除应用与无主残留。")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: contentW, height: 52, alignment: .leading)

            primaryActionCard
                .frame(width: contentW, height: 78)

            section2Group
                .frame(width: contentW, height: 132)

            if !uninstaller.installedApps.isEmpty || !uninstaller.orphanedResidues.isEmpty {
                appReviewItemsCard
                    .frame(width: contentW, height: reviewCardH)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 35)
        .padding(.bottom, 24)
        .onAppear {
            if uninstaller.installedApps.isEmpty && !uninstaller.isScanning {
                uninstaller.startScan()
            }
        }
    }

    // MARK: - 卸载说明与应用分类卡片

    private var section2Group: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("卸载说明")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("· 涵盖 5 类范围与安全机制")
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
                UninstallerArtworkIconView(size: 50, forcedColorScheme: colorScheme)
                    .clipShape(RoundedRectangle(cornerRadius: 11.5, style: .continuous))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 4, y: 2)
                    .padding(.leading, 24)
                    .padding(.trailing, 20)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 8) {
                        Text(primaryStatusTitle)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        if uninstaller.isScanning || uninstaller.isUninstalling {
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
        switch uninstaller.status {
        case .idle:
            return uninstaller.lastUninstallDescription
        case .scanning:
            return "正在全面排查应用与残留…"
        case .completed:
            let totalCount = uninstaller.installedApps.count + uninstaller.orphanedResidues.count
            return "已检索 \(totalCount) 项，预计可清理 \(uninstaller.formattedSelectedBytes)"
        case .uninstalling:
            return "正在安全卸载选定项目…"
        case .finished(let freed, _):
            return "卸载完成！已释放 \(uninstaller.formatBytes(freed))"
        }
    }

    private var primaryStatusSubtitle: String {
        switch uninstaller.status {
        case .idle:
            return "扫描不会删除任何内容。"
        case .scanning(_, let currentApp):
            return currentApp.isEmpty ? "正在分析应用足迹与沙盒残留…" : currentApp
        case .completed:
            let selectedCount = uninstaller.selectedItemIDs.count
            return "已选中 \(selectedCount) 项，包含应用本体、沙盒容器与无主残留。"
        case .uninstalling(_, let currentApp):
            return currentApp.isEmpty ? "正在移至废纸篓并清理关联残留…" : currentApp
        case .finished:
            return "应用及关联残留已彻底清理，系统空间已恢复清爽。"
        }
    }

    private var actionButtonsGroup: some View {
        HStack(spacing: 12) {
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
                        .background(
                            Capsule().fill(theme.pillFill)
                                .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8))
                        )
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
                    .background(
                        Capsule().fill(theme.pillFill)
                            .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8))
                    )
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

            case .uninstalling:
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var scanButton: some View {
        Button {
            uninstaller.startScan()
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

    // MARK: - 2. 应用分类与安全说明卡片

    private var categoriesAndSafetyCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(AppCategoryFilter.allCases) { cat in
                        categoryPill(cat)
                    }
                }

                Divider()
                    .overlay(theme.dividerColor)

                HStack(spacing: 24) {
                    guaranteeItem(icon: "eye", title: "先扫描再卸载")
                    guaranteeItem(icon: "lock.shield", title: "系统应用防误删")
                    guaranteeItem(icon: "shippingbox", title: "关联残留全覆盖")
                    guaranteeItem(icon: "trash", title: "默认移至废纸篓")
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    // MARK: - 3. 应用与残留列表卡片

    private var appReviewItemsCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
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

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        TextField("搜索应用名称或 Bundle ID…", text: $uninstaller.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !uninstaller.searchQuery.isEmpty {
                            Button {
                                uninstaller.searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .frame(width: 240)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.pillFill))

                    Spacer()

                    Menu {
                        ForEach(AppSortOption.allCases) { opt in
                            Button {
                                uninstaller.toggleSort(option: opt)
                            } label: {
                                HStack {
                                    Text(opt.rawValue)
                                    if uninstaller.sortOption == opt {
                                        Image(systemName: "checkmark")
                                    }
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
                .padding(.horizontal, 16)
                .frame(height: 38)

                Divider()
                    .overlay(theme.dividerColor)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        ForEach(uninstaller.filteredDisplayItems) { item in
                            uninstallerRow(item: item)
                        }
                    }
                    .padding(.vertical, 4.5)
                }
                .frame(height: max(341, reviewCardH - 39))
            }
            .frame(width: contentW, height: reviewCardH)
        }
    }

    // MARK: - Row Rendering for Card 3

    private func uninstallerRow(item: UninstallerRowItem) -> some View {
        let isSelected = uninstaller.isItemSelected(item.id)
        let isHovered = (uninstaller.hoveredItemID == item.id)

        switch item {
        case .app(let app):
            let isExpanded = uninstaller.expandedAppIDs.contains(app.id)

            return AnyView(
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
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
                                .help("macOS 系统原生保护组件，禁止卸载")
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

                                Text("·")
                                    .foregroundStyle(theme.secondaryText.opacity(0.5))

                                Text(app.formattedLastUsed)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(theme.secondaryText)

                                Text("·")
                                    .foregroundStyle(theme.secondaryText.opacity(0.5))

                                Text(app.bundleID)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText.opacity(0.75))
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Text("\(app.components.count) 项关联")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.cyan.opacity(0.12)))

                        Text(app.formattedTotalSize)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                            .frame(width: 85, alignment: .trailing)

                        if app.isSystemApp {
                            Text("系统原生")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.purple)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.purple.opacity(0.12)))
                        } else {
                            Text("可安全卸载")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.55))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
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

                        Button {
                            NSWorkspace.shared.selectFile(app.bundleURL.path, inFileViewerRootedAtPath: app.bundleURL.deletingLastPathComponent().path)
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

                    // Granular footprint details accordion
                    if isExpanded {
                        VStack(spacing: 4) {
                            ForEach(app.components) { comp in
                                HStack(spacing: 8) {
                                    Image(systemName: comp.type.iconName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.cyan)
                                        .frame(width: 14)

                                    Text(comp.type.rawValue)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(theme.primaryText)
                                        .frame(width: 80, alignment: .leading)

                                    Text(comp.path.path)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(theme.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()

                                    Text(comp.formattedSize)
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.cyan)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(theme.pillFill)
                                )
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
                .onHover { hovering in
                    uninstaller.hoveredItemID = hovering ? app.id : nil
                }
                .contentShape(Rectangle())
            )

        case .residue(let res):
            return AnyView(
                HStack(spacing: 14) {
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
                        }

                        Text(res.path.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.secondaryText.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Text("无主残留")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color(red: 0.95, green: 0.45, blue: 0.45).opacity(0.12)))

                    Text(res.formattedSize)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.purple)
                        .frame(width: 85, alignment: .trailing)

                    Text("可安全清理")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.55))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.85, blue: 0.55).opacity(0.12)))

                    Button {
                        NSWorkspace.shared.selectFile(res.path.path, inFileViewerRootedAtPath: res.path.deletingLastPathComponent().path)
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
                    uninstaller.hoveredItemID = hovering ? res.id : nil
                }
                .contentShape(Rectangle())
            )
        }
    }

    // MARK: - 4. Options & Protection Settings Popover

    private var uninstallerSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("卸载设置与安全机制", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                Button {
                    uninstaller.isOptionsPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            Divider()

            // Delete Mode Selector (移到废纸篓 vs 永久删除)
            VStack(alignment: .leading, spacing: 6) {
                Text("卸载删除方式")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Picker("", selection: $uninstaller.deleteMode) {
                    ForEach(UninstallerDeleteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .pointingHandOnHover()

                Text(uninstaller.deleteMode.subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }

            Divider()

            // System App Protection Summary
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("系统原生应用防误删保护")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("永久生效")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green)
                }

                Text("macOS 系统原生组件、系统守护进程及系统核心组件受到永久保护，禁止勾选卸载，确保系统运行绝对稳健。")
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
}

// MARK: - Native App Icon Helper

private struct NativeAppIconThumbnail: View {
    let bundleURL: URL

    var body: some View {
        let image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
