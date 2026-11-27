import SwiftUI
import AppKit

public enum PanelScreen: Equatable, Sendable {
    case dashboard
    case upsSettings
    case about
}

public enum PopoverTab: String, CaseIterable, Identifiable, Sendable {
    case system = "系统功能"
    case cleaner = "智能清理"

    public var id: String { rawValue }
}

@Observable
@MainActor
public final class PanelCoordinator: NSObject {
    public static let shared = PanelCoordinator()
    public var activeScreen: PanelScreen = .dashboard
    public var selectedTab: PopoverTab = .system
    public var isEventsExpanded: Bool = false

    public var hoveredMenuBarCardID: String? = nil
    public var activeMenuBarPopover: String? = nil {
        didSet {
            if activeMenuBarPopover == nil && activeMenuBarProcessPID == nil {
                popoverDismissWorkItem?.cancel()
                popoverDismissWorkItem = nil
                isMenuBarPopoverContentHovered = false
            }
        }
    }
    public var hoveredMenuBarProcessPID: Int32? = nil
    public var activeMenuBarProcessPID: Int32? = nil {
        didSet {
            if activeMenuBarProcessPID == nil {
                menuBarProcessInspectorVM = nil
                if activeMenuBarPopover == nil {
                    popoverDismissWorkItem?.cancel()
                    popoverDismissWorkItem = nil
                    isMenuBarPopoverContentHovered = false
                }
            }
        }
    }
    public var menuBarProcessInspectorVM: ProcessInspectorViewModel? = nil
    public var isMenuBarPopoverContentHovered: Bool = false
    public var menuBarCardFrames: [String: CGRect] = [:]
    public var menuBarDashboardSize: CGSize = CGSize(width: 334, height: 792)
    public weak var activeInPanelOverlayNSView: NSView? = nil
    private var popoverDismissWorkItem: DispatchWorkItem? = nil

    public var hasActiveMenuBarSubPopover: Bool {
        activeMenuBarPopover != nil || activeMenuBarProcessPID != nil
    }

    public func updateMenuBarCardFrame(id: String, rect: CGRect) {
        if menuBarCardFrames[id] != rect {
            menuBarCardFrames[id] = rect
        }
    }

    public func isMouseInsideInPanelOverlay() -> Bool {
        guard activeMenuBarPopover != nil,
              let view = activeInPanelOverlayNSView,
              let win = view.window,
              win.isVisible else {
            return false
        }
        let ptInWin = win.mouseLocationOutsideOfEventStream
        let ptInView = view.convert(ptInWin, from: nil)
        return view.bounds.contains(ptInView)
    }

    public func processPopoverBinding(for pid: Int32) -> Binding<Bool> {
        Binding(
            get: { self.activeMenuBarProcessPID == pid && self.menuBarProcessInspectorVM?.app.pid == pid },
            set: { isPresented in
                if isPresented {
                    self.activeMenuBarPopover = nil
                    self.activeMenuBarProcessPID = pid
                } else if self.activeMenuBarProcessPID == pid {
                    self.activeMenuBarProcessPID = nil
                }
            }
        )
    }

    public func toggleCardPopover(_ id: String) {
        activeMenuBarProcessPID = nil
        activeMenuBarPopover = (activeMenuBarPopover == id) ? nil : id
    }

    public func toggleProcessPopover(for app: EnergyAppItem) {
        activeMenuBarPopover = nil
        if activeMenuBarProcessPID == app.pid {
            activeMenuBarProcessPID = nil
        } else {
            menuBarProcessInspectorVM = ProcessInspectorViewModel(app: app)
            activeMenuBarProcessPID = app.pid
        }
    }

    public func handleMenuBarCardHover(id: String, hovering: Bool) {
        popoverDismissWorkItem?.cancel()
        popoverDismissWorkItem = nil

        if hovering {
            if isMouseInsideInPanelOverlay() {
                return
            }
            hoveredMenuBarCardID = id
            if activeMenuBarProcessPID != nil {
                activeMenuBarProcessPID = nil
            }
            if let active = activeMenuBarPopover, active != id {
                activeMenuBarPopover = nil
            }
        } else {
            if hoveredMenuBarCardID == id {
                hoveredMenuBarCardID = nil
            }
            if activeMenuBarPopover == id {
                scheduleMenuBarPopoverAutoDismiss(expectedCardID: id, expectedProcessPID: nil)
            }
        }
    }

