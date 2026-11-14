import SwiftUI
import AppKit
import QuartzCore

// MARK: - 主窗口根视图

public struct MainStudioWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var navState = StudioWindowNavigationState.shared
    @Bindable var engine = PowerSourceEngine.shared
    @Bindable var toggles = FeatureToggleManager.shared
    @Bindable var diskGuardian = DiskGuardian.shared

    private var theme: LiquidGlassTheme {
        LiquidGlassTheme(colorScheme: colorScheme)
    }

    public init() {}

    public var body: some View {
        GeometryReader { windowGeo in
            let baseW: CGFloat = 1200
            let baseH: CGFloat = 822
            let actualW = max(baseW, windowGeo.size.width)
            let actualH = max(baseH, windowGeo.size.height)
            let scale = max(1.0, min(actualW / baseW, actualH / baseH))
            let logicalW = max(baseW, actualW / scale)
            let logicalH = max(baseH, actualH / scale)

            ZStack {
                // Adaptive Liquid Glass Window Background
                WindowLiquidBackdrop(state: toggles.enablePluginUPSManager ? engine.telemetry.state : .acPower, theme: theme)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 顶部导航栏
                    topNavigationBar

                    // 当前标签页内容区（窗口隐藏时卸载以停止内部动画与后台任务）
                    ZStack(alignment: .top) {
                        if navState.isMainWindowVisible {
                            switch navState.selectedTab {
                            case .status:
                                StatusOverviewSection(
                                    navState: navState,
                                    engine: engine,
                                    monitor: SystemResourceMonitor.shared,
                                    toggles: toggles,
                                    diskGuardian: diskGuardian,
                                    theme: theme,
                                    canvasWidth: logicalW,
                                    canvasHeight: logicalH
                                )
                            case .network:
                                NetworkMonitorSection(
                                    theme: theme,
                                    canvasWidth: logicalW,
                                    canvasHeight: logicalH
                                )
                            case .cleaner:
                                StorageCleanerSection(
                                    theme: theme,
                                    canvasWidth: logicalW,
                                    canvasHeight: logicalH
                                )
                            case .software:
                                AppUninstallerSection(
                                    theme: theme,
                                    canvasWidth: logicalW,
                                    canvasHeight: logicalH
                                )
                            case .space:
                                StorageAnalysisSection(
                                    theme: theme,
                                    canvasWidth: logicalW,
                                    canvasHeight: logicalH
                                )
                            case .plugins:
                                PluginsDashboardView(
                                    theme: theme,
                                    canvasWidth: logicalW,
                                    canvasHeight: logicalH
                                )
                            }
                        }
                    }
                    .frame(width: logicalW, height: logicalH - 79, alignment: .top)
                }
                .frame(width: logicalW, height: logicalH, alignment: .top)
                .ignoresSafeArea(edges: .top)

                // 模态弹窗覆盖层
                if navState.isModalPresented {
                    modalOverlaySheet
                }
            }
            .frame(width: logicalW, height: logicalH)
            .scaleEffect(scale, anchor: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部导航栏

    private var topNavigationBar: some View {
        let tabs = StudioTopTab.allCases
        let tabWidth: CGFloat = 70
        let tabHeight: CGFloat = 36
        let tabSpacing: CGFloat = 6
        let itemPitch = tabWidth + tabSpacing
        let selectedIndex = tabs.firstIndex(of: navState.selectedTab) ?? 0
        let sliderX = CGFloat(selectedIndex) * itemPitch

        return ZStack {
            // 1. 水平居中导航栏
            HStack(spacing: 0) {
                // 左上角应用图标下拉菜单按钮
                Button {
                    navState.isIconMenuPresented.toggle()
                } label: {
                    SysPulseAppIconView(size: 30, forcedColorScheme: colorScheme, isCircle: true)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08), lineWidth: 0.6)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .popover(isPresented: $navState.isIconMenuPresented, arrowEdge: .bottom) {
                    appIconDropdownMenu
                }
                .padding(.leading, 3)

                Spacer()
                    .frame(width: 14)

                // 顶部模块切换标签
                HStack(spacing: tabSpacing) {
                    ForEach(tabs) { tab in
                        let isSelected = (navState.selectedTab == tab && !navState.isModalPresented)
                        let isHovered = (navState.hoveredTopTab == tab && !isSelected)
                        Button {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                                navState.selectedTab = tab
                                navState.isModalPresented = false
                            }
                        } label: {
                            ZStack {
                                if isHovered {
                                    Capsule(style: .continuous)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                        .transition(.opacity)
                                }

                                Text(tab.rawValue)
                                    .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(
                                        isSelected
                                            ? (colorScheme == .dark ? Color.white : Color(red: 0.05, green: 0.18, blue: 0.36))
                                            : theme.primaryText.opacity(0.76)
                                    )
                            }
                            .frame(width: tabWidth, height: tabHeight)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.15)) {
                                if hovering {
                                    navState.hoveredTopTab = tab
                                } else if navState.hoveredTopTab == tab {
                                    navState.hoveredTopTab = nil
                                }
                            }
                        }
                    }
                }
                .background(alignment: .leading) {
                    // 选中标签高亮滑块
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [
                                        Color(red: 0.34, green: 0.56, blue: 0.88).opacity(0.42),
                                        Color(red: 0.16, green: 0.28, blue: 0.48).opacity(0.36)
                                    ]
                                    : [
                                        Color(red: 0.95, green: 0.98, blue: 1.00).opacity(0.92),
                                        Color(red: 0.85, green: 0.91, blue: 0.99).opacity(0.86)
                                    ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: colorScheme == .dark
                                            ? [
                                                Color.white.opacity(0.55),
                                                Color(red: 0.32, green: 0.62, blue: 1.00).opacity(0.28)
                                            ]
                                            : [
                                                Color.white.opacity(0.94),
                                                Color(red: 0.12, green: 0.42, blue: 0.82).opacity(0.24)
                                            ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.75
                                )
                        )
                        .frame(width: tabWidth, height: tabHeight)
                        .offset(x: sliderX)
                        .opacity(navState.isModalPresented ? 0.0 : 1.0)
                        .animation(.spring(response: 0.34, dampingFraction: 0.74), value: sliderX)
                        .animation(.easeOut(duration: 0.18), value: navState.isModalPresented)
                }
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(theme.studioCardFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
            )

            // 2. 右侧版本号与检查更新按钮
            HStack(spacing: 0) {
                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        AppUpdateManager.shared.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppUpdateManager.shared.hasUpdateAvailable ? Color.cyan : Color.green)
                            .frame(width: 6, height: 6)
                        Text(AppUpdateManager.shared.hasUpdateAvailable ? "\(AppMetadata.versionDisplay) · 有更新" : AppMetadata.versionDisplay)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppUpdateManager.shared.hasUpdateAvailable ? Color.cyan : theme.secondaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                AppUpdateManager.shared.hasUpdateAvailable
                                    ? Color.cyan.opacity(colorScheme == .dark ? 0.18 : 0.12)
                                    : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                AppUpdateManager.shared.hasUpdateAvailable
                                    ? Color.cyan.opacity(0.45)
                                    : (colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.08)),
                                lineWidth: 0.7
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("点击检查 GitHub 最新版本更新")
                .padding(.trailing, 24)
            }
        }
        .frame(height: 44)
        .padding(.top, 35)
        .padding(.horizontal, 8)
    }

    // MARK: - 应用图标下拉菜单

    private var appIconDropdownMenu: some View {
        AppIconDropdownMenuView(navState: navState, theme: theme)
    }

    // MARK: - 模态弹窗容器

    private var modalOverlaySheet: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.60 : 0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        navState.closeModal()
                    }
                }

            Group {
                if navState.isUpdateModalPresented {
                    AppUpdateModalView(
                        theme: theme,
                        onClose: {
                            withAnimation(.snappy(duration: 0.2)) {
                                navState.closeModal()
                            }
                        }
                    )
                    .frame(width: 540, height: 480)
                } else if navState.isDiagnosticsModalPresented {
                    SystemDiagnosticsModalView(
                        theme: theme,
                        onClose: {
                            withAnimation(.snappy(duration: 0.2)) {
                                navState.isDiagnosticsModalPresented = false
                            }
                        }
                    )
                    .frame(width: 600, height: 640)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()

                            // Segmented Tabs [设置 | UPS 设置 | 关于 SysPulse]
                            HStack(spacing: 4) {
                                ForEach(StudioModalTab.allCases) { tab in
                                    let isSelected = (navState.activeModalTab == tab)
                                    Button {
                                        withAnimation(.snappy(duration: 0.18)) {
                                            navState.activeModalTab = tab
                                        }
                                    } label: {
                                        Text(tab.rawValue)
                                            .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                                            .foregroundStyle(isSelected ? (colorScheme == .dark ? Color.black : Color.white) : theme.secondaryText)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 5)
                                            .background(
                                                Capsule().fill(isSelected ? (colorScheme == .dark ? Color.white : Color.primary) : Color.clear)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandOnHover()
                                }
                            }
                            .padding(3)
                            .background(
                                Capsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                            )

                            Spacer()

                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    navState.closeModal()
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundStyle(theme.secondaryText)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 14)

                        Divider()
                            .overlay(theme.dividerColor.opacity(0.5))

                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 16) {
                                switch navState.activeModalTab {
                                case .cleaner:
                                    CleanerSettingsModalView(theme: theme)
                                case .settings:
                                    CustomizationTogglesSection(toggles: toggles, theme: theme)
                                case .about:
                                    WindowAboutSection(engine: engine, theme: theme)
                                }
                            }
                            .padding(20)
                        }
                    }
                    .frame(width: 580, height: 530)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.15).opacity(0.96) : Color(red: 0.96, green: 0.96, blue: 0.97).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.8)
            )
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }
}

// MARK: - 状态总览视图

private struct StatusOverviewSection: View {
    @Bindable var navState: StudioWindowNavigationState
    @Bindable var engine: PowerSourceEngine
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var toggles: FeatureToggleManager
    @Bindable var diskGuardian: DiskGuardian
    @Bindable var fan = FanController.shared
    @Bindable var accessories = AccessoryBatteryManager.shared
    let theme: LiquidGlassTheme
    var canvasWidth: CGFloat = 1200
    var canvasHeight: CGFloat = 822

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(684, canvasHeight - 79 - 59) }
    private var col1W: CGFloat { max(348, round((contentW - 36) * (348.0 / 1116.0))) }
    private var colOtherW: CGFloat { max(256, (contentW - 36 - col1W) / 3.0) }
    private var cardRowH: CGFloat { max(170, round((contentH - 28) * (170.0 / 656.0))) }
    private var processCardH: CGFloat { max(316, (contentH - 28) - 2 * cardRowH) }

    public var body: some View {
        VStack(spacing: 14) {
            // 2x4 核心状态指标卡片网格
            OverviewTopBentoGridView(
                navState: navState,
                engine: engine,
                monitor: monitor,
                toggles: toggles,
                fan: fan,
                accessories: accessories,
                theme: theme,
                col1W: col1W,
                colOtherW: colOtherW,
                cardRowH: cardRowH
            )

            // 底部高能耗进程排行卡片
            OverviewProcessRankingCardView(
                navState: navState,
                monitor: monitor,
                theme: theme,
                contentW: contentW,
                processCardH: processCardH
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 35)
        .padding(.bottom, 24)
    }
}

