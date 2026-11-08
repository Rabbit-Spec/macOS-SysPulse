import SwiftUI
import AppKit

// MARK: - 主窗口根视图

public struct MainStudioWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var navState = StudioWindowNavigationState.shared
    @Bindable var engine = PowerSourceEngine.shared
    @Bindable var monitor = SystemResourceMonitor.shared
    @Bindable var toggles = FeatureToggleManager.shared
    @Bindable var diskGuardian = DiskGuardian.shared
    @Bindable var upsSettings = SystemUPSSettingsManager.shared

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
                WindowLiquidBackdrop(state: engine.telemetry.state, theme: theme)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 顶部导航栏
                    topNavigationBar

                    // 当前标签页内容区
                    ZStack(alignment: .top) {
                        switch navState.selectedTab {
                        case .status:
                            StatusOverviewSection(
                                navState: navState,
                                engine: engine,
                                monitor: monitor,
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
        HStack(spacing: 0) {
            Spacer()
                .frame(width: 80)

            Spacer()

            // 居中胶囊导航栏
            HStack(spacing: 0) {
                // 1. 左上角应用图标下拉菜单按钮
                Button {
                    navState.isIconMenuPresented.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                        SysPulseAppIconView(size: 30, forcedColorScheme: colorScheme, isCircle: true)
                    }
                    .frame(width: 32, height: 32)
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

                // 2. 顶部模块切换标签
                HStack(spacing: 6) {
                    ForEach(StudioTopTab.allCases) { tab in
                        let isSelected = (navState.selectedTab == tab && !navState.isModalPresented)
                        Button {
                            withAnimation(.spring(duration: 0.2, bounce: 0.0)) {
                                navState.selectedTab = tab
                                navState.isModalPresented = false
                            }
                        } label: {
                            ZStack {
                                Capsule(style: .continuous)
                                    .fill(isSelected ? (colorScheme == .dark ? Color.white : Color(white: 0.15)) : Color.black.opacity(0.0001))

                                Text(tab.rawValue)
                                    .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(isSelected ? (colorScheme == .dark ? Color.black : Color.white) : theme.primaryText.opacity(0.85))
                            }
                            .frame(width: 70, height: 36)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.8)
                    )
            )

            Spacer()

            // 右上角版本号与检查更新按钮
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
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.cardFill)
                        .overlay(Capsule().strokeBorder(AppUpdateManager.shared.hasUpdateAvailable ? Color.cyan.opacity(0.45) : theme.cardBorder, lineWidth: 0.6))
                )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("点击检查 GitHub 最新版本更新")
            .padding(.trailing, 24)
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
                                case .ups:
                                    UPSCenterSection(
                                        engine: engine,
                                        monitor: monitor,
                                        upsSettings: upsSettings,
                                        diskGuardian: diskGuardian,
                                        toggles: toggles,
                                        theme: theme
                                    )
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
    @Environment(\.colorScheme) private var colorScheme

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(684, canvasHeight - 79 - 59) }
    private var col1W: CGFloat { max(348, round((contentW - 36) * (348.0 / 1116.0))) }
    private var colOtherW: CGFloat { max(256, (contentW - 36 - col1W) / 3.0) }
    private var cardRowH: CGFloat { max(170, round((contentH - 28) * (170.0 / 656.0))) }
    private var processCardH: CGFloat { max(316, (contentH - 28) - 2 * cardRowH) }
    private var rowScale: CGFloat { max(1.0, cardRowH / 170.0) }

    var body: some View {
        VStack(spacing: 14) {
            // 2x4 核心状态指标卡片网格
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

            // 底部高能耗进程排行卡片
            processRankingCard
                .frame(width: contentW, height: processCardH)
        }
        .padding(.horizontal, 24)
        .padding(.top, 35)
        .padding(.bottom, 24)
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
                        let osVer = ProcessInfo.processInfo.operatingSystemVersion
                        pillBadge(MacHardwareInfo.shared.chipBrand.replacingOccurrences(of: "Apple ", with: ""))
                        pillBadge("\(Int(monitor.memory.totalGB)) GB")
                        pillBadge("macOS \(osVer.majorVersion).\(osVer.minorVersion)")
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(snapshot.score)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text(snapshot.rating.rawValue)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }

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
                    headerBadge("\(temp)°C")
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(cpuPercent)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 2)

                // 多核负载柱状图
                GeometryReader { geo in
                    let count = max(8, coreCount)
                    let totalW = geo.size.width
                    let spacing: CGFloat = count > 12 ? 2.5 : 3.5
                    let totalSpacing = spacing * CGFloat(count - 1)
                    let barWidth = max(3.5, (totalW - totalSpacing) / CGFloat(count))

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(0..<count, id: \.self) { idx in
                            let coreVal = idx < coreLoads.count ? coreLoads[idx] : Double(cpuPercent)
                            let barHeight = max(3.5, min(eqH, 3.5 + (coreVal / 100.0) * (eqH - 3.5)))

                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: coreVal > 75
                                            ? [Color(red: 0.96, green: 0.58, blue: 0.24), Color(red: 0.90, green: 0.42, blue: 0.20)]
                                            : [Color(red: 0.32, green: 0.86, blue: 0.58), Color(red: 0.20, green: 0.74, blue: 0.46)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: barWidth, height: barHeight)
                                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: coreVal)
                        }
                    }
                    .frame(width: totalW, height: eqH, alignment: .bottom)
                }
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
                    headerBadge("\(temp)°C")
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(gpuPercent)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 2)

                MiniWaveformLine(history: monitor.hardware.gpuHistory, color: Color(red: 0.95, green: 0.60, blue: 0.20))
                    .frame(height: round(24.0 * rowScale))

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

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(usedPercent)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.90, green: 0.75, blue: 0.35), Color(red: 0.85, green: 0.60, blue: 0.25)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, geo.size.width * CGFloat(usedPercent) / 100.0))
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
        let isMacBook = toggles.enableMacBookDemoMode || (monitor.loadRuntime.hasInternalBattery && !engine.telemetry.isConnected)
        let batteryLevel = engine.telemetry.isConnected
            ? engine.telemetry.batteryLevel
            : (monitor.loadRuntime.hasInternalBattery ? monitor.loadRuntime.internalBatteryPercent : 100)
        let isOnline = engine.telemetry.isConnected ? engine.telemetry.state.isAC : (isMacBook ? monitor.loadRuntime.isInternalCharging : true)
        let curWatts = monitor.power.totalSystemWatts
        let peakWatts = max(monitor.power.peakWatts, curWatts)
        let topEnergyApp = monitor.topEnergyApps.first?.name ?? "WindowServer"
        let connectedAccessories = accessories.accessories.filter { $0.isConnected }

        return cardBackground(id: "power") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PulsingHeaderSymbolView(
                        systemName: isMacBook ? "battery.100.bolt" : (engine.telemetry.isConnected ? "bolt.fill" : "powerplug.fill"),
                        size: 13,
                        color: Color(red: 0.35, green: 0.82, blue: 0.55)
                    )
                    Text(isMacBook ? "电池" : (engine.telemetry.isConnected ? "UPS 供电" : "AC 供电"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 0.55))
                    Spacer()
                }

                HStack(alignment: .center, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(batteryLevel)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("%")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }

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
                    Text(isOnline ? (isMacBook ? "充电中" : "市电在线") : "电池供电")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOnline ? Color(red: 0.35, green: 0.85, blue: 0.55) : Color.orange)

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

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(freeGB)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("GB")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(Color.blue)
                            .frame(width: max(8, geo.size.width * CGFloat(usedPct) / 100.0))
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

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.value)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text(parts.unit)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 2)

                DualSparklineView(
                    downloadHistory: monitor.hardware.networkHistoryDownload,
                    uploadHistory: monitor.hardware.networkHistoryUpload,
                    color: Color.cyan
                )
                .frame(height: round(24.0 * rowScale))

                Spacer(minLength: 2)

                HStack {
                    Text("上传 \(monitor.hardware.formattedUploadSpeed)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()

                    let wifiLL = WiFiLowLatencyManager.shared
                    Button(action: {
                        wifiLL.toggleLowLatency()
                    }) {
                        HStack(spacing: 4) {
                            if wifiLL.isBusy {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                            } else if wifiLL.isLowLatencyActive {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                            }
                            Text(wifiLL.statusMessage)
                                .font(.system(size: 12.5, weight: wifiLL.isLowLatencyActive ? .medium : .regular))
                                .foregroundStyle(wifiLL.isLowLatencyActive ? Color.green : theme.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help(wifiLL.isLowLatencyActive
                        ? "低延迟模式已开启：暂停隔空投送、iPhone 镜像及其他 AWDL 直连，关闭即可恢复。"
                        : "开启后暂停隔空投送、iPhone 镜像及其他 AWDL 直连，消除信道跳跃延迟波动；关闭即可恢复。")
                }
                .lineLimit(1)
            }
        }
        .frame(height: cardRowH)
    }

    // 8. 风扇转速与温控卡片（无风扇机型自适应为「静音散热」热工况卡片）
    private var fanCard: some View {
        let fan = FanController.shared
        let rpm = fan.currentRPM
        let pct = Int(round(Double(rpm) / Double(max(1, fan.maxRPM)) * 100.0))

        return cardBackground(id: "fan") {
            if fan.isFanSupported {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        SpinningFanIconView(rpm: rpm, size: 13.5, color: Color.orange)
                        Text("风扇")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange)
                        Spacer()
                        headerBadge("转速 \(pct)%")
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(NumberFormatter.localizedString(from: NSNumber(value: rpm), number: .decimal))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("RPM")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }

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
                        Text("被动均热 · \(tempC)°C")
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

    // MARK: - 高能耗进程排行列表

    private var currentDisplayApps: [EnergyAppItem] {
        if navState.displayedProcesses.isEmpty {
            return monitor.topEnergyApps
        }
        return navState.displayedProcesses
    }

    private var sortedDisplayApps: [EnergyAppItem] {
        let list = currentDisplayApps
        let field = navState.processSortField
        let order = navState.processSortOrder
        return list.sorted { a, b in
            switch field {
            case .name:
                let comp = a.name.localizedStandardCompare(b.name)
                return order == .ascending ? (comp == .orderedAscending) : (comp == .orderedDescending)
            case .memory:
                return order == .ascending ? (a.memoryBytes < b.memoryBytes) : (a.memoryBytes > b.memoryBytes)
            case .cpu:
                return order == .ascending ? (a.cpuPercent < b.cpuPercent) : (a.cpuPercent > b.cpuPercent)
            case .energy:
                return order == .ascending ? (a.energyImpactScore < b.energyImpactScore) : (a.energyImpactScore > b.energyImpactScore)
            case .pid:
                return order == .ascending ? (a.pid < b.pid) : (a.pid > b.pid)
            }
        }
    }

    private var processRankingCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
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
                    .frame(width: 110, alignment: .trailing)
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
                    .frame(width: 140, alignment: .trailing)
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
                    .frame(width: 90, alignment: .trailing)
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
                    .frame(width: 75, alignment: .trailing)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.8)
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
        HStack(spacing: 24) {
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
                .frame(width: 110, alignment: .trailing)

            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Color.cyan)
                            .frame(width: max(2, geo.size.width * CGFloat(min(100.0, app.cpuPercent)) / 100.0))
                    }
                }
                .frame(width: 65, height: 4.5)

                Text(String(format: "%.1f", app.cpuPercent))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 45, alignment: .trailing)
            }
            .frame(width: 140, alignment: .trailing)

            Text(String(format: "%.1f", app.energyImpactScore))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(app.energyImpactScore > 20 ? Color.orange : theme.primaryText)
                .frame(width: 90, alignment: .trailing)

            Text("\(app.pid)")
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 75, alignment: .trailing)

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

    // MARK: - Component Helpers

    private func cardBackground<Content: View>(id: String = "", @ViewBuilder content: () -> Content) -> some View {
        let isHovered = (!id.isEmpty && navState.hoveredOverviewCardID == id)
        let borderColor = isHovered
            ? (colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.18))
            : theme.cardBorder

        return VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isHovered ? 1.1 : 0.8)
                )
                .shadow(
                    color: Color.black.opacity(isHovered ? (colorScheme == .dark ? 0.32 : 0.08) : 0.0),
                    radius: isHovered ? 10 : 0,
                    y: isHovered ? 4 : 0
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

    private func headerBadge(_ text: String) -> some View {
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

// MARK: - 健康度萌兔徽章视图

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
        case 1: return Color(red: 0.20, green: 0.82, blue: 0.55) // 极佳：翡翠薄荷绿
        case 2: return Color(red: 0.15, green: 0.68, blue: 0.95) // 良好：天青纯蓝
        case 3: return Color(red: 0.98, green: 0.62, blue: 0.15) // 繁忙：活力暖金
        default: return Color(red: 0.96, green: 0.28, blue: 0.38) // 告警：珊瑚绯红
        }
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let mainColor = tierColor
        let waveSpeed: Double = (tierIndex == 1 || tierIndex == 2) ? 0.17 : (tierIndex == 3 ? 0.25 : 0.35)
        let maxWaveSpan: CGFloat = max(14.0, (ringSize - mascotSize) * 1.12)

        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 1.1) + 1.0) * 0.5

            ZStack {
                // 1. 紧凑内敛的呼吸基底光晕
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                mainColor.opacity((isDark ? 0.28 : 0.18) + 0.08 * breath),
                                mainColor.opacity((isDark ? 0.08 : 0.04) + 0.04 * breath),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: mascotSize * 0.38,
                            endRadius: (mascotSize + maxWaveSpan) * 0.52
                        )
                    )
                    .frame(width: mascotSize + maxWaveSpan + 6, height: mascotSize + maxWaveSpan + 6)
                    .blur(radius: 2.0)

                // 2. 双层慢速、小范围向外散发的柔光波纹
                ForEach(0..<2, id: \.self) { idx in
                    let phase = ((t * waveSpeed) + Double(idx) * 0.5).truncatingRemainder(dividingBy: 1.0)
                    let eased = 1.0 - pow(1.0 - phase, 1.45)
                    let waveDiameter = mascotSize + maxWaveSpan * CGFloat(eased)
                    let fadeEnvelope = sin(phase * .pi) * (1.0 - phase * 0.45)
                    let waveAlpha = max(0.0, fadeEnvelope * (isDark ? 0.68 : 0.56))

                    ZStack {
                        // 柔光波晕
                        Circle()
                            .stroke(mainColor.opacity(waveAlpha * 0.38), lineWidth: 2.8 * (1.0 - CGFloat(phase) * 0.4))
                            .frame(width: waveDiameter, height: waveDiameter)
                            .blur(radius: 1.5)

                        // 细腻波峰光线
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        mainColor.opacity(waveAlpha * 0.88),
                                        mainColor.opacity(waveAlpha * 0.48),
                                        mainColor.opacity(waveAlpha * 0.82)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: max(0.6, 1.3 - CGFloat(phase) * 0.55)
                            )
                            .frame(width: waveDiameter, height: waveDiameter)
                    }
                }

                // 3. 固定不动的中心水彩兔子徽章
                if let img = Self.loadTierImage(tier: tierIndex, isDark: isDark) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: mascotSize, height: mascotSize)
                        .clipShape(Circle())
                        .overlay(
                            Circle().strokeBorder(isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: mainColor.opacity(0.30 + 0.12 * breath), radius: 5, y: 2)
                } else {
                    Circle()
                        .fill(mainColor.opacity(0.2))
                        .frame(width: mascotSize, height: mascotSize)
                }
            }
            .frame(width: ringSize, height: ringSize)
        }
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
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path,
            "/Volumes/巨无霸/SPEC/v3.0.0/Resources/\(name).png",
            "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/Resources/\(name).png",
            "/tmp/\(name).png",
            "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/health_rabbit_tier\(tier)_\(tier == 1 ? "excellent" : (tier == 2 ? "good" : (tier == 3 ? "busy" : "alert"))).png"
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
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
            Bundle.main.resourceURL?.appendingPathComponent("\(iconName).png").path,
            "/Volumes/巨无霸/SPEC/v3.0.0/Resources/\(iconName).png",
            "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/Resources/\(iconName).png"
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