    public func handleMenuBarProcessRowHover(pid: Int32, hovering: Bool) {
        popoverDismissWorkItem?.cancel()
        popoverDismissWorkItem = nil

        if hovering {
            if isMouseInsideInPanelOverlay() {
                return
            }
            hoveredMenuBarProcessPID = pid
            if activeMenuBarPopover != nil {
                activeMenuBarPopover = nil
            }
            if let activePID = activeMenuBarProcessPID, activePID != pid {
                activeMenuBarProcessPID = nil
            }
        } else {
            if hoveredMenuBarProcessPID == pid {
                hoveredMenuBarProcessPID = nil
            }
            if activeMenuBarProcessPID == pid {
                scheduleMenuBarPopoverAutoDismiss(expectedCardID: nil, expectedProcessPID: pid)
            }
        }
    }

    public func handleMenuBarPopoverContentHover(_ hovering: Bool) {
        isMenuBarPopoverContentHovered = hovering
        popoverDismissWorkItem?.cancel()
        popoverDismissWorkItem = nil
        if !hovering {
            if let activeCard = activeMenuBarPopover {
                scheduleMenuBarPopoverAutoDismiss(expectedCardID: activeCard, expectedProcessPID: nil)
            } else if let activePID = activeMenuBarProcessPID {
                scheduleMenuBarPopoverAutoDismiss(expectedCardID: nil, expectedProcessPID: activePID)
            }
        }
    }

    private func scheduleMenuBarPopoverAutoDismiss(expectedCardID: String?, expectedProcessPID: Int32?) {
        popoverDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isMenuBarPopoverContentHovered else { return }
                if let expectedCardID,
                   !self.isMouseInsideInPanelOverlay(),
                   self.activeMenuBarPopover == expectedCardID,
                   self.hoveredMenuBarCardID != expectedCardID {
                    self.activeMenuBarPopover = nil
                }
                if let expectedProcessPID,
                   self.activeMenuBarProcessPID == expectedProcessPID,
                   self.hoveredMenuBarProcessPID != expectedProcessPID {
                    self.activeMenuBarProcessPID = nil
                }
            }
        }
        popoverDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    public func resetTransientInteractions() {
        popoverDismissWorkItem?.cancel()
        popoverDismissWorkItem = nil
        isMenuBarPopoverContentHovered = false
        hoveredMenuBarCardID = nil
        activeMenuBarPopover = nil
        hoveredMenuBarProcessPID = nil
        activeMenuBarProcessPID = nil
        menuBarProcessInspectorVM = nil
        activeInPanelOverlayNSView = nil
    }
}