private struct OverviewTopBentoGridView: View {
    @Bindable var navState: StudioWindowNavigationState
    @Bindable var engine: PowerSourceEngine
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var toggles: FeatureToggleManager
    @Bindable var fan: FanController
    @Bindable var accessories: AccessoryBatteryManager
    let theme: LiquidGlassTheme
    let col1W: CGFloat
    let colOtherW: CGFloat
    let cardRowH: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var rowScale: CGFloat { max(1.0, cardRowH / 170.0) }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                healthCard
                    .frame(width: col1W, height: cardRowH)
                cpuCard
                    .frame(width: colOtherW, height: cardRowH)
                gpuCard
                    .frame(width: colOtherW, height: cardRowH)
                memoryCard
                    .frame(width: colOtherW, height: cardRowH)
            }

            HStack(spacing: 12) {
                powerBatteryCard
                    .frame(width: col1W, height: cardRowH)
                diskSpaceCard
                    .frame(width: colOtherW, height: cardRowH)
                networkCard
                    .frame(width: colOtherW, height: cardRowH)
                fanCard
                    .frame(width: colOtherW, height: cardRowH)
            }
        }
    }

    // 1. 健康度卡片
    private var healthCard: some View {
        let snapshot = SystemHealthEvaluator.shared.evaluate()

        return cardBackground(id: "health") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PulsingHeaderSymbolView(
                        systemName: "sun.max.fill",
                        size: 13,
                        color: Color(red: 0.35, green: 0.82, blue: 0.55),
                        isRotating: true
                    )
                    Text("健康度")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 0.55))

                    Spacer()

                    HStack(spacing: 4) {
                        pillBadge(MacHardwareInfo.shared.chipBrand.replacingOccurrences(of: "Apple ", with: ""))
                        pillBadge("\(Int(monitor.memory.totalGB)) GB")
                        pillBadge(MacHardwareInfo.shared.macOSDisplayString)
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        overviewMetricHeadline(
                            "\(snapshot.score)",
                            unit: snapshot.rating.rawValue,
                            unitSize: 15,
                            unitSpacing: "  ",
                            numericValue: Double(snapshot.score)
                        )

                        Text(snapshot.primarySummary)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.secondaryText.opacity(0.9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Spacer(minLength: 4)

                        Text(snapshot.formattedUptime)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer()

                    HealthPulseAuraBadgeView(
                        score: snapshot.score,
                        mascotSize: 90 * rowScale,
                        ringSize: 108 * rowScale,
                        auraSize: 132 * rowScale
                    )
                    .padding(.trailing, 20)
                }
            }
        }
        .frame(height: cardRowH)
    }

    // 2. CPU 卡片
    private var cpuCard: some View {
        let cpuPercent = Int(round(monitor.power.cpuTotalPercent))
        let temp = Int(round(monitor.hardware.cpuTemperatureC))
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let loadAvg = monitor.hardware.cpuLoadAverage1Min
        let coreLoads = monitor.hardware.perCoreLoads
        let eqH = round(24.0 * rowScale)

        let loadStatus: String
        if cpuPercent < 20 {
            loadStatus = "低负载"
        } else if cpuPercent < 60 {
            loadStatus = "正常"
        } else if cpuPercent < 85 {
            loadStatus = "繁忙"
        } else {
            loadStatus = "高负载"
        }

        return cardBackground(id: "cpu") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("CPU", systemImage: "cpu")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 0.55))
                    Spacer()
                    headerBadge("\(temp)°C", numericValue: Double(temp))
                }

                overviewMetricHeadline("\(cpuPercent)", unit: "%", numericValue: Double(cpuPercent))

                Spacer(minLength: 2)

                // 多核负载均衡器
                OverviewCPUFluidEqualizerView(
                    coreCount: max(8, coreCount),
                    coreLoads: coreLoads,
                    fallbackPercent: Double(cpuPercent),
                    height: eqH,
                    isDark: colorScheme == .dark
                )
                .frame(height: eqH)

                Spacer(minLength: 2)

                Text("\(loadStatus) · \(coreCount) 核 · 平均负载 \(String(format: "%.1f", loadAvg))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(height: cardRowH)
    }

    // 3. GPU 卡片
    private var gpuCard: some View {
        let gpuPercent = Int(round(monitor.hardware.gpuUsagePercent))
        let temp = max(32, Int(round(monitor.hardware.gpuTemperatureC)))
        let gpuWatts = monitor.hardware.gpuWatts

        let gpuStatus: String
        if gpuPercent < 15 {
            gpuStatus = "低负载"
        } else if gpuPercent < 50 {
            gpuStatus = "正常"
        } else {
            gpuStatus = "高负载"
        }

        return cardBackground(id: "gpu") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("GPU", systemImage: "display")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.95, green: 0.60, blue: 0.20))
                    Spacer()
                    headerBadge("\(temp)°C", numericValue: Double(temp))
                }

                overviewMetricHeadline("\(gpuPercent)", unit: "%", numericValue: Double(gpuPercent))

                Spacer(minLength: 2)

                SurgeConveyorWaveformView(
                    primaryHistory: monitor.hardware.gpuHistory,
                    secondaryHistory: nil,
                    minScaleCeiling: 20.0,
                    activeThreshold: 2.0,
                    accentColor: Color(red: 0.95, green: 0.60, blue: 0.20),
                    isDark: colorScheme == .dark
                )
                .equatable()
                .frame(height: round(26.0 * rowScale))

                Spacer(minLength: 2)

                Text("\(gpuStatus) · \(String(format: "%.1fW", gpuWatts))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(height: cardRowH)
    }

    // 4. 内存卡片
    private var memoryCard: some View {
        let usedPercent = monitor.memory.usedPercent
        let usedGB = String(format: "%.1f", monitor.memory.usedGB)
        let swapMB = String(format: "%.1f", Double(monitor.memory.compressedBytes) / 1048576.0)

        return cardBackground(id: "memory") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("内存", systemImage: "memorychip")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.40))
                    Spacer()
                    headerBadge("压力\(monitor.memory.pressureLabel)")
                }

                overviewMetricHeadline("\(usedPercent)", unit: "%", numericValue: Double(usedPercent))

                Spacer(minLength: 2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.gaugeTrack)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.90, green: 0.75, blue: 0.35), Color(red: 0.85, green: 0.60, blue: 0.25)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, geo.size.width * CGFloat(usedPercent) / 100.0))
                            .animation(.smooth(duration: 0.45), value: usedPercent)
                    }
                }
                .frame(height: round(6.0 * rowScale))

                Spacer(minLength: 2)

                Text("\(usedGB) GB · 交换空间 \(swapMB) MB")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(height: cardRowH)
    }

    // 5. 供电与电池卡片
    private var powerBatteryCard: some View {
        let presentation = PowerCardPresentation.resolve(
            upsEnabled: toggles.enablePluginUPSManager,
            upsTelemetry: engine.telemetry,
            loadRuntime: monitor.loadRuntime,
            hardwareBatteryCharging: monitor.hardware.isBatteryCharging,
            isMacBookDemoMode: toggles.enableMacBookDemoMode
        )
        let curWatts = monitor.power.totalSystemWatts
        let peakWatts = max(monitor.power.peakWatts, curWatts)
        let topEnergyApp = monitor.topEnergyApps.first?.name ?? "WindowServer"
        let connectedAccessories = accessories.accessories.filter { $0.isConnected }

        return cardBackground(id: "power") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PulsingHeaderSymbolView(
                        systemName: presentation.iconName,
                        size: 13,
                        color: presentation.iconColor
                    )
                    Text(presentation.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 0.55))
                    Spacer()
                }

                HStack(alignment: .center, spacing: 4) {
                    overviewMetricHeadline("\(presentation.percent)", unit: "%", numericValue: Double(presentation.percent))

                    Spacer()

                    // 已连接蓝牙外设电量圆环
                    if !connectedAccessories.isEmpty {
                        HStack(spacing: connectedAccessories.count > 3 ? 7 : 9) {
                            ForEach(connectedAccessories) { acc in
                                accessoryRing(item: acc, totalCount: connectedAccessories.count)
                            }
                        }
                    }
                }

                Spacer(minLength: 2)

                // 实时功耗与峰值功耗
                HStack(spacing: 8) {
                    Text("当前 \(String(format: "%.1f W", curWatts))")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.cyan)
                    Text("·")
                        .foregroundStyle(theme.secondaryText)
                    Text("最高 \(String(format: "%.1f W", peakWatts))")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                }

                Spacer(minLength: 2)

                HStack(spacing: 7) {
                    Text(presentation.statusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(presentation.statusColor)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))

                    Text("当前耗电最多 \(topEnergyApp)")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: cardRowH)
    }

    private func accessoryRing(item: AccessoryBatteryItem, totalCount: Int) -> some View {
        let pct = Double(item.batteryLevel) / 100.0
        let ringColor: Color = {
            if item.batteryLevel <= 20 {
                return Color(red: 0.95, green: 0.40, blue: 0.35)
            }
            return Color(red: 0.35, green: 0.85, blue: 0.55)
        }()

        let baseRingSize: CGFloat = totalCount > 3 ? 31 : 34
        let ringSize = round(baseRingSize * rowScale)

        return ZStack {
            Circle()
                .stroke(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 3.5 * rowScale)

            Circle()
                .trim(from: 0.0, to: max(0.04, pct))
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 3.5 * rowScale, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            NativePeripheralSymbolView(
                symbolName: item.iconName,
                pointSize: (baseRingSize > 32 ? 11.5 : 10.5) * rowScale
            )
            .foregroundStyle(theme.primaryText.opacity(0.88))
        }
        .frame(width: ringSize, height: ringSize)
        .help(item.detailText)
    }

    // 6. 磁盘可用空间卡片
    private var diskSpaceCard: some View {
        let totalGB = Int(round(monitor.hardware.statfsTotalGB))
        let freeGB = Int(round(monitor.hardware.statfsFreeGB))
        let usedGB = Int(round(monitor.hardware.statfsUsedGB))
        let usedPct = monitor.hardware.statfsUsedPercent

        return cardBackground(id: "disk") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("可用空间", systemImage: "internaldrive")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.blue)
                    Spacer()
                    headerBadge("\(totalGB) GB")
                }

                overviewMetricHeadline("\(freeGB)", unit: "GB", numericValue: Double(freeGB))

                Spacer(minLength: 2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.gaugeTrack)
                        Capsule()
                            .fill(Color.blue)
                            .frame(width: max(8, geo.size.width * CGFloat(usedPct) / 100.0))
                            .animation(.smooth(duration: 0.45), value: usedPct)
                    }
                }
                .frame(height: round(6.0 * rowScale))

                Spacer(minLength: 2)

                Text("已用 \(usedGB) GB · \(usedPct)%")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(height: cardRowH)
    }

    // 7. 网络吞吐卡片
    private var networkCard: some View {
        let downloadBytes = monitor.hardware.networkDownloadBytesPerSec
        let parts = monitor.hardware.downloadSpeedParts
        let ifKind = monitor.hardware.primaryInterfaceKind

        return cardBackground(id: "network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("网络", systemImage: "network")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cyan)
                    Spacer()
                    headerBadge(ifKind)
                }

                overviewMetricHeadline(parts.value, unit: parts.unit, numericValue: downloadBytes)

                Spacer(minLength: 2)

                SurgeConveyorWaveformView(
                    primaryHistory: monitor.hardware.networkHistoryDownload,
                    secondaryHistory: monitor.hardware.networkHistoryUpload,
                    minScaleCeiling: 1024.0 * 20.0,
                    activeThreshold: 512.0,
                    accentColor: Color.cyan,
                    isDark: colorScheme == .dark
                )
                .equatable()
                .frame(height: round(26.0 * rowScale))

                Spacer(minLength: 2)

                HStack {
                    Text("上传 \(monitor.hardware.formattedUploadSpeed)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                }
                .lineLimit(1)
            }
        }
        .frame(height: cardRowH)
    }

    // 8. 风扇转速与温控卡片
    private var fanCard: some View {
        let fan = FanController.shared
        let rpm = fan.currentRPM
        let pct = rpm <= 0 ? 0 : min(100, max(1, Int(round(Double(rpm) / Double(max(1, fan.maxRPM)) * 100.0))))

        return cardBackground(id: "fan") {
            if fan.isFanSupported {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        SpinningFanIconView(rpm: rpm, size: 13.5, color: Color.orange)
                        Text("风扇")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange)
                        Spacer()
                        headerBadge("转速 \(pct)%", numericValue: Double(pct))
                    }

                    overviewMetricHeadline(
                        NumberFormatter.localizedString(from: NSNumber(value: rpm), number: .decimal),
                        unit: "RPM",
                        numericValue: Double(rpm)
                    )

                    Spacer(minLength: 2)

                    // 风扇模式切换按钮
                    HStack(spacing: 8) {
                        fanModeButton(.auto)
                        fanModeButton(.cool)
                        fanModeButton(.maxCool)
                    }

                    Spacer(minLength: 2)

                    if fan.needsAuthorization {
                        Text("未更改，需要授权")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.25))
                            .lineLimit(1)
                    } else {
                        Text(fan.statusText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            } else {
                let tier = fan.passiveThermalTier
                let accent = fan.passiveThermalAccentColor
                let tempC = Int(round(monitor.hardware.cpuTemperatureC))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        PulsingHeaderSymbolView(
                            systemName: "snowflake",
                            size: 13.5,
                            color: accent,
                            isRotating: false
                        )
                        Text("静音散热")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                        Spacer()
                        headerBadge("零噪音 0 dB")
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(tier.rawValue)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.28), value: tier)
                        Text("被动均热 · \(tempC)°C")
                            .monospacedDigit()
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer(minLength: 2)

                    HStack(spacing: 8) {
                        ForEach(PassiveThermalTier.allCases) { item in
                            let isCurrent = (item == tier)
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: isCurrent ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isCurrent ? theme.primaryText : theme.secondaryText.opacity(0.75))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4.5)
                                .background(
                                    Capsule().fill(
                                        isCurrent
                                            ? accent.opacity(colorScheme == .dark ? 0.24 : 0.16)
                                            : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(isCurrent ? accent.opacity(0.45) : Color.clear, lineWidth: 0.8)
                                )
                        }
                    }

                    Spacer(minLength: 2)

                    Text(fan.passiveThermalDetailText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: cardRowH)
    }

    private func fanModeButton(_ mode: FanMode) -> some View {
        let fan = FanController.shared
        let isSelected = (fan.activeMode == mode)
        return Button {
            fan.setMode(mode)
        } label: {
            Text(mode.rawValue)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 4.5)
                .background(
                    Capsule().fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)) : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    // MARK: - Component Helpers

    /// 状态卡片主数字与单位排版（支持数字翻页动画）
    private func overviewMetricHeadline(
        _ valueText: String,
        unit: String,
        unitSize: CGFloat = 14,
        unitSpacing: String = " ",
        numericValue: Double
    ) -> some View {
        RollingFlipMetricHeadlineView(
            valueText: valueText,
            unitText: unitSpacing + unit,
            unitSize: unitSize,
            numericValue: numericValue,
            primaryColor: theme.primaryText,
            secondaryColor: theme.secondaryText,
            isDark: colorScheme == .dark
        )
    }

    private func cardBackground<Content: View>(id: String = "", @ViewBuilder content: () -> Content) -> some View {
        OverviewCardShell(id: id, navState: navState, theme: theme) {
            content()
        }
    }

    private func pillBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
            )
    }

    private func headerBadge(_ text: String, numericValue: Double? = nil) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
            )
    }

    private func circularPill(icon: String, isActive: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isActive ? Color(red: 0.35, green: 0.82, blue: 0.55) : theme.secondaryText)
            .frame(width: 20, height: 20)
            .background(
                Circle().fill(isActive ? Color(red: 0.35, green: 0.82, blue: 0.55).opacity(0.18) : Color.white.opacity(0.05))
            )
    }
}