// Keep SolarSphereView as a direct drop-in alias pointing to HealthPulseAuraBadgeView
public typealias SolarSphereView = HealthPulseAuraBadgeView

// MARK: - Mini Waveform Line Component

struct MiniWaveformLine: View {
    var history: [Double] = []
    var color: Color

    var body: some View {
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

                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = (t * 0.9).truncatingRemainder(dividingBy: 1.0)

                    ZStack {
                        Circle()
                            .stroke(color.opacity(max(0.0, (1.0 - pulse) * 0.65)), lineWidth: 1.2)
                            .frame(width: 5 + CGFloat(pulse) * 9, height: 5 + CGFloat(pulse) * 9)

                        Circle()
                            .fill(color)
                            .frame(width: 4.5, height: 4.5)
                            .shadow(color: color.opacity(0.8), radius: 3)
                    }
                    .position(x: max(3, min(w - 3, lastPoint.x)), y: lastPoint.y)
                }
            }
        }
    }
}

// MARK: - 网络流量波形组件

struct DualSparklineView: View {
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var color: Color

    var body: some View {
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

                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = (t * 0.9).truncatingRemainder(dividingBy: 1.0)

                    ZStack {
                        Circle()
                            .stroke(color.opacity(max(0.0, (1.0 - pulse) * 0.65)), lineWidth: 1.2)
                            .frame(width: 5 + CGFloat(pulse) * 9, height: 5 + CGFloat(pulse) * 9)

                        Circle()
                            .fill(color)
                            .frame(width: 4.5, height: 4.5)
                            .shadow(color: color.opacity(0.8), radius: 3)
                    }
                    .position(x: max(3, min(w - 3, lastPoint.x)), y: lastPoint.y)
                }
            }
        }
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

    var body: some View {
        let icon: NSImage = {
            if let running = NSRunningApplication(processIdentifier: pid), let img = running.icon {
                return img
            }
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }()
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 24, height: 24)
    }
}