public struct LiquidGlassPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var engine = PowerSourceEngine.shared
    @Bindable var guardian = DiskGuardian.shared
    @Bindable var monitor = SystemResourceMonitor.shared
    @Bindable var fan = FanController.shared
    @Bindable var accessories = AccessoryBatteryManager.shared
    @Bindable var navState = StudioWindowNavigationState.shared
    @Bindable var keepAwake = KeepAwakeController.shared
    @Bindable var toggles = FeatureToggleManager.shared
    @Bindable var updateManager = AppUpdateManager.shared
    @Bindable var coordinator = PanelCoordinator.shared

    public init() {}

    private var theme: LiquidGlassTheme {
        LiquidGlassTheme(colorScheme: colorScheme)
    }

    private var metricTrackFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
    }

    public var body: some View {
        dashboardContentView
            .opacity(navState.isNetworkDetailPresented ? 0 : 1)
            .allowsHitTesting(!navState.isNetworkDetailPresented)
            .accessibilityHidden(navState.isNetworkDetailPresented)
            .overlay {
                if navState.isNetworkDetailPresented {
                    NetworkDetailCardView(onDismiss: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            navState.isNetworkDetailPresented = false
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: 334)
            .activeLiquidPanelSubstrate()
    }

    private var dashboardContentView: some View {
        VStack(spacing: 8) {
            healthHeaderCard

            if updateManager.shouldShowMenuBarUpdateBanner, let release = updateManager.availableRelease {
                updateAvailableBanner(release: release)
            }

            metricsGridSection

            batteryAccessoriesCard

            highUsageProcessesCard

            quickActionsBar

            Divider()
                .overlay(theme.dividerColor.opacity(0.35))
                .padding(.top, 2)

            openSysPulseFooterButton
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            if coordinator.activeMenuBarPopover != nil {
                coordinator.activeMenuBarPopover = nil
            }
        }
        .coordinateSpace(name: "MenuBarDashboardSpace")
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            if coordinator.menuBarDashboardSize != size {
                coordinator.menuBarDashboardSize = size
            }
        }
        .overlay(alignment: .topLeading) {
            if !navState.isNetworkDetailPresented,
               let activeID = coordinator.activeMenuBarPopover,
               let cardRect = coordinator.menuBarCardFrames[activeID] {
                menuBarCardOverlayView(for: activeID, cardRect: cardRect)
                    .id(activeID)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: coordinator.activeMenuBarPopover)
    }

    @ViewBuilder
    private func menuBarCardOverlayView(for cardID: String, cardRect: CGRect) -> some View {
        let isAnchoredAbove = (cardID == "power")
        let glassShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let container = MenuBarInPanelOverlayContainer(
            glassShape: glassShape,
            isAnchoredAbove: isAnchoredAbove,
            theme: theme
        ) {
            menuBarCardOverlayContent(for: cardID)
        }

        if isAnchoredAbove {
            let bottomOffset = max(12, coordinator.menuBarDashboardSize.height - cardRect.minY + 6)
            container
                .padding(.leading, 12)
                .padding(.bottom, bottomOffset)
                .frame(
                    width: coordinator.menuBarDashboardSize.width,
                    height: coordinator.menuBarDashboardSize.height,
                    alignment: .bottomLeading
                )
        } else {
            let topOffset = max(12, cardRect.maxY + 6)
            container
                .padding(.leading, 12)
                .padding(.top, topOffset)
        }
    }

    @ViewBuilder
    private func menuBarCardOverlayContent(for cardID: String) -> some View {
        switch cardID {
        case "health":
            HealthCardPopoverContent(monitor: monitor, navState: navState, theme: theme)
        case "cpu":
            CPUCardPopoverContent(monitor: monitor, navState: navState, theme: theme)
        case "gpu":
            GPUCardPopoverContent(monitor: monitor, navState: navState, theme: theme)
        case "memory":
            MemoryCardPopoverContent(monitor: monitor, navState: navState, theme: theme)
        case "disk":
            DiskCardPopoverContent(monitor: monitor, navState: navState, theme: theme)
        case "network":
            NetworkCardPopoverContent(detail: NetworkDetailModel.shared, navState: navState, theme: theme)
        case "fan":
            FanCardPopoverContent(monitor: monitor, navState: navState, theme: theme)
        case "power":
            PowerCardPopoverContent(
                monitor: monitor,
                engine: engine,
                toggles: toggles,
                accessories: accessories,
                navState: navState,
                theme: theme
            )
        default:
            EmptyView()
        }
    }

    // MARK: - 1. Top Health & Device Specs Header

    private var healthHeaderCard: some View {
        let snapshot = SystemHealthEvaluator.shared.evaluate()
        let totalCores = max(1, ProcessInfo.processInfo.activeProcessorCount)

        return MenuBarInteractiveCardShell(
            id: "health",
            height: nil,
            hPadding: 11,
            vPadding: 10,
            coordinator: coordinator,
            theme: theme
        ) {
            HStack(alignment: .center, spacing: 11) {
                MenuBarHealthRabbitView(rating: snapshot.rating, size: 72)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(snapshot.score)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.primaryText)

                        Text(snapshot.rating.rawValue)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)

                        Spacer()
                    }

                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            headerPill(MacHardwareInfo.shared.chipBrand.replacingOccurrences(of: "Apple ", with: ""))
                            headerPill("\(totalCores) 核")
                            headerPill("\(Int(monitor.memory.totalGB)) GB")
                        }

                        HStack(spacing: 5) {
                            headerPill(MacHardwareInfo.shared.macOSDisplayString)
                            headerPill(snapshot.formattedUptime)
                        }
                    }
                }
            }
        }
    }

    private func headerPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
            )
    }

    // MARK: - 2. 2x3 Core Metrics Grid

    private var metricsGridSection: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            cpuMetricCard

            gpuMetricCard

            memoryMetricCard

            storageMetricCard

            networkMetricCard

            fanMetricCard
        }
    }

    private var cpuMetricCard: some View {
        let cpuPercent = Int(round(monitor.power.cpuTotalPercent))
        let totalCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let topology = MacHardwareInfo.shared.coreTopology
        let loadStatus: String = {
            if cpuPercent < 20 { return "低负载" }
            if cpuPercent < 60 { return "正常" }
            if cpuPercent < 85 { return "繁忙" }
            return "高负载"
        }()
        let coreLoads = monitor.hardware.perCoreLoads

        return metricCardContainer(id: "cpu") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.55))
                        Text("CPU")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                    metricBadge("\(Int(round(monitor.hardware.cpuTemperatureC)))°C")
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(cpuPercent)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                // Multi-Core Equalizer (Real per-core telemetry with dual-tier cluster tinting)
                HStack(spacing: totalCores >= 16 ? 1.5 : 2.0) {
                    ForEach(0..<totalCores, id: \.self) { idx in
                        let coreVal = idx < coreLoads.count ? coreLoads[idx] : Double(cpuPercent)
                        let isActive = coreVal >= 6.0
                        let isPrimaryTier = topology.isPrimaryTierCore(at: idx, coreCount: totalCores)
                        let activeTint = isPrimaryTier
                            ? Color(red: 0.25, green: 0.72, blue: 0.98)
                            : Color(red: 0.35, green: 0.85, blue: 0.55)
                        let inactiveTint = topology.hasDualTier
                            ? (isPrimaryTier ? Color(red: 0.25, green: 0.72, blue: 0.98).opacity(0.18) : Color(red: 0.35, green: 0.85, blue: 0.55).opacity(0.18))
                            : metricTrackFill
                        Capsule()
                            .fill(isActive ? activeTint : inactiveTint)
                            .frame(height: 3.5)
                            .transaction { $0.animation = nil }
                    }
                }
                .help(topology.legendText)

                Spacer(minLength: 4)

                Text(topology.hasDualTier ? "\(loadStatus) · \(topology.legendText)" : "\(loadStatus) · \(totalCores) 核")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private func updateAvailableBanner(release: GitHubReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cyan)

            VStack(alignment: .leading, spacing: 1) {
                Text("发现新版本 v\(release.version)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text("点击立即查看更新说明并升级")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                updateManager.openUpdateModalFromBanner()
            } label: {
                Text("更新")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.cyan))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()

            Button {
                updateManager.dismissCurrentUpdateBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                    .padding(4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("忽略此版本横幅提醒")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color.cyan.opacity(0.14) : Color.cyan.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.32), lineWidth: 0.8)
                )
        )
    }

    private var gpuMetricCard: some View {
        let gpuTemp = max(32, Int(round(monitor.hardware.gpuTemperatureC)))
        let gpuUsage = Int(round(monitor.hardware.gpuUsagePercent))
        let gpuLoadStatus = gpuUsage < 40 ? "低负载" : (gpuUsage < 75 ? "正常" : "高负载")

        return metricCardContainer(id: "gpu") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "display")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.orange)
                        Text("GPU")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                    metricBadge("\(gpuTemp)°C")
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(gpuUsage)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                GeometryReader { geo in
                    let pct = CGFloat(max(0.02, min(1.0, monitor.hardware.gpuUsagePercent / 100.0)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(metricTrackFill)
                            .frame(height: 3.5)
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: max(4, geo.size.width * pct), height: 3.5)
                    }
                }
                .frame(height: 3.5)

                Spacer(minLength: 4)

                Text("\(gpuLoadStatus) · \(String(format: "%.1f", monitor.hardware.gpuWatts))W")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var memoryMetricCard: some View {
        metricCardContainer(id: "memory") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.95, green: 0.70, blue: 0.25))
                        Text("内存")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                    metricBadge("压力\(monitor.memory.pressureLabel)")
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(monitor.memory.usedPercent)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                GeometryReader { geo in
                    let ratio = CGFloat(max(0.02, min(1.0, Double(monitor.memory.usedPercent) / 100.0)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(metricTrackFill)
                            .frame(height: 3.5)
                        Capsule()
                            .fill(Color(red: 0.95, green: 0.70, blue: 0.25))
                            .frame(width: max(4, geo.size.width * ratio), height: 3.5)
                    }
                }
                .frame(height: 3.5)

                Spacer(minLength: 4)

                Text("\(String(format: "%.1f", monitor.memory.usedGB)) GB / \(Int(monitor.memory.totalGB)) GB")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var storageMetricCard: some View {
        metricCardContainer(id: "disk") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.cyan)
                        Text("可用空间")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                    metricBadge("\(Int(round(monitor.hardware.statfsTotalGB))) GB")
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(round(monitor.hardware.statfsFreeGB)))")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("GB")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                GeometryReader { geo in
                    let usedRatio = CGFloat(max(0.02, min(1.0, Double(monitor.hardware.statfsUsedPercent) / 100.0)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(metricTrackFill)
                            .frame(height: 3.5)
                        Capsule()
                            .fill(Color.cyan)
                            .frame(width: max(4, geo.size.width * usedRatio), height: 3.5)
                    }
                }
                .frame(height: 3.5)

                Spacer(minLength: 4)

                Text("已用 \(Int(monitor.hardware.statfsUsedGB)) GB · \(monitor.hardware.statfsUsedPercent)%")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var networkMetricCard: some View {
        let parts = monitor.hardware.downloadSpeedParts
        return metricCardContainer(id: "network") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "network")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.cyan)
                        Text("网络")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                    metricBadge(monitor.hardware.primaryInterfaceKind)
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(parts.value)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text(parts.unit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                DualSparklineView(
                    downloadHistory: monitor.hardware.networkHistoryDownload,
                    uploadHistory: monitor.hardware.networkHistoryUpload,
                    color: Color.cyan
                )
                .frame(height: 12)

                Spacer(minLength: 4)

                Text("上传 \(monitor.hardware.formattedUploadSpeed)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var fanMetricCard: some View {
        let rpm = fan.currentRPM
        let pct = rpm <= 0 ? 0 : min(100, max(1, Int(round(Double(rpm) / Double(max(1, fan.maxRPM)) * 100.0))))

        return metricCardContainer(id: "fan") {
            if fan.isFanSupported {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HStack(spacing: 4) {
                            SpinningFanIconView(rpm: rpm, size: 10.5, color: Color.orange)
                            Text("风扇")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                        }
                        Spacer()
                        metricBadge("转速 \(pct)%")
                    }

                    Spacer(minLength: 2)

                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(rpm)")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("RPM")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer(minLength: 2)

                    Text(fan.statusText)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // 风扇控制模式切换按钮
                    HStack(spacing: 4) {
                        fanModeButton(.auto)
                        fanModeButton(.cool)
                        fanModeButton(.maxCool)
                    }
                }
            } else {
                let tier = fan.passiveThermalTier
                let accent = fan.passiveThermalAccentColor
                let tempC = Int(round(monitor.hardware.cpuTemperatureC))

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HStack(spacing: 4) {
                            PulsingHeaderSymbolView(
                                systemName: "snowflake",
                                size: 10.5,
                                color: accent,
                                isRotating: false
                            )
                            Text("静音散热")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                        }
                        Spacer()
                        metricBadge("0 dB")
                    }

                    Spacer(minLength: 2)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(tier.rawValue)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("均热 \(tempC)°C")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer(minLength: 2)

                    Text("无风扇架构 · 零噪音导热")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        ForEach(PassiveThermalTier.allCases) { item in
                            let isCurrent = (item == tier)
                            Text(item.rawValue)
                                .font(.system(size: 9.5, weight: isCurrent ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isCurrent ? theme.primaryText : theme.secondaryText.opacity(0.75))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3.5)
                                .background(
                                    Capsule().fill(
                                        isCurrent
                                            ? accent.opacity(colorScheme == .dark ? 0.24 : 0.16)
                                            : (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(isCurrent ? accent.opacity(0.45) : Color.clear, lineWidth: 0.6)
                                )
                        }
                    }
                }
            }
        }
    }

    private func fanModeButton(_ mode: FanMode) -> some View {
        let isSelected = (fan.activeMode == mode)
        let fgColor = isSelected ? theme.primaryText : theme.secondaryText.opacity(0.85)
        let fillColor = isSelected
            ? (colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.14))
            : (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
        let strokeColor = isSelected
            ? (colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.18))
            : Color.clear
        let fontWeight: Font.Weight = isSelected ? .bold : .medium

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                fan.setMode(mode)
            }
        } label: {
            Text(mode.rawValue)
                .font(.system(size: 9.5, weight: fontWeight, design: .rounded))
                .foregroundStyle(fgColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(fillColor)
                )
                .overlay(
                    Capsule().strokeBorder(strokeColor, lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func metricBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.5))
            )
    }

    private func metricCardContainer<Content: View>(id: String, @ViewBuilder content: () -> Content) -> some View {
        MenuBarInteractiveCardShell(
            id: id,
            height: 106,
            hPadding: 10,
            vPadding: 8,
            coordinator: coordinator,
            theme: theme
        ) {
            content()
        }
    }

    // MARK: - 3. 供电状态与外设电量卡片

    private var batteryAccessoriesCard: some View {
        let presentation = PowerCardPresentation.resolve(
            upsEnabled: toggles.enablePluginUPSManager,
            upsTelemetry: engine.telemetry,
            loadRuntime: monitor.loadRuntime,
            hardwareBatteryCharging: monitor.hardware.isBatteryCharging,
            isMacBookDemoMode: toggles.enableMacBookDemoMode
        )

        return MenuBarInteractiveCardShell(
            id: "power",
            height: nil,
            hPadding: 12,
            vPadding: 9,
            coordinator: coordinator,
            theme: theme
        ) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        PulsingHeaderSymbolView(
                            systemName: presentation.iconName,
                            size: 11,
                            color: presentation.iconColor
                        )
                        Text(presentation.title)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }

                    Text("\(presentation.percent)%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text(presentation.statusText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(presentation.isOnBattery ? Color.orange : theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                let connectedAccessories = accessories.accessories.filter { $0.isConnected }
                if connectedAccessories.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText.opacity(0.6))
                        Text("未连接外设")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.secondaryText.opacity(0.7))
                    }
                    .padding(.trailing, 4)
                } else {
                    HStack(spacing: connectedAccessories.count >= 5 ? 5 : (connectedAccessories.count > 3 ? 7 : 10)) {
                        ForEach(connectedAccessories) { acc in
                            accessoryRing(item: acc, totalCount: connectedAccessories.count)
                        }
                    }
                }
            }
        }
    }

    private func accessoryRing(item: AccessoryBatteryItem, totalCount: Int) -> some View {
        let pct = Double(item.batteryLevel) / 100.0
        let ringColor: Color = {
            if item.batteryLevel <= 20 {
                return Color(red: 0.95, green: 0.40, blue: 0.35)
            }
            return Color(red: 0.35, green: 0.85, blue: 0.55)
        }()

        let ringSize: CGFloat = totalCount >= 5 ? 27 : (totalCount > 3 ? 31 : 34)

        return ZStack {
            Circle()
                .stroke(metricTrackFill, lineWidth: 3.5)

            Circle()
                .trim(from: 0.0, to: max(0.04, pct))
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // 外设 SF Symbol 图标
            NativePeripheralSymbolView(
                symbolName: item.iconName,
                pointSize: ringSize > 32 ? 11.5 : 10.5
            )
            .foregroundStyle(theme.primaryText.opacity(0.88))
        }
        .frame(width: ringSize, height: ringSize)
        .help(item.detailText)
    }

    // MARK: - 快捷操作栏

    private var quickActionsBar: some View {
        HStack(spacing: 8) {
            // Keep Awake Quick Action
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    keepAwake.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(keepAwake.isActive ? Color.orange : Color(red: 0.95, green: 0.70, blue: 0.25))
                    Text(keepAwake.isActive ? keepAwake.remainingFormattedText : "保持常亮")
                        .font(.system(size: 10.5, weight: keepAwake.isActive ? .bold : .medium, design: .rounded))
                        .foregroundStyle(keepAwake.isActive ? theme.primaryText : theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(keepAwake.isActive ? (colorScheme == .dark ? Color.orange.opacity(0.18) : Color.orange.opacity(0.12)) : theme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(keepAwake.isActive ? Color.orange.opacity(0.35) : theme.cardBorder, lineWidth: 0.8)
                        )
                )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help(keepAwake.isActive ? "点击停止常亮 (\(keepAwake.currentBehavior.rawValue))" : "点击开启屏幕常亮")

            // Network Detail & Speed Test Quick Action
            Button {
                coordinator.resetTransientInteractions()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    navState.isNetworkDetailPresented = true
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                    Text("网络测速")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                        )
                )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("查看网络链路详情与运行测速")
        }
    }

    // MARK: - 4. 高占用进程排行卡片

    private var highUsageProcessesCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("高占用进程")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                Text("内存")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 72, alignment: .trailing)

                Text("% CPU")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()
                .overlay(theme.dividerColor.opacity(0.4))

            let topApps = monitor.topEnergyApps.isEmpty ? defaultFallbackTopApps() : Array(monitor.topEnergyApps.prefix(5))
            if topApps.isEmpty {
                HStack(spacing: 6) {
                    Spacer()
                    Text("正在采集进程资源占用…")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                    Spacer()
                }
                .frame(height: 120)
            } else {
                VStack(spacing: 2) {
                    ForEach(topApps) { app in
                        popoverProcessRow(app: app)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                )
        )
    }

    // MARK: - 5. 底部导航栏

    private var openSysPulseFooterButton: some View {
        Button {
            MenuBarController.shared?.closePopover(deactivateApp: false)
            MainStudioWindowController.shared.showWindow(section: .overview)
        } label: {
            HStack {
                Spacer()
                Text("进入 SysPulse")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help("打开 SysPulse 智能管家主控制台")
    }

    private func defaultFallbackTopApps() -> [EnergyAppItem] {
        return []
    }

    private func loadIndicatorColor(for app: EnergyAppItem) -> Color {
        if app.cpuPercent >= 80.0 || app.energyImpactScore >= 50.0 {
            return Color(red: 0.94, green: 0.36, blue: 0.34)
        }
        if app.cpuPercent >= 25.0 || app.energyImpactScore >= 20.0 {
            return Color(red: 0.92, green: 0.65, blue: 0.32)
        }
        return theme.gaugeTrack
    }

    private func popoverProcessRow(app: EnergyAppItem) -> some View {
        let isHovered = (coordinator.hoveredMenuBarProcessPID == app.pid)
        let isActive = (coordinator.activeMenuBarProcessPID == app.pid)
        let isHighlighted = isHovered || isActive
        let rowShape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let indicatorColor = loadIndicatorColor(for: app)
        let fillColor: Color = isHighlighted
            ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
            : Color.clear
        let strokeColor: Color = {
            if isActive {
                return colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.14)
            }
            if isHovered {
                return colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)
            }
            return Color.clear
        }()
        let cpuText = String(format: "%.1f", app.cpuPercent)

        let rowContent = HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(indicatorColor)
                .frame(width: 3, height: 14)

            AppSmallIconView(bundleIdentifier: app.bundleIdentifier, appName: app.name)
                .frame(width: 17, height: 17)

            Text(app.name)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            Spacer()

            Text(app.formattedMemory)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 68, alignment: .trailing)

            Text(cpuText)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            rowShape
                .fill(fillColor)
                .overlay(rowShape.strokeBorder(strokeColor, lineWidth: 0.6))
        )
        .contentShape(rowShape)

        return rowContent
            .pointingHandOnHover()
            .alwaysActiveOnHover { hovering in
                coordinator.handleMenuBarProcessRowHover(pid: app.pid, hovering: hovering)
            }
            .onTapGesture {
                coordinator.toggleProcessPopover(for: app)
            }
            .popover(isPresented: coordinator.processPopoverBinding(for: app.pid), arrowEdge: .leading) {
                popoverProcessDetailView(for: app.pid)
            }
    }

    @ViewBuilder
    private func popoverProcessDetailView(for pid: Int32) -> some View {
        if let vm = coordinator.menuBarProcessInspectorVM, vm.app.pid == pid {
            MenuBarProcessPopoverContent(
                vm: vm,
                navState: navState,
                theme: theme,
                onClose: {
                    coordinator.activeMenuBarProcessPID = nil
                }
            )
        }
    }
}