private struct RollingFlipMetricHeadlineView: NSViewRepresentable, Equatable {
    let valueText: String
    let unitText: String
    let unitSize: CGFloat
    let numericValue: Double
    let primaryColor: Color
    let secondaryColor: Color
    let isDark: Bool

    nonisolated static func == (lhs: RollingFlipMetricHeadlineView, rhs: RollingFlipMetricHeadlineView) -> Bool {
        lhs.valueText == rhs.valueText
            && lhs.unitText == rhs.unitText
            && lhs.unitSize == rhs.unitSize
            && lhs.isDark == rhs.isDark
    }

    func makeNSView(context: Context) -> RollingFlipHeadlineNSView {
        RollingFlipHeadlineNSView()
    }

    func updateNSView(_ nsView: RollingFlipHeadlineNSView, context: Context) {
        nsView.configure(
            valueText: valueText,
            unitText: unitText,
            unitSize: unitSize,
            numericValue: numericValue,
            primaryColor: primaryColor,
            secondaryColor: secondaryColor,
            isDark: isDark
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingFlipHeadlineNSView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

private final class RollingFlipHeadlineNSView: NSView {
    private static let valueFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 32, weight: .bold)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let mono = rounded.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        return NSFont(descriptor: mono, size: 32) ?? NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .bold)
    }()

    private static let unitFont14: NSFont = {
        let base = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: desc, size: 14) ?? base
    }()

    private static let unitFont15: NSFont = {
        let base = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: desc, size: 15) ?? base
    }()

    private let flipClipContainer = NSView()
    private let valueLabel = NSTextField(labelWithString: "")
    private let unitLabel = NSTextField(labelWithString: "")

    private var lastValueText: String?
    private var lastNumericValue: Double = 0
    private var lastUnitSize: CGFloat = 0
    private var lastIsDark: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHierarchy()
    }

    private func setupHierarchy() {
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)

        flipClipContainer.wantsLayer = true
        flipClipContainer.layer?.masksToBounds = true
        flipClipContainer.translatesAutoresizingMaskIntoConstraints = false
        flipClipContainer.setContentHuggingPriority(.required, for: .horizontal)
        flipClipContainer.setContentHuggingPriority(.required, for: .vertical)

        valueLabel.wantsLayer = true
        valueLabel.font = Self.valueFont
        valueLabel.maximumNumberOfLines = 1
        valueLabel.lineBreakMode = .byClipping
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .vertical)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        unitLabel.font = Self.unitFont14
        unitLabel.maximumNumberOfLines = 1
        unitLabel.lineBreakMode = .byClipping
        unitLabel.translatesAutoresizingMaskIntoConstraints = false
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        unitLabel.setContentHuggingPriority(.required, for: .vertical)
        unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        unitLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        flipClipContainer.addSubview(valueLabel)
        addSubview(flipClipContainer)
        addSubview(unitLabel)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: flipClipContainer.leadingAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: flipClipContainer.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: flipClipContainer.topAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: flipClipContainer.bottomAnchor),

            flipClipContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            flipClipContainer.topAnchor.constraint(equalTo: topAnchor),
            flipClipContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            unitLabel.leadingAnchor.constraint(equalTo: flipClipContainer.trailingAnchor),
            unitLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            unitLabel.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor)
        ])
    }

    func configure(
        valueText: String,
        unitText: String,
        unitSize: CGFloat,
        numericValue: Double,
        primaryColor: Color,
        secondaryColor: Color,
        isDark: Bool
    ) {
        if lastIsDark != isDark {
            lastIsDark = isDark
            appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            valueLabel.textColor = NSColor(primaryColor)
            unitLabel.textColor = NSColor(secondaryColor)
        }

        if abs(lastUnitSize - unitSize) > 0.1 {
            lastUnitSize = unitSize
            if abs(unitSize - 15) < 0.1 {
                unitLabel.font = Self.unitFont15
            } else if abs(unitSize - 14) < 0.1 {
                unitLabel.font = Self.unitFont14
            } else {
                let base = NSFont.systemFont(ofSize: unitSize, weight: .semibold)
                let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
                unitLabel.font = NSFont(descriptor: desc, size: unitSize) ?? base
            }
        }

        var needsSizeInvalidation = false

        if unitLabel.stringValue != unitText {
            unitLabel.stringValue = unitText
            needsSizeInvalidation = true
        }

        if lastValueText != valueText {
            if let _ = lastValueText {
                let transition = CATransition()
                transition.type = .push
                transition.subtype = (numericValue >= lastNumericValue) ? .fromBottom : .fromTop
                transition.duration = 0.22
                transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
                valueLabel.layer?.add(transition, forKey: "metricPushFlip")
            }
            lastValueText = valueText
            lastNumericValue = numericValue
            valueLabel.stringValue = valueText
            needsSizeInvalidation = true
        } else {
            lastNumericValue = numericValue
        }

        if needsSizeInvalidation {
            invalidateIntrinsicContentSize()
            layoutSubtreeIfNeeded()
        }
    }
}

private struct OverviewCardShell<Content: View>: View {
    let id: String
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(
        id: String,
        navState: StudioWindowNavigationState,
        theme: LiquidGlassTheme,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.navState = navState
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        let isHovered = (!id.isEmpty && navState.hoveredOverviewCardID == id)

        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isHovered ? theme.studioCardHoverBorder : theme.studioCardBorder,
                            lineWidth: isHovered ? 1.1 : 0.8
                        )
                )
        )
        .offset(y: isHovered ? -2.0 : 0.0)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isHovered)
        .onHover { hovering in
            guard !id.isEmpty else { return }
            if hovering {
                navState.hoveredOverviewCardID = id
            } else if navState.hoveredOverviewCardID == id {
                navState.hoveredOverviewCardID = nil
            }
        }
    }
}

/// CPU 多核负载均衡器视图
private struct OverviewCPUFluidEqualizerView: View, Equatable {
    let coreCount: Int
    let coreLoads: [Double]
    let fallbackPercent: Double
    let height: CGFloat
    let isDark: Bool

