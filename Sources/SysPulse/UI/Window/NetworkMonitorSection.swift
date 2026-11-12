import SwiftUI
import AppKit

// MARK: - 网络监控视图

public struct NetworkMonitorSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var vm = NetworkMonitorViewModel.shared
    @Bindable var model = NetworkDetailModel.shared
    @Bindable var speedTest = NetworkSpeedTest.shared
    @Bindable var wifiLL = WiFiLowLatencyManager.shared
    @Bindable var monitor = SystemResourceMonitor.shared

    let theme: LiquidGlassTheme
    var canvasWidth: CGFloat = 1200
    var canvasHeight: CGFloat = 822

    private var contentW: CGFloat { max(1152, canvasWidth - 48) }
    private var contentH: CGFloat { max(682, canvasHeight - 79 - 59) }
    private var workspaceH: CGFloat { max(562, contentH - 120) }
    private var leftColW: CGFloat { max(370, round((contentW - 14) * (370.0 / 1138.0))) }
    private var rightColW: CGFloat { max(768, (contentW - 14) - leftColW) }
    private var leftCard1H: CGFloat { max(198, round((workspaceH - 28) * (198.0 / 534.0))) }
    private var leftCard2H: CGFloat { max(168, round((workspaceH - 28 - leftCard1H) / 2.0)) }
    private var leftCard3H: CGFloat { max(168, (workspaceH - 28) - leftCard1H - leftCard2H) }
    private var rightUpperH: CGFloat { max(160, round((workspaceH - 14) * (160.0 / 548.0))) }
    private var rightLowerH: CGFloat { max(388, (workspaceH - 14) - rightUpperH) }
    private var latencyCardW: CGFloat { max(372, round((rightColW - 28) * (372.0 / 740.0))) }
    private var waveCardW: CGFloat { max(181, (rightColW - 28 - latencyCardW) / 2.0) }

    public init(theme: LiquidGlassTheme, canvasWidth: CGFloat = 1200, canvasHeight: CGFloat = 822) {
        self.theme = theme
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    public var body: some View {
        VStack(spacing: 14) {
            headerBar
                .frame(width: contentW, alignment: .leading)

            // 硬件链路状态条
            hardwareTelemetryStrip

            // 双列监控卡片区
            HStack(alignment: .top, spacing: 14) {
                leftColumnCards
                    .frame(width: leftColW, height: workspaceH)

                rightColumnCards
                    .frame(width: rightColW, height: workspaceH)
            }
            .frame(width: contentW, height: workspaceH)
        }
        .frame(width: contentW, height: contentH)
        .padding(.horizontal, 24)
        .padding(.top, 35)
        .padding(.bottom, 24)
        .onAppear {
            model.refresh()
            vm.refreshRealTraffic(iface: model.activeInterfaceName)
            vm.measureRealLatencies(gatewayIP: model.gatewayIP)
            model.refreshActiveSockets(syncSummaryTo: vm)
        }
        .task {
            // 每 3.0 秒合并刷新活跃连接与进程流量，共享单次 lsof 避免重复子进程；每 9.0 秒刷新链路延迟
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                tick += 1
                vm.refreshRealTraffic(iface: model.activeInterfaceName)
                model.refreshAppNetworkUsage()
                model.refreshActiveSockets(syncSummaryTo: vm)
                if tick % 3 == 0 {
                    vm.measureRealLatencies(gatewayIP: model.gatewayIP)
                }
            }
        }
    }

    // MARK: - 1. 顶部标题栏

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("网络监控")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("带宽流量去向一目了然，快捷搞定测速与诊断。")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()
        }
    }

    // MARK: - 左列：网络详情、活动连接与累计流量

    private var leftColumnCards: some View {
        VStack(spacing: 14) {
            networkDetailsCard
                .frame(width: leftColW, height: leftCard1H)

            activeSocketsCard
                .frame(width: leftColW, height: leftCard2H)

            totalTrafficCard
                .frame(width: leftColW, height: leftCard3H)
        }
    }

    private var networkDetailsCard: some View {
        let edgeInset: CGFloat = 12
        return cardContainer(height: leftCard1H, padding: edgeInset) {
            VStack(alignment: .leading, spacing: edgeInset) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.cyan)
                        Text("网络详情")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                    Text(model.vpnStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(model.isVPNActive ? Color(red: 0.55, green: 0.55, blue: 0.95) : Color.cyan)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill((model.isVPNActive ? Color(red: 0.55, green: 0.55, blue: 0.95) : Color.cyan).opacity(0.12)))
                }

                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: 当前网络 (SSID)
                    infoTableRow(label: "当前网络", verticalPadding: 3.5) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 5.5, height: 5.5)
                            Text(model.ssid)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                        }
                    }

                    // Row 2: 内网 IP
                    infoTableRow(label: "内网 IP", verticalPadding: 3.5) {
                        Text(model.localIPv4)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                    }

                    // Row 3: 外网 IP
                    infoTableRow(label: "外网 IP", verticalPadding: 3.5) {
                        Text(model.publicIP)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                    }

                    // Row 4: 网关 IP
                    infoTableRow(label: "网关 IP", verticalPadding: 3.5) {
                        Text(model.gatewayIP)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                    }

                    // Row 5: DNS (默认显示物理网卡主 DNS)
                    infoTableRow(label: "DNS", verticalPadding: 3.5) {
                        Text(model.primaryDNS)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var activeSocketsCard: some View {
        cardContainer(height: leftCard2H) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("活动连接")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    let statusColor = vm.isConnectionCountNormal ? Color(red: 0.35, green: 0.85, blue: 0.55) : Color.orange
                    HStack(spacing: 4.5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6.5, height: 6.5)
                        Text(vm.connectionStatusText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(statusColor)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(vm.activeSocketCount)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("个活跃 TCP/UDP 连接")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                HStack(spacing: 0) {
                    metricItem(value: "\(vm.activeProcessCount)", label: "活跃进程")
                    Divider()
                        .frame(height: 26)
                        .overlay(theme.dividerColor.opacity(0.4))
                    metricItem(value: "\(vm.activeInterfaceCount)", label: "网卡接口")
                    Divider()
                        .frame(height: 26)
                        .overlay(theme.dividerColor.opacity(0.4))
                    metricItem(value: String(format: "%.0f%%", vm.packetLossPercent), label: "丢包率", valueColor: Color(red: 0.35, green: 0.85, blue: 0.55))
                }
                .padding(.top, 6)
                .border(width: 0.8, edges: [.top], color: theme.dividerColor.opacity(0.3))
            }
        }
    }

    private var totalTrafficCard: some View {
        cardContainer(height: leftCard3H) {
            VStack(alignment: .leading, spacing: 6) {
                // Header & Segment Picker
                HStack {
                    Text("累计传输流量")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(TrafficTimeRange.allCases) { range in
                            let isSel = (vm.selectedTimeRange == range)
                            Button {
                                vm.selectedTimeRange = range
                            } label: {
                                Text(range.rawValue)
                                    .font(.system(size: 10.5, weight: isSel ? .bold : .medium))
                                    .foregroundStyle(isSel ? theme.primaryText : theme.secondaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(isSel ? (colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                    .padding(2)
                    .background(
                        Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(vm.currentTotalNumberFormatted)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(vm.currentTotalUnitText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                // 上下行流量占比进度条
                VStack(spacing: 6) {
                    HStack {
                        HStack(spacing: 4) {
                            Circle().fill(Color.cyan).frame(width: 5.5, height: 5.5)
                            Text("下行传入: \(vm.currentDownloadFormatted) (\(Int(vm.currentDownloadRatio * 100))%)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(Color(red: 0.55, green: 0.55, blue: 0.95)).frame(width: 5.5, height: 5.5)
                            Text("上行传出: \(vm.currentUploadFormatted) (\(Int(vm.currentUploadRatio * 100))%)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }

                    GeometryReader { geo in
                        let w = geo.size.width
                        let downW = max(5.0, w * CGFloat(vm.currentDownloadRatio))
                        let upW = max(5.0, w * CGFloat(vm.currentUploadRatio))

                        HStack(spacing: 2) {
                            Capsule()
                                .fill(Color.cyan)
                                .frame(width: downW, height: 6)
                            Capsule()
                                .fill(Color(red: 0.55, green: 0.55, blue: 0.95))
                                .frame(width: upW, height: 6)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    // MARK: - 右列：实时速率、延迟测速与流量排行

    private var rightColumnCards: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                internetLatencyCard
                    .frame(width: latencyCardW, height: rightUpperH)

                realtimeUploadCard
                    .frame(width: waveCardW, height: rightUpperH)

                realtimeDownloadCard
                    .frame(width: waveCardW, height: rightUpperH)
            }
            .frame(width: rightColW, height: rightUpperH)

            trafficHistogramAndRankingCard
                .frame(width: rightColW, height: rightLowerH)
        }
    }

    // 链路延迟与网络测速卡片
    private var internetLatencyCard: some View {
        cardContainer(height: rightUpperH) {
            ZStack {
                if vm.isSpeedTestCardActive {
                    speedTestCardContent
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity.combined(with: .scale(scale: 0.95))
                        ))
                } else {
                    latencyCardContent
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity.combined(with: .scale(scale: 0.95))
                        ))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: vm.isSpeedTestCardActive)
        }
    }

    // INTERNET 延迟内容视图
    private var latencyCardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Text("INTERNET 延迟")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Button {
                        vm.measureRealLatencies(gatewayIP: model.gatewayIP)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText)
                            .rotationEffect(.degrees(vm.isMeasuringLatency ? 360 : 0))
                            .animation(vm.isMeasuringLatency ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: vm.isMeasuringLatency)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        vm.isSpeedTestCardActive = true
                    }
                    speedTest.startTest()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9.5))
                        Text("立即测速")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.cyan))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(vm.internetPingMs)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("ms")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 4)

            // 路由网关与 DNS 解析延迟
            HStack(spacing: 0) {
                latencySubCell(title: "路由网关", ms: vm.routerPingText)
                Divider().frame(height: 24).overlay(theme.dividerColor.opacity(0.4))
                latencySubCell(title: "DNS 解析", ms: vm.dnsPingText)
            }
            .padding(.top, 6)
            .border(width: 0.8, edges: [.top], color: theme.dividerColor.opacity(0.3))
        }
    }

    // 网络测速面板
    private var speedTestCardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.cyan)
                    Text("网络测速")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    if speedTest.isRunning {
                        HStack(spacing: 3.5) {
                            Circle().fill(Color.cyan).frame(width: 5, height: 5)
                            Text("测速中…")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.cyan)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.cyan.opacity(0.12)))
                    } else if speedTest.downloadMbps > 0 {
                        Text("测速完成")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.55))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.12)))
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if !speedTest.isRunning && speedTest.downloadMbps > 0 {
                        Button {
                            speedTest.startTest()
                        } label: {
                            HStack(spacing: 3.5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text("重测")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .frame(width: 58, height: 22)
                            .background(Capsule().fill(Color.orange))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }

                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            vm.isSpeedTestCardActive = false
                        }
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("返回")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .frame(width: 58, height: 22)
                        .background(Capsule().fill(Color.cyan))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }

            // Body: Measuring Animation or Completed Results
            if speedTest.isRunning {
                speedTestMeasuringAnimationView
            } else if speedTest.downloadMbps > 0 {
                speedTestResultView
            } else if let error = speedTest.errorMessage {
                VStack(spacing: 8) {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.orange)
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Button {
                        speedTest.startTest()
                    } label: {
                        Text("点击重试")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.cyan)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 6) {
                    Spacer()
                    Text("点击上方测速按钮开启双向吞吐量测试")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // 测速进行中状态视图
    private var speedTestMeasuringAnimationView: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 2)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .inset(by: 2)
                        .stroke(colorScheme == .dark ? Color.cyan.opacity(0.30) : Color.cyan.opacity(0.20), lineWidth: 3.0)

                    Circle()
                        .inset(by: 2)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.cyan.opacity(0.15),
                                    Color.cyan.opacity(0.6),
                                    Color.cyan,
                                    Color(red: 0.55, green: 0.6, blue: 1.0),
                                    Color.cyan.opacity(0.15)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3.0, lineCap: .round)
                        )
                        .rotationEffect(.degrees(speedTest.progressSeconds * 240))

                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(width: 32, height: 32)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.cyan)
                        .scaleEffect(1.0 + 0.08 * sin(speedTest.progressSeconds * 4))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3.5) {
                    Text("正在测速…")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("动态吞吐:")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                        Text("↓ \(speedTest.liveDownloadSpeedFormatted)   ↑ \(speedTest.liveUploadSpeedFormatted)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.cyan)
                    }

                    GeometryReader { geo in
                        let p = min(1.0, max(0.06, speedTest.progressSeconds / 8.0))
                        ZStack(alignment: .leading) {
                            Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [Color.cyan, Color(red: 0.55, green: 0.55, blue: 0.95)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(p))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(.vertical, 2)

            Spacer(minLength: 2)

            // 测速底部信息条
            HStack {
                Text("基于 Apple networkQuality 官方双向测速规范")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                Spacer()
                Text(String(format: "已耗时 %.1fs", speedTest.progressSeconds))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.top, 4)
            .border(width: 0.8, edges: [.top], color: theme.dividerColor.opacity(0.3))
        }
    }

    // 测速完成结果视图
    private var speedTestResultView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 1)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3.5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.cyan)
                        Text("下载带宽")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.1f", speedTest.downloadMbps))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cyan)
                        Text("Mbps")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 32)
                    .overlay(theme.dividerColor.opacity(0.4))
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3.5) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.95))
                        Text("上传带宽")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.1f", speedTest.uploadMbps))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.95))
                        Text("Mbps")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 2)

            HStack(spacing: 0) {
                latencySubCell(title: "基准时延", ms: String(format: "%.0f", speedTest.latencyMs))
                Divider().frame(height: 24).overlay(theme.dividerColor.opacity(0.4))
                latencySubCell(
                    title: "响应质量",
                    ms: speedTest.responsivenessRPM > 0 ? String(format: "%.0f", speedTest.responsivenessRPM) : "--",
                    unit: "RPM"
                )
            }
            .padding(.top, 4)
            .border(width: 0.8, edges: [.top], color: theme.dividerColor.opacity(0.3))
        }
    }

    private func latencySubCell(title: String, ms: String, unit: String = "ms", highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            HStack(spacing: 2) {
                Text(ms)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(highlight ? Color.cyan : theme.primaryText)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // Upper Card 2: 实时上传
    private var realtimeUploadCard: some View {
        let parts = monitor.hardware.uploadSpeedParts
        return cardContainer(height: rightUpperH) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("实时上传")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("峰值 \(peakUploadFormatted)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(parts.value)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(parts.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                SingleSparklineWave(
                    history: monitor.hardware.networkHistoryUpload,
                    color: Color(red: 0.55, green: 0.55, blue: 0.95)
                )
                .frame(height: max(56, 56 + (rightUpperH - 160)))
            }
        }
    }

    // Upper Card 3: 实时下载
    private var realtimeDownloadCard: some View {
        let parts = monitor.hardware.downloadSpeedParts
        return cardContainer(height: rightUpperH) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("实时下载")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("峰值 \(peakDownloadFormatted)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(parts.value)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cyan)
                    Text(parts.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 4)

                SingleSparklineWave(
                    history: monitor.hardware.networkHistoryDownload,
                    color: Color.cyan
                )
                .frame(height: max(56, 56 + (rightUpperH - 160)))
            }
        }
    }

    // Lower Card: 24h Histogram + App Ranking / Active Sockets
    private var trafficHistogramAndRankingCard: some View {
        cardContainer(height: rightLowerH) {
            VStack(alignment: .leading, spacing: 10) {
                // 当日 24 小时流量分布柱状图
                VStack(spacing: 5) {
                    HStack {
                        Text("当日流量趋势")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Text(vm.peakHourVolumeFormatted)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.cyan)
                    }

                    GeometryReader { geo in
                        let maxVal = max(10.0, vm.hourlyTrafficMB.max() ?? 100.0)
                        let barW = (geo.size.width - CGFloat(vm.hourlyTrafficMB.count - 1) * 3.5) / CGFloat(vm.hourlyTrafficMB.count)

                        HStack(alignment: .bottom, spacing: 3.5) {
                            ForEach(0..<vm.hourlyTrafficMB.count, id: \.self) { idx in
                                let val = vm.hourlyTrafficMB[idx]
                                let ratio = val > 0 ? max(0.08, CGFloat(val / maxVal)) : 0.04
                                let isPeak = (idx == vm.peakHourIndex && val > 0)

                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(
                                        isPeak
                                        ? LinearGradient(colors: [Color.cyan, Color(red: 0.35, green: 0.85, blue: 0.95)], startPoint: .bottom, endPoint: .top)
                                        : (val > 0
                                            ? LinearGradient(colors: [Color.cyan.opacity(0.40), Color.cyan.opacity(0.20)], startPoint: .bottom, endPoint: .top)
                                            : LinearGradient(colors: [Color.cyan.opacity(0.12), Color.cyan.opacity(0.06)], startPoint: .bottom, endPoint: .top))
                                    )
                                    .frame(width: max(2, barW), height: geo.size.height * ratio)
                                    .help("\(idx):00 - \(idx):59: \(String(format: val >= 1024 ? "%.2f GB" : "%.0f MB", val >= 1024 ? val / 1024.0 : val))")
                            }
                        }
                    }
                    .frame(height: 76)

                    HStack {
                        Text("00:00")
                        Spacer()
                        Text("06:00")
                        Spacer()
                        Text("12:00")
                        Spacer()
                        Text("18:00")
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                }

                Divider()
                    .overlay(theme.dividerColor.opacity(0.35))
                    .padding(.vertical, 2)

                // Section B: App Traffic Ranking / Active Sockets
                VStack(spacing: 7) {
                    HStack {
                        HStack(spacing: 3) {
                            ForEach(AppRankingSubTab.allCases) { tab in
                                let isSel = (vm.selectedRankingTab == tab)
                                Button {
                                    vm.selectedRankingTab = tab
                                } label: {
                                    Text(tab.rawValue)
                                        .font(.system(size: 11, weight: isSel ? .bold : .medium))
                                        .foregroundStyle(isSel ? theme.primaryText : theme.secondaryText)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 3.5)
                                        .background(
                                            Capsule().fill(isSel ? (colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)) : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .pointingHandOnHover()
                            }
                        }
                        .padding(2)
                        .background(
                            Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                        )

                        Spacer()

                        if vm.selectedRankingTab == .apps {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    vm.appTrafficSortMode = (vm.appTrafficSortMode == .today ? .month : .today)
                                }
                            } label: {
                                HStack(spacing: 3.5) {
                                    Text(vm.appTrafficSortMode.rawValue)
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.system(size: 8.5, weight: .bold))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(Color.cyan.opacity(colorScheme == .dark ? 0.14 : 0.08))
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                            .help("点击切换当日/当月累计流量排序")
                        } else {
                            Button {
                                ActiveConnectionsWindowController.shared.show()
                            } label: {
                                HStack(spacing: 3) {
                                    Text("显示更多")
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.system(size: 9.5))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(Color.cyan.opacity(colorScheme == .dark ? 0.14 : 0.08))
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            if vm.selectedRankingTab == .apps {
                                let displayList = (vm.appTrafficSortMode == .month && !model.monthAppNetworkItems.isEmpty) ? model.monthAppNetworkItems : model.appNetworkItems
                                if displayList.isEmpty {
                                    HStack {
                                        Spacer()
                                        ProgressView().controlSize(.small)
                                        Text("正在读取系统应用网络数据…")
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.secondaryText)
                                        Spacer()
                                    }
                                    .frame(height: 180)
                                } else {
                                    ForEach(displayList) { app in
                                        appRowView(app: app)
                                    }
                                }
                            } else {
                                if model.activeSockets.isEmpty {
                                    HStack {
                                        Spacer()
                                        ProgressView().controlSize(.small)
                                        Text("正在扫描内核活动连接…")
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.secondaryText)
                                        Spacer()
                                    }
                                    .frame(height: 180)
                                } else {
                                    ForEach(model.activeSockets) { socket in
                                        socketRowView(socket: socket)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: max(180, 180 + (rightLowerH - 388)))
                }
            }
        }
    }

    private func appRowView(app: AppNetworkItem) -> some View {
        HStack(spacing: 9) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(Color.cyan.opacity(0.15))
                    Image(systemName: "app.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.cyan)
                }
                .frame(width: 20, height: 20)
            }

            Text(app.name)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            if app.pid > 0 {
                Text("(PID \(app.pid))")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Text("↓ \(app.downloadSpeedFormatted) · ↑ \(app.uploadSpeedFormatted)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.secondaryText)

            Text(app.totalTrafficFormatted)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025))
        )
    }

    private func socketRowView(socket: ActiveSocketItem) -> some View {
        let isTCP = socket.proto == "TCP"
        let stateColor: Color = {
            switch socket.state {
            case "ESTABLISHED": return Color(red: 0.35, green: 0.85, blue: 0.55)
            case "LISTEN": return Color.blue
            case "SYN_SENT": return Color.orange
            default: return theme.secondaryText
            }
        }()

        return HStack(spacing: 8) {
            Text(socket.proto)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isTCP ? Color.blue : Color.purple)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(
                    Capsule().fill((isTCP ? Color.blue : Color.purple).opacity(0.15))
                )

            Text(socket.processName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            Text("(PID \(socket.pid))")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.secondaryText)

            Spacer()

            HStack(spacing: 3) {
                Text(socket.localAddress)
                if !socket.remoteAddress.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                    Text(socket.remoteAddress)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)

            HStack(spacing: 3.5) {
                Circle().fill(stateColor).frame(width: 4.5, height: 4.5)
                Text(socket.state == "ESTABLISHED" ? "已连接" : (socket.state == "LISTEN" ? "监听中" : socket.state))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(stateColor)
            }
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(stateColor.opacity(0.12))
            )
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025))
        )
    }

    // MARK: - 2. 硬件链路参数状态条

    private var hardwareTelemetryStrip: some View {
        HStack(spacing: 18) {
            telemetryPill(label: "硬件网卡", value: "\(model.activeInterfaceName) (\(model.link))")
            telemetryPill(label: "无线协议", value: model.wifiProtocol)
            telemetryPill(label: "频段与信道", value: "\(model.frequencyBand) · 信道 \(model.channel)")
            telemetryPill(label: "物理协商速率", value: String(format: "%.0f Mbps", model.txRate))
            signalPill

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
                Text(wifiLL.isLowLatencyActive ? "AWDL 低延迟直连已开启" : "AWDL 直连待命")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: contentW, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                )
        )
    }

    private var signalPill: some View {
        HStack(spacing: 5) {
            Text("信号强度:")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.secondaryText)
            Text("\(model.signalDbm) dBm")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
        }
    }

    private var signalStrengthColor: Color {
        switch model.signal {
        case "极强", "强":
            return Color(red: 0.35, green: 0.85, blue: 0.55)
        case "中":
            return Color.yellow
        case "弱":
            return Color.orange
        default:
            return theme.secondaryText
        }
    }

    private func telemetryPill(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Text("\(label):")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor ?? theme.primaryText)
        }
    }

    // MARK: - Helper Components

    private func infoTableRow<Content: View>(label: String, verticalPadding: CGFloat = 5, expandVertically: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 60, alignment: .leading)
            Spacer()
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, verticalPadding)
        .frame(maxHeight: expandVertically ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025))
        )
    }

    private func metricItem(value: String, label: String, valueColor: Color? = nil) -> some View {
        VStack(spacing: 2.5) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor ?? theme.primaryText)
            Text(label)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var peakUploadFormatted: String {
        let maxBps = monitor.hardware.networkHistoryUpload.max() ?? 0.0
        return formatSpeed(max(maxBps, monitor.hardware.networkUploadBytesPerSec))
    }

    private var peakDownloadFormatted: String {
        let maxBps = monitor.hardware.networkHistoryDownload.max() ?? 0.0
        return formatSpeed(max(maxBps, monitor.hardware.networkDownloadBytesPerSec))
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024.0 * 1024.0 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024.0 * 1024.0))
        } else if bytesPerSec >= 1024.0 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else {
            return "< 1 KB/s"
        }
    }

    private func cardContainer<Content: View>(height: CGFloat, padding: CGFloat = 13, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(padding)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                    )
            )
    }
}