private struct MenuBarInteractiveCardShell<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let id: String
    let height: CGFloat?
    let hPadding: CGFloat
    let vPadding: CGFloat
    @Bindable var coordinator: PanelCoordinator
    let theme: LiquidGlassTheme
    let content: Content

    init(
        id: String,
        height: CGFloat? = nil,
        hPadding: CGFloat = 10,
        vPadding: CGFloat = 8,
        coordinator: PanelCoordinator,
        theme: LiquidGlassTheme,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.height = height
        self.hPadding = hPadding
        self.vPadding = vPadding
        self.coordinator = coordinator
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        let isHovered = (coordinator.hoveredMenuBarCardID == id)
        let isActive = (coordinator.activeMenuBarPopover == id)
        let isElevated = isHovered || isActive
        let cardShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let borderColor: Color = isActive
            ? (colorScheme == .dark ? Color.white.opacity(0.34) : Color.black.opacity(0.22))
            : (isHovered ? theme.studioCardHoverBorder : theme.cardBorder)
        let borderWidth: CGFloat = isActive ? 1.2 : (isHovered ? 1.05 : 0.8)

        content
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .leading)
            .clipped()
            .background(
                cardShape
                    .fill(theme.cardFill)
                    .overlay(
                        cardShape.fill(
                            isActive
                                ? (colorScheme == .dark ? Color.white.opacity(0.05) : Color.cyan.opacity(0.06))
                                : Color.clear
                        )
                    )
                    .overlay(
                        cardShape.strokeBorder(borderColor, lineWidth: borderWidth)
                    )
            )
            .contentShape(cardShape)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("MenuBarDashboardSpace"))
            } action: { rect in
                coordinator.updateMenuBarCardFrame(id: id, rect: rect)
            }
            .offset(y: isElevated ? -1.5 : 0.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isElevated)
            .alwaysActiveOnHover { hovering in
                coordinator.handleMenuBarCardHover(id: id, hovering: hovering)
            }
            .onTapGesture {
                coordinator.toggleCardPopover(id)
            }
            .pointingHandOnHover()
    }
}

private struct MenuBarInPanelOverlayContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let glassShape: RoundedRectangle
    let isAnchoredAbove: Bool
    let theme: LiquidGlassTheme
    let content: Content

    init(
        glassShape: RoundedRectangle,
        isAnchoredAbove: Bool,
        theme: LiquidGlassTheme,
        @ViewBuilder content: () -> Content
    ) {
        self.glassShape = glassShape
        self.isAnchoredAbove = isAnchoredAbove
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        let baseFill: Color = colorScheme == .dark
            ? Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.62)
            : Color.white.opacity(0.68)
        let strokeColor: Color = colorScheme == .dark
            ? Color.white.opacity(0.24)
            : Color.black.opacity(0.12)
        let shadowColor: Color = Color.black.opacity(colorScheme == .dark ? 0.36 : 0.16)

        content
            .frame(width: 310)
            .background(InPanelOverlayBoundsTracker())
            .background(glassShape.fill(baseFill))
            .glassEffect(.regular, in: glassShape)
            .overlay(glassShape.strokeBorder(strokeColor, lineWidth: 0.9))
            .shadow(color: shadowColor, radius: 16, y: 6)
            .contentShape(glassShape)
            .onTapGesture {}
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: isAnchoredAbove ? .bottom : .top)))
    }
}

private struct InPanelOverlayBoundsTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> InPanelOverlayTrackerNSView {
        let view = InPanelOverlayTrackerNSView()
        PanelCoordinator.shared.activeInPanelOverlayNSView = view
        return view
    }

    func updateNSView(_ nsView: InPanelOverlayTrackerNSView, context: Context) {
        PanelCoordinator.shared.activeInPanelOverlayNSView = nsView
    }

    static func dismantleNSView(_ nsView: InPanelOverlayTrackerNSView, coordinator: ()) {
        MainActor.assumeIsolated {
            if PanelCoordinator.shared.activeInPanelOverlayNSView === nsView {
                PanelCoordinator.shared.activeInPanelOverlayNSView = nil
            }
        }
    }
}

private final class InPanelOverlayTrackerNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - App Small Icon View

public final class AppIconLookupCache: @unchecked Sendable {
    public static let shared = AppIconLookupCache()
    private let fileIconCache = NSCache<NSString, NSImage>()
    private let appIconCache = NSCache<NSString, NSImage>()

    private init() {
        fileIconCache.countLimit = 96
        appIconCache.countLimit = 64
    }

    public func icon(forFilePath path: String) -> NSImage {
        let key = path as NSString
        if let cached = fileIconCache.object(forKey: key) {
            return cached
        }
        let raw = NSWorkspace.shared.icon(forFile: path)
        let img = AppIconManager.downsampledUIImage(from: raw, maxPixelSize: 48, exactPixelTarget: true)
        fileIconCache.setObject(img, forKey: key)
        return img
    }