    nonisolated static func == (lhs: OverviewCPUFluidEqualizerView, rhs: OverviewCPUFluidEqualizerView) -> Bool {
        lhs.coreCount == rhs.coreCount
            && lhs.height == rhs.height
            && lhs.isDark == rhs.isDark
            && lhs.fallbackPercent == rhs.fallbackPercent
            && lhs.coreLoads == rhs.coreLoads
    }

    var body: some View {
        GeometryReader { geo in
            let count = max(8, coreCount)
            let totalW = geo.size.width
            let spacing: CGFloat = count > 12 ? 2.5 : 3.5
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = max(3.5, (totalW - totalSpacing) / CGFloat(count))
            let trackColor = isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { idx in
                    let rawVal = idx < coreLoads.count ? coreLoads[idx] : fallbackPercent
                    let quantizedVal = (max(0.0, min(100.0, rawVal)) / 2.0).rounded() * 2.0
                    let fillRatio = max(0.14, min(1.0, quantizedVal / 100.0))
                    let heatStep = (max(0.0, min(1.0, (quantizedVal - 50.0) / 40.0)) * 4.0).rounded() / 4.0

                    let topColor = Color(
                        red: 0.32 + (0.96 - 0.32) * heatStep,
                        green: 0.86 + (0.58 - 0.86) * heatStep,
                        blue: 0.58 + (0.24 - 0.58) * heatStep
                    )
                    let bottomColor = Color(
                        red: 0.20 + (0.90 - 0.20) * heatStep,
                        green: 0.74 + (0.42 - 0.74) * heatStep,
                        blue: 0.46 + (0.20 - 0.46) * heatStep
                    )

                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2.0, style: .continuous)
                            .fill(trackColor)
                            .frame(width: barWidth, height: height)

                        RoundedRectangle(cornerRadius: 2.0, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [topColor, bottomColor],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .transaction { $0.animation = nil }
                            .frame(width: barWidth, height: height)
                            .scaleEffect(x: 1.0, y: fillRatio, anchor: .bottom)
                            .animation(.easeOut(duration: 0.25), value: fillRatio)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2.0, style: .continuous))
                }
            }
            .frame(width: totalW, height: height, alignment: .bottom)
        }
    }
}

private struct OverviewProcessRankingCardView: View {
    @Bindable var navState: StudioWindowNavigationState
    @Bindable var monitor: SystemResourceMonitor
    let theme: LiquidGlassTheme
    let contentW: CGFloat
    let processCardH: CGFloat

    private var currentDisplayApps: [EnergyAppItem] {
        if navState.displayedProcesses.isEmpty {
            return monitor.topEnergyApps
        }
        return navState.displayedProcesses
    }

    private var sortedDisplayApps: [EnergyAppItem] {
        if !navState.sortedProcesses.isEmpty {
            return navState.sortedProcesses
        }
        return currentDisplayApps
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        navState.toggleSort(field: .name)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("名称 (\(currentDisplayApps.count))")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(navState.processSortField == .name ? theme.primaryText : theme.secondaryText)
                        if navState.processSortField == .name {
                            Image(systemName: navState.processSortOrder == .ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.cyan)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        navState.toggleSort(field: .memory)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("内存")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(navState.processSortField == .memory ? theme.primaryText : theme.secondaryText)
                        if navState.processSortField == .memory {
                            Image(systemName: navState.processSortOrder == .ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.cyan)
                        }
                    }
                    .frame(width: 96, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        navState.toggleSort(field: .cpu)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("% CPU")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(navState.processSortField == .cpu ? theme.primaryText : theme.secondaryText)
                        if navState.processSortField == .cpu {
                            Image(systemName: navState.processSortOrder == .ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.cyan)
                        }
                    }
                    .frame(width: 124, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        navState.toggleSort(field: .energy)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("能耗")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(navState.processSortField == .energy ? theme.primaryText : theme.secondaryText)
                        if navState.processSortField == .energy {
                            Image(systemName: navState.processSortOrder == .ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.cyan)
                        }
                    }
                    .frame(width: 78, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        navState.toggleSort(field: .pid)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("PID")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(navState.processSortField == .pid ? theme.primaryText : theme.secondaryText)
                        if navState.processSortField == .pid {
                            Image(systemName: navState.processSortOrder == .ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.cyan)
                        }
                    }
                    .frame(width: 68, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Spacer()
                    .frame(width: 32)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)

            Divider().overlay(theme.dividerColor.opacity(0.4))

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(sortedDisplayApps) { app in
                        processRow(app: app)
                    }
                }
            }
            .frame(height: max(272, processCardH - 44))
        }
        .padding(.vertical, 4.5)
        .frame(width: contentW, height: processCardH)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
                )
        )
        .onHover { hovering in
            navState.isProcessTableHovered = hovering
            if !hovering {
                withAnimation(.easeInOut(duration: 0.25)) {
                    navState.updateDisplayedProcesses(from: monitor.topEnergyApps)
                }
            }
        }
        .onAppear {
            navState.updateDisplayedProcesses(from: monitor.topEnergyApps)
        }
        .onChange(of: monitor.topEnergyApps) { _, newApps in
            navState.updateDisplayedProcesses(from: newApps)
        }
    }

    private func processRow(app: EnergyAppItem) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                AppIconImageView(pid: app.pid)
                    .frame(width: 20, height: 20)

                Text(app.name)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(app.formattedMemory)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .frame(width: 96, alignment: .trailing)

            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.gaugeTrack)
                        Capsule().fill(Color.cyan)
                            .frame(width: max(2, geo.size.width * CGFloat(min(100.0, app.cpuPercent)) / 100.0))
                    }
                }
                .frame(width: 54, height: 4.5)

                Text(String(format: "%.1f", app.cpuPercent))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: 124, alignment: .trailing)

            Text(String(format: "%.1f", app.energyImpactScore))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(app.energyImpactScore > 20 ? Color.orange : theme.primaryText)
                .frame(width: 78, alignment: .trailing)

            Text("\(app.pid)")
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 68, alignment: .trailing)

            Menu {
                Button {
                    revealProcessInFinder(pid: app.pid)
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }

                Button {
                    copyProcessInfo(app: app)
                } label: {
                    Label("复制进程信息 (PID: \(app.pid))", systemImage: "doc.on.doc")
                }

                Divider()

                Button {
                    terminateProcess(pid: app.pid, force: false)
                } label: {
                    Label("退出进程", systemImage: "xmark.circle")
                }

                Button(role: .destructive) {
                    terminateProcess(pid: app.pid, force: true)
                } label: {
                    Label("强制退出进程", systemImage: "bolt.slash.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 32, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 20)
            .pointingHandOnHover()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .contentShape(Rectangle())
    }

    private func revealProcessInFinder(pid: Int32) {
        if let running = NSRunningApplication(processIdentifier: pid),
           let url = running.bundleURL ?? running.executableURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if len > 0 {
            let path = String(decoding: pathBuffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func copyProcessInfo(app: EnergyAppItem) {
        let info = "\(app.name) (PID: \(app.pid)) - CPU: \(String(format: "%.1f%%", app.cpuPercent)), 内存: \(app.formattedMemory), 能耗影响: \(String(format: "%.1f", app.energyImpactScore))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    private func terminateProcess(pid: Int32, force: Bool) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        if let running = NSRunningApplication(processIdentifier: pid) {
            if force {
                _ = running.forceTerminate()
            } else {
                _ = running.terminate()
            }
        } else {
            _ = Darwin.kill(pid, force ? SIGKILL : SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SystemResourceMonitor.shared.refreshNow()
        }
    }
}

// MARK: - 健康度萌兔徽章视图

private final class HealthRippleAuraNSView: NSView {
    private let auraLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private var currentKey: String = ""
    private var currentMascotSize: CGFloat = 90
    private var currentMaxWaveSpan: CGFloat = 30
    private var currentTargetWaveScale: CGFloat = 1.24
    private var currentIsDark: Bool = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        auraLayer.contentsGravity = .resizeAspect
        auraLayer.masksToBounds = false
        layer?.addSublayer(auraLayer)

        ringLayer.fillColor = nil
        ringLayer.lineWidth = 1.2
        ringLayer.masksToBounds = false
        layer?.addSublayer(ringLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let auraDia = currentMascotSize + currentMaxWaveSpan + 6
        auraLayer.bounds = CGRect(x: 0, y: 0, width: auraDia, height: auraDia)
        auraLayer.position = center

        ringLayer.bounds = CGRect(x: 0, y: 0, width: currentMascotSize, height: currentMascotSize)
        ringLayer.position = center
        ringLayer.path = CGPath(ellipseIn: ringLayer.bounds, transform: nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowActivityChanged),
                name: NSWindow.didBecomeKeyNotification,
                object: newWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowActivityChanged),
                name: NSWindow.didResignKeyNotification,
                object: newWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowActivityChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAnimationActivity()
    }

    @objc private func handleWindowActivityChanged(_ notification: Notification) {
        syncAnimationActivity()
    }

    private var shouldAnimateAura: Bool {
        guard let win = window else { return false }
        return win.occlusionState.contains(.visible) && win.isKeyWindow
    }

    private func syncAnimationActivity() {
        if shouldAnimateAura {
            if auraLayer.animation(forKey: "syspulse.aura") == nil || ringLayer.animation(forKey: "syspulse.ripple") == nil {
                installAnimations(targetWaveScale: currentTargetWaveScale, isDark: currentIsDark)
            }
        } else {
            auraLayer.removeAllAnimations()
            ringLayer.removeAllAnimations()
        }
    }

    func configure(
        mascotSize: CGFloat,
        maxWaveSpan: CGFloat,
        targetWaveScale: CGFloat,
        mainColor: NSColor,
        isDark: Bool
    ) {
        currentMascotSize = mascotSize
        currentMaxWaveSpan = maxWaveSpan
        currentTargetWaveScale = targetWaveScale
        currentIsDark = isDark

        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let srgb = mainColor.usingColorSpace(.sRGB) ?? mainColor
        let r = Int(round(srgb.redComponent * 255))
        let g = Int(round(srgb.greenComponent * 255))
        let b = Int(round(srgb.blueComponent * 255))
        let key = "\(Int(round(mascotSize)))-\(Int(round(maxWaveSpan)))-\(r)-\(g)-\(b)-\(isDark)-\(Int(round(backingScale * 10)))"

        if key != currentKey {
            currentKey = key
            let auraDia = mascotSize + maxWaveSpan + 6
            auraLayer.contentsScale = backingScale
            auraLayer.contents = Self.renderRadialAura(
                pointDiameter: auraDia,
                scale: backingScale,
                color: srgb,
                startRadiusPt: mascotSize * 0.34,
                endRadiusPt: min((mascotSize + maxWaveSpan) * 0.56, (mascotSize + maxWaveSpan + 4) * 0.5),
                isDark: isDark
            )
            ringLayer.strokeColor = srgb.withAlphaComponent(0.75).cgColor
            ringLayer.contentsScale = backingScale
            needsLayout = true
            layoutSubtreeIfNeeded()
            if shouldAnimateAura {
                installAnimations(targetWaveScale: targetWaveScale, isDark: isDark)
            }
        } else {
            syncAnimationActivity()
        }
    }

    private func installAnimations(targetWaveScale: CGFloat, isDark: Bool) {
        auraLayer.removeAllAnimations()
        ringLayer.removeAllAnimations()
        guard shouldAnimateAura else { return }

        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let ambientRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)

        let auraScale = CABasicAnimation(keyPath: "transform.scale")
        auraScale.fromValue = 0.96
        auraScale.toValue = 1.06

        let auraOpacity = CABasicAnimation(keyPath: "opacity")
        auraOpacity.fromValue = 0.72
        auraOpacity.toValue = 1.0

        let auraGroup = CAAnimationGroup()
        auraGroup.animations = [auraScale, auraOpacity]
        auraGroup.duration = 2.8
        auraGroup.autoreverses = true
        auraGroup.repeatCount = .infinity
        auraGroup.timingFunction = timing
        auraGroup.isRemovedOnCompletion = false
        auraGroup.preferredFrameRateRange = ambientRange
        auraLayer.add(auraGroup, forKey: "syspulse.aura")

        let ringScale = CABasicAnimation(keyPath: "transform.scale")
        ringScale.fromValue = 1.04
        ringScale.toValue = targetWaveScale

        let ringOpacity = CABasicAnimation(keyPath: "opacity")
        ringOpacity.fromValue = isDark ? 0.55 : 0.44
        ringOpacity.toValue = isDark ? 0.16 : 0.12

        let ringGroup = CAAnimationGroup()
        ringGroup.animations = [ringScale, ringOpacity]
        ringGroup.duration = 2.8
        ringGroup.autoreverses = true
        ringGroup.repeatCount = .infinity
        ringGroup.timingFunction = timing
        ringGroup.isRemovedOnCompletion = false
        ringGroup.preferredFrameRateRange = ambientRange
        ringLayer.add(ringGroup, forKey: "syspulse.ripple")
    }

    private static func renderRadialAura(
        pointDiameter: CGFloat,
        scale: CGFloat,
        color: NSColor,
        startRadiusPt: CGFloat,
        endRadiusPt: CGFloat,
        isDark: Bool
    ) -> CGImage? {
        let px = max(16, Int(ceil(pointDiameter * scale)))
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: px,
            height: px,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgbSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let colors: [CGColor] = [
            color.withAlphaComponent(isDark ? 0.34 : 0.22).cgColor,
            color.withAlphaComponent(isDark ? 0.16 : 0.10).cgColor,
            color.withAlphaComponent(isDark ? 0.05 : 0.03).cgColor,
            color.withAlphaComponent(0.0).cgColor
        ]
        let locations: [CGFloat] = [0.0, 0.45, 0.78, 1.0]
        guard let gradient = CGGradient(colorsSpace: srgbSpace, colors: colors as CFArray, locations: locations) else {
            return nil
        }
        let center = CGPoint(x: CGFloat(px) * 0.5, y: CGFloat(px) * 0.5)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: startRadiusPt * scale,
            endCenter: center,
            endRadius: endRadiusPt * scale,
            options: [.drawsBeforeStartLocation]
        )
        return ctx.makeImage()
    }
}

private struct HealthRippleAuraCAView: NSViewRepresentable {
    let mascotSize: CGFloat
    let maxWaveSpan: CGFloat
    let targetWaveScale: CGFloat
    let mainColor: Color
    let isDark: Bool

    func makeNSView(context: Context) -> HealthRippleAuraNSView {
        HealthRippleAuraNSView()
    }

    func updateNSView(_ nsView: HealthRippleAuraNSView, context: Context) {
        nsView.configure(
            mascotSize: mascotSize,
            maxWaveSpan: maxWaveSpan,
            targetWaveScale: targetWaveScale,
            mainColor: NSColor(mainColor),
            isDark: isDark
        )
    }
}

public struct HealthPulseAuraBadgeView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var score: Int = 98
    public var mascotSize: CGFloat = 90
    public var ringSize: CGFloat = 108
    public var auraSize: CGFloat = 132
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedTier1: NSImage?
    private static var cachedTier2: NSImage?
    private static var cachedTier3: NSImage?
    private static var cachedTier4: NSImage?
    private static let cacheLock = NSLock()

    public init(
        score: Int = 98,
        mascotSize: CGFloat = 90,
        ringSize: CGFloat = 108,
        auraSize: CGFloat = 132,
        forcedColorScheme: ColorScheme? = nil
    ) {
        self.score = score
        self.mascotSize = mascotSize
        self.ringSize = ringSize
        self.auraSize = auraSize
        self.forcedColorScheme = forcedColorScheme
    }

    public init(score: Int, size: CGFloat, forcedColorScheme: ColorScheme? = nil) {
        self.score = score
        self.mascotSize = 90
        self.ringSize = 108
        self.auraSize = 132
        self.forcedColorScheme = forcedColorScheme
    }

    private var activeScheme: ColorScheme {
        forcedColorScheme ?? envColorScheme
    }

    private var tierIndex: Int {
        if score >= 90 { return 1 }
        else if score >= 70 { return 2 }
        else if score >= 30 { return 3 }
        else { return 4 }
    }

    private var tierColor: Color {
        switch tierIndex {
        case 1: return Color(red: 0.20, green: 0.82, blue: 0.55) // 极佳
        case 2: return Color(red: 0.15, green: 0.68, blue: 0.95) // 良好
        case 3: return Color(red: 0.98, green: 0.62, blue: 0.15) // 繁忙
        default: return Color(red: 0.96, green: 0.28, blue: 0.38) // 告警
        }
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let mainColor = tierColor
        // 单侧向外波动 15pt（总直径扩展 30pt @ 90pt 基准尺寸）
        let maxWaveSpan: CGFloat = max(24.0, 30.0 * (mascotSize / 90.0))
        let targetWaveScale: CGFloat = (mascotSize + maxWaveSpan) / max(1.0, mascotSize)

        ZStack {
            // 1. 外圈呼吸光晕
            HealthRippleAuraCAView(
                mascotSize: mascotSize,
                maxWaveSpan: maxWaveSpan,
                targetWaveScale: targetWaveScale,
                mainColor: mainColor,
                isDark: isDark
            )
            .frame(width: mascotSize + maxWaveSpan + 6, height: mascotSize + maxWaveSpan + 6)

            // 2. 中心水彩兔子徽章
            if let img = Self.loadTierImage(tier: tierIndex, isDark: isDark) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: mascotSize, height: mascotSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .background(
                        Circle()
                            .stroke(mainColor.opacity(isDark ? 0.22 : 0.16), lineWidth: 2.5)
                            .frame(width: mascotSize + 3, height: mascotSize + 3)
                    )
            } else {
                Circle()
                    .fill(mainColor.opacity(0.2))
                    .frame(width: mascotSize, height: mascotSize)
            }
        }
        .frame(width: ringSize, height: ringSize)
    }

    public static func loadTierImage(tier: Int, isDark: Bool) -> NSImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        switch tier {
        case 1: if let img = cachedTier1 { return img }
        case 2: if let img = cachedTier2 { return img }
        case 3: if let img = cachedTier3 { return img }
        default: if let img = cachedTier4 { return img }
        }

        let name = "HealthRabbit-Tier\(tier)-1024"
        let fallbackPaths: [String?] = [
            Bundle.main.url(forResource: name, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let rawImg = NSImage(contentsOfFile: path) {
                let img = AppIconManager.downsampledUIImage(from: rawImg, maxPixelSize: 192)
                switch tier {
                case 1: cachedTier1 = img
                case 2: cachedTier2 = img
                case 3: cachedTier3 = img
                default: cachedTier4 = img
                }
                return img
            }
        }

        // Fallback to app icon if tier image not found
        let iconName = isDark ? "AppIcon-Dark-1024" : "AppIcon-Light-1024"
        let iconFallbacks: [String?] = [
            Bundle.main.url(forResource: iconName, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(iconName).png").path
        ]
        for path in iconFallbacks.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
        }

        return nil
    }
}

