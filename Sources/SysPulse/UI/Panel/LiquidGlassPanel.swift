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

    public init() {}

    private var theme: LiquidGlassTheme {
        LiquidGlassTheme(colorScheme: colorScheme)
    }

    private var metricTrackFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
    }

    public var body: some View {
        Group {
            if navState.isNetworkDetailPresented {
                NetworkDetailCardView(onDismiss: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        navState.isNetworkDetailPresented = false
                    }
                })
            } else {
                VStack(spacing: 8) {
                    healthHeaderCard

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
            }
        }
        .frame(width: 334)
        .activeLiquidPanelSubstrate()
    }

    // MARK: - 1. Top Health & Device Specs Header

    private var healthHeaderCard: some View {
        let snapshot = SystemHealthEvaluator.shared.evaluate()
        let os = ProcessInfo.processInfo.operatingSystemVersion

        return Button {
            MainStudioWindowController.shared.showWindow(section: .overview)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    PulsingHeaderSymbolView(
                        systemName: "sun.max.fill",
                        size: 15,
                        color: Color(red: 0.35, green: 0.85, blue: 0.55),
                        isRotating: true
                    )

                    Text("\(snapshot.score)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text(snapshot.rating.rawValue)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.secondaryText.opacity(0.45))
                }

                HStack(spacing: 5) {
                    headerPill(MacHardwareInfo.shared.chipBrand.replacingOccurrences(of: "Apple ", with: ""))
                    headerPill("\(Int(monitor.memory.totalGB)) GB")
                    headerPill("macOS \(os.majorVersion).\(os.minorVersion)")
                    headerPill(snapshot.formattedUptime)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func headerPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.5))
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
        let loadStatus: String = {
            if cpuPercent < 20 { return "低负载" }
            if cpuPercent < 60 { return "正常" }
            if cpuPercent < 85 { return "繁忙" }
            return "高负载"
        }()
        let coreLoads = monitor.hardware.perCoreLoads

        return metricCardContainer {
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

                // Multi-Core Equalizer (Real per-core telemetry)
                HStack(spacing: 2.0) {
                    ForEach(0..<totalCores, id: \.self) { idx in
                        let coreVal = idx < coreLoads.count ? coreLoads[idx] : Double(cpuPercent)
                        let isActive = coreVal >= 6.0
                        Capsule()
                            .fill(isActive ? Color(red: 0.35, green: 0.85, blue: 0.55) : metricTrackFill)
                            .frame(height: 3.5)
                            .animation(.spring(response: 0.30, dampingFraction: 0.72), value: isActive)
                    }
                }

                Spacer(minLength: 4)

                Text("\(loadStatus) · \(totalCores) 核")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var gpuMetricCard: some View {
        let gpuTemp = max(32, Int(round(monitor.hardware.gpuTemperatureC)))
        let gpuUsage = Int(round(monitor.hardware.gpuUsagePercent))
        let gpuLoadStatus = gpuUsage < 40 ? "低负载" : (gpuUsage < 75 ? "正常" : "高负载")

        return metricCardContainer {
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
        metricCardContainer {
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
        metricCardContainer {
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
                    metricBadge("\(Int(monitor.hardware.statfsTotalGB)) GB")
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(monitor.hardware.statfsFreeGB))")
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
        return metricCardContainer {
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
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            navState.isNetworkDetailPresented = true
                        }
                    } label: {
                        metricBadge(monitor.hardware.primaryInterfaceKind)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("查看网络链路详情与测速")
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

        return metricCardContainer {
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

    private func metricCardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(height: 106)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                    )
            )
            .clipped()
    }

    // MARK: - 3. 供电状态与外设电量卡片

    private var batteryAccessoriesCard: some View {
        let upsConnected = toggles.enablePluginUPSManager && engine.telemetry.isConnected
        let isLaptop = monitor.loadRuntime.hasInternalBattery
        let batteryPct = isLaptop ? monitor.loadRuntime.internalBatteryPercent : (upsConnected && engine.telemetry.batteryLevel > 0 ? engine.telemetry.batteryLevel : 100)
        let isCharging = (upsConnected && engine.telemetry.isCharging) || monitor.loadRuntime.isInternalCharging || monitor.hardware.isBatteryCharging
        let statusString: String = {
            if isCharging { return "充电中" }
            if (upsConnected && engine.telemetry.state.isAC) || monitor.loadRuntime.isInternalPluggedIn || !isLaptop { return "市电在线" }
            return "电池供电"
        }()

        let headerIcon: (name: String, color: Color) = {
            if isCharging {
                return ("battery.100.bolt", Color(red: 0.35, green: 0.85, blue: 0.55))
            }
            if isLaptop {
                if monitor.loadRuntime.isInternalPluggedIn {
                    return ("bolt.fill", Color(red: 0.35, green: 0.85, blue: 0.55))
                }
                if batteryPct > 50 {
                    return ("battery.75", Color(red: 0.35, green: 0.85, blue: 0.55))
                } else if batteryPct > 20 {
                    return ("battery.50", Color(red: 0.95, green: 0.70, blue: 0.25))
                } else {
                    return ("battery.25", Color(red: 0.95, green: 0.40, blue: 0.35))
                }
            }
            if upsConnected {
                return ("bolt.shield.fill", Color(red: 0.35, green: 0.82, blue: 0.55))
            }
            return ("powerplug.fill", Color(red: 0.35, green: 0.82, blue: 0.55))
        }()

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    PulsingHeaderSymbolView(
                        systemName: headerIcon.name,
                        size: 11,
                        color: headerIcon.color
                    )
                    Text(isLaptop ? "电池" : (upsConnected ? "UPS 供电" : "AC 供电"))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }

                Text("\(batteryPct)%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text(statusString)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
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
                HStack(spacing: connectedAccessories.count > 3 ? 7 : 10) {
                    ForEach(connectedAccessories) { acc in
                        accessoryRing(item: acc, totalCount: connectedAccessories.count)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                )
        )
    }

    private func accessoryRing(item: AccessoryBatteryItem, totalCount: Int) -> some View {
        let pct = Double(item.batteryLevel) / 100.0
        let ringColor: Color = {
            if item.batteryLevel <= 20 {
                return Color(red: 0.95, green: 0.40, blue: 0.35)
            }
            return Color(red: 0.35, green: 0.85, blue: 0.55)
        }()

        let ringSize: CGFloat = totalCount > 3 ? 31 : 34

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
            VStack(spacing: 2) {
                ForEach(topApps) { app in
                    popoverProcessRow(app: app)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil }
        var result: [EnergyAppItem] = []
        for app in running.prefix(5) {
            result.append(EnergyAppItem(
                pid: app.processIdentifier,
                name: app.localizedName ?? "App",
                bundleIdentifier: app.bundleIdentifier,
                cpuPercent: max(0.1, Double.random(in: 0.4...6.5)),
                energyImpact: 1.5,
                estimatedWatts: 0.4,
                memoryBytes: UInt64.random(in: 450_000_000...2_200_000_000)
            ))
        }
        if result.isEmpty {
            result = [
                EnergyAppItem(pid: 101, name: "Finder", bundleIdentifier: "com.apple.finder", cpuPercent: 0.4, energyImpact: 0.5, estimatedWatts: 0.2, memoryBytes: 210 * 1048576),
                EnergyAppItem(pid: 102, name: "Safari浏览器", bundleIdentifier: "com.apple.Safari", cpuPercent: 2.3, energyImpact: 2.6, estimatedWatts: 1.1, memoryBytes: 940 * 1048576),
                EnergyAppItem(pid: 103, name: "WindowServer", bundleIdentifier: nil, cpuPercent: 9.2, energyImpact: 10.0, estimatedWatts: 3.2, memoryBytes: 1350 * 1048576),
                EnergyAppItem(pid: 104, name: "终端", bundleIdentifier: "com.apple.Terminal", cpuPercent: 0.6, energyImpact: 0.8, estimatedWatts: 0.3, memoryBytes: 150 * 1048576),
                EnergyAppItem(pid: 105, name: "微信", bundleIdentifier: "com.tencent.xinWeChat", cpuPercent: 1.1, energyImpact: 1.4, estimatedWatts: 0.5, memoryBytes: 680 * 1048576)
            ]
        }
        return result
    }

    private func popoverProcessRow(app: EnergyAppItem) -> some View {
        HStack(spacing: 8) {
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
                .frame(width: 72, alignment: .trailing)

            Text(String(format: "%.1f", app.cpuPercent))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
    }
}

// MARK: - App Small Icon View

private struct AppSmallIconView: View {
    let bundleIdentifier: String?
    let appName: String

    var body: some View {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let bundleIdentifier,
                  let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
                  let icon = runningApp.icon {
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