// MARK: - Section 3: UPS & Battery Center (UPS 续航中枢)

private struct UPSCenterSection: View {
    var engine: PowerSourceEngine
    var monitor: SystemResourceMonitor
    @Bindable var upsSettings: SystemUPSSettingsManager
    @Bindable var diskGuardian: DiskGuardian
    var toggles: FeatureToggleManager
    let theme: LiquidGlassTheme

    var body: some View {
        VStack(spacing: 16) {
            // 1. MacBook + Desktop UPS Replacement Banner
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer.and.ipad")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.cyan.opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("完美替代 macOS 系统 UPS 设置")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("USB HID 直连")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                    Text("macOS 在 MacBook 接入外置 UPS 时默认隐藏系统的 UPS 设置面板。SysPulse 通过底层 IOKit 与 USB HID 直接读取外置 UPS 电量、电压与供电状态，并提供独立的断电保护，在 MacBook 与 Mac 桌面设备上均可完整接管 UPS 控制。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1.0)
                    )
            )

            // 2. Active Software Protection + System UPS Thresholds
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("UPS 自动断电保护策略", systemImage: "bolt.shield.fill")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Button {
                        upsSettings.commitChangesToSystem(forceAuthorize: true) {}
                    } label: {
                        Label("同步写入系统", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.cyan.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                // Software Watchdog Mode for MacBook & Desktop
                HStack {
                    Toggle("启用断电自动休眠 / 关机保护（MacBook 推荐）", isOn: $upsSettings.softwareProtectionEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .pointingHandOnHover()

                    Spacer()

                    Picker("触发阈值后执行：", selection: $upsSettings.protectionAction) {
                        Text("安全退出外接盘并睡眠 (推荐)").tag("sleep")
                        Text("安全退出外接盘并关机").tag("shutdown")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 250)
                    .font(.system(size: 12))
                    .pointingHandOnHover()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.pillFill))

                // 3 Discrete Threshold Sliders with Pixel-Perfect Alignment
                DiscreteAlignedSlider(
                    title: "使用 UPS 电池供电达到此时间时保护 Mac",
                    enabled: $upsSettings.haltAfterEnabled,
                    value: $upsSettings.haltAfterMinutes,
                    options: SystemUPSSettingsManager.validMinuteOptions,
                    unit: "分钟",
                    theme: theme
                )

                DiscreteAlignedSlider(
                    title: "UPS 电池剩余使用时间低于此时间时保护 Mac",
                    enabled: $upsSettings.haltRemainEnabled,
                    value: $upsSettings.haltRemainMinutes,
                    options: SystemUPSSettingsManager.validMinuteOptions,
                    unit: "分钟",
                    theme: theme
                )

                DiscreteAlignedSlider(
                    title: "UPS 电池电量低于此水平时保护 Mac",
                    enabled: $upsSettings.haltLevelEnabled,
                    value: $upsSettings.haltLevelPercent,
                    options: SystemUPSSettingsManager.validPercentOptions,
                    unit: "%",
                    theme: theme
                )
            }
            .padding(18)
            .background(cardBackground)

            // 3. External Disk Escape Pod Settings
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("外置磁盘安全逃生舱", systemImage: "externaldrive.fill.badge.timemachine")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Toggle("断电自动退盘保护", isOn: $diskGuardian.autoEjectEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 12, weight: .semibold))
                        .pointingHandOnHover()
                }

                HStack {
                    Text("断电后自动安全推出延时：")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                    Picker("", selection: $diskGuardian.delayMinutes) {
                        Text("断电后 1 分钟").tag(1)
                        Text("断电后 3 分钟 (推荐)").tag(3)
                        Text("断电后 5 分钟").tag(5)
                        Text("断电后 10 分钟").tag(10)
                    }
                    .frame(width: 180)
                    .pointingHandOnHover()
                    Spacer()
                    Button("立即推出所有外接盘") {
                        diskGuardian.emergencyEjectAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandOnHover()
                }
            }
            .padding(18)
            .background(cardBackground)

            // 4. 供电事件记录
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("供电事件记录", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    if !engine.events.isEmpty {
                        Button {
                            withAnimation(.spring(duration: 0.28, bounce: 0.0)) {
                                engine.clearEvents()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .medium))
                                Text("清空记录")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.pillFill))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help("清空所有供电事件记录")
                    } else {
                        Text("0 条记录")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                if engine.events.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.green.opacity(0.8))
                            Text("市电供电稳定，暂无电网中断或告警事件")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, 14)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(engine.events.prefix(10)) { event in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(powerEventColor(event.type))
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.type.rawValue)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.primaryText)
                                    Text(event.details)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(theme.secondaryText)
                                }

                                Spacer()

                                Text(event.timestamp.formatted(date: .numeric, time: .standard))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.pillFill))
                        }
                    }
                }
            }
            .padding(18)
            .background(cardBackground)
        }
    }

    private func powerEventColor(_ type: PowerEventType) -> Color {
        switch type {
        case .powerCut, .batteryLow:
            return LiquidTheme.crimsonAlert
        case .powerRestored:
            return LiquidTheme.mintGreen
        case .voltageDip, .voltageSurge:
            return LiquidTheme.amberWarning
        case .diskEjected, .networkNotified:
            return Color.cyan
        case .selfTest:
            return Color.purple
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.9)
            )
    }
}