public typealias SolarSphereView = HealthPulseAuraBadgeView

// MARK: - Mini Waveform Line Component

struct MiniWaveformLine: View {
    var history: [Double] = []
    var color: Color

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxVal = max(5.0, history.max() ?? 5.0)
            let step = w / CGFloat(max(1, history.count - 1))

            let lastPoint: CGPoint = {
                guard let lastVal = history.last, !history.isEmpty else {
                    return CGPoint(x: w, y: h * 0.85)
                }
                let norm = CGFloat(min(maxVal, max(0.0, lastVal)) / maxVal)
                let y = h - (norm * (h * 0.75) + h * 0.12)
                return CGPoint(x: w, y: y)
            }()

            ZStack {
                Path { path in
                    guard !history.isEmpty else { return }
                    for (idx, val) in history.enumerated() {
                        let norm = CGFloat(min(maxVal, max(0.0, val)) / maxVal)
                        let y = h - (norm * (h * 0.75) + h * 0.12)
                        let x = CGFloat(idx) * step
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: h))
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            let prevX = CGFloat(idx - 1) * step
                            let prevVal = history[idx - 1]
                            let prevY = h - (CGFloat(min(maxVal, max(0.0, prevVal)) / maxVal) * (h * 0.75) + h * 0.12)
                            let midX = (prevX + x) / 2.0
                            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: midX, y: prevY), control2: CGPoint(x: midX, y: y))
                        }
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    if history.isEmpty {
                        path.move(to: CGPoint(x: 0, y: h * 0.85))
                        path.addLine(to: CGPoint(x: w, y: h * 0.85))
                        return
                    }
                    for (idx, val) in history.enumerated() {
                        let norm = CGFloat(min(maxVal, max(0.0, val)) / maxVal)
                        let y = h - (norm * (h * 0.75) + h * 0.12)
                        let x = CGFloat(idx) * step
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            let prevX = CGFloat(idx - 1) * step
                            let prevVal = history[idx - 1]
                            let prevY = h - (CGFloat(min(maxVal, max(0.0, prevVal)) / maxVal) * (h * 0.75) + h * 0.12)
                            let midX = (prevX + x) / 2.0
                            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: midX, y: prevY), control2: CGPoint(x: midX, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

                ZStack {
                    Circle()
                        .fill(color.opacity(0.24))
                        .frame(width: 11.5, height: 11.5)

                    Circle()
                        .stroke(color.opacity(0.35), lineWidth: 1.2)
                        .frame(width: 9.5, height: 9.5)

                    Circle()
                        .fill(color)
                        .frame(width: 4.5, height: 4.5)
                }
                .position(x: max(3, min(w - 3, lastPoint.x)), y: lastPoint.y)
            }
        }
    }
}


// MARK: - 网络流量波形组件

struct DualSparklineView: View {
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var color: Color

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxDown = max(1024.0 * 20.0, downloadHistory.max() ?? 1024.0)
            let step = w / CGFloat(max(1, downloadHistory.count - 1))