    public func icon(forPID pid: pid_t) -> NSImage {
        let key = "pid:\(pid)" as NSString
        if let cached = appIconCache.object(forKey: key) {
            return cached
        }
        if let running = NSRunningApplication(processIdentifier: pid), let raw = running.icon {
            let img = AppIconManager.downsampledUIImage(from: raw, maxPixelSize: 48, exactPixelTarget: true)
            appIconCache.setObject(img, forKey: key)
            return img
        }
        let fallbackKey = "fallback:app" as NSString
        if let cached = appIconCache.object(forKey: fallbackKey) {
            return cached
        }
        let rawFallback = NSWorkspace.shared.icon(for: .applicationBundle)
        let img = AppIconManager.downsampledUIImage(from: rawFallback, maxPixelSize: 48, exactPixelTarget: true)
        appIconCache.setObject(img, forKey: fallbackKey)
        return img
    }

    public func icon(forBundleIdentifier bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let key = "bid:\(bundleIdentifier)" as NSString
        if let cached = appIconCache.object(forKey: key) {
            return cached
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let raw = NSWorkspace.shared.icon(forFile: url.path)
            let img = AppIconManager.downsampledUIImage(from: raw, maxPixelSize: 48, exactPixelTarget: true)
            appIconCache.setObject(img, forKey: key)
            return img
        }
        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           let raw = runningApp.icon {
            let img = AppIconManager.downsampledUIImage(from: raw, maxPixelSize: 48, exactPixelTarget: true)
            appIconCache.setObject(img, forKey: key)
            return img
        }
        return nil
    }
}

