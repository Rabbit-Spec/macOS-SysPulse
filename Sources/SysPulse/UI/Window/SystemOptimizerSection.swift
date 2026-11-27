import AppKit
import SwiftUI

// MARK: - 系统优化与日常急救视图

public struct SystemOptimizerSection: View {
    @Bindable var optimizer = SystemOptimizerEngine.shared
    @Bindable var permissions = SystemPermissionManager.shared
    let theme: LiquidGlassTheme
    var canvasWidth: CGFloat = 1200
    var canvasHeight: CGFloat = 822
    @Environment(\.colorScheme) private var colorScheme

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(684, canvasHeight - 79 - 59) }

    public init(theme: LiquidGlassTheme, canvasWidth: CGFloat = 1200, canvasHeight: CGFloat = 822) {
        self.theme = theme
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 14) {
                // 1. 顶部标题区 (与清理/空间页严格对齐)
                VStack(alignment: .leading, spacing: 4) {
                    Text("系统优化")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("先体检再按需维护，自动跳过健康项目；右侧提供针对日常小故障的一键无损急救。")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(width: contentW, height: 52, alignment: .leading)

                // 2. 主控制状态横卡
                primaryActionCard
                    .frame(width: contentW, height: 78)

                // 3. 双栏 Bento 工作台：左侧系统维护清单，右侧修复小毛病
                HStack(alignment: .top, spacing: 14) {
                    maintenanceChecklistCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    quickRepairCard
                        .frame(width: 416)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: contentW)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: contentW, height: contentH)
            .padding(.horizontal, 24)
            .padding(.top, 35)
            .padding(.bottom, 24)

            optimizerAuthGuidanceModal
        }
        .onAppear {
            optimizer.checkOnEntry()
        }
    }

    // MARK: - 主状态横卡

    private var primaryActionCard: some View {
        cardContainer {
            HStack(spacing: 0) {
                AnimatedModuleArtworkBadgeView(
                    size: 58,
                    isActive: optimizer.isInspecting || optimizer.isOptimizing,
                    accentColor: .mint
                ) {
                    OptimizerArtworkIconView(size: 58, forcedColorScheme: colorScheme)
                }
                .padding(.leading, 24)
                .padding(.trailing, 20)

                VStack(alignment: .leading, spacing: 3.5) {
                    HStack(spacing: 8) {
                        Text(primaryStatusTitle)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        if optimizer.isInspecting || optimizer.isOptimizing {
                            ProgressView()
                                .controlSize(.small)
                        } else if let summary = optimizer.lastSummary {
                            Text("已完成 \(summary.completedCount) · 跳过 \(summary.skippedCount)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        } else if optimizer.actionableCount > 0 {
                            Text("\(optimizer.actionableCount) 项可优化")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.mint)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Color.mint.opacity(0.15)))
                        }
                    }

                    Text(primaryStatusSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(optimizer.lastError != nil ? Color.red : theme.secondaryText)
                        .lineLimit(1)

                    if optimizer.isOptimizing {
                        GeometryReader { geo in
                            let clamped = min(max(optimizer.progressValue, 0.04), 1.0)
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.gaugeTrack)
                                Capsule()
                                    .fill(LinearGradient(colors: [.mint, .teal], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(8, geo.size.width * clamped))
                                    .animation(.easeOut(duration: 0.25), value: clamped)
                            }
                        }
                        .frame(maxWidth: 360, maxHeight: 4)
                        .padding(.top, 2)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    if !permissions.optimizerHelperStatus.isAuthorized {
                        Button {
                            optimizer.requestPermanentAuthorizationFromUI()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "lock.shield")
                                    .font(.system(size: 11.5, weight: .bold))
                                Text(optimizer.isRequestingPermanentAuth ? "开启中..." : "开启优化权限")
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.13))
                                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(optimizer.isOptimizing || optimizer.isRequestingPermanentAuth)
                        .help("开启系统优化权限后，深度系统维护与 mDNS 刷新全部免密执行")
                    }

                    Button {
                        optimizer.inspectAll()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11.5, weight: .bold))
                            Text(optimizer.isInspecting ? "体检中..." : "重新体检")
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
                    .disabled(optimizer.isInspecting || optimizer.isOptimizing)

                    Button {
                        optimizer.runOptimization()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: optimizer.isOptimizing ? "hourglass" : "wand.and.stars")
                                .font(.system(size: 12, weight: .bold))
                            Text(optimizer.isOptimizing
                                 ? "优化中..."
                                 : (optimizer.selectedTaskIDs.isEmpty ? "请先勾选" : "一键优化 (\(optimizer.selectedTaskIDs.count))"))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(
                            Capsule()
                                .fill(LinearGradient(
                                    colors: colorScheme == .dark
                                        ? [Color(red: 0.08, green: 0.64, blue: 0.50), Color(red: 0.09, green: 0.55, blue: 0.58)]
                                        : [Color(red: 0.05, green: 0.58, blue: 0.45), Color(red: 0.06, green: 0.50, blue: 0.54)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .shadow(color: Color(red: 0.05, green: 0.58, blue: 0.45).opacity(colorScheme == .dark ? 0.30 : 0.24), radius: 4, y: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(optimizer.isInspecting || optimizer.isOptimizing || optimizer.selectedTaskIDs.isEmpty)
                }
                .padding(.trailing, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var primaryStatusTitle: String {
        if optimizer.isInspecting {
            return "正在全面体检系统配置与数据库…"
        }
        if optimizer.isOptimizing {
            return "正在执行系统维护"
        }
        if let summary = optimizer.lastSummary {
            if summary.failedCount == 0 && summary.completedCount > 0 {
                return "系统维护完成 · 已优化 \(summary.completedCount) 项"
            } else if summary.completedCount == 0 && summary.failedCount == 0 {
                return "检查完成 · 这台 Mac 状态良好"
            }
            return "系统维护结束 · \(summary.completedCount) 完成 / \(summary.skippedCount) 跳过 / \(summary.failedCount) 失败"
        }
        return optimizer.actionableCount > 0
            ? "体检完成 · 发现 \(optimizer.actionableCount) 项可整理项目"
            : "系统状态良好 · 点击右侧可强制刷新预检"
    }

    private var primaryStatusSubtitle: String {
        if let err = optimizer.lastError {
            return err
        }
        if optimizer.isOptimizing {
            return optimizer.currentRunningTaskTitle ?? "正在顺序执行维护项…"
        }
        if let summary = optimizer.lastSummary {
            return String(format: "本次维护耗时 %.1f 秒 · 无关或健康项目已智能跳过，未触发无效读写。", summary.duration)
        }
        return "只清理失效后台项、损坏列表、旧窗口状态与可整理数据库，绝不误删个人文稿与应用核心数据。"
    }

    // MARK: - 左侧：系统维护清单卡片

    private var maintenanceChecklistCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 0) {
                // 顶栏与筛选条
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("系统维护清单")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Text("共 \(SystemOptimizeTaskID.allCases.count) 项")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(theme.pillFill))

                        Spacer()

                        HStack(spacing: 6) {
                            presetActionPill("推荐", active: false) {
                                optimizer.selectRecommended()
                            }
                            presetActionPill("全选", active: optimizer.selectedTaskIDs.count == SystemOptimizeTaskID.allCases.count - optimizer.whitelistedTaskIDs.count) {
                                optimizer.selectAll()
                            }
                            presetActionPill("清空", active: optimizer.selectedTaskIDs.isEmpty) {
                                optimizer.deselectAll()
                            }
                        }
                    }

                    // 分组过滤胶囊条
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            groupFilterPill(title: "全部分组", group: nil, isWhitelistTab: false)
                            ForEach(SystemOptimizeGroup.allCases) { grp in
                                groupFilterPill(title: grp.title, group: grp, isWhitelistTab: false)
                            }
                            groupFilterPill(
                                title: "已保护 (\(optimizer.whitelistedTaskIDs.count))",
                                group: nil,
                                isWhitelistTab: true
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

                Divider().overlay(theme.dividerColor.opacity(0.32))

                // 列表内容（滚动视口直通卡片下沿并沿圆角裁切）
                let visibleTasks = optimizer.filteredTasks
                if visibleTasks.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: optimizer.showWhitelistedOnly ? "checkmark.shield" : "sparkles")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.secondaryText.opacity(0.6))
                        Text(optimizer.showWhitelistedOnly ? "暂无加入优化保护名单的项目" : "当前筛选下暂无维护项")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 7) {
                            ForEach(visibleTasks) { task in
                                optimizerTaskRow(task)
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func presetActionPill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? Color.mint : theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Color.mint.opacity(0.14) : theme.pillFill)
                        .overlay(Capsule().strokeBorder(active ? Color.mint.opacity(0.35) : theme.studioCardBorder.opacity(0.5), lineWidth: 0.6))
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .disabled(optimizer.isOptimizing)
    }

    private func groupFilterPill(title: String, group: SystemOptimizeGroup?, isWhitelistTab: Bool) -> some View {
        let isSelected: Bool = {
            if isWhitelistTab { return optimizer.showWhitelistedOnly }
            return !optimizer.showWhitelistedOnly && optimizer.selectedGroupFilter == group
        }()
        return Button {
            optimizer.showWhitelistedOnly = isWhitelistTab
            if !isWhitelistTab {
                optimizer.selectedGroupFilter = group
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color.white : theme.primaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? Color.teal : theme.pillFill.opacity(0.7))
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func optimizerTaskRow(_ task: SystemOptimizeTaskID) -> some View {
        let isWhitelisted = optimizer.whitelistedTaskIDs.contains(task)
        let isSelected = optimizer.selectedTaskIDs.contains(task) && !isWhitelisted
        let inspection = optimizer.inspections[task] ?? .pending
        let outcome = optimizer.lastOutcomes[task]

        let statusText: String = {
            if isWhitelisted { return "已保护" }
            if let outcome { return outcome.badgeText }
            return inspection.badgeText
        }()

        let statusColor: Color = {
            if isWhitelisted { return .blue }
            if let outcome {
                switch outcome {
                case .completed: return .green
                case .skipped: return theme.secondaryText
                case .failed: return .red
                }
            }
            switch inspection {
            case .pending: return theme.secondaryText
            case .actionable: return .mint
            case .healthy: return .green
            case .unavailable: return theme.secondaryText
            }
        }()

        let subtitleText: String = {
            if isWhitelisted { return "已加入优化保护名单，执行时将自动跳过" }
            if let outcome { return outcome.detailText }
            return inspection.detailText
        }()

        return HStack(spacing: 11) {
            Button {
                optimizer.toggleTaskSelection(task)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isWhitelisted ? theme.secondaryText.opacity(0.35) : (isSelected ? Color.mint : theme.secondaryText.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .disabled(isWhitelisted || optimizer.isOptimizing)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isWhitelisted ? theme.secondaryText : theme.primaryText)
                        .lineLimit(1)

                    Text(task.group.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(theme.pillFill))

                    if task.requiresAdmin {
                        let permanentAuth = permissions.optimizerHelperStatus.isAuthorized
                        Text(permanentAuth ? "已免密" : "需优化权限")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(permanentAuth ? Color.teal : Color.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill((permanentAuth ? Color.teal : Color.orange).opacity(0.14)))
                    }
                }

                Text(subtitleText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(task.descriptionText)

            Spacer(minLength: 6)

            Text(statusText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(statusColor.opacity(0.13)))

            Button {
                optimizer.toggleWhitelist(task)
            } label: {
                Image(systemName: isWhitelisted ? "shield.fill" : "shield")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isWhitelisted ? Color.blue : theme.secondaryText.opacity(0.65))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isWhitelisted ? Color.blue.opacity(0.14) : theme.pillFill.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help(isWhitelisted ? "从优化保护名单移出" : "加入优化保护名单（一键优化时跳过）")
            .disabled(optimizer.isOptimizing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.pillFill.opacity(0.42))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.42), lineWidth: 0.6))
        )
    }

    // MARK: - 右侧：修复小毛病卡片（6 项等高铺满）

    private var quickRepairCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("修复小毛病")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Spacer()

                    Text("独立手动急救")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.teal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.teal.opacity(0.14)))
                }

                Text("遇到局部卡顿或图标错乱时点按刷新守护进程，不随一键优化自动重启界面。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)

                VStack(spacing: 8) {
                    ForEach(SystemQuickRepairID.allCases) { item in
                        quickRepairRow(item)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
        }
    }

    private func quickRepairRow(_ item: SystemQuickRepairID) -> some View {
        let isRunning = (optimizer.runningRepairID == item)
        let isRefreshed = optimizer.refreshedRepairIDs.contains(item)

        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.teal.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: item.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.teal)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                optimizer.runQuickRepair(item)
            } label: {
                HStack(spacing: 4) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else if isRefreshed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11.5, weight: .bold))
                        Text("已刷新")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                        Text("刷新")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(isRefreshed ? Color.green : theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isRefreshed ? Color.green.opacity(0.14) : theme.pillFill)
                        .overlay(Capsule().strokeBorder(isRefreshed ? Color.green.opacity(0.35) : theme.studioCardBorder, lineWidth: 0.7))
                )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .disabled(optimizer.runningRepairID != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.pillFill.opacity(0.42))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.45), lineWidth: 0.6))
        )
    }

    // MARK: - 卡片壳体

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.studioCardFill)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            )
    }

    // MARK: - 初次扫描系统优化授权引导弹窗

    @ViewBuilder
    private var optimizerAuthGuidanceModal: some View {
        if optimizer.showingInitialAuthGuidance {
            let solidCardFill = colorScheme == .dark
                ? Color(red: 0.14, green: 0.15, blue: 0.18)
                : Color.white
            let solidCardBorder = colorScheme == .dark
                ? Color.white.opacity(0.14)
                : Color.black.opacity(0.10)
            let modalPrimaryText = colorScheme == .dark ? Color.white : Color.black
            let modalSecondaryText = colorScheme == .dark
                ? Color.white.opacity(0.76)
                : Color.black.opacity(0.68)

            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.55 : 0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        optimizer.showingInitialAuthGuidance = false
                    }

                VStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(Color.teal.opacity(0.16))
                            .frame(width: 40, height: 40)
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color.teal)
                    }

                    Text("系统优化权限")
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .foregroundStyle(modalPrimaryText)

                    Text("开启系统优化权限后，例行维护、权限修复与内存释放将免密执行，无后台常驻，可随时在设置中关闭。")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(modalSecondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2.5)

                    HStack(spacing: 10) {
                        Button {
                            optimizer.showingInitialAuthGuidance = false
                        } label: {
                            Text("暂不开启")
                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                .foregroundStyle(modalSecondaryText)
                                .frame(maxWidth: .infinity)
                                .frame(height: 31)
                                .background(
                                    Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                                )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()

                        Button {
                            optimizer.requestPermanentAuthorizationFromUI()
                        } label: {
                            Text("立即开启")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 31)
                                .background(
                                    Capsule()
                                        .fill(LinearGradient(
                                            colors: [Color(red: 0.05, green: 0.58, blue: 0.45), Color(red: 0.06, green: 0.50, blue: 0.54)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ))
                                )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                    .padding(.top, 2)
                }
                .padding(18)
                .frame(width: 320)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(solidCardFill)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(solidCardBorder, lineWidth: 1))
                        .shadow(color: .black.opacity(0.32), radius: 20, y: 10)
                )
            }
            .transition(.opacity)
        }
    }
}