            let lastPoint: CGPoint = {
                guard let lastVal = downloadHistory.last, !downloadHistory.isEmpty else {
                    return CGPoint(x: w, y: h * 0.85)
                }
                let norm = min(1.0, CGFloat(lastVal / maxDown))
                let y = h - (norm * (h * 0.75) + h * 0.12)
                return CGPoint(x: w, y: y)
            }()

            ZStack {
                Path { path in
                    guard !downloadHistory.isEmpty else { return }
                    for (idx, val) in downloadHistory.enumerated() {
                        let norm = min(1.0, CGFloat(val / maxDown))
                        let y = h - (norm * (h * 0.75) + h * 0.12)
                        let x = CGFloat(idx) * step
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: h))
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            let prevX = CGFloat(idx - 1) * step
                            let prevVal = downloadHistory[idx - 1]
                            let prevY = h - (min(1.0, CGFloat(prevVal / maxDown)) * (h * 0.75) + h * 0.12)
                            let midX = (prevX + x) / 2.0
                            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: midX, y: prevY), control2: CGPoint(x: midX, y: y))
                        }
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    if downloadHistory.isEmpty {
                        path.move(to: CGPoint(x: 0, y: h * 0.85))
                        path.addLine(to: CGPoint(x: w, y: h * 0.85))
                        return
                    }
                    for (idx, val) in downloadHistory.enumerated() {
                        let norm = min(1.0, CGFloat(val / maxDown))
                        let y = h - (norm * (h * 0.75) + h * 0.12)
                        let x = CGFloat(idx) * step
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            let prevX = CGFloat(idx - 1) * step
                            let prevVal = downloadHistory[idx - 1]
                            let prevY = h - (min(1.0, CGFloat(prevVal / maxDown)) * (h * 0.75) + h * 0.12)
                            let midX = (prevX + x) / 2.0
                            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: midX, y: prevY), control2: CGPoint(x: midX, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

                ZStack {
                    Circle()
                        .fill(color.opacity(0.24))
                        .frame(width: 11.5, height: 11.5)

                    Circle()
                        .stroke(color.opacity(0.35), lineWidth: 1.2)
                        .frame(width: 9.5, height: 9.5)

                    Circle()
                        .fill(color)
                        .frame(width: 4.5, height: 4.5)
                }
                .position(x: max(3, min(w - 3, lastPoint.x)), y: lastPoint.y)
            }
        }
    }
}

/// 连续平移实时波形组件（支持阻尼峰值量程自适应）
struct SurgeConveyorWaveformView: NSViewRepresentable, Equatable {
    let primaryHistory: [Double]
    let secondaryHistory: [Double]?
    let minScaleCeiling: Double
    let activeThreshold: Double
    let accentColor: Color
    let isDark: Bool

    nonisolated static func == (lhs: SurgeConveyorWaveformView, rhs: SurgeConveyorWaveformView) -> Bool {
        lhs.primaryHistory == rhs.primaryHistory
            && lhs.secondaryHistory == rhs.secondaryHistory
            && lhs.minScaleCeiling == rhs.minScaleCeiling
            && lhs.isDark == rhs.isDark
    }

    func makeNSView(context: Context) -> SurgeConveyorWaveformNSView {
        SurgeConveyorWaveformNSView()
    }

    func updateNSView(_ nsView: SurgeConveyorWaveformNSView, context: Context) {
        nsView.configure(
            primaryHistory: primaryHistory,
            secondaryHistory: secondaryHistory,
            minScaleCeiling: minScaleCeiling,
            activeThreshold: activeThreshold,
            accentNSColor: NSColor(accentColor),
            isDark: isDark
        )
    }
}

final class SurgeConveyorWaveformNSView: NSView {
    override var isFlipped: Bool { true }

    private let gridLayer = CAShapeLayer()
    private let scrollClipLayer = CALayer()
    private let waveConveyorLayer = CALayer()
    private let dotContainerLayer = CALayer()
    private let haloLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()

    private var lastPrimary: [Double] = []
    private var lastSecondary: [Double]?
    private var lastMinScaleCeiling: Double = 20.0
    private var lastActiveThreshold: Double = 2.0
    private var lastAccentColor: NSColor = .systemCyan
    private var lastIsDark: Bool = true
    private var lastConfiguredSize: CGSize = .zero
    private var currentDotY: CGFloat?

    private var lastDataTickTime: CFTimeInterval?
    private var smoothedTickInterval: Double = 1.50
    private var displayedMaxScale: Double = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = false

        gridLayer.fillColor = nil
        gridLayer.lineWidth = 0.6
        gridLayer.lineDashPattern = [3, 3]
        root.addSublayer(gridLayer)

        scrollClipLayer.masksToBounds = true
        root.addSublayer(scrollClipLayer)

        waveConveyorLayer.anchorPoint = .zero
        waveConveyorLayer.contentsGravity = .resize
        scrollClipLayer.addSublayer(waveConveyorLayer)

        dotContainerLayer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        dotContainerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.addSublayer(dotContainerLayer)

        haloLayer.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        haloLayer.position = CGPoint(x: 8, y: 8)
        haloLayer.path = CGPath(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 9, height: 9), transform: nil)
        haloLayer.lineWidth = 1.0
        dotContainerLayer.addSublayer(haloLayer)

        dotLayer.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        dotLayer.position = CGPoint(x: 8, y: 8)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 5, height: 5), transform: nil)
        dotContainerLayer.addSublayer(dotLayer)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 10, bounds.height > 8 else { return }
        if lastConfiguredSize != bounds.size {
            renderAndAnimate(dataAdvanced: false, didSlideLeft: false)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowActivityChanged),
                name: NSWindow.didBecomeKeyNotification,
                object: newWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowActivityChanged),
                name: NSWindow.didResignKeyNotification,
                object: newWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowActivityChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            waveConveyorLayer.removeAllAnimations()
            haloLayer.removeAllAnimations()
            dotContainerLayer.removeAllAnimations()
            lastDataTickTime = nil
        } else {
            updatePulseState()
            if bounds.width > 10, bounds.height > 8, !lastPrimary.isEmpty {
                renderAndAnimate(dataAdvanced: false, didSlideLeft: false)
            }
        }
    }

    @objc private func handleWindowActivityChanged(_ notification: Notification) {
        updatePulseState()
        if !isWindowVisibleOnScreen {
            waveConveyorLayer.removeAllAnimations()
            dotContainerLayer.removeAllAnimations()
        }
    }

    private var isWindowVisibleOnScreen: Bool {
        guard let win = window else { return false }
        return win.occlusionState.contains(.visible)
    }

    private var conveyorFrameRateRange: CAFrameRateRange {
        if window?.isKeyWindow == true {
            return CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        return CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
    }

    func configure(
        primaryHistory: [Double],
        secondaryHistory: [Double]?,
        minScaleCeiling: Double,
        activeThreshold: Double,
        accentNSColor: NSColor,
        isDark: Bool
    ) {
        let dataChanged = (primaryHistory != lastPrimary || secondaryHistory != lastSecondary)
        let styleChanged = (isDark != lastIsDark || minScaleCeiling != lastMinScaleCeiling)
        let wasEmpty = lastPrimary.isEmpty
        let didSlideLeft = !wasEmpty
            && primaryHistory.count == lastPrimary.count
            && primaryHistory.count > 2
            && Array(lastPrimary.dropFirst()) == Array(primaryHistory.dropLast())

        if dataChanged {
            let now = CACurrentMediaTime()
            if let prev = lastDataTickTime {
                let dt = now - prev
                if dt >= 0.45 && dt <= 3.0 {
                    smoothedTickInterval = smoothedTickInterval * 0.65 + dt * 0.35
                }
            }
            lastDataTickTime = now
        }

        lastPrimary = primaryHistory
        lastSecondary = secondaryHistory
        lastMinScaleCeiling = minScaleCeiling
        lastActiveThreshold = activeThreshold
        lastAccentColor = accentNSColor
        lastIsDark = isDark

        guard dataChanged || styleChanged || lastConfiguredSize != bounds.size else { return }
        renderAndAnimate(dataAdvanced: dataChanged && !wasEmpty, didSlideLeft: didSlideLeft)
        updatePulseState()
    }

    private func updatePulseState() {
        let latestPrimary = lastPrimary.last ?? 0
        let latestSecondary = lastSecondary?.last ?? 0
        let isActive = isWindowVisibleOnScreen && (latestPrimary > lastActiveThreshold || latestSecondary > lastActiveThreshold)

        let tone = lastAccentColor.usingColorSpace(.sRGB) ?? .systemCyan
        haloLayer.fillColor = tone.withAlphaComponent(0.24).cgColor
        haloLayer.strokeColor = tone.withAlphaComponent(0.42).cgColor
        dotLayer.fillColor = tone.cgColor

        if isActive {
            if haloLayer.animation(forKey: "surgeHaloPulse") == nil {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.88
                scale.toValue = 1.75

                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.72
                fade.toValue = 0.0

                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = 1.65
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
                haloLayer.add(group, forKey: "surgeHaloPulse")
            }
            haloLayer.opacity = 1.0
        } else {
            haloLayer.removeAnimation(forKey: "surgeHaloPulse")
            haloLayer.transform = CATransform3DIdentity
            haloLayer.opacity = 0.55
        }
    }

    private func renderAndAnimate(dataAdvanced: Bool, didSlideLeft: Bool) {
        let w = bounds.width
        let h = bounds.height
        guard w > 16, h > 8 else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        lastConfiguredSize = bounds.size

        let rightPad: CGFloat = 5.5
        let visibleW = max(12, w - rightPad)

        // 1. 水平参考网格线
        let gridPath = CGMutablePath()
        let midY = round(h * 0.44 * scale) / scale
        let baseY = round((h - 2.0) * scale) / scale
        gridPath.move(to: CGPoint(x: 0, y: midY))
        gridPath.addLine(to: CGPoint(x: visibleW, y: midY))
        gridPath.move(to: CGPoint(x: 0, y: baseY))
        gridPath.addLine(to: CGPoint(x: visibleW, y: baseY))
        gridLayer.frame = bounds
        gridLayer.path = gridPath
        gridLayer.strokeColor = (lastIsDark ? NSColor.white : NSColor.black).withAlphaComponent(lastIsDark ? 0.075 : 0.065).cgColor

        // 2. 计算波形绘制尺寸（右侧预留 1 个采样步长用于连续左移）
        let samplesPrimary = lastPrimary.isEmpty ? [0, 0] : lastPrimary
        let samplesSecondary = lastSecondary ?? []
        let count = samplesPrimary.count
        let intervalsInViewport = CGFloat(max(1, count - 2))
        let stepX = visibleW / intervalsInViewport
        let totalLayerW = visibleW + stepX

        // Snapshot live presentation coordinates BEFORE updating layer contents
        let curPresentationTX = waveConveyorLayer.presentation()?.transform.m41 ?? (-stepX)
        let curPresentationDotY = dotContainerLayer.presentation()?.position.y ?? currentDotY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollClipLayer.frame = CGRect(x: 0, y: 0, width: visibleW, height: h)
        waveConveyorLayer.bounds = CGRect(x: 0, y: 0, width: totalLayerW, height: h)
        waveConveyorLayer.position = .zero
        waveConveyorLayer.contentsScale = scale
        CATransaction.commit()

        let peakPrimary = samplesPrimary.max() ?? 0.0
        let peakSecondary = samplesSecondary.max() ?? 0.0
        let targetMax = max(lastMinScaleCeiling, peakPrimary, peakSecondary * 0.85)
        if displayedMaxScale <= 0.0 || targetMax >= displayedMaxScale || !dataAdvanced {
            displayedMaxScale = targetMax
        } else {
            // 柔和阻尼衰减：波峰移出时曲线缓慢下沉，不突变
            displayedMaxScale = max(targetMax, displayedMaxScale * 0.88 + targetMax * 0.12)
        }
        let maxScale = max(lastMinScaleCeiling, displayedMaxScale)

        func yFor(_ val: Double) -> CGFloat {
            let norm = min(1.0, max(0.0, CGFloat(val / maxScale)))
            return h - (norm * (h * 0.74) + h * 0.13)
        }

        // 3. Draw bitmap once per update
        let pixelW = max(1, Int(ceil(totalLayerW * scale)))
        let pixelH = max(1, Int(ceil(h * scale)))
        if let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: scale, y: -scale)

            let accentRGB = lastAccentColor.usingColorSpace(.sRGB) ?? .systemCyan
            let secondaryColor = NSColor(srgbRed: 0.55, green: 0.58, blue: 1.0, alpha: lastIsDark ? 0.34 : 0.42)

            if samplesSecondary.count >= 2 && peakSecondary > 128.0 {
                let secPath = buildSmoothCurvePath(values: samplesSecondary, stepX: stepX, yMapper: yFor)
                ctx.saveGState()
                ctx.addPath(secPath)
                ctx.setStrokeColor(secondaryColor.cgColor)
                ctx.setLineWidth(1.0)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
                ctx.restoreGState()
            }

            let primaryLine = buildSmoothCurvePath(values: samplesPrimary, stepX: stepX, yMapper: yFor)
            let areaPath = primaryLine.mutableCopy() ?? CGMutablePath()
            let lastX = CGFloat(count - 1) * stepX
            areaPath.addLine(to: CGPoint(x: lastX, y: h))
            areaPath.addLine(to: CGPoint(x: 0, y: h))
            areaPath.closeSubpath()

            ctx.saveGState()
            ctx.addPath(areaPath)
            ctx.clip()
            let gradColors = [
                accentRGB.withAlphaComponent(lastIsDark ? 0.30 : 0.24).cgColor,
                accentRGB.withAlphaComponent(0.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradColors, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: h),
                    options: []
                )
            }
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(primaryLine)
            ctx.setStrokeColor(accentRGB.withAlphaComponent(lastIsDark ? 0.20 : 0.14).cgColor)
            ctx.setLineWidth(3.4)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(primaryLine)
            ctx.setStrokeColor(accentRGB.cgColor)
            ctx.setLineWidth(1.65)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()

            if let cgImage = ctx.makeImage() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                waveConveyorLayer.contents = cgImage
                CATransaction.commit()
            }
        }

        // 4. 连续水平滚动动画（失焦降频，全零直线静止）
        let targetY = yFor(samplesPrimary.last ?? 0.0)
        let dotX = w - rightPad
        let restingTransform = CATransform3DMakeTranslation(-stepX, 0, 0)
        let dotMoved = abs((currentDotY ?? targetY) - targetY) > 0.35
        let isFlatBaseline = peakPrimary <= lastActiveThreshold * 0.25
            && peakSecondary <= 128.0
            && !dotMoved

        if dataAdvanced && isWindowVisibleOnScreen && count > 2 && !isFlatBaseline {
            let rateRange = conveyorFrameRateRange
            // 相位无缝衔接：若上一帧动画未走完，新位置从 (curPresentationTX + stepX) 继续匀速滑向 -stepX
            let startTX: CGFloat = didSlideLeft
                ? min(stepX * 0.4, max(-stepX * 0.6, curPresentationTX + stepX))
                : 0.0
            let slideDuration = min(2.2, max(0.85, smoothedTickInterval)) + 0.04

            waveConveyorLayer.removeAnimation(forKey: "surgeConveyor")
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = startTX
            slide.toValue = -stepX
            slide.duration = slideDuration
            slide.timingFunction = CAMediaTimingFunction(name: .linear)
            slide.fillMode = .forwards
            slide.isRemovedOnCompletion = false
            slide.preferredFrameRateRange = rateRange
            waveConveyorLayer.transform = restingTransform
            waveConveyorLayer.add(slide, forKey: "surgeConveyor")

            let startY = curPresentationDotY ?? targetY
            dotContainerLayer.removeAnimation(forKey: "dotTrackY")
            let moveY = CABasicAnimation(keyPath: "position.y")
            moveY.fromValue = startY
            moveY.toValue = targetY
            moveY.duration = slideDuration
            moveY.timingFunction = CAMediaTimingFunction(name: .linear)
            moveY.preferredFrameRateRange = rateRange
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dotContainerLayer.position = CGPoint(x: dotX, y: targetY)
            CATransaction.commit()
            dotContainerLayer.add(moveY, forKey: "dotTrackY")
        } else {
            waveConveyorLayer.removeAnimation(forKey: "surgeConveyor")
            dotContainerLayer.removeAnimation(forKey: "dotTrackY")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            waveConveyorLayer.transform = restingTransform
            dotContainerLayer.position = CGPoint(x: dotX, y: targetY)
            CATransaction.commit()
        }
        currentDotY = targetY
    }

    private func buildSmoothCurvePath(values: [Double], stepX: CGFloat, yMapper: (Double) -> CGFloat) -> CGPath {
        let path = CGMutablePath()
        for (idx, val) in values.enumerated() {
            let x = CGFloat(idx) * stepX
            let y = yMapper(val)
            if idx == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                let prevX = CGFloat(idx - 1) * stepX
                let prevY = yMapper(values[idx - 1])
                let midX = (prevX + x) * 0.5
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: midX, y: prevY), control2: CGPoint(x: midX, y: y))
            }
        }
        return path
    }
}