// MARK: - Discrete Aligned Slider

private struct DiscreteAlignedSlider: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var value: Int
    let options: [Int]
    let unit: String
    let theme: LiquidGlassTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(title, isOn: $enabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .pointingHandOnHover()
                Spacer()
                Text("\(value) \(unit)")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(enabled ? .cyan : theme.secondaryText)
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
                    Capsule()
                        .fill(theme.gaugeTrack)
                        .frame(width: usableWidth, height: 4)
                        .position(x: trackInset + usableWidth / 2, y: 11)

                    if enabled && selectedIdx > 0 {
                        Capsule()
                            .fill(Color.cyan)
                            .frame(width: usableWidth * activeRatio, height: 4)
                            .position(x: trackInset + (usableWidth * activeRatio) / 2, y: 11)
                    }

                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        let ratio = CGFloat(idx) / CGFloat(max(1, count - 1))
                        let xPos = trackInset + usableWidth * ratio
                        let isCurrent = (idx == selectedIdx)

                        Circle()
                            .fill(
                                !enabled ? theme.secondaryText.opacity(0.25) :
                                (idx <= selectedIdx ? Color.cyan : theme.secondaryText.opacity(0.4))
                            )
                            .frame(width: 4, height: 4)
                            .position(x: xPos, y: 11)

                        Text("\(opt)\(unit)")
                            .font(.system(size: 10.5, weight: isCurrent && enabled ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(
                                !enabled ? theme.secondaryText.opacity(0.35) :
                                (isCurrent ? .cyan : theme.secondaryText)
                            )
                            .fixedSize()
                            .position(x: xPos, y: 28)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if enabled {
                                    withAnimation(.spring(duration: 0.2)) {
                                        value = opt
                                    }
                                }
                            }
                            .pointingHandOnHover()
                    }

                    Circle()
                        .fill(enabled ? Color.white : Color.gray.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .shadow(color: Color.black.opacity(0.22), radius: 2, x: 0, y: 1)
                        .overlay(
                            Circle()
                                .stroke(enabled ? Color.cyan : Color.secondary.opacity(0.4), lineWidth: 2)
                        )
                        .position(x: thumbX, y: 11)
                        .pointingHandOnHover()
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
                                        value = targetVal
                                    }
                                }
                        )
                }
            }
            .frame(height: 38)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.pillFill))
    }
}

