import SwiftUI
import AppKit

/// Pure-SwiftUI switch style that retains its configured tint even when the host window loses focus.
private struct AlwaysTintedSwitchToggleStyle: ToggleStyle {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let offTrackColor = colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.16)
        let strokeColor = isOn
            ? Color.white.opacity(0.22)
            : (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10))

        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? tint : offTrackColor)
                    .overlay(
                        Capsule()
                            .strokeBorder(strokeColor, lineWidth: 0.6)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: Color.black.opacity(0.24), radius: 1.5, x: 0, y: 0.5)
                    .padding(2)
            }
            .frame(width: 32, height: 18)
            .contentShape(Capsule())
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isOn)
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}

public struct PluginsDashboardView: View {
    @Bindable var pluginManager = PSPortalPluginManager.shared
    @Bindable var navState = StudioWindowNavigationState.shared
    @Bindable var wifiManager = WiFiLowLatencyManager.shared
    @Bindable var upsManager = SystemUPSSettingsManager.shared
    @Bindable var lanSniffer = LanDeviceSnifferEngine.shared
    @Bindable var metadataManager = LanDeviceMetadataManager.shared
    @Bindable var engine = PowerSourceEngine.shared
    @Bindable var diskGuardian = DiskGuardian.shared
    @Bindable var antigravityManager = AntigravityContextManager.shared
    @Bindable var codexThemeManager = AntigravityCodexThemeManager.shared
    @Bindable var aiCleanerManager = AIToolCleanerManager.shared
    @Bindable var updaterManager = SoftwareUpdaterManager.shared
    @Bindable var accessoryLocationManager = AccessoryLocationPluginManager.shared
    @Bindable var toggles = FeatureToggleManager.shared
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