private struct AppSmallIconView: View {
    let bundleIdentifier: String?
    let appName: String

    var body: some View {
        if let icon = AppIconLookupCache.shared.icon(forBundleIdentifier: bundleIdentifier) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary.opacity(0.6))
        }
    }
}

// MARK: - Native macOS Peripheral SF Symbol Loader (Public & Private CoreGlyphs Symbols)

public struct NativePeripheralSymbolView: View {
    public let symbolName: String
    public let pointSize: CGFloat

    public init(symbolName: String, pointSize: CGFloat) {
        self.symbolName = symbolName
        self.pointSize = pointSize
    }

    public var body: some View {
        if let img = Self.loadNativeSymbol(symbolName, pointSize: pointSize, weight: .semibold) {
            Image(nsImage: img)
                .renderingMode(.template)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: pointSize, weight: .semibold))
        }
    }

    public static func loadNativeSymbol(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .semibold
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let configured = img.withSymbolConfiguration(config) ?? img
            configured.isTemplate = true
            return configured
        }
        let sel = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
        if NSImage.responds(to: sel),
           let unmanaged = (NSImage.self as AnyObject).perform(sel, with: name),
           let img = unmanaged.takeUnretainedValue() as? NSImage {
            let configured = img.withSymbolConfiguration(config) ?? img
            configured.isTemplate = true
            return configured
        }
        return nil
    }
}