// MARK: - Section 4: Feature & Display Toggles (功能与选项设置)

private struct CustomizationTogglesSection: View {
    @Bindable var toggles: FeatureToggleManager
    let theme: LiquidGlassTheme
    @Bindable var permissions = SystemPermissionManager.shared

    var body: some View {
        VStack(spacing: 16) {
            // 系统权限状态检测
            permissionCheckGroup

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
                permissionRow(
                    icon: "internaldrive.fill",
                    iconColor: .cyan,
                    title: "完全磁盘访问权限 (Full Disk Access)",
                    description: "智能清理与应用管理深度扫描系统日志、用户缓存与残留垃圾时必需",
                    status: permissions.fullDiskAccessStatus,
                    actionTitle: permissions.fullDiskAccessStatus.isAuthorized ? "已授权" : "前往系统设置授权",
                    action: {
                        permissions.openFullDiskAccessSettings()
                    }
                )

                Divider().overlay(theme.dividerColor.opacity(0.5))

                permissionRow(
                    icon: "bell.badge.fill",
                    iconColor: .orange,
                    title: "桌面通知权限 (Notifications)",
                    description: "UPS 断电告警、低电量关机倒计时与垃圾清理完毕时发送即时横幅提醒",
                    status: permissions.notificationStatus,
                    actionTitle: permissions.notificationStatus.isAuthorized ? "已授权" : "请求系统授权",
                    action: {
                        if permissions.notificationStatus == .notDetermined {
                            permissions.requestNotificationPermission()
                        } else {
                            permissions.openNotificationSettings()
                        }
                    }
                )

                Divider().overlay(theme.dividerColor.opacity(0.5))

                permissionRow(
                    icon: "externaldrive.badge.checkmark",
                    iconColor: .purple,
                    title: "外置磁盘安全推出权限 (Apple Events)",
                    description: "外置磁盘逃生舱在市电意外断开时向系统发送安全退出指令",
                    status: permissions.automationStatus,
                    actionTitle: permissions.automationStatus.isAuthorized ? "已授权" : (permissions.automationStatus == .notDetermined ? "请求系统授权" : "前往系统设置授权"),
                    action: {
                        permissions.requestAutomationPermission()
                    }
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.pillFill))
        }
        .padding(16)
        .background(cardBackground)
    }

    private func permissionRow(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        status: SystemPermissionManager.PermissionStatus,
        actionTitle: String,
        action: @escaping () -> Void
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
                        .foregroundStyle(status.isAuthorized ? .green : .orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill((status.isAuthorized ? Color.green : Color.orange).opacity(0.15))
                        )
                }

                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(status.isAuthorized ? theme.secondaryText : Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule().fill(status.isAuthorized ? theme.cardBorder.opacity(0.5) : Color.cyan)
                    )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .disabled(status.isAuthorized)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.9)
            )
    }
}

// MARK: - Section 5: Window About Section

private struct WindowAboutSection: View {
    @Environment(\.colorScheme) private var colorScheme
    var engine: PowerSourceEngine
    let theme: LiquidGlassTheme

    var body: some View {
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
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.9)
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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: theme.backdropGradientColors(isAC: state.isAC),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(theme.isLight ? 0.5 : 0.35)
        }
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
            menuRow(icon: "bolt.shield", title: "UPS 设置") {
                navState.isIconMenuPresented = false
                navState.openModal(tab: .ups)
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