// MARK: - Shared Energy App Row View

public struct EnergyAppRowView: View {
    public let app: EnergyAppItem
    public let theme: LiquidGlassTheme

    public init(app: EnergyAppItem, theme: LiquidGlassTheme) {
        self.app = app
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: 10) {
            AppIconImageView(pid: app.id)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text("PID \(app.id) · 内存 \(String(format: "%.0f MB", app.memoryMB))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: 190, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.gaugeTrack)
                        .frame(height: 6)
                    Capsule()
                        .fill(app.energyImpactScore > 30 ? Color.red : (app.energyImpactScore > 12 ? Color.orange : Color.cyan))
                        .frame(width: max(6, geo.size.width * min(1.0, CGFloat(app.energyImpactScore / 100.0))), height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 20)

            Text(String(format: "CPU %.1f%%", app.cpuPercent))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .frame(width: 78, alignment: .trailing)
                .help("与系统「活动监视器」一致，以单核心 100% 为基准。Safari 包含网页渲染与多标签页子进程，多核并发总计可超 100%")

            Text(String(format: "~%.1f W", app.estimatedWatts))
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(app.estimatedWatts > 4.0 ? .orange : .cyan)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.pillFill)
        )
    }
}

private struct AppIconImageView: View {
    let pid: pid_t

    public var body: some View {
        Image(nsImage: AppIconLookupCache.shared.icon(forPID: pid))
            .resizable()
            .interpolation(.high)
            .frame(width: 24, height: 24)
    }
}

// MARK: - 分档刻度滑块

public struct DiscreteAlignedSlider: View {
    public let title: String
    @Binding public var enabled: Bool
    @Binding public var value: Int
    public let options: [Int]
    public let unit: String
    public let theme: LiquidGlassTheme
    @Environment(\.colorScheme) private var colorScheme

    public init(title: String, enabled: Binding<Bool>, value: Binding<Int>, options: [Int], unit: String, theme: LiquidGlassTheme) {
        self.title = title
        self._enabled = enabled
        self._value = value
        self.options = options
        self.unit = unit
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(title, isOn: $enabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .pointingHandOnHover()

                Spacer()

                Text("\(value) \(unit)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(enabled ? Color.orange : theme.secondaryText)
            }

            GeometryReader { geo in
                let totalWidth = geo.size.width
                let trackInset: CGFloat = 24
                let usableWidth = max(10, totalWidth - trackInset * 2)
                let count = options.count
                let selectedIdx: Int = {
                    if let idx = options.firstIndex(of: value) { return idx }
                    var bestIdx = 0
                    var minDiff = Int.max
                    for (i, opt) in options.enumerated() {
                        let diff = abs(opt - value)
                        if diff < minDiff {
                            minDiff = diff
                            bestIdx = i
                        }
                    }
                    return bestIdx
                }()

                let activeRatio = CGFloat(selectedIdx) / CGFloat(max(1, count - 1))
                let thumbX = trackInset + usableWidth * activeRatio

                ZStack(alignment: .topLeading) {
                    // 1. 滑道底槽
                    Capsule(style: .continuous)
                        .fill(theme.cardFill.opacity(0.85))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(theme.cardBorder.opacity(0.65), lineWidth: 0.8)
                        )
                        .frame(width: usableWidth, height: 7)
                        .position(x: trackInset + usableWidth / 2, y: 12)

                    // 2. 激活填充层
                    if enabled && selectedIdx > 0 {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.orange.opacity(0.95),
                                        Color.yellow.opacity(0.85)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.55), Color.clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.6
                                    )
                            )
                            .shadow(color: Color.orange.opacity(0.35), radius: 3, x: 0, y: 1)
                            .frame(width: usableWidth * activeRatio, height: 7)
                            .position(x: trackInset + (usableWidth * activeRatio) / 2, y: 12)
                    }

                    // 3. 刻度点与刻度文字
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        let ratio = CGFloat(idx) / CGFloat(max(1, count - 1))
                        let xPos = trackInset + usableWidth * ratio
                        let isCurrent = (idx == selectedIdx)

                        Circle()
                            .fill(
                                !enabled ? theme.secondaryText.opacity(0.20) :
                                (idx <= selectedIdx ? Color.white.opacity(0.95) : theme.secondaryText.opacity(0.35))
                            )
                            .frame(width: idx == selectedIdx ? 5 : 3.5, height: idx == selectedIdx ? 5 : 3.5)
                            .position(x: xPos, y: 12)