// MARK: - Waveform View

public struct SingleSparklineWave: View {
    let history: [Double]
    let color: Color

    public var body: some View {
        GeometryReader { geo in
            let points = normalizedPoints(width: geo.size.width, height: geo.size.height)
            ZStack {
                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    path.addLine(to: points[0])
                    for i in 1..<points.count {
                        path.addLine(to: points[i])
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: points[0])
                    for i in 1..<points.count {
                        path.addLine(to: points[i])
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func normalizedPoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard !history.isEmpty else {
            return [CGPoint(x: 0, y: height * 0.7), CGPoint(x: width, y: height * 0.7)]
        }
        let maxVal = max(1024.0, history.max() ?? 1024.0)
        let step = width / CGFloat(max(1, history.count - 1))

        return history.enumerated().map { idx, val in
            let ratio = CGFloat(val / maxVal)
            let y = height * (1.0 - max(0.08, min(0.92, ratio)))
            return CGPoint(x: CGFloat(idx) * step, y: y)
        }
    }
}

// MARK: - Border Helper Extension

extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(
            EdgeBorder(width: width, edges: edges).foregroundColor(color)
        )
    }
}

struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat {
                switch edge {
                case .top, .bottom, .leading: return rect.minX
                case .trailing: return rect.maxX - width
                }
            }
            var y: CGFloat {
                switch edge {
                case .top, .leading, .trailing: return rect.minY
                case .bottom: return rect.maxY - width
                }
            }
            var w: CGFloat {
                switch edge {
                case .top, .bottom: return rect.width
                case .leading, .trailing: return width
                }
            }
            var h: CGFloat {
                switch edge {
                case .top, .bottom: return width
                case .leading, .trailing: return rect.height
                }
            }
            path.addRect(CGRect(x: x, y: y, width: w, height: h))
        }
        return path
    }
}