    private func pluginBinding(for type: PluginModuleType) -> Binding<Bool> {
        Binding(
            get: { toggles.isPluginEnabled(type) },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.18)) {
                    toggles.setPluginEnabled(type, newValue)
                }
            }
        )
    }

    public var body: some View {
        Group {
            if let plugin = pluginManager.activePluginType {
                detailView(for: plugin)
            } else {
                pluginsHomeView
            }
        }
        .frame(width: contentW, height: contentH)
        .padding(.horizontal, 24)
        .padding(.top, 35)
        .padding(.bottom, 24)
        .onAppear {
            DispatchQueue.main.async {
                if toggles.enablePluginARPSniffer {
                    lanSniffer.detectActiveInterfaces()
                    if lanSniffer.discoveredDevices.isEmpty && !lanSniffer.isScanning {
                        lanSniffer.startScan()
                    }
                }
                if toggles.enablePluginPSPortal {
                    pluginManager.detectInterfaces()
                    if pluginManager.discoveredDevices.isEmpty && !pluginManager.isScanningDevices {
                        pluginManager.scanLocalDevices()
                    }
                }
                if toggles.enablePluginAntigravityContext {
                    antigravityManager.checkOnEntry()
                    codexThemeManager.checkOnEntry()
                }
                if toggles.enablePluginAIToolCleaner && aiCleanerManager.lastScanDate == nil && !aiCleanerManager.isScanning {
                    aiCleanerManager.scanAITools()
                }
                if toggles.enablePluginSoftwareUpdater {
                    updaterManager.scanAllIfNeeded()
                }
                if toggles.enablePluginAccessoryLocation {
                    accessoryLocationManager.refreshMFiStatus()
                    accessoryLocationManager.refreshDevices()
                }
            }
        }
        .onChange(of: pluginManager.activePluginType) { _, newPlugin in
            if newPlugin == .antigravityContext && toggles.enablePluginAntigravityContext {
                antigravityManager.checkOnEntry()
                codexThemeManager.checkOnEntry()
            } else if newPlugin == .aiToolCleaner && toggles.enablePluginAIToolCleaner && aiCleanerManager.lastScanDate == nil && !aiCleanerManager.isScanning {
                aiCleanerManager.scanAITools()
            } else if newPlugin == .softwareUpdater && toggles.enablePluginSoftwareUpdater {
                updaterManager.scanAllIfNeeded()
            } else if newPlugin == .accessoryLocation && toggles.enablePluginAccessoryLocation {
                accessoryLocationManager.refreshMFiStatus()
                accessoryLocationManager.refreshDevices()
            }
        }
    }

    // MARK: - 插件中心主视图 (一级多卡片总览)

    private var pluginsHomeView: some View {
        VStack(spacing: 16) {
            // 顶部标题栏
            headerSection
                .frame(width: contentW, height: 52, alignment: .leading)

            // 插件卡片网格（支持拖拽排序）
            let colW = (contentW - 14) / 2
            let rows = max(1, (toggles.pluginModuleOrder.count + 1) / 2)
            let gridH = CGFloat(rows) * 172.0 + CGFloat(max(0, rows - 1)) * 14.0

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    ForEach(PluginModuleType.allCases) { moduleType in
                        let idx = toggles.pluginModuleOrder.firstIndex(of: moduleType) ?? 0
                        let slot = pluginSlotOrigin(index: idx, colW: colW)
                        let isDragging = (navState.draggingPluginCard == moduleType)
                        let isHovered = (navState.hoveredPluginCard == moduleType && navState.draggingPluginCard == nil)
                        let posX = isDragging ? (navState.dragPluginBaseOrigin.x + navState.dragPluginTranslation.width) : slot.x
                        let posY = isDragging ? (navState.dragPluginBaseOrigin.y + navState.dragPluginTranslation.height) : slot.y

                        moduleCard(for: moduleType, colW: colW)
                            .frame(width: colW, height: 172)
                            .offset(x: posX, y: posY)
                            .zIndex(isDragging ? 100 : (isHovered ? 10 : 0))
                    }
                }
                .frame(width: contentW, height: gridH, alignment: .topLeading)
                .coordinateSpace(name: "pluginGrid")
                .padding(.horizontal, 16)
                .padding(.top, 3)
                .padding(.bottom, 1)
            }
            .padding(.horizontal, -16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            navState.draggingPluginCard = nil
            navState.dragPluginTranslation = .zero
        }
    }

    private func pluginSlotOrigin(index: Int, colW: CGFloat) -> CGPoint {
        let row = index / 2
        let col = index % 2
        return CGPoint(
            x: CGFloat(col) * (colW + 14.0),
            y: CGFloat(row) * (172.0 + 14.0)
        )
    }

    @ViewBuilder
    private func moduleCard(for type: PluginModuleType, colW: CGFloat) -> some View {
        let content: AnyView = {
            switch type {
            case .psPortal: return AnyView(psPortalCardContent)
            case .wifiLatency: return AnyView(wifiLatencyCardContent)
            case .arpSniffer: return AnyView(arpSnifferCardContent)
            case .upsManager: return AnyView(upsManagerCardContent)
            case .antigravityContext: return AnyView(antigravityContextCardContent)
            case .aiToolCleaner: return AnyView(aiToolCleanerCardContent)
            case .softwareUpdater: return AnyView(softwareUpdaterCardContent)
            case .accessoryLocation: return AnyView(accessoryLocationCardContent)
            }
        }()
        pluginModuleCardShell(for: type, colW: colW) {
            content
        }
    }

    private var pluginDisabledBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.gray.opacity(0.55))
                .frame(width: 6, height: 6)
            Text("未启用")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05)))
    }

    private func pluginVersionBadge(for type: PluginModuleType, tint: Color, enabled: Bool = true, fontSize: CGFloat = 10) -> some View {
        Text("v\(type.version)")
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(enabled ? tint : theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((enabled ? tint : Color.gray).opacity(0.12)))
            .fixedSize(horizontal: true, vertical: false)
    }

    private func pluginCardToggle(for type: PluginModuleType, tint: Color) -> some View {
        Toggle("", isOn: pluginBinding(for: type))
            .toggleStyle(AlwaysTintedSwitchToggleStyle(tint: tint))
            .labelsHidden()
            .help(toggles.isPluginEnabled(type) ? "点击停用此插件并释放后台资源" : "点击启用此插件")
    }

    private func pluginModuleCardShell<Content: View>(
        for type: PluginModuleType,
        colW: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isHovered = (navState.hoveredPluginCard == type && navState.draggingPluginCard == nil)
        let isDragging = (navState.draggingPluginCard == type)

        return content()
            .padding(16)
            .frame(width: colW, height: 172)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.studioCardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                (isHovered || isDragging) ? theme.studioCardHoverBorder : theme.studioCardBorder,
                                lineWidth: (isHovered || isDragging) ? 1.15 : 0.8
                            )
                    )
            )
            .shadow(
                color: isDragging ? Color.black.opacity(colorScheme == .dark ? 0.36 : 0.16) : Color.clear,
                radius: isDragging ? 18 : 0,
                x: 0,
                y: isDragging ? 10 : 0
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(isDragging ? 1.025 : 1.0)
            .offset(y: (!isDragging && isHovered) ? -2.0 : 0.0)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isHovered)
            .onHover { hovering in
                guard navState.draggingPluginCard == nil else { return }
                if hovering {
                    navState.hoveredPluginCard = type
                } else if navState.hoveredPluginCard == type {
                    navState.hoveredPluginCard = nil
                }
            }
            .onTapGesture {
                guard navState.draggingPluginCard == nil else { return }
                navState.hoveredPluginCard = nil
                withAnimation(.easeInOut(duration: 0.18)) {
                    pluginManager.activePluginType = type
                }
            }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("pluginGrid"))
                    .onChanged { value in
                        if navState.draggingPluginCard == nil {
                            let startIdx = toggles.pluginModuleOrder.firstIndex(of: type) ?? 0
                            navState.hoveredPluginCard = nil
                            navState.dragPluginBaseOrigin = pluginSlotOrigin(index: startIdx, colW: colW)
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                navState.draggingPluginCard = type
                            }
                        }
                        guard navState.draggingPluginCard == type else { return }
                        navState.dragPluginTranslation = value.translation

                        let centerX = navState.dragPluginBaseOrigin.x + value.translation.width + colW * 0.5
                        let centerY = navState.dragPluginBaseOrigin.y + value.translation.height + 86.0
                        let order = toggles.pluginModuleOrder
                        if let currentIdx = order.firstIndex(of: type) {
                            for (candidateIdx, candidateType) in order.enumerated() where candidateIdx != currentIdx {
                                let origin = pluginSlotOrigin(index: candidateIdx, colW: colW)
                                let hitRect = CGRect(x: origin.x, y: origin.y, width: colW, height: 172.0).insetBy(dx: 8, dy: 8)
                                if hitRect.contains(CGPoint(x: centerX, y: centerY)) {
                                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                                        toggles.movePluginModule(from: type, to: candidateType)
                                    }
                                    break
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        guard navState.draggingPluginCard == type else { return }
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
                            navState.draggingPluginCard = nil
                            navState.dragPluginTranslation = .zero
                        }
                    }
            )
            .pointingHandOnHover()
    }

    // MARK: - 卡片 1: PS Portal 串流画质增强

    private var psPortalCardContent: some View {
        let enabled = toggles.enablePluginPSPortal

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .psPortal,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("PS Portal 串流画质增强")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .psPortal, tint: .blue, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                statusBadgeView
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .psPortal, tint: .blue)
                        }
                    }

                    Text("开源项目: atameric/ps5-portal-high-bitrate · 动态协议级串流握手注入")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("无需硬件拆机或越狱。拦截局域网 UDP 9296 握手帧，动态修改 LaunchSpec 目标码率，突破官方限制锁定最高 100M/200M 高清串流。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    HStack(spacing: 6) {
                        Text("目标码率: \(pluginManager.targetBitrate.shortTag)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.blue)
                        Text("·")
                            .foregroundStyle(theme.secondaryText)
                        Text(pluginManager.autoWatchEnabled ? "自动守望" : (pluginManager.relayMode == .oneWayDirect ? "单向直连" : "双向遥测"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(pluginManager.autoWatchEnabled ? statusBadgeColor : theme.secondaryText)
                        Text("·")
                            .foregroundStyle(theme.secondaryText)
                        Text("网卡: \(pluginManager.selectedInterfaceInfo?.compactDisplayName ?? pluginManager.selectedInterface)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    Text("模块未启用 · 零后台资源占用")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "打开工作台" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.blue : theme.secondaryText)
            }
        }
    }

    // MARK: - 卡片 2: Wi-Fi 低延迟

    private var wifiLatencyCardContent: some View {
        let enabled = toggles.enablePluginWiFiLatency

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .wifiLatency,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Wi-Fi 低延迟")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .wifiLatency, tint: .teal, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(wifiManager.isLowLatencyActive ? Color.teal : Color.gray.opacity(0.5))
                                        .frame(width: 6, height: 6)
                                    Text(wifiManager.isLowLatencyActive ? "运行中" : "待机")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(wifiManager.isLowLatencyActive ? Color.teal : theme.secondaryText)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(wifiManager.isLowLatencyActive ? Color.teal.opacity(0.12) : Color.white.opacity(0.04))
                                )
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .wifiLatency, tint: .teal)
                        }
                    }

                    Text("系统底层 awdl0 接口调度 · 阻断后台 Wi-Fi 信道切换")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("动态冻结 macOS 系统后台 AirDrop 与空中扫描轮询，消除局域网内每隔 60 秒一次的网络抖动与丢包峰值，为联机游戏保驾护航。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    Text(wifiManager.isLowLatencyActive ? "状态: 已锁定 5GHz/6GHz 专注通道" : "状态: 随时可一键启动")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(wifiManager.isLowLatencyActive ? Color.teal : theme.secondaryText)
                } else {
                    Text("模块未启用 · 零后台资源占用")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "进入控制面板" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.teal : theme.secondaryText)
            }
        }
    }

    // MARK: - 卡片 3: 局域网 ARP 嗅探与设备诊断

    private var arpSnifferCardContent: some View {
        let enabled = toggles.enablePluginARPSniffer

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .arpSniffer,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("局域网 ARP 嗅探与设备诊断")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .arpSniffer, tint: .purple, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(lanSniffer.isScanning ? Color.orange : Color.purple)
                                        .frame(width: 6, height: 6)
                                    Text(lanSniffer.isScanning ? "嗅探中..." : "已发现 \(lanSniffer.discoveredDevices.count) 台设备")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(lanSniffer.isScanning ? Color.orange : Color.purple)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(lanSniffer.isScanning ? Color.orange.opacity(0.12) : Color.purple.opacity(0.12)))
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .arpSniffer, tint: .purple)
                        }
                    }

                    Text("独立二层拓扑扫描 · 智能推断设备名 · IP 与 MAC 映射")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("独立运行的二层网络拓扑嗅探引擎。实时解析局域网在线设备的主机名称、IP 地址与 12 位物理 MAC 地址，精准识别路由器、PS5、Portal 掌机与苹果设备。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    Text("当前网卡: \(lanSniffer.selectedInterfaceInfo?.compactDisplayName ?? lanSniffer.selectedInterface) | \(lanSniffer.discoveredDevices.isEmpty ? "等待扫描" : "已发现 \(lanSniffer.discoveredDevices.count) 个活动节点")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("模块未启用 · 零后台资源占用")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "查看设备清单" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.purple : theme.secondaryText)
            }
        }
    }

    // MARK: - 卡片 4: UPS 不间断电源智能管理

    private var upsManagerCardContent: some View {
        let enabled = toggles.enablePluginUPSManager

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .upsManager,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("UPS 电源管理")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .upsManager, tint: .orange, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(engine.telemetry.isConnected ? Color.green : Color.orange)
                                        .frame(width: 6, height: 6)
                                    Text(engine.telemetry.isConnected ? "已接入 UPS" : "守护就绪")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(engine.telemetry.isConnected ? Color.green : Color.orange)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill((engine.telemetry.isConnected ? Color.green : Color.orange).opacity(0.12)))
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .upsManager, tint: .orange)
                        }
                    }

                    Text("原生 IOKit UPS 关机保护与外置硬盘逃生舱")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("原生接管 USB-HID 电源协议与外置 UPS，提供断电自动休眠/关机保护、外置硬盘逃生舱与系统级阈值同步。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    Text("当前策略: \(upsManager.haltAfterEnabled ? "使用 \(upsManager.haltAfterMinutes) 分钟后关机" : "防断电关机已就绪")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("未启用时状态页与菜单栏默认显示 AC / 电池供电")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "配置策略" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.orange : theme.secondaryText)
            }
        }
    }

    // MARK: - 卡片 5: Antigravity 扩展

    private var antigravityContextCardContent: some View {
        let enabled = toggles.enablePluginAntigravityContext
        let needsReapply = antigravityManager.versionWatchState.needsReapplyWarning
        let isPatched = antigravityManager.latestReport?.clampState.isPatched ?? false
        let isOriginal = antigravityManager.latestReport?.clampState == .original256K
        let codexActive = codexThemeManager.isInstalled && codexThemeManager.daemonRunning && codexThemeManager.cdpStatus == "ready"

        let badgeColor: Color = {
            if needsReapply { return .orange }
            if isPatched || codexActive { return .green }
            if isOriginal { return .orange }
            return .indigo
        }()

        let badgeText: String = {
            if antigravityManager.isAnalyzing { return "检测中" }
            if needsReapply { return "待重新解锁" }
            if let clamp = antigravityManager.latestReport?.clampState {
                if codexThemeManager.isInstalled {
                    return "\(clamp.compactBadge) · 主题\(codexThemeManager.compactStatusBadge)"
                }
                return clamp.compactBadge
            }
            if codexThemeManager.isInstalled {
                return "主题\(codexThemeManager.compactStatusBadge)"
            }
            if antigravityManager.selectedTargetPath.isEmpty { return "未发现目标" }
            return "就绪"
        }()

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .antigravityContext,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Antigravity 扩展")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .antigravityContext, tint: .indigo, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(badgeColor)
                                        .frame(width: 6, height: 6)
                                    Text(badgeText)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(badgeColor)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(badgeColor.opacity(0.12)))
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .antigravityContext, tint: .indigo)
                        }
                    }

                    Text("上下文 256K 解锁 · Codex 昼夜主题 / 中文汉化 / 额度监控")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("集成本地 Mach-O 上下文扩容与开源 Codex 主题汉化扩展，支持自动复用内置 Node 运行时、双向配置热同步与在线一键更新。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    let verText = antigravityManager.currentAppVersion.map { "v\($0)" } ?? "未识别版本"
                    if needsReapply {
                        Text("版本变更/失效 (\(verText)) · 建议重新解锁")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.orange)
                    } else if let clamp = antigravityManager.latestReport?.clampState {
                        Text("当前版本: \(verText) · \(clamp.compactBadge)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(isPatched ? Color.green : theme.secondaryText)
                    } else {
                        Text("当前版本: \(verText) · 进入自动体检")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    Text("模块未启用 · 零后台资源占用")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "进入控制台" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.indigo : theme.secondaryText)
            }
        }
    }

    private var aiToolCleanerCardContent: some View {
        let enabled = toggles.enablePluginAIToolCleaner
        let cleanableText = ByteCountFormatter.string(fromByteCount: aiCleanerManager.totalCleanableBytes, countStyle: .file)
        let badgeColor: Color = {
            if aiCleanerManager.isScanning { return .orange }
            if aiCleanerManager.totalCleanableBytes > 0 { return .mint }
            return .green
        }()

        let badgeText: String = {
            if aiCleanerManager.isScanning { return "扫描中" }
            if aiCleanerManager.lastScanDate == nil { return "待扫描" }
            if aiCleanerManager.totalCleanableBytes > 0 { return "可释 \(cleanableText)" }
            return "已洁净"
        }()

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .aiToolCleaner,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("AI 工具清理与维护")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .aiToolCleaner, tint: .mint, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(badgeColor)
                                        .frame(width: 6, height: 6)
                                    Text(badgeText)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(badgeColor)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(badgeColor.opacity(0.12)))
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .aiToolCleaner, tint: .mint)
                        }
                    }

                    Text("Claude / Codex / Cursor / Ollama 缓存治理、对话修剪与 SQLite 压缩")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("分层治理 AI 客户端缓存、超期对话备份、孤儿项目会话、Worktree 与 SQLite 数据库，与系统清理共享保护白名单。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    let toolsCount = aiCleanerManager.detectedToolNames.count
                    if aiCleanerManager.isScanning {
                        Text("正在扫描 AI 工具缓存与本地数据库...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.orange)
                    } else if aiCleanerManager.lastScanDate != nil {
                        Text("已识别 \(toolsCount) 款 AI 工具 · 保护项 \(aiCleanerManager.protectedItemsCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("点击进入即可扫描 Claude / Codex / Ollama 等")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    Text("模块未启用 · 零后台资源占用")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "进入工作台" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.mint : theme.secondaryText)
            }
        }
    }

    private var softwareUpdaterCardContent: some View {
        let enabled = toggles.enablePluginSoftwareUpdater
        let availCount = updaterManager.totalAvailableUpdatesCount
        let badgeColor: Color = {
            if updaterManager.isScanning { return .orange }
            if availCount > 0 { return .cyan }
            return .green
        }()

        let badgeText: String = {
            if updaterManager.isScanning { return "检查中" }
            if updaterManager.lastScanDate == nil { return "待检测" }
            if availCount > 0 { return "\(availCount) 项可更新" }
            return "均已最新"
        }()

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .softwareUpdater,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("软件更新中心")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .softwareUpdater, tint: .cyan, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(badgeColor)
                                        .frame(width: 6, height: 6)
                                    Text(badgeText)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(badgeColor)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(badgeColor.opacity(0.12)))
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .softwareUpdater, tint: .cyan)
                        }
                    }

                    Text("Sparkle / Electron / App Store / Homebrew 多源版本聚合与签名校验更新")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("并发检测本机桌面应用、MAS 商店及 Homebrew Cask / CLI 公式更新，安装前自动校验代码签名与 Team ID 连续性。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    if updaterManager.isScanning {
                        Text("正在检查本机应用与 CLI 公式新版本...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.orange)
                    } else if updaterManager.lastScanDate != nil {
                        Text("可更新应用 \(updaterManager.visibleAppUpdates.count) 款 · CLI \(updaterManager.visibleFormulaUpdates.count) 项")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("点击进入即可扫描本机多渠道更新源")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    Text("模块未启用 · 零后台资源占用")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "进入工作台" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.cyan : theme.secondaryText)
            }
        }
    }

    private var accessoryLocationCardContent: some View {
        let enabled = toggles.enablePluginAccessoryLocation
        let badgeColor: Color = {
            if accessoryLocationManager.isRunning {
                return accessoryLocationManager.stage == .streaming ? .green : .orange
            }
            return accessoryLocationManager.mfiStatus.isConfigured ? .pink : .orange
        }()
        let badgeText: String = {
            if accessoryLocationManager.isRunning {
                return accessoryLocationManager.stage.shortTitle
            }
            return accessoryLocationManager.mfiStatus.isConfigured ? "凭据就绪" : "待导入 MFi"
        }()

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 14) {
                PluginArtworkIconView(
                    kind: .accessoryLocation,
                    size: 58,
                    isEnabled: enabled,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("iOS 虚拟定位")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        pluginVersionBadge(for: .accessoryLocation, tint: .pink, enabled: enabled)

                        Spacer()

                        HStack(spacing: 8) {
                            if enabled {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(badgeColor)
                                        .frame(width: 6, height: 6)
                                    Text(badgeText)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(badgeColor)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(badgeColor.opacity(0.12)))
                            } else {
                                pluginDisabledBadge
                            }
                            pluginCardToggle(for: .accessoryLocation, tint: .pink)
                        }
                    }

                    Text(verbatim: "开源项目：https://github.com/aur3l14no/accessory-location")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Text("通过蓝牙 RFCOMM 或 USB CarKit 通道与 iPhone 握手并实时注入 NMEA 位置，支持国内地图纠偏与收藏选点。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack {
                if enabled {
                    let wgs = accessoryLocationManager.effectiveWGS84Coordinate
                    Text(String(format: "目标 WGS-84: %.4f, %.4f", wgs.latitude, wgs.longitude))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("模块未启用 · 零后台资源占用")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(enabled ? "进入工作台" : "查看详情")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(enabled ? Color.pink : theme.secondaryText)
            }
        }
    }

    // MARK: - 二级页面分发器

    private func accentColor(for plugin: PluginModuleType) -> Color {
        switch plugin {
        case .psPortal: return .blue
        case .wifiLatency: return .teal
        case .arpSniffer: return .purple
        case .upsManager: return .orange
        case .antigravityContext: return .indigo
        case .aiToolCleaner: return .mint
        case .softwareUpdater: return .cyan
        case .accessoryLocation: return .pink
        }
    }

    private func iconName(for plugin: PluginModuleType) -> String {
        switch plugin {
        case .psPortal: return "gamecontroller.fill"
        case .wifiLatency: return "antenna.radiowaves.left.and.right"
        case .arpSniffer: return "network"
        case .upsManager: return "battery.100.bolt"
        case .antigravityContext: return "sparkles"
        case .aiToolCleaner: return "wand.and.sparkles.inverse"
        case .softwareUpdater: return "arrow.triangle.2.circlepath.circle.fill"
        case .accessoryLocation: return "location.north.line.fill"
        }
    }

    private func artworkKind(for plugin: PluginModuleType) -> PluginArtworkKind {
        switch plugin {
        case .psPortal: return .psPortal
        case .wifiLatency: return .wifiLatency
        case .arpSniffer: return .arpSniffer
        case .upsManager: return .upsManager
        case .antigravityContext: return .antigravityContext
        case .aiToolCleaner: return .aiToolCleaner
        case .softwareUpdater: return .softwareUpdater
        case .accessoryLocation: return .accessoryLocation
        }
    }

    private func pluginDecoupledDescription(for plugin: PluginModuleType) -> String {
        switch plugin {
        case .psPortal:
            return "按需启用后将加载本地协议中继脚本与局域网设备发现功能。停用状态下不驻留任何后台进程或监听器。"
        case .wifiLatency:
            return "按需启用后可按需调度 macOS 底层 awdl0 无线接口以消除无线抖动。停用状态下保持标准系统网络行为。"
        case .arpSniffer:
            return "按需启用后将允许枚举本地网卡与读取物理内核 ARP 拓扑表。停用状态下不发送任何局域网探活包。"
        case .upsManager:
            return "按需启用后将开启 USB-HID 外置电源轮询与断电自动保护；未启用时，状态总览与菜单栏将默认显示 AC / 内置电池供电。"
        case .antigravityContext:
            return "按需启用后可使用纯 Swift 原生引擎解除 Antigravity 256K 上下文上限，并可一键部署管理开源 Codex 昼夜主题、中文界面汉化、实时用量与模型额度监控扩展。"
        case .aiToolCleaner:
            return "按需启用后可扫描 Claude、Codex、ChatGPT、Cursor、Antigravity、Ollama 等 AI 工具缓存、超期对话（含备份恢复）与 SQLite 数据库压缩，且共享全盘清理保护白名单。"
        case .softwareUpdater:
            return "按需启用后将扫描 Sparkle Appcast、Electron / GitHub 发布源、Mac App Store 与 Homebrew Cask / CLI 公式更新，并在替换前执行代码签名及 Team ID 校验。"
        case .accessoryLocation:
            return "按需启用后将在本地运行纯原生的 MFi-v3 P-256 签名与 iAP2 NMEA 位置配件协议（支持蓝牙 RFCOMM 与沙盒隔离的 USB usbmuxd），不含内置私钥，停用即释放系统定位回真实硬件。"
        }
    }

    @ViewBuilder
    private func detailView(for plugin: PluginModuleType) -> some View {
        let isEnabled = toggles.isPluginEnabled(plugin)
        let accent = accentColor(for: plugin)

        VStack(spacing: 12) {
            // 统一返回导航条
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        pluginManager.activePluginType = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("返回模块中心")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.studioCardFill)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Text("/")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText.opacity(0.4))

                Text(plugin.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                if isEnabled && plugin == .psPortal {
                    HStack(spacing: 8) {
                        Button {
                            pluginManager.checkForPluginUpdates()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: pluginManager.isCheckingForUpdates ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                                    .font(.system(size: 12))
                                Text(pluginManager.isCheckingForUpdates ? "检查中..." : "检查插件更新")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.studioCardFill)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(pluginManager.isCheckingForUpdates)
                        .help("检查 atameric/ps5-portal-high-bitrate 远端最新提交与更新")

                        Button {
                            pluginManager.openPluginFolder()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                Text("打开插件目录")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.studioCardFill)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help("打开 ~/Library/Application Support/SysPulse/Plugins/PSPortal")

                        Button {
                            pluginManager.reloadPlugin()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                                Text("重新载入插件")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.studioCardFill)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help("重新读取 manifest.json 与 config.json")
                    }
                } else if isEnabled && plugin == .upsManager {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(engine.telemetry.state.isAC ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(engine.telemetry.state.isAC ? "市电直供 · 守护中" : "电池供电 · 保护中")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(engine.telemetry.state.isAC ? Color.green : Color.orange)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.pillFill))

                        Button {
                            upsManager.commitChangesToSystem(forceAuthorize: true) {}
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 12))
                                Text("同步写入系统")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.studioCardFill)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help("将 UPS 关机保护阈值同步写入 macOS 系统底层 IOPMCopyUPSShutdownLevels")
                    }
                } else if isEnabled && plugin == .antigravityContext {
                    HStack(spacing: 8) {
                        Button {
                            antigravityManager.refreshAllStatus()
                            codexThemeManager.refreshStatus()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                                Text((antigravityManager.isAnalyzing || codexThemeManager.isRefreshing) ? "检测中..." : "刷新全部状态")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.studioCardFill)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(antigravityManager.isAnalyzing || antigravityManager.isApplying || codexThemeManager.isBusy)
                    }
                }

                // 统一模块启用开关胶囊
                HStack(spacing: 8) {
                    Text(isEnabled ? "模块已启用" : "模块未启用")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isEnabled ? accent : theme.secondaryText)

                    Toggle("", isOn: pluginBinding(for: plugin))
                        .toggleStyle(AlwaysTintedSwitchToggleStyle(tint: accent))
                        .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.studioCardFill)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                )
            }
            .frame(width: contentW)

            // 各模块工作台（未启用时展示引导面板）
            if !isEnabled {
                disabledPluginPlaceholder(for: plugin)
                    .frame(width: contentW)
                    .frame(maxHeight: .infinity)
            } else {
                switch plugin {
                case .psPortal:
                    psPortalDetailWorkstation
                case .wifiLatency:
                    wifiLatencyDetailWorkstation
                case .arpSniffer:
                    arpSnifferDetailWorkstation
                case .upsManager:
                    upsManagerDetailWorkstation
                case .antigravityContext:
                    antigravityContextDetailWorkstation
                case .aiToolCleaner:
                    AIToolCleanerDetailView(theme: theme)
                case .softwareUpdater:
                    SoftwareUpdaterDetailView(theme: theme)
                case .accessoryLocation:
                    AccessoryLocationDetailView(theme: theme)
                }
            }
        }
    }

    private func disabledPluginPlaceholder(for plugin: PluginModuleType) -> some View {
        let accent = accentColor(for: plugin)

        return VStack(spacing: 20) {
            Spacer()

            PluginArtworkIconView(
                kind: artworkKind(for: plugin),
                size: 78,
                isEnabled: false,
                forcedColorScheme: colorScheme
            )

            VStack(spacing: 8) {
                Text("「\(plugin.name)」尚未启用")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text(pluginDecoupledDescription(for: plugin))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    toggles.setPluginEnabled(plugin, true)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .bold))
                    Text("立即启用此模块")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accent)
                )
                .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    // MARK: - PS Portal 工作台

    private var psPortalDetailWorkstation: some View {
        VStack(spacing: 14) {
            // 主插件卡片
            mainPluginCard
                .frame(width: contentW)

            // 实时中继遥测与通信日志卡片
            liveLogCard
                .frame(width: contentW)
                .frame(maxHeight: .infinity)
        }
        .onAppear {
            pluginManager.detectInterfaces()
        }
    }

    // MARK: - Wi-Fi 低延迟专属工作台

    private var wifiLatencyDetailWorkstation: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    PluginArtworkIconView(
                        kind: .wifiLatency,
                        size: 58,
                        forcedColorScheme: colorScheme
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Wi-Fi 低延迟")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)

                            pluginVersionBadge(for: .wifiLatency, tint: .teal, fontSize: 11)
                        }

                        Text("智能管理 Apple Wireless Direct Link (awdl0) 接口，彻底消除周期性信道漫游跳变")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer()

                    Button {
                        wifiManager.toggleLowLatency()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: wifiManager.isLowLatencyActive ? "bolt.slash.fill" : "bolt.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(wifiManager.isLowLatencyActive ? "停用低延迟" : "一键激活低延迟")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(wifiManager.isLowLatencyActive ? Color.gray.opacity(0.3) : Color.teal)
                        )
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                Divider().opacity(0.3)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前物理无线链路状态")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                        Text(wifiManager.isLowLatencyActive ? "⚡️ AWDL 已冻结：后台扫描被抑制，独占 5GHz / 6GHz 通信通道" : "● AWDL 正常处于活跃状态 (隔周期可能产生 100~300ms 抖动)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(wifiManager.isLowLatencyActive ? Color.teal : theme.secondaryText)
                    }

                    Spacer()

                    Button {
                        wifiManager.checkAWDLState()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("刷新状态")
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.studioCardFill)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            )

            Spacer()
        }
    }

    // MARK: - 局域网 ARP 嗅探工作台

    private var arpSnifferDetailWorkstation: some View {
        VStack(spacing: 12) {
            // 顶部工具栏与状态卡片
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    PluginArtworkIconView(
                        kind: .arpSniffer,
                        size: 50,
                        forcedColorScheme: colorScheme
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("局域网活动设备")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)

                            Text("v0.1.2")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.12)))

                            if let notice = lanSniffer.copiedNotice {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text(notice)
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                                .transition(.opacity)
                            }
                        }

                        Text("独立读取系统物理内核 ARP 缓存表，实时探测局域网内所有已连接设备的名称、IP 与 MAC 地址")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer()

                    // 真实物理网卡展示与选择（统一复用活跃网卡菜单）
                    activeInterfaceSelector(
                        activeInterfaces: lanSniffer.activeInterfaces,
                        selectedInterface: lanSniffer.selectedInterface,
                        selectedInfo: lanSniffer.selectedInterfaceInfo,
                        disabled: lanSniffer.isScanning,
                        useCardStyle: true,
                        onSelect: { lanSniffer.selectInterface($0) },
                        onRefresh: { lanSniffer.detectActiveInterfaces() }
                    )

                    // 导入路由器 DHCP 备份 CSV 批量改名
                    Button {
                        lanSniffer.promptImportDHCPBackup()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11))
                            Text("导入 DHCP 备份")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.studioCardFill)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                        )
                        .foregroundStyle(theme.primaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("选择路由器导出的 DHCP 备份表 (.csv)，按 MAC 地址批量匹配修改设备名称")

                    // 厂商名称映射规则管理按钮
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            lanSniffer.showVendorRulesPanel.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(lanSniffer.showVendorRulesPanel ? Color.white : Color.purple)
                            Text("厂商规则")
                                .font(.system(size: 12, weight: .medium))
                            if !metadataManager.vendorRules.isEmpty {
                                Text("\(metadataManager.vendorRules.count)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(
                                            lanSniffer.showVendorRulesPanel
                                                ? Color.white.opacity(0.22)
                                                : Color.purple.opacity(0.16)
                                        )
                                    )
                                    .foregroundStyle(lanSniffer.showVendorRulesPanel ? Color.white : Color.purple)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(lanSniffer.showVendorRulesPanel ? Color.purple : theme.studioCardFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(lanSniffer.showVendorRulesPanel ? Color.purple : theme.studioCardBorder, lineWidth: 0.8)
                                )
                        )
                        .foregroundStyle(lanSniffer.showVendorRulesPanel ? Color.white : theme.primaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("管理全局厂商名称 / MAC 前缀映射规则（如 Shenzhen Zhangyue → iReader）")

                    // 重新探测按钮
                    Button {
                        lanSniffer.startScan()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: lanSniffer.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                                .rotationEffect(.degrees(lanSniffer.isScanning ? 360 : 0))
                                .animation(lanSniffer.isScanning ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: lanSniffer.isScanning)
                            Text(lanSniffer.isScanning ? "探活嗅探中..." : "重新探测局域网")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.purple)
                        )
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(lanSniffer.isScanning)
                    .pointingHandOnHover()
                }

                Divider().opacity(0.2)

                // 搜索过滤与统计栏
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)

                        TextField("按设备名称、IP 地址、MAC 地址过滤...", text: $lanSniffer.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))

                        if !lanSniffer.searchQuery.isEmpty {
                            Button {
                                lanSniffer.searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                    )

                    HStack(spacing: 6) {
                        Text("共发现 \(lanSniffer.discoveredDevices.count) 台设备")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.purple)
                        if !lanSniffer.searchQuery.isEmpty {
                            Text("(筛选出 \(lanSniffer.filteredDevices.count) 台)")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))

                    Spacer()

                    if let lastSeen = lanSniffer.lastScannedAt {
                        Text("最近更新: \(lastSeen.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText.opacity(0.7))
                    }
                }

                if lanSniffer.showVendorRulesPanel {
                    vendorRulesManagementPanel
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.studioCardFill)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            )

            // 表头栏
            HStack(spacing: 72) {
                Text("设备名称")
                    .frame(width: 265, alignment: .leading)
                Text("IP 地址")
                    .padding(.leading, 6)
                    .frame(width: 168, alignment: .leading)
                Text("物理 MAC 地址")
                    .padding(.leading, 6)
                    .frame(width: 187, alignment: .leading)
                Text("厂商 / 接口")
                    .padding(.leading, 6)
                    .frame(width: 142, alignment: .leading)
                Text("网络状态")
                    .frame(width: 46, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 28)
            .padding(.vertical, 6)

            // 设备列表展示卡片
            if lanSniffer.filteredDevices.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: lanSniffer.isScanning ? "antenna.radiowaves.left.and.right" : "network.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(theme.secondaryText.opacity(0.5))

                    Text(lanSniffer.isScanning ? "正在向全网段轻量探活并同步物理内核 ARP 表..." : (lanSniffer.searchQuery.isEmpty ? "未发现任何局域网设备，请点击右上角「重新探测局域网」" : "未找到匹配 “\(lanSniffer.searchQuery)” 的设备"))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)

                    if !lanSniffer.searchQuery.isEmpty {
                        Button("清空搜索条件") {
                            lanSniffer.searchQuery = ""
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.purple)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.studioCardFill)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                )
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(lanSniffer.filteredDevices) { dev in
                            lanDeviceRow(dev)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.studioCardFill)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                )
            }
        }
        .onAppear {
            if toggles.enablePluginARPSniffer {
                lanSniffer.detectActiveInterfaces()
                if lanSniffer.discoveredDevices.isEmpty && !lanSniffer.isScanning {
                    lanSniffer.startScan()
                }
            }
        }
    }

    private func rowBgColor(for dev: LanDeviceItem) -> Color {
        if dev.isGateway { return Color.teal.opacity(0.05) }
        if dev.isLocalHost { return Color.green.opacity(0.04) }
        return Color.white.opacity(0.02)
    }

    private func rowBorderColor(for dev: LanDeviceItem, isEditing: Bool) -> Color {
        if isEditing { return Color.purple.opacity(0.5) }
        if dev.isGateway { return Color.teal.opacity(0.2) }
        return theme.studioCardBorder.opacity(0.4)
    }

    // MARK: - 单台局域网设备行组件

    private func lanDeviceRow(_ dev: LanDeviceItem) -> some View {
        let isEditing = (lanSniffer.editingMAC == dev.mac)
        let bg = rowBgColor(for: dev)
        let border = rowBorderColor(for: dev, isEditing: isEditing)
        let strokeW: CGFloat = isEditing ? 1.0 : 0.6

        return VStack(spacing: 8) {
            lanDeviceHeaderRow(dev, isEditing: isEditing)

            if isEditing {
                lanDeviceEditingDrawer(dev)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(border, lineWidth: strokeW)
                )
        )
    }

    private func lanDeviceTitleView(dev: LanDeviceItem, isEditing: Bool) -> some View {
        HStack(spacing: 6) {
            Text(dev.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            if dev.isGateway {
                Text("网关")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.teal)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.teal.opacity(0.15)))
            } else if dev.isLocalHost {
                Text("本机")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isEditing {
                        lanSniffer.cancelEditing()
                    } else {
                        lanSniffer.startEditing(dev: dev)
                    }
                }
            } label: {
                Image(systemName: isEditing ? "pencil.circle.fill" : "square.and.pencil")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isEditing ? Color.purple : theme.secondaryText.opacity(0.85))
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                isEditing
                                    ? Color.purple.opacity(0.16)
                                    : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        isEditing ? Color.purple.opacity(0.5) : theme.studioCardBorder.opacity(0.45),
                                        lineWidth: 0.6
                                    )
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("更改设备名称、厂商与自定义图标")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lanDeviceHeaderRow(_ dev: LanDeviceItem, isEditing: Bool) -> some View {
        let pillFill = colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05)

        return HStack(spacing: 72) {
            // 设备图标 + 标识名称
            HStack(spacing: 10) {
                deviceIconView(for: dev)
                lanDeviceTitleView(dev: dev, isEditing: isEditing)
            }
            .frame(width: 265, alignment: .leading)

            // IP 地址（点击一键复制）
            Button {
                lanSniffer.copyToClipboard(dev.ip, notice: "已复制 IP: \(dev.ip)")
            } label: {
                HStack(spacing: 4) {
                    Text(dev.ip)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText.opacity(0.5))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(pillFill))
            }
            .buttonStyle(.plain)
            .help("点击复制 IP 地址")
            .frame(width: 168, alignment: .leading)

            // 物理 MAC 地址（点击一键复制）
            Button {
                lanSniffer.copyToClipboard(dev.mac, notice: "已复制 MAC: \(dev.mac)")
            } label: {
                HStack(spacing: 4) {
                    Text(dev.mac)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText.opacity(0.5))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(pillFill))
            }
            .buttonStyle(.plain)
            .help("点击复制 MAC 地址")
            .frame(width: 187, alignment: .leading)

            // 设备厂商与接口
            lanDeviceVendorInterfaceView(dev: dev, pillFill: pillFill)
                .frame(width: 142, alignment: .leading)

            // 网络在线状态指示
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("在线")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.green)
            }
            .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func lanDeviceVendorInterfaceView(dev: LanDeviceItem, pillFill: Color) -> some View {
        let ifaceFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let vendorFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let ifaceTextW = ceil((dev.interface as NSString).size(withAttributes: [.font: ifaceFont]).width)
        let vendorTextW = ceil((dev.vendor as NSString).size(withAttributes: [.font: vendorFont]).width)
        let colWidth: CGFloat = 142
        let ifaceBoxW = ifaceTextW + 10
        let maxVendorCapsuleW = max(56, colWidth - 6 - ifaceBoxW)
        let maxInnerVendorW = max(44, maxVendorCapsuleW - 12)
        let overflow = max(0, vendorTextW - maxInnerVendorW)
        let totalNeededW = min(vendorTextW, maxInnerVendorW) + 12 + 6 + ifaceBoxW

        let row = HStack(spacing: 6) {
            Group {
                if overflow > 1 {
                    Text(dev.vendor)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: maxInnerVendorW, alignment: .leading)
                } else {
                    Text(dev.vendor)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(pillFill))
            .help(dev.vendor)

            Text(dev.interface)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.secondaryText.opacity(0.75))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(pillFill))
        }

        if totalNeededW > colWidth {
            ScrollView(.horizontal, showsIndicators: false) {
                row
            }
        } else {
            row
        }
    }

    private func vendorMarqueeOffset(overflow: CGFloat, date: Date) -> CGFloat {
        guard overflow > 0 else { return 0 }
        let pause: Double = 1.1
        let speed: Double = 26.0
        let travel = Double(overflow) / speed
        let halfCycle = pause + travel
        let cycle = halfCycle * 2.0
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        if phase < pause { return 0 }
        if phase < halfCycle {
            return -overflow * CGFloat((phase - pause) / max(0.01, travel))
        }
        if phase < halfCycle + pause { return -overflow }
        return -overflow * CGFloat(1.0 - (phase - halfCycle - pause) / max(0.01, travel))
    }

    @ViewBuilder
    private var vendorRulesManagementPanel: some View {
        let controlFill = colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)
        let inputFill = colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.8)

        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.2)

            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.purple)
                Text("全局厂商名称 / MAC 前缀映射规则")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                Text("优先级低于单设备自定义，高于内置 IEEE OUI 识别结果")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Button("收起") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        lanSniffer.showVendorRulesPanel = false
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            HStack(spacing: 10) {
                TextField("原厂商名或 MAC 前缀（如 Shenzhen Zhangyue / d0:da:24:5）", text: $lanSniffer.ruleMatchInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(inputFill)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.studioCardBorder.opacity(0.6), lineWidth: 0.8))
                    )
                    .frame(minWidth: 280, maxWidth: 360)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)

                TextField("目标显示厂商（如 iReader）", text: $lanSniffer.ruleTargetInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(inputFill)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.studioCardBorder.opacity(0.6), lineWidth: 0.8))
                    )
                    .frame(width: 190)

                Button {
                    lanSniffer.addVendorRuleFromInputs()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("添加规则")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple))
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Spacer()
            }

            if metadataManager.vendorRules.isEmpty {
                Text("暂无自定义全局映射规则。你可以在上方输入映射关系，或在设备编辑框中勾选「同步将所有同类厂商映射为此厂商」。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                    .padding(.vertical, 2)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(metadataManager.vendorRules) { rule in
                            HStack(spacing: 6) {
                                Text(rule.matchKey)
                                    .font(.system(size: 11, weight: .medium, design: LanDeviceMetadataManager.normalizeMACPrefix(rule.matchKey) != nil ? .monospaced : .default))
                                    .foregroundStyle(theme.secondaryText)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color.purple)
                                Text(rule.targetVendor)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.primaryText)

                                Button {
                                    lanSniffer.removeVendorRule(rule)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                                }
                                .buttonStyle(.plain)
                                .pointingHandOnHover()
                                .help("删除此厂商映射规则")
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(controlFill)
                                    .overlay(Capsule().strokeBorder(Color.purple.opacity(0.35), lineWidth: 0.7))
                            )
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func lanDeviceEditingDrawer(_ dev: LanDeviceItem) -> some View {
        let controlFill = colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        let inputFill = colorScheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.75)

        return VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.2)

            HStack(spacing: 10) {
                Text("自定义名称:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                TextField("输入新的设备名称...", text: $lanSniffer.editingNameInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(inputFill)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.purple.opacity(0.5), lineWidth: 1))
                    )
                    .frame(width: 175)

                Text("自定义厂商:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                TextField("输入厂商名称...", text: $lanSniffer.editingVendorInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(inputFill)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.purple.opacity(0.5), lineWidth: 1))
                    )
                    .frame(width: 155)

                Button("保存修改") {
                    lanSniffer.saveEditingName()
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple))
                .foregroundStyle(Color.white)
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Button("上传图片图标...") {
                    lanSniffer.promptUploadIconFile()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(controlFill)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.studioCardBorder.opacity(0.5), lineWidth: 0.6))
                )
                .foregroundStyle(theme.primaryText)
                .buttonStyle(.plain)
                .help("选择本地 PNG/JPG 作为此设备的头像图标")

                if dev.isCustomized {
                    Button("恢复系统默认") {
                        lanSniffer.resetToDefault()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("关闭") {
                    lanSniffer.cancelEditing()
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .buttonStyle(.plain)
            }

            if !dev.defaultVendor.isEmpty && dev.defaultVendor != "未知厂商" {
                HStack(spacing: 8) {
                    Button {
                        lanSniffer.applyVendorRuleToAll.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: lanSniffer.applyVendorRuleToAll ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12.5))
                                .foregroundStyle(lanSniffer.applyVendorRuleToAll ? Color.purple : theme.secondaryText)
                            Text("同步将所有「\(dev.defaultVendor)」厂商设备统一映射为此厂商名称")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    if dev.vendor != dev.defaultVendor {
                        Text("原始识别: \(dev.defaultVendor)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(controlFill))
                    }
                }
            }

            // 预设图标快捷选择栏
            HStack(spacing: 8) {
                Text("选择预设图标:")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LanDeviceSnifferEngine.presetIcons, id: \.self) { icon in
                            let isSelected = (dev.customProfile?.customIcon == icon && dev.customProfile?.isCustomImage != true)
                            Button {
                                lanSniffer.selectPresetIcon(icon: icon)
                            } label: {
                                Image(systemName: icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSelected ? Color.white : theme.primaryText)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? Color.purple : controlFill)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .strokeBorder(isSelected ? Color.purple : theme.studioCardBorder.opacity(0.5), lineWidth: 0.6)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func deviceIconView(for dev: LanDeviceItem) -> some View {
        if let profile = dev.customProfile, profile.isCustomImage, let path = profile.customIcon, let nsImg = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImg)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        } else {
            let iconName = dev.customProfile?.customIcon ?? dev.defaultIcon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(rowIconGradient(for: dev))
                    .frame(width: 32, height: 32)

                Image(systemName: iconName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white)
            }
        }
    }

    private func rowIconGradient(for dev: LanDeviceItem) -> LinearGradient {
        if dev.isGateway {
            return LinearGradient(colors: [Color.teal, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if dev.isLocalHost {
            return LinearGradient(colors: [Color.green, Color.mint], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if dev.name.contains("PlayStation") || dev.name.contains("PS5") || dev.name.contains("Portal") {
            return LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if dev.name.contains("Nintendo") {
            return LinearGradient(colors: [Color.red, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if dev.name.contains("Apple") {
            return LinearGradient(colors: [Color.gray, Color.black.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [Color.purple.opacity(0.8), Color.indigo.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - UPS 电源管理专属工作台

    private var upsManagerDetailWorkstation: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
                // 1. MacBook + Desktop UPS 替代方案说明 Banner
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.studioCardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1.0)
                        )
                )

                // 2. 实时供电与 UPS 硬件状态看板 (Live Power & UPS Telemetry Bento)
                HStack(spacing: 12) {
                    upsTelemetryCard(
                        icon: engine.telemetry.state.isAC ? "bolt.fill" : "battery.50",
                        iconColor: engine.telemetry.state.isAC ? Color.green : Color.orange,
                        title: "供电来源",
                        value: engine.telemetry.state.isAC ? "交流市电 (AC)" : "电池供电 (DC)",
                        subtext: engine.telemetry.state.isAC ? "电网稳定直供中" : "正在依靠电池供电"
                    )

                    upsTelemetryCard(
                        icon: "battery.100.bolt",
                        iconColor: Color.orange,
                        title: "外置 UPS 设备",
                        value: engine.telemetry.isConnected ? engine.telemetry.deviceName : "未检测到外置设备",
                        subtext: engine.telemetry.isConnected ? "USB HID 协议已同步" : "系统电池守护就绪"
                    )

                    upsTelemetryCard(
                        icon: "chart.bar.xaxis",
                        iconColor: Color.purple,
                        title: "实时负载功耗",
                        value: String(format: "%.1f W", engine.telemetry.loadWatts ?? 0),
                        subtext: (engine.telemetry.loadPercent ?? 0) > 0 ? "UPS 负荷 \(Int(engine.telemetry.loadPercent ?? 0))%" : "整机活跃负载"
                    )

                    upsTelemetryCard(
                        icon: "gauge.with.needle",
                        iconColor: Color.mint,
                        title: "当前电量与续航",
                        value: "\(engine.telemetry.batteryLevel)%",
                        subtext: engine.telemetry.state.isAC ? "处于满电浮充状态" : (engine.telemetry.timeRemainingMinutes != nil ? "剩余约 \(engine.telemetry.timeRemainingMinutes!) 分钟" : "放电计算中")
                    )
                }

                // 3. UPS 自动断电保护策略
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("UPS 自动断电保护策略", systemImage: "bolt.shield.fill")
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Spacer()

                        Button {
                            upsManager.commitChangesToSystem(forceAuthorize: true) {}
                        } label: {
                            Label("同步写入系统", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help("将 UPS 关机保护阈值同步写入 macOS 系统底层 IOPMCopyUPSShutdownLevels")
                    }

                    // 软件守护模式与动作选择
                    HStack {
                        Toggle("启用断电自动休眠 / 关机保护（MacBook 推荐）", isOn: $upsManager.softwareProtectionEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .pointingHandOnHover()

                        Spacer()

                        Picker("触发阈值后执行：", selection: $upsManager.protectionAction) {
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

                    // 3 组离散对齐滑块
                    DiscreteAlignedSlider(
                        title: "使用 UPS 电池供电达到此时间时保护 Mac",
                        enabled: $upsManager.haltAfterEnabled,
                        value: $upsManager.haltAfterMinutes,
                        options: SystemUPSSettingsManager.validMinuteOptions,
                        unit: "分钟",
                        theme: theme
                    )

                    DiscreteAlignedSlider(
                        title: "UPS 电池剩余使用时间低于此时间时保护 Mac",
                        enabled: $upsManager.haltRemainEnabled,
                        value: $upsManager.haltRemainMinutes,
                        options: SystemUPSSettingsManager.validMinuteOptions,
                        unit: "分钟",
                        theme: theme
                    )

                    DiscreteAlignedSlider(
                        title: "UPS 电池电量低于此水平时保护 Mac",
                        enabled: $upsManager.haltLevelEnabled,
                        value: $upsManager.haltLevelPercent,
                        options: SystemUPSSettingsManager.validPercentOptions,
                        unit: "%",
                        theme: theme
                    )
                }
                .padding(18)
                .background(upsCardBackground)

                // 4. 外置硬盘逃生舱 (包含一行两个大硬盘卡片)
                VStack(alignment: .leading, spacing: 14) {
                    // 顶部控制行：标题 + 延时选择器 + 开关 + 立即推出按钮
                    HStack(spacing: 12) {
                        Label("外置硬盘逃生舱", systemImage: "externaldrive.fill.badge.timemachine")
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Spacer()

                        HStack(spacing: 8) {
                            Text("断电后自动安全推出延时：")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.secondaryText)

                            Picker("", selection: $diskGuardian.delayMinutes) {
                                Text("断电后 1 分钟").tag(1)
                                Text("断电后 3 分钟 (推荐)").tag(3)
                                Text("断电后 5 分钟").tag(5)
                                Text("断电后 10 分钟").tag(10)
                            }
                            .frame(width: 175)
                            .pointingHandOnHover()
                        }

                        Toggle("断电自动退盘保护", isOn: $diskGuardian.autoEjectEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 12, weight: .semibold))
                            .pointingHandOnHover()

                        Button("立即推出所有外接盘") {
                            diskGuardian.emergencyEjectAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointingHandOnHover()
                    }

                    // 内部硬盘大卡片区域：一行两个大卡片 (2 列网格)
                    if diskGuardian.mountedExternalDisks.isEmpty {
                        HStack(spacing: 14) {
                            diskStandbySlotCard(slotName: "插槽 A")
                            diskStandbySlotCard(slotName: "插槽 B")
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                            ForEach(diskGuardian.mountedExternalDisks) { disk in
                                diskLargeCard(disk: disk)
                            }
                        }
                    }
                }
                .padding(18)
                .background(upsCardBackground)

                // 5. 供电事件记录
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
                                        .fill(upsPowerEventColor(event.type))
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
                .background(upsCardBackground)
            }
            .padding(.bottom, 1)
        }
    }

    private func upsTelemetryCard(icon: String, iconColor: Color, title: String, value: String, subtext: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            Text(subtext)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var upsCardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(theme.studioCardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.studioCardBorder, lineWidth: 0.9)
            )
    }

    private func upsPowerEventColor(_ type: PowerEventType) -> Color {
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

    private func diskLargeCard(disk: ExternalDiskItem) -> some View {
        let usedBytes = max(0, disk.totalBytes - disk.freeBytes)
        let usageRatio: Double = disk.totalBytes > 0 ? Double(usedBytes) / Double(disk.totalBytes) : 0
        let usedStr = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        let totalStr = disk.formattedSize

        return HStack(spacing: 14) {
            // 1. 左侧磁盘图标
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.22), Color.blue.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 0.8)
                    )

                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.cyan)
            }

            // 2. 中间信息流与存储条
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(disk.name)
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(usageRatio * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(usageRatio > 0.9 ? Color.orange : Color.cyan)
                }

                HStack(spacing: 6) {
                    Text("已用 \(usedStr) / 共 \(totalStr)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)

                    Spacer()

                    Text(disk.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                        .lineLimit(1)
                }

                // 进度条
                GeometryReader { pGeo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.pillFill)
                            .frame(height: 5)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: usageRatio > 0.9 ? [Color.orange, Color.red] : [Color.cyan, Color.blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, pGeo.size.width * CGFloat(min(1.0, max(0.0, usageRatio)))), height: 5)
                    }
                }
                .frame(height: 5)
            }

            // 3. 右侧推出操作
            Button {
                diskGuardian.ejectDisk(at: disk.path)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 12))
                    Text("推出")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.pillFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.studioCardBorder, lineWidth: 0.6)
                        )
                )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("安全推出此外接硬盘")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.pillFill.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
                )
        )
    }

    private func diskStandbySlotCard(slotName: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.green.opacity(0.3), lineWidth: 0.8)
                    )

                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.green)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(slotName) · 逃生舱待命中")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }

                Text("未挂载外置硬盘 · 插入后自动纳管断电保护")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.pillFill.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.studioCardBorder.opacity(0.6), lineWidth: 0.8)
                )
        )
    }

    // MARK: - 顶部标题

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("模块中心")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("模块化独立扩展生态 · 支持动态脚本热更新 · 局域网协议级串流与系统硬件增强")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            HStack(spacing: 8) {
                if toggles.isCustomPluginOrder {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                            toggles.resetPluginModuleOrder()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("恢复默认排序")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(theme.studioCardFill)
                                .overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("将模块中心卡片恢复为默认排列顺序")
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(toggles.enabledPluginsCount > 0 ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text("已启用 \(toggles.enabledPluginsCount) / \(PluginModuleType.allCases.count) 个功能模块")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(toggles.enabledPluginsCount > 0 ? theme.primaryText : theme.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(theme.studioCardFill)
                        .overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                )
            }
        }
    }

    // MARK: - 主插件控制卡片

    private var mainPluginCard: some View {
        VStack(spacing: 16) {
            // 插件基本信息与启停开关
            HStack(alignment: .center, spacing: 16) {
                PluginArtworkIconView(
                    kind: .psPortal,
                    size: 58,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("PS Portal 串流画质增强")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        pluginVersionBadge(for: .psPortal, tint: .blue, fontSize: 11)

                        if pluginManager.engineState != .disabled {
                            statusBadgeView
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("开源项目:")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: true, vertical: false)

                        Button {
                            if let url = URL(string: pluginManager.pluginRepo) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("atameric/ps5-portal-high-bitrate")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.cyan)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.cyan)
                            }
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()

                        Text("· 无需硬改与越狱，动态协议修改提升比特率")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }

                    // 实时运行状态提示语
                    HStack(spacing: 6) {
                        Image(systemName: pluginManager.isStreamActive ? "sparkles" : (pluginManager.autoWatchEnabled ? "eye.fill" : "checkmark.shield.fill"))
                            .font(.system(size: 11))
                            .foregroundStyle(pluginManager.isStreamActive ? Color.green : Color.blue)
                        Text(pluginManager.engineState.subtitle(bitrateTag: pluginManager.targetBitrate.shortTag))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText.opacity(0.9))
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    // Debug 详细诊断开关胶囊
                    Toggle(isOn: Binding(
                        get: { pluginManager.debugModeEnabled },
                        set: { pluginManager.setDebugModeEnabled($0) }
                    )) {
                        HStack(spacing: 4) {
                            Image(systemName: "ladybug.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(pluginManager.debugModeEnabled ? Color.orange : theme.secondaryText)
                            Text("Debug")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(pluginManager.debugModeEnabled ? Color.orange : theme.primaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(pluginManager.debugModeEnabled ? Color.orange.opacity(0.14) : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
                            .overlay(Capsule().strokeBorder(pluginManager.debugModeEnabled ? Color.orange.opacity(0.42) : theme.studioCardBorder, lineWidth: 0.8))
                    )
                    .help("开启后记录完整 ARP 包、分片重组与 UDP/9296 十六进制握手诊断日志，并同步写入 ~/Library/Logs/SysPulse/psportal.log")

                    // 自动增强守望开关胶囊（纯旁路只读 BPF + 触发式按需激活）
                    Toggle(isOn: Binding(
                        get: { pluginManager.autoWatchEnabled },
                        set: { pluginManager.setAutoWatchEnabled($0) }
                    )) {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.badge.automatic")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(pluginManager.autoWatchEnabled ? Color.blue : theme.secondaryText)
                            Text("自动增强")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(pluginManager.autoWatchEnabled ? Color.blue : theme.primaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(pluginManager.autoWatchEnabled ? Color.blue.opacity(0.12) : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
                            .overlay(Capsule().strokeBorder(pluginManager.autoWatchEnabled ? Color.blue.opacity(0.35) : theme.studioCardBorder, lineWidth: 0.8))
                    )
                    .help("开启后采用零干扰只读 BPF 守望，Portal 唤醒连接 PS5 时自动激活高码率增强")

                    if case .enhancingActive = pluginManager.engineState {
                        Button {
                            pluginManager.endEnhancementSession(reason: "用户手动重置画质增强会话状态")
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 11.5))
                                Text("结束会话")
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.green.opacity(0.14))
                                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 0.8))
                            )
                            .foregroundStyle(Color.green)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }

                    // 兜底复原网络直连入口
                    Button {
                        pluginManager.restoreNetworkDirect()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward.circle")
                                .font(.system(size: 12))
                            Text("恢复直连")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                .overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                        )
                        .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(pluginManager.isRunning || pluginManager.isStopping)
                    .help("异常退出后若设备无法连接，点此立即清理 ARP 缓存并恢复直连")

                    // 一键启停主按钮
                    Button {
                        if pluginManager.isRunning {
                            if pluginManager.autoWatchEnabled {
                                pluginManager.setAutoWatchEnabled(false)
                            } else {
                                pluginManager.stopRelay()
                            }
                        } else {
                            pluginManager.startRelay()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: pluginManager.isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(pluginManager.isStopping ? "停止中..." : (pluginManager.isRunning ? (pluginManager.autoWatchEnabled ? "停止守望" : "停止增强") : "启动画质增强"))
                                .font(.system(size: 14, weight: .bold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    pluginManager.isRunning
                                        ? Color.red.opacity(pluginManager.isStopping ? 0.5 : 0.85)
                                        : (colorScheme == .dark ? Color.white : Color(white: 0.15))
                                )
                        )
                        .foregroundStyle(
                            pluginManager.isRunning
                                ? Color.white
                                : (colorScheme == .dark ? Color.black : Color.white)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(pluginManager.isStopping)
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }

            if let errorText = pluginManager.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                    Text(errorText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Button {
                        pluginManager.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8))
                )
            }

            Divider()
                .opacity(0.2)

            // 码率档位与配置表单
            HStack(alignment: .top, spacing: 24) {
                // 左侧：目标码率胶囊选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("目标比特率 (Target Bitrate)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primaryText)

                    HStack(spacing: 8) {
                        ForEach(BitrateProfile.allCases) { profile in
                            let isSelected = pluginManager.targetBitrate == profile
                            Button {
                                pluginManager.targetBitrate = profile
                                pluginManager.saveConfig()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(profile.rawValue)
                                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                            .foregroundStyle(isSelected ? Color.white : theme.primaryText)
                                        Spacer()
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(Color.white)
                                        }
                                    }
                                    Text(profile.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : theme.secondaryText)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(
                                            isSelected
                                                ? Color.blue.opacity(0.85)
                                                : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(
                                                    isSelected ? Color.blue : theme.studioCardBorder,
                                                    lineWidth: 0.8
                                                )
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                            .disabled(pluginManager.isRunning)
                        }
                    }

                    // 中继模式切换
                    HStack(spacing: 8) {
                        Text("中继模式:")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.secondaryText)

                        HStack(spacing: 4) {
                            ForEach(PortalRelayMode.allCases) { mode in
                                let isModeActive = pluginManager.relayMode == mode
                                Button {
                                    pluginManager.relayMode = mode
                                    pluginManager.saveConfig()
                                } label: {
                                    Text(mode.title)
                                        .font(.system(size: 11, weight: isModeActive ? .semibold : .medium))
                                        .foregroundStyle(isModeActive ? Color.white : theme.secondaryText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(isModeActive ? Color.blue.opacity(0.85) : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .pointingHandOnHover()
                                .help(mode.subtitle)
                            }
                        }
                        .padding(3)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                                .overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                        )
                        .disabled(pluginManager.isRunning)

                        Text(pluginManager.relayMode.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)

                // 右侧：接口与 IP 设置
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("网络参数与设备 IP")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.primaryText)

                        Spacer()

                        Button {
                            pluginManager.scanLocalDevices()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: pluginManager.isScanningDevices ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 11))
                                Text(pluginManager.isScanningDevices ? "扫描中..." : "扫描局域网设备")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Color.blue)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(pluginManager.isScanningDevices)
                    }

                    HStack(spacing: 12) {
                        // 网络网卡选择（仅列出当前真实活跃有 IP 的物理网卡）
                        VStack(alignment: .leading, spacing: 6) {
                            Text("网卡接口")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.secondaryText)

                            activeInterfaceSelector(
                                activeInterfaces: pluginManager.activeInterfaces,
                                selectedInterface: pluginManager.selectedInterface,
                                selectedInfo: pluginManager.selectedInterfaceInfo,
                                disabled: pluginManager.isRunning,
                                width: 190,
                                useCardStyle: false,
                                controlHeight: 38,
                                fontSize: 13,
                                horizontalPadding: 10,
                                verticalPadding: 8.5,
                                dotSize: 7,
                                controlCornerRadius: 8,
                                onSelect: { pluginManager.selectInterface($0) },
                                onRefresh: { pluginManager.detectInterfaces() }
                            )
                        }

                        // PS5 IP 输入框
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "tv.fill")
                                    .font(.system(size: 11))
                                Text("PS5 IP (必填)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.blue)

                            TextField("例如 192.168.1.50", text: $pluginManager.ps5IP)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8.5)
                                .frame(minHeight: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.blue.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.35), lineWidth: 0.8))
                                )
                                .disabled(pluginManager.isRunning)
                        }

                        // PS Portal IP 输入框
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 11))
                                Text("PS Portal IP (必填)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.indigo)

                            TextField("例如 192.168.1.107", text: $pluginManager.portalIP)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.indigo)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8.5)
                                .frame(minHeight: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.indigo.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.indigo.opacity(0.35), lineWidth: 0.8))
                                )
                                .disabled(pluginManager.isRunning)
                        }
                    }

                    // 扫描到的 Sony 设备快捷填入条
                    let sonyDevices = pluginManager.discoveredDevices.filter { $0.isLikelySony }
                    HStack(spacing: 8) {
                        if !sonyDevices.isEmpty {
                            Text("检测到 Sony 设备:")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(theme.secondaryText)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(sonyDevices) { dev in
                                        Menu {
                                            Button("设为 PS5 IP (\(dev.ip))") {
                                                pluginManager.bindDiscoveredDevice(dev, as: .ps5Host)
                                            }
                                            Button("设为 PS Portal IP (\(dev.ip))") {
                                                pluginManager.bindDiscoveredDevice(dev, as: .portalClient)
                                            }
                                            if let iface = dev.interfaceName, iface != pluginManager.selectedInterface {
                                                Button("切换至所在网卡 (\(iface))") {
                                                    pluginManager.selectInterface(iface)
                                                }
                                            }
                                        } label: {
                                            let isPS5Role = dev.role == .ps5Host
                                            let roleTag = isPS5Role ? "PS5" : (dev.role == .portalClient ? "Portal" : "Sony")
                                            let iconName = isPS5Role ? "tv.fill" : "gamecontroller.fill"
                                            let tintColor: Color = isPS5Role ? .blue : .indigo
                                            let crossIface = dev.interfaceName != nil && dev.interfaceName != pluginManager.selectedInterface
                                            HStack(spacing: 4.5) {
                                                Image(systemName: iconName)
                                                    .font(.system(size: 10.5))
                                                Text("\(roleTag) · \(dev.ip)")
                                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                if crossIface, let iface = dev.interfaceName {
                                                    Text("(\(iface))")
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundStyle(Color.orange)
                                                }
                                            }
                                            .foregroundStyle(tintColor)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule()
                                                    .fill(tintColor.opacity(0.12))
                                                    .overlay(Capsule().strokeBorder(tintColor.opacity(0.3), lineWidth: 0.8))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .pointingHandOnHover()
                                        .disabled(pluginManager.isRunning || pluginManager.isStopping)
                                        .help(dev.matchReasons.isEmpty ? dev.label : "\(dev.label) · 依据: \(dev.matchReasons.joined(separator: ", "))")
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11))
                                Text("点击右上角「扫描局域网设备」可自动识别 PS5 / Portal IP")
                                    .font(.system(size: 11.5))
                            }
                            .foregroundStyle(theme.secondaryText.opacity(0.75))
                        }
                    }
                    .frame(minHeight: 28, alignment: .leading)
                    .padding(.top, 2)
                }
                .frame(width: 530)
            }

            Divider()
                .opacity(0.16)

            portalSleepPreventionBar
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var portalSleepPreventionBar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { pluginManager.preventSleepInAutoWatch },
                set: { pluginManager.setPreventSleepInAutoWatch($0) }
            )) {
                HStack(spacing: 5) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pluginManager.preventSleepInAutoWatch ? Color.cyan : theme.secondaryText)
                    Text("守望防休眠")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("开启「自动增强」期间阻止 Mac 因闲置休眠（显示器仍会正常自动熄灭，不影响休眠后节能）")

            if pluginManager.preventSleepInAutoWatch {
                HStack(spacing: 3) {
                    ForEach(PortalSleepPreventMode.allCases) { mode in
                        let isActive = pluginManager.sleepPreventMode == mode
                        Button {
                            pluginManager.setSleepPreventMode(mode)
                        } label: {
                            Text(mode.shortTitle)
                                .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? Color.white : theme.secondaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(isActive ? Color.cyan.opacity(0.85) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(2.5)
                .background(
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                        .overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                )

                if pluginManager.sleepPreventMode == .scheduled {
                    HStack(spacing: 4) {
                        Menu {
                            ForEach(0..<24, id: \.self) { hour in
                                Button(String(format: "%02d:00", hour)) {
                                    pluginManager.setScheduleHours(start: hour, end: pluginManager.scheduleEndHour)
                                }
                            }
                        } label: {
                            Text(String(format: "%02d:00", pluginManager.scheduleStartHour))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize(horizontal: true, vertical: false)

                        Text("—")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText)

                        Menu {
                            ForEach(0..<24, id: \.self) { hour in
                                Button(String(format: "%02d:00", hour)) {
                                    pluginManager.setScheduleHours(start: pluginManager.scheduleStartHour, end: hour)
                                }
                            }
                        } label: {
                            Text(String(format: "%02d:00", pluginManager.scheduleEndHour))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .help("仅在该时间段内保持系统清醒（支持跨午夜，如 18:00 — 01:00）")
                } else if pluginManager.sleepPreventMode == .idleTimeout {
                    Menu {
                        ForEach([1, 2, 4, 8], id: \.self) { hrs in
                            Button("\(hrs) 小时无操作") {
                                pluginManager.setIdleTimeoutHours(hrs)
                            }
                        }
                    } label: {
                        Text("\(pluginManager.idleTimeoutHours) 小时无操作")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("连续指定小时未检测到键盘鼠标操作与 Portal 活动后自动放行休眠")
                }

                if pluginManager.isMacLaptop {
                    HStack(spacing: 3) {
                        ForEach(PortalPowerCondition.allCases) { cond in
                            let isCondActive = pluginManager.powerCondition == cond
                            Button {
                                pluginManager.setPowerCondition(cond)
                            } label: {
                                Text(cond.shortTitle)
                                    .font(.system(size: 10.5, weight: isCondActive ? .semibold : .medium))
                                    .foregroundStyle(isCondActive ? Color.white : theme.secondaryText)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(Capsule().fill(isCondActive ? Color.blue.opacity(0.85) : Color.clear))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                    .padding(2.5)
                    .background(
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                            .overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
                    )

                    if pluginManager.powerCondition == .always {
                        Menu {
                            ForEach([15, 20, 30], id: \.self) { pct in
                                Button("电量 ≤\(pct)% 停止") {
                                    pluginManager.setLowBatteryThreshold(pct)
                                }
                            }
                        } label: {
                            Text("≤\(pluginManager.lowBatteryThreshold)%")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("使用内置电池且电量低于阈值时自动释放防休眠断言")
                    }

                    Toggle(isOn: Binding(
                        get: { pluginManager.allowClamshellKeepAwake },
                        set: { pluginManager.setAllowClamshellKeepAwake($0) }
                    )) {
                        Text("插电合盖守望")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(pluginManager.allowClamshellKeepAwake ? Color.orange : theme.secondaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill(pluginManager.allowClamshellKeepAwake ? Color.orange.opacity(0.13) : (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)))
                            .overlay(Capsule().strokeBorder(pluginManager.allowClamshellKeepAwake ? Color.orange.opacity(0.4) : theme.studioCardBorder, lineWidth: 0.8))
                    )
                    .help("仅在接通电源且位于家庭局域网内时阻止合盖强制休眠；拔电、离开家庭网络或退出应用立即自动复原")
                }
            }

            Spacer(minLength: 4)

            if !pluginManager.sleepPreventionStatusText.isEmpty {
                let isActiveHold = pluginManager.isSleepAssertionActive
                Text(pluginManager.sleepPreventionStatusText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isActiveHold ? (pluginManager.isClamshellKeepAwakeActive ? Color.orange : Color.cyan) : theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isActiveHold ? (pluginManager.isClamshellKeepAwakeActive ? Color.orange.opacity(0.12) : Color.cyan.opacity(0.12)) : theme.pillFill)
                    )
            } else {
                Text("仅开启自动增强时生效")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - 状态指示徽章 (方案 A 全状态周期)

    private var statusBadgeColor: Color {
        switch pluginManager.engineState {
        case .disabled:
            return .gray
        case .idle:
            return .blue
        case .authorizing, .starting, .autoBursting, .manualListening, .stopping:
            return .orange
        case .autoWatching:
            return .cyan
        case .enhancingActive:
            return .green
        case .suspendedOutOfLAN, .needsConfiguration, .deviceOffline, .alreadyStreamingHint:
            return .yellow
        case .error:
            return .red
        }
    }

    private var statusBadgeView: some View {
        let tint = statusBadgeColor
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(pluginManager.engineState.badgeText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tint.opacity(0.13))
        )
    }

    // MARK: - 实时日志控制台

    private var liveLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.green)
                    Text("实时通信与握手遥测")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.primaryText)

                    if pluginManager.engineState != .disabled {
                        statusBadgeView
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        pluginManager.openDebugLogFile()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 11))
                            Text("定位日志文件")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(pluginManager.debugModeEnabled ? Color.orange : theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("在访达中定位 ~/Library/Logs/SysPulse/psportal.log")

                    Button {
                        pluginManager.copyLogs()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                            Text("复制日志")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Button {
                        pluginManager.clearLogs()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("清空")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }

            // 控制台视窗 (顶部对齐，超过视口自动向下滚动)
            portalLogConsole
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.85))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var portalLogConsole: some View {
        let activeBurstId = pluginManager.logs.last(where: { $0.text.hasPrefix("[指引] 🎮 已检测到 Portal 唤醒并开启增强通道") })?.id
        let activeReadyId = pluginManager.logs.last(where: {
            $0.text.hasPrefix("[就绪] 🎮 增强通道已就绪") || $0.text.hasPrefix("[准备] ⚡️ 网络协商就绪")
        })?.id
        let activeCooldownId = pluginManager.logs.last(where: { $0.text.hasPrefix("[守望] ⏸ 本轮 120 秒窗口内暂未收到连接握手") })?.id

        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        if pluginManager.logs.isEmpty {
                            Text("等待插件执行，日志输出将实时显示于此...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .padding(.vertical, 8)
                        } else {
                            ForEach(pluginManager.logs) { entry in
                                let displayLine = portalLogDisplayLine(
                                    for: entry,
                                    activeBurstId: activeBurstId,
                                    activeReadyId: activeReadyId,
                                    activeCooldownId: activeCooldownId
                                )
                                Text(displayLine)
                                    .font(.system(size: 12, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(logColor(for: displayLine))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(entry.id)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding([.horizontal, .top], 10)
                    .padding(.bottom, 9)
                    .frame(maxWidth: .infinity, minHeight: 179, alignment: .topLeading)

                    Color.clear
                        .frame(height: 1)
                        .id("portal_log_bottom")
                }
                .onGeometryChange(for: CGFloat.self) { geo in
                    geo.size.height
                } action: { _, _ in
                    guard !pluginManager.logs.isEmpty,
                          Date().timeIntervalSince(pluginManager.lastLogAppendAt) < 0.6 else { return }
                    proxy.scrollTo("portal_log_bottom", anchor: .bottom)
                }
            }
            .onAppear {
                guard !pluginManager.logs.isEmpty else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo("portal_log_bottom", anchor: .bottom)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    proxy.scrollTo("portal_log_bottom", anchor: .bottom)
                }
            }
            .onChange(of: pluginManager.logs.last?.id) { _, lastId in
                guard lastId != nil else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo("portal_log_bottom", anchor: .bottom)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    proxy.scrollTo("portal_log_bottom", anchor: .bottom)
                }
            }
        }
    }

    private func portalLogDisplayLine(
        for entry: PortalLogEntry,
        activeBurstId: UUID?,
        activeReadyId: UUID?,
        activeCooldownId: UUID?
    ) -> String {
        if pluginManager.isListening, let remaining = pluginManager.listenRemainingSeconds {
            if entry.id == activeBurstId {
                return "[指引] 🎮 已检测到 Portal 唤醒并开启增强通道！请在 \(remaining) 秒内于 Portal 上点击「连接 PS5」。"
            }
            if entry.id == activeReadyId {
                return "[就绪] 🎮 增强通道已就绪！现在请在 \(remaining) 秒内于 PS Portal 上点击连接 PS5。"
            }
        }
        if let cooldown = pluginManager.cooldownRemainingSeconds,
           cooldown > 0,
           entry.id == activeCooldownId {
            return "[守望] ⏸ 本轮 120 秒窗口内暂未收到连接握手，已恢复直连路由。请等待 \(cooldown) 秒冷却结束后再用 Portal 连接。"
        }
        return entry.text
    }

    private func activeInterfaceSelector(
        activeInterfaces: [ActiveInterfaceInfo],
        selectedInterface: String,
        selectedInfo: ActiveInterfaceInfo?,
        disabled: Bool,
        width: CGFloat? = nil,
        useCardStyle: Bool,
        controlHeight: CGFloat? = nil,
        fontSize: CGFloat? = nil,
        horizontalPadding: CGFloat? = nil,
        verticalPadding: CGFloat? = nil,
        dotSize: CGFloat = 6,
        controlCornerRadius: CGFloat? = nil,
        onSelect: @escaping (String) -> Void,
        onRefresh: @escaping () -> Void
    ) -> some View {
        let hasIP = !(selectedInfo?.ip ?? "").isEmpty
        let labelText = selectedInfo?.compactDisplayName ?? selectedInterface
        let cornerRadius: CGFloat = controlCornerRadius ?? (useCardStyle ? 8 : 6)
        let resolvedFontSize: CGFloat = fontSize ?? (useCardStyle ? 11 : 11.5)
        let resolvedHorizontalPadding: CGFloat = horizontalPadding ?? (useCardStyle ? 10 : 8)
        let resolvedVerticalPadding: CGFloat = verticalPadding ?? (useCardStyle ? 6 : 5.5)
        let fillColor: Color = useCardStyle
            ? theme.studioCardFill
            : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))

        return Menu {
            ForEach(activeInterfaces) { iface in
                Button {
                    onSelect(iface.name)
                } label: {
                    if selectedInterface == iface.name {
                        Label(iface.displayName, systemImage: "checkmark")
                    } else {
                        Text(iface.displayName)
                    }
                }
            }
            Divider()
            Button {
                onRefresh()
            } label: {
                Label("重新检测活跃网卡", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(hasIP ? Color.green : Color.orange)
                    .frame(width: dotSize, height: dotSize)
                Text(labelText)
                    .font(.system(size: resolvedFontSize, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if width != nil {
                    Spacer(minLength: 2)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: fontSize != nil ? 10 : 9))
                    .foregroundStyle(theme.secondaryText)
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, resolvedHorizontalPadding)
            .padding(.vertical, resolvedVerticalPadding)
            .frame(width: width)
            .frame(minHeight: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fillColor)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .disabled(disabled)
    }

    // MARK: - 卡片 5 二级工作台: Antigravity 扩展 (单屏 Bento 双栏工作台)

    private var antigravityContextDetailWorkstation: some View {
        VStack(spacing: 12) {
            antigravityHeroHeaderCard

            HStack(alignment: .top, spacing: 12) {
                antigravityContextLeftCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                antigravityCodexRightCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            antigravityManager.checkOnEntry()
            codexThemeManager.checkOnEntry()
        }
    }

    private var antigravityHeroHeaderCard: some View {
        let contextPatched = antigravityManager.latestReport?.clampState.isPatched ?? false
        let contextBadgeText = antigravityManager.latestReport?.clampState.compactBadge
            ?? (antigravityManager.isAnalyzing ? "检测中" : "待检测")
        let contextTint: Color = contextPatched ? .green : .orange

        let codexBadgeText: String = {
            if !codexThemeManager.isInstalled { return "Codex 未安装" }
            if codexThemeManager.daemonRunning && codexThemeManager.cdpStatus == "ready" {
                return "Codex 主题插件运行中"
            }
            if codexThemeManager.cdpStatus == "missing_opt_in_flag" {
                return "Codex 待激活"
            }
            return "Codex \(codexThemeManager.compactStatusBadge)"
        }()
        let codexTint: Color = {
            if !codexThemeManager.isInstalled { return theme.secondaryText }
            if codexThemeManager.daemonRunning && codexThemeManager.cdpStatus == "ready" { return .green }
            return .orange
        }()

        let runtimeText = codexThemeManager.runtimeInfo?.displayLabel ?? "未检测到 Node"
        let pathText = antigravityManager.selectedTargetPath.isEmpty
            ? "尚未检测到 language_server 二进制"
            : antigravityManager.selectedTargetPath

        return HStack(spacing: 14) {
            PluginArtworkIconView(
                kind: .antigravityContext,
                size: 50,
                isEnabled: true,
                forcedColorScheme: colorScheme
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Antigravity 扩展")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    if let ver = antigravityManager.currentAppVersion ?? codexThemeManager.appVersion {
                        Text("v\(ver)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.indigo)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.14)))
                    }

                    Text("上下文 \(contextBadgeText)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(contextTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(contextTint.opacity(0.14)))

                    Text(codexBadgeText)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(codexTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(codexTint.opacity(0.12)))
                }

                Text("\(pathText)  ·  \(runtimeText)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                if let banner = antigravityManager.versionWatchState.bannerTitle {
                    if case .externalPatchedUnrecorded = antigravityManager.versionWatchState {
                        Button {
                            antigravityManager.syncCurrentVersionMemory()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("记录当前版本")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.indigo))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .help(banner)
                    } else {
                        Button {
                            antigravityManager.applySelectedPatch(autoRestartIfRunning: true)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("版本已更新 · 立即重解锁")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.orange))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(antigravityManager.isApplying)
                        .help(banner)
                    }
                }

                if !antigravityManager.discoveredTargets.isEmpty {
                    Menu {
                        ForEach(antigravityManager.discoveredTargets) { cand in
                            Button {
                                antigravityManager.selectedTargetPath = cand.path
                                antigravityManager.refreshAllStatus()
                            } label: {
                                Text("\(cand.displayName) · \(cand.path)")
                            }
                        }
                        Divider()
                        Button("手动选择其他文件...") {
                            antigravityManager.selectCustomTargetViaPanel()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 11, weight: .bold))
                            Text("切换目标")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                } else {
                    Button {
                        antigravityManager.selectCustomTargetViaPanel()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("手动选择")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.indigo.opacity(0.12)).overlay(Capsule().strokeBorder(Color.indigo.opacity(0.35), lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var antigravityContextLeftCard: some View {
        let hasBackup = antigravityManager.memory.managedBackupPath != nil || !antigravityManager.legacyBackupPaths.isEmpty
        let alreadyApplied = (antigravityManager.latestReport?.alreadyMatchesTarget ?? false)
        let isEffective = alreadyApplied && !antigravityManager.isApplying

        return VStack(alignment: .leading, spacing: 10) {
            // 卡片顶栏
            HStack(spacing: 8) {
                Text("上下文扩容")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("解除 256K 限制")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                if let memVer = antigravityManager.memory.lastKnownVersion {
                    let memWarn = antigravityManager.versionWatchState.needsReapplyWarning
                    Text("已记忆 v\(memVer)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(memWarn ? Color.orange : Color.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((memWarn ? Color.orange : Color.green).opacity(0.12)))
                }
            }

            // 档位分段轨道
            HStack(spacing: 4) {
                ForEach(AntigravityContextPreset.allCases) { preset in
                    let selected = (antigravityManager.selectedPreset == preset)
                    Button {
                        antigravityManager.selectedPreset = preset
                        antigravityManager.refreshAllStatus()
                    } label: {
                        Text(preset.shortLabel)
                            .font(.system(size: 12.5, weight: selected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(selected ? Color.white : theme.primaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.indigo : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.pillFill.opacity(0.65))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.5), lineWidth: 0.6))
            )

            if antigravityManager.selectedPreset == .custom {
                HStack(spacing: 8) {
                    Text("自定义上限")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    TextField("例如 900K / 512K / 983040", text: $antigravityManager.customTokensText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("预检") {
                        antigravityManager.refreshAllStatus()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.indigo.opacity(0.12)))
                    .pointingHandOnHover()
                }
            }

            // Apple 设置风格的清爽环境体检列表
            VStack(spacing: 0) {
                ForEach(Array(antigravityManager.environmentItems.enumerated()), id: \.element.id) { index, item in
                    let itemColor: Color = {
                        switch item.level {
                        case .ready: return .green
                        case .warning: return .orange
                        case .blocked: return .red
                        }
                    }()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(itemColor)
                            .frame(width: 7, height: 7)

                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.primaryText)

                        Text(item.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 6)

                        if let actionTitle = item.actionTitle {
                            Button {
                                if item.id == "codesign" {
                                    antigravityManager.installCommandLineTools()
                                } else if item.id == "perm" {
                                    antigravityManager.selectCustomTargetViaPanel()
                                } else if item.id == "proc" {
                                    antigravityManager.quitAntigravityOnly()
                                }
                            } label: {
                                Text(actionTitle)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(itemColor)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3.5)
                                    .background(Capsule().fill(itemColor.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        } else if item.level == .ready {
                            Text("正常")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.green.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6.5)

                    if index < antigravityManager.environmentItems.count - 1 {
                        Divider()
                            .overlay(theme.dividerColor.opacity(0.26))
                            .padding(.leading, 27)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.pillFill.opacity(0.38))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.5), lineWidth: 0.6))
            )

            // 常驻展开底层符号与字节预检（4 行网格均匀铺满底部分割线上方空间）
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("底层符号与字节预检")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    if let report = antigravityManager.latestReport {
                        Text("\(report.edits.count) 处 ARM64 指令就绪")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text(antigravityManager.isAnalyzing ? "检测中..." : "待检测")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                if let report = antigravityManager.latestReport {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider().overlay(theme.dividerColor.opacity(0.24))

                        VStack(spacing: 6) {
                            HStack(spacing: 7) {
                                antigravityMetaTile(
                                    label: "目标切片 & __text",
                                    value: "0x\(String(report.sliceOffset, radix: 16)) · 0x\(String(report.textVirtualSize, radix: 16))"
                                )
                                antigravityMetaTile(
                                    label: "Go 函数表 pclntab",
                                    value: "0x\(String(report.pclnOffset, radix: 16)) (\(report.pclnVersion), \(report.functionCount))"
                                )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            HStack(spacing: 7) {
                                antigravityMetaTile(
                                    label: "GetCheckpointConfig",
                                    value: "+0x\(String(report.symbolOffset, radix: 16)) (\(report.symbolSize) B)"
                                )
                                antigravityMetaTile(
                                    label: "文件校验 SHA-256",
                                    value: antigravityManager.isBinaryIntegrityValid ? "校验通过" : "校验异常",
                                    valueColor: antigravityManager.isBinaryIntegrityValid ? nil : Color.red,
                                    isSemibold: !antigravityManager.isBinaryIntegrityValid
                                )
                                .help(antigravityManager.isBinaryIntegrityValid
                                      ? "SHA-256: \(report.binarySHA256)"
                                      : "Mach-O 签名或指令校验未通过 · SHA-256: \(report.binarySHA256)")
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if report.edits.count <= 4 {
                                ForEach(Array(stride(from: 0, to: report.edits.count, by: 2)), id: \.self) { rowStart in
                                    HStack(spacing: 7) {
                                        antigravityBytePatchChip(report.edits[rowStart])
                                        if rowStart + 1 < report.edits.count {
                                            antigravityBytePatchChip(report.edits[rowStart + 1])
                                        } else {
                                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            } else {
                                ScrollView(.vertical, showsIndicators: true) {
                                    antigravityBytePatchGrid(report.edits)
                                }
                                .frame(maxHeight: 68)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text(antigravityManager.isAnalyzing ? "正在解析 ARM64 Mach-O 与 Go pclntab..." : "暂无分析报告")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.pillFill.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.45), lineWidth: 0.6))
            )

            if let err = antigravityManager.lastError {
                Text(err)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            } else if let msg = antigravityManager.statusMessage {
                Text(msg)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.green)
                    .lineLimit(2)
            }

            Divider().overlay(theme.dividerColor.opacity(0.28))

            // 底部贴底操作区
            HStack(spacing: 8) {
                Button {
                    antigravityManager.applySelectedPatch(autoRestartIfRunning: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: antigravityManager.isApplying
                              ? "hourglass"
                              : (isEffective ? "checkmark.circle.fill" : "wand.and.stars"))
                            .font(.system(size: 12, weight: .bold))
                        Text(antigravityManager.isApplying
                             ? "处理中..."
                             : (isEffective
                                ? "已生效"
                                : (antigravityManager.isAntigravityRunning ? "一键解锁并重启 Antigravity" : "一键解锁")))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isEffective ? Color.green : Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(isEffective ? Color.green.opacity(0.14) : Color.indigo)
                            .overlay(
                                Capsule()
                                    .strokeBorder(isEffective ? Color.green.opacity(0.35) : Color.clear, lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .disabled(isEffective || antigravityManager.isApplying || !antigravityManager.isAppleSilicon || antigravityManager.selectedTargetPath.isEmpty)

                if hasBackup {
                    Button {
                        antigravityManager.restoreFromBackup()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11.5, weight: .bold))
                            Text("还原 256K")
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(antigravityManager.isApplying)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var antigravityCodexRightCard: some View {
        let isCodexReady = codexThemeManager.isInstalled && codexThemeManager.daemonRunning && codexThemeManager.cdpStatus == "ready"
        let isReadyPillState = isCodexReady && !codexThemeManager.isBusy
        let daemonStatusText: String = {
            if !codexThemeManager.isInstalled { return "未安装" }
            if isCodexReady {
                return "已就绪"
            }
            let d = codexThemeManager.daemonRunning ? "守护运行中" : "守护未运行"
            return "\(d) · \(codexThemeManager.cdpStatusDisplayText)"
        }()
        let daemonStatusTint: Color = {
            if !codexThemeManager.isInstalled { return theme.secondaryText }
            if isCodexReady { return .green }
            return .orange
        }()
        let needsRelaunch = (codexThemeManager.cdpStatus == "missing_opt_in_flag")

        return VStack(alignment: .leading, spacing: 10) {
            // 卡片顶栏
            HStack(spacing: 8) {
                Text("主题与界面增强")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text(codexThemeManager.isInstalled
                     ? "v\(codexThemeManager.installedVersion ?? codexThemeManager.bundledVersion)"
                     : "内置 v\(codexThemeManager.bundledVersion)")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.indigo.opacity(0.12)))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if !isCodexReady {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(daemonStatusTint)
                            .frame(width: 6.5, height: 6.5)
                        Text(daemonStatusText)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(daemonStatusTint)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(daemonStatusTint.opacity(0.12)))
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Text("启用扩展")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    Toggle("", isOn: Binding(
                        get: { codexThemeManager.config.enabled },
                        set: { val in codexThemeManager.updateConfig { $0.enabled = val } }
                    ))
                    .toggleStyle(AlwaysTintedSwitchToggleStyle(tint: .indigo))
                    .labelsHidden()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            // 单行分段外观条
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("主题配色")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    HStack(spacing: 3) {
                        ForEach(CodexThemePreset.allCases) { preset in
                            let selected = (codexThemeManager.config.preset == preset)
                            Button {
                                codexThemeManager.updateConfig { $0.preset = preset }
                            } label: {
                                Text(preset.displayName)
                                    .font(.system(size: 12.5, weight: selected ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(selected ? Color.white : theme.primaryText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.indigo : Color.clear))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.pillFill.opacity(0.65))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.5), lineWidth: 0.6))
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 5) {
                    Text("用量统计布局")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    HStack(spacing: 3) {
                        ForEach([("compact", "紧凑"), ("detailed", "详细")], id: \.0) { item in
                            let selected = (codexThemeManager.config.telemetryLayout == item.0)
                            Button {
                                codexThemeManager.updateConfig { $0.telemetryLayout = item.0 }
                            } label: {
                                Text(item.1)
                                    .font(.system(size: 12.5, weight: selected ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(selected ? Color.white : theme.primaryText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.indigo : Color.clear))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.pillFill.opacity(0.65))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.5), lineWidth: 0.6))
                    )
                }
                .frame(width: 180)
            }

            // 5×2 全高自适应功能子模块开关网格（均分填满底部分割线上方全部高度）
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("功能子模块")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text(codexThemeManager.isInstalled
                         ? "与 Antigravity 设置实时热同步"
                         : "安装后立即生效")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                }

                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        codexModuleSwitchRow("Codex 昼夜主题", subtitle: "纯白与炭灰深色双配色优化", isOn: Binding(
                            get: { codexThemeManager.config.moduleTheme },
                            set: { v in codexThemeManager.updateConfig { $0.moduleTheme = v } }
                        ))
                        codexModuleSwitchRow("中文界面与右键汉化", subtitle: "主界面文本与上下文菜单本地化", isOn: Binding(
                            get: { codexThemeManager.config.moduleI18n },
                            set: { v in codexThemeManager.updateConfig { $0.moduleI18n = v } }
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    HStack(spacing: 10) {
                        codexModuleSwitchRow("实时会话状态与用量", subtitle: "状态栏展示上下文与 Token 消耗", isOn: Binding(
                            get: { codexThemeManager.config.moduleMetrics },
                            set: { v in codexThemeManager.updateConfig { $0.moduleMetrics = v } }
                        ))
                        codexModuleSwitchRow("模型 5h/7d 额度面板", subtitle: "追踪各模型周期额度与重置倒计时", isOn: Binding(
                            get: { codexThemeManager.config.moduleQuota },
                            set: { v in codexThemeManager.updateConfig { $0.moduleQuota = v } }
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    HStack(spacing: 10) {
                        codexModuleSwitchRow("侧栏常驻额度显示", subtitle: "侧边栏常驻展示模型剩余额度", isOn: Binding(
                            get: { codexThemeManager.config.moduleQuotaSidebar },
                            set: { v in codexThemeManager.updateConfig { $0.moduleQuotaSidebar = v } }
                        ))
                        codexModuleSwitchRow("设置死锁修复", subtitle: "自动规避设置页卡死与渲染阻塞", isOn: Binding(
                            get: { codexThemeManager.config.moduleDeadlockHealer },
                            set: { v in codexThemeManager.updateConfig { $0.moduleDeadlockHealer = v } }
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    HStack(spacing: 10) {
                        codexModuleSwitchRow("Cmd ±/0 缩放快捷键", subtitle: "支持快捷键快速缩放界面比例", isOn: Binding(
                            get: { codexThemeManager.config.moduleZoomShortcuts },
                            set: { v in codexThemeManager.updateConfig { $0.moduleZoomShortcuts = v } }
                        ))
                        codexModuleSwitchRow("输入框下一句预测", subtitle: "智能补全并预测下一条输入提示", isOn: Binding(
                            get: { codexThemeManager.config.modulePromptSuggestions },
                            set: { v in codexThemeManager.updateConfig { $0.modulePromptSuggestions = v } }
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    HStack(spacing: 10) {
                        codexModuleSwitchRow("冷启动自动接力 CDP", subtitle: "应用启动时自动接管调试注入通道", isOn: Binding(
                            get: { codexThemeManager.config.moduleCdpAutoRelaunch },
                            set: { v in codexThemeManager.updateConfig { $0.moduleCdpAutoRelaunch = v } }
                        ))
                        codexModuleSwitchRow("自定义 CSS / JS", subtitle: "加载 user/ 目录个人样式与脚本", isOn: Binding(
                            get: { codexThemeManager.config.moduleCustomAssets },
                            set: { v in codexThemeManager.updateConfig { $0.moduleCustomAssets = v } }
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(codexThemeManager.isInstalled ? 1.0 : 0.65)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let err = codexThemeManager.lastError {
                Text(err)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            } else if let msg = codexThemeManager.statusMessage {
                Text(msg)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.green)
                    .lineLimit(2)
            }

            Divider().overlay(theme.dividerColor.opacity(0.28))

            // 底部贴底操作区 + MIT 开源致谢
            HStack(spacing: 8) {
                if !codexThemeManager.isInstalled {
                    Button {
                        codexThemeManager.installFromBundle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: codexThemeManager.isBusy ? "hourglass" : "arrow.down.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(codexThemeManager.isBusy ? "正在部署..." : "一键安装（内置离线包）")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.indigo))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(codexThemeManager.isBusy || codexThemeManager.runtimeInfo == nil)
                } else {
                    Button {
                        codexThemeManager.relaunchAntigravityWithCDP()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: codexThemeManager.isBusy
                                  ? "hourglass"
                                  : (isReadyPillState ? "checkmark.circle.fill" : "arrow.clockwise.circle.fill"))
                                .font(.system(size: 12, weight: .bold))
                            Text(codexThemeManager.isBusy
                                 ? "处理中..."
                                 : (isReadyPillState ? "已就绪" : "重启 Antigravity 激活"))
                                .font(.system(size: isReadyPillState ? 13 : 12.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(isReadyPillState ? Color.green : (needsRelaunch ? Color.white : theme.primaryText))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(isReadyPillState ? Color.green.opacity(0.14) : (needsRelaunch ? Color.orange : theme.pillFill))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            isReadyPillState ? Color.green.opacity(0.35) : (needsRelaunch ? Color.clear : theme.studioCardBorder),
                                            lineWidth: 0.8
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(isReadyPillState || codexThemeManager.isBusy)

                    if codexThemeManager.updateAvailable {
                        Button {
                            codexThemeManager.applyOnlineUpdate()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("立即在线更新")
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.indigo))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(codexThemeManager.isBusy)
                    } else {
                        Button {
                            codexThemeManager.checkForOnlineUpdates()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.system(size: 12))
                                Text(codexThemeManager.isCheckingUpdate ? "检查中..." : "检查更新")
                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(codexThemeManager.isBusy || codexThemeManager.isCheckingUpdate)
                    }

                    Button {
                        codexThemeManager.isMoreMenuPresented.toggle()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(theme.primaryText)
                            .frame(width: 36, height: 34)
                            .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("更多操作")
                    .popover(isPresented: $codexThemeManager.isMoreMenuPresented, arrowEdge: .top) {
                        codexMoreActionsPopover
                    }
                }

                Button {
                    codexThemeManager.openGitHubRepo()
                } label: {
                    HStack(spacing: 4) {
                        Text("GitHub · MIT")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .padding(.leading, 2)
                .help("nkjDSLcvanv/antigravity-codex-theme (MIT) · 在浏览器打开 GitHub 仓库")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var codexMoreActionsPopover: some View {
        VStack(alignment: .leading, spacing: 3) {
            codexPopoverMenuRow(
                icon: "arrow.clockwise.circle",
                title: "重启 Antigravity 激活",
                tint: .indigo,
                disabled: codexThemeManager.isBusy
            ) {
                codexThemeManager.relaunchAntigravityWithCDP()
            }

            codexPopoverMenuRow(
                icon: "wrench.and.screwdriver",
                title: "重新安装 / 修复",
                tint: .indigo,
                disabled: codexThemeManager.isBusy
            ) {
                codexThemeManager.installFromBundle()
            }

            codexPopoverMenuRow(
                icon: "folder",
                title: "打开配置目录",
                tint: .indigo,
                disabled: false
            ) {
                codexThemeManager.openInstallFolder()
            }

            Divider()
                .padding(.vertical, 2)

            codexPopoverMenuRow(
                icon: "trash",
                title: "卸载扩展",
                tint: .red,
                textColor: .red,
                disabled: codexThemeManager.isBusy
            ) {
                codexThemeManager.uninstallPlugin()
            }
        }
        .padding(6)
        .frame(width: 192)
    }

    private func codexPopoverMenuRow(
        icon: String,
        title: String,
        tint: Color,
        textColor: Color? = nil,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            codexThemeManager.isMoreMenuPresented = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(textColor ?? theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }

    private func codexModuleSwitchRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .toggleStyle(AlwaysTintedSwitchToggleStyle(tint: .indigo))
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.pillFill.opacity(0.42))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.45), lineWidth: 0.5))
        )
    }

    private func antigravityMetaTile(
        label: String,
        value: String,
        valueColor: Color? = nil,
        isSemibold: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12.5, weight: isSemibold ? .semibold : .regular, design: isSemibold ? .rounded : .monospaced))
                .foregroundStyle(valueColor ?? theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.pillFill.opacity(0.45))
        )
    }

    private func antigravityBytePatchChip(_ edit: AntigravityBinaryEdit) -> some View {
        HStack(spacing: 5) {
            Text("0x\(String(edit.fileOffset, radix: 16))")
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 2)
            Text("\(edit.originalHex) → \(edit.replacementHex)")
                .fontWeight(.semibold)
                .foregroundStyle(edit.originalBytes == edit.replacementBytes ? Color.green : Color.cyan)
                .lineLimit(1)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.pillFill.opacity(0.38))
        )
    }

    private func antigravityBytePatchGrid(_ edits: [AntigravityBinaryEdit]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 7),
                GridItem(.flexible(), spacing: 7)
            ],
            spacing: 6
        ) {
            ForEach(edits) { edit in
                antigravityBytePatchChip(edit)
            }
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("[DEBUG") {
            return Color.orange.opacity(0.92)
        }
        if line.contains("[成功]") || line.contains("[就绪]") || line.contains("[ACCEPTED]") || line.contains("[ACTIVE]") || line.contains("[SUCCESS]") || line.contains("🎉") || line.contains("✅") {
            return Color.green
        }
        if line.contains("[注入]") || line.contains("[响应]") || line.contains("[路由]") || line.contains("[识别]") || line.contains("[PATCH]") || line.contains("[FORWARD]") || line.contains("🚀") || line.contains("🎯") {
            return Color.cyan
        }
        if line.contains("[警告]") || line.contains("[准备]") || line.contains("[指引]") || line.contains("[诊断]") || line.contains("[WARNING]") || line.contains("[WAITING]") || line.contains("⚡️") || line.contains("⚠️") {
            return Color.yellow
        }
        if line.contains("[错误]") || line.contains("[失败]") || line.contains("[ERROR]") || line.contains("❌") || line.contains("Traceback") || line.contains("Error") {
            return Color.red
        }
        return Color.white.opacity(0.92)
    }
}