                        Text("\(opt)\(unit)")
                            .font(.system(size: 10.5, weight: isCurrent && enabled ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(
                                !enabled ? theme.secondaryText.opacity(0.35) :
                                (isCurrent ? Color.orange : theme.secondaryText)
                            )
                            .fixedSize()
                            .position(x: xPos, y: 31)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if enabled {
                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.75)) {
                                        value = opt
                                    }
                                }
                            }
                            .pointingHandOnHover()
                    }

                    // 4. 滑块按钮
                    liquidGlassSliderThumb(thumbX: thumbX)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    guard enabled else { return }
                                    let touchX = gesture.location.x
                                    let clamped = max(trackInset, min(totalWidth - trackInset, touchX))
                                    let ratio = (clamped - trackInset) / usableWidth
                                    let nearestIdx = Int(round(ratio * CGFloat(count - 1)))
                                    let targetVal = options[max(0, min(count - 1, nearestIdx))]
                                    if value != targetVal {
                                        withAnimation(.spring(response: 0.24, dampingFraction: 0.75)) {
                                            value = targetVal
                                        }
                                    }
                                }
                        )
                }
            }
            .frame(height: 42)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.pillFill))
    }

    private func liquidGlassSliderThumb(thumbX: CGFloat) -> some View {
        ZStack {
            // 1. 磨砂底面
            Circle()
                .fill(
                    enabled
                        ? (colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.85))
                        : Color.gray.opacity(0.25)
                )

            // 2. 顶部高光层
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(enabled ? (colorScheme == .dark ? 0.42 : 0.75) : 0.15),
                            Color.white.opacity(enabled ? (colorScheme == .dark ? 0.08 : 0.20) : 0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 3. 高光描边
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(enabled ? (colorScheme == .dark ? 0.65 : 0.95) : 0.3),
                            Color.white.opacity(enabled ? (colorScheme == .dark ? 0.15 : 0.30) : 0.1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.9
                )

            // 4. 中心圆点
            Circle()
                .fill(enabled ? Color.orange : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
                .shadow(color: enabled ? Color.orange.opacity(0.5) : Color.clear, radius: 2)
        }
        .frame(width: 22, height: 22)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.15), radius: 4, x: 0, y: 2)
        .position(x: thumbX, y: 12)
        .pointingHandOnHover()
    }
}

// MARK: - Section 4: Feature & Display Toggles (功能与选项设置)

private struct CustomizationTogglesSection: View {
    @Bindable var toggles: FeatureToggleManager
    let theme: LiquidGlassTheme
    @Bindable var permissions = SystemPermissionManager.shared
    @Bindable var updater = AppUpdateManager.shared

    public var body: some View {
        VStack(spacing: 16) {
            // 系统权限状态检测
            permissionCheckGroup

            // Software Update Strategy
            VStack(alignment: .leading, spacing: 10) {
                Label("软件更新检查策略", systemImage: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                VStack(alignment: .leading, spacing: 8) {
                    compactToggle("每日早晚各自动检查 1 次更新", isOn: $updater.autoUpdateCheckEnabled)

                    Text("开启后仅在每日早间（06:00–13:00）与晚间（18:00–24:00）各静默检查 1 次并启用 ETag 零配额缓存；关闭后仅在手动点击检查更新时联网。")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .background(cardBackground)

            // Menu Bar Display Items
            VStack(alignment: .leading, spacing: 12) {
                Label("菜单栏功能显示项", systemImage: "menubar.rectangle")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                    compactToggle("CPU 负载 (上) / GPU 负载 (下)", isOn: $toggles.menuBarShowCpuGpu)
                    compactToggle("内存占用 (上) / 处理器温度 (下)", isOn: $toggles.menuBarShowMemTemp)
                    compactToggle("当前网速上传 (上) / 下载 (下)", isOn: $toggles.menuBarShowNetworkSpeed)
                    compactToggle("整机最高功耗 (上) / 整机实时功耗 (下)", isOn: $toggles.menuBarShowSystemWatts)
                }
            }
            .padding(16)
            .background(cardBackground)
        }
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointingHandOnHover()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.pillFill))
    }

    // MARK: - Permission Check Card Group

    private var permissionCheckGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("系统权限与授权状态检查", systemImage: "lock.shield.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button {
                    permissions.checkAllPermissions()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("刷新状态")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            VStack(spacing: 10) {
                permissionSwitchRow(
                    icon: "internaldrive.fill",
                    iconColor: .cyan,
                    title: "完全磁盘访问权限 (Full Disk Access)",
                    description: "智能清理与应用管理深度扫描系统日志、用户缓存与残留垃圾时必需",
                    status: permissions.fullDiskAccessStatus,
                    isTCCManaged: true,
                    onEnable: { permissions.openFullDiskAccessSettings(expectAuthorized: true) },
                    onDisable: { permissions.openFullDiskAccessSettings(expectAuthorized: false) }
                )

                Divider().overlay(theme.dividerColor.opacity(0.5))

                permissionSwitchRow(
                    icon: "antenna.radiowaves.left.and.right",
                    iconColor: .blue,
                    title: "蓝牙访问权限 (Bluetooth)",
                    description: "读取 AirPods 系列、妙控键盘/触控板及蓝牙外设的连接状态与实时电量",
                    status: permissions.bluetoothStatus,
                    isTCCManaged: true,
                    onEnable: { permissions.requestBluetoothPermission() },
                    onDisable: { permissions.openBluetoothSettings(expectAuthorized: false) }
                )

                Divider().overlay(theme.dividerColor.opacity(0.5))

                permissionSwitchRow(
                    icon: "bell.badge.fill",
                    iconColor: .orange,
                    title: "桌面通知权限 (Notifications)",
                    description: "UPS 断电告警、低电量关机倒计时与垃圾清理完毕时发送即时横幅提醒",
                    status: permissions.notificationStatus,
                    isTCCManaged: true,
                    onEnable: {
                        if permissions.notificationStatus == .notDetermined {
                            permissions.requestNotificationPermission()
                        } else {
                            permissions.openNotificationSettings(expectAuthorized: true)
                        }
                    },
                    onDisable: { permissions.openNotificationSettings(expectAuthorized: false) }
                )

                Divider().overlay(theme.dividerColor.opacity(0.5))

                permissionSwitchRow(
                    icon: "externaldrive.badge.checkmark",
                    iconColor: .purple,
                    title: "外置磁盘安全推出权限 (Apple Events)",
                    description: "外置磁盘逃生舱在市电意外断开时向系统发送安全退出指令",
                    status: permissions.automationStatus,
                    isTCCManaged: true,
                    onEnable: { permissions.requestAutomationPermission() },
                    onDisable: { permissions.openAutomationSettings(expectAuthorized: false) }
                )

                Divider().overlay(theme.dividerColor.opacity(0.5))

                permissionSwitchRow(
                    icon: "fan.fill",
                    iconColor: .orange,
                    title: "风扇控制特权授权 (SMC Helper)",
                    description: "在手动降温或强冷模式下写入 AppleSMC 调节风扇转速，关闭开关可卸载特权助手",
                    status: permissions.fanHelperStatus,
                    isTCCManaged: false,
                    onEnable: { permissions.requestFanHelperPermission() },
                    onDisable: { permissions.revokeFanHelperPermission() }
                )

                Divider().overlay(theme.dividerColor.opacity(0.5))

                permissionSwitchRow(
                    icon: "power.circle.fill",
                    iconColor: .green,
                    title: "开机自启动授权 (Login Items)",
                    description: "默认开启 · 系统登录后自动在后台启动 SysPulse 并恢复菜单栏监控与断电保护",
                    status: permissions.launchAtLoginStatus,
                    isTCCManaged: false,
                    onEnable: { permissions.setLaunchAtLogin(true) },
                    onDisable: { permissions.setLaunchAtLogin(false) }
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.pillFill))
        }
        .padding(16)
        .background(cardBackground)
    }

    private func permissionSwitchRow(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        status: SystemPermissionManager.PermissionStatus,
        isTCCManaged: Bool,
        onEnable: @escaping () -> Void,
        onDisable: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.primaryText)

                    Text(status.title)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(status.isAuthorized ? .green : (status == .denied ? .red : .orange))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill((status.isAuthorized ? Color.green : (status == .denied ? Color.red : Color.orange)).opacity(0.15))
                        )
                }

                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { status.isAuthorized },
                    set: { enabled in
                        if enabled {
                            onEnable()
                        } else {
                            onDisable()
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .pointingHandOnHover()
            .help(
                status.isAuthorized && isTCCManaged
                    ? "关闭将打开系统设置取消授权，切回后自动同步状态"
                    : description
            )
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(theme.studioCardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
            )
    }
}

// MARK: - Section 5: Window About Section

private struct WindowAboutSection: View {
    @Environment(\.colorScheme) private var colorScheme
    var engine: PowerSourceEngine
    let theme: LiquidGlassTheme

    public var body: some View {
        VStack(spacing: 16) {
            PowerGlassAppIconView(size: 80, forcedColorScheme: colorScheme)
                .padding(.top, 8)

            VStack(spacing: 5) {
                Text("SysPulse")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("专为 macOS 打造的智能系统管家")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Text(AppMetadata.fullVersionDisplay)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
            }

            VStack(spacing: 10) {
                aboutRow(label: "作者", value: "Rabbit-Spec", link: "https://github.com/Rabbit-Spec/macOS-SysPulse")
                Divider().overlay(theme.dividerColor.opacity(0.5))
                aboutRow(label: "Bilibili 频道", value: "汤圆_Lyric", link: "https://space.bilibili.com/7135720")
                Divider().overlay(theme.dividerColor.opacity(0.5))
                aboutRow(label: "硬件平台", value: MacHardwareInfo.shared.platformName)
                Divider().overlay(theme.dividerColor.opacity(0.5))
                HStack {
                    Text("运行诊断")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            StudioWindowNavigationState.shared.isDiagnosticsModalPresented = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("查看诊断报告")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            Image(systemName: "stethoscope")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(16)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.studioCardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
                    )
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func aboutRow(label: String, value: String, link: String? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            if let link, let url = URL(string: link) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(value)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(theme.primaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            } else {
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
        }
    }
}

// MARK: - Window Liquid Backdrop

private struct WindowLiquidBackdrop: View {
    let state: PowerSupplyState
    let theme: LiquidGlassTheme

    public var body: some View {
        // 单层环境色罩
        LinearGradient(
            colors: theme.studioBackdropTintColors(isAC: state.isAC),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
    }
}

// MARK: - 应用图标下拉菜单

public struct AppIconDropdownMenuView: View {
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme
    var keepAwake = KeepAwakeController.shared

    public init(navState: StudioWindowNavigationState = .shared, theme: LiquidGlassTheme = LiquidGlassTheme(colorScheme: .dark)) {
        self.navState = navState
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            menuRow(icon: "shield.lefthalf.filled", title: "清理设置") {
                navState.isIconMenuPresented = false
                navState.openModal(tab: .cleaner)
            }
            menuRow(icon: "gearshape", title: "系统设置") {
                navState.isIconMenuPresented = false
                navState.openModal(tab: .settings)
            }
            menuRow(icon: "info.circle", title: "关于 SysPulse") {
                navState.isIconMenuPresented = false
                navState.openModal(tab: .about)
            }

            Divider()
                .padding(.vertical, 2)

            menuRow(
                icon: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                title: keepAwake.isActive ? "停止常亮 (\(keepAwake.remainingFormattedText))" : "保持常亮"
            ) {
                navState.isIconMenuPresented = false
                keepAwake.toggle()
            }
            menuRow(icon: "arrow.triangle.2.circlepath", title: "检查更新") {
                navState.isIconMenuPresented = false
                AppUpdateManager.shared.checkForUpdates(userInitiated: true)
            }
        }
        .padding(6)
        .frame(width: 176)
    }

    private func menuRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}
