import SwiftUI
import AppKit

// MARK: - 网络详情与测速面板

public struct NetworkDetailCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model = NetworkDetailModel.shared
    @Bindable var speedTest = NetworkSpeedTest.shared
    @Bindable var wifiLL = WiFiLowLatencyManager.shared

    var onDismiss: () -> Void

    private var theme: LiquidGlassTheme {
        LiquidGlassTheme(colorScheme: colorScheme)
    }

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 9) {
            headerBar
                .padding(.horizontal, 2)

            VStack(spacing: 11) {
                speedTestCard
                networkInfoCard
                appNetworkUsageCard
            }

            Divider()
                .overlay(theme.dividerColor.opacity(0.35))
                .padding(.top, 4)

            openSysPulseFooterButton
        }
        .padding(12)
        .frame(width: 334)
        .onAppear {
            model.refresh()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                model.refresh()
            }
        }
    }

    // MARK: - 顶部标题栏

    private var headerBar: some View {
        ZStack {
            Text("网络与测速")
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            HStack {
                Button(action: onDismiss) {
                    HStack(spacing: 3.5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("返回")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Spacer()

                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .padding(5.5)
                        .background(
                            Circle().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("刷新网络状态")
            }
        }
        .frame(height: 28)
    }

    // MARK: - 1. 网络测速卡片

    private var speedTestCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                    Text("测速")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }

                Spacer()

                speedTestActionButton
            }

            ZStack {
                if speedTest.isRunning {
                    speedTestMeasuringAnimationView
                } else {
                    speedTestResultGrid
                }
            }
            .frame(height: 104)
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(cardBackground)
    }

    private var speedTestResultGrid: some View {
        VStack(spacing: 5) {
            if let error = speedTest.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.orange)
                    Text(error)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.vertical, 1)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 7) {
                metricCell(
                    icon: "arrow.down.circle.fill",
                    title: "下载",
                    value: speedTest.downloadMbps > 0 ? String(format: "%.1f", speedTest.downloadMbps) : "--",
                    unit: "Mbps",
                    tint: Color(red: 0.35, green: 0.85, blue: 0.55)
                )
                metricCell(
                    icon: "arrow.up.circle.fill",
                    title: "上传",
                    value: speedTest.uploadMbps > 0 ? String(format: "%.1f", speedTest.uploadMbps) : "--",
                    unit: "Mbps",
                    tint: Color.cyan
                )
                metricCell(
                    icon: "clock.arrow.circlepath",
                    title: "空载延迟",
                    value: speedTest.latencyMs > 0 ? String(format: "%.0f", speedTest.latencyMs) : "--",
                    unit: "ms",
                    tint: Color.orange
                )
                metricCell(
                    icon: "bolt.horizontal.circle.fill",
                    title: "满载响应",
                    value: speedTest.responsivenessRPM > 0 ? "\(Int(speedTest.responsivenessRPM))" : "--",
                    unit: "RPM",
                    tint: Color.purple
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - 测速动态指示器

    private var speedTestMeasuringAnimationView: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
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
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.cyan)
                        .scaleEffect(1.0 + 0.08 * sin(speedTest.progressSeconds * 4))
                }
                .frame(width: 44, height: 44)
                .padding(.leading, 2)

                VStack(alignment: .leading, spacing: 3.5) {
                    Text("正在测速…")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text("动态吞吐")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                        Text("↓ \(speedTest.liveDownloadSpeedFormatted)  ↑ \(speedTest.liveUploadSpeedFormatted)")
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
                    .frame(height: 4.5)
                }
            }

            Divider()
                .overlay(theme.dividerColor.opacity(0.35))
                .padding(.vertical, 1)

            // 测速底部计时与引擎声明
            HStack {
                Text("Apple networkQuality 官方测速引擎")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                Spacer()
                Text(String(format: "已耗时 %.1fs", speedTest.progressSeconds))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var speedTestActionButton: some View {
        Group {
            if speedTest.isRunning {
                Button(action: { speedTest.cancelTest() }) {
                    Text("取消")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.red.opacity(0.12))
                        )
                }
            } else if speedTest.downloadMbps > 0 {
                Button(action: { speedTest.startTest() }) {
                    Text("重新测速")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.cyan.opacity(0.15))
                        )
                }
            } else {
                Button(action: { speedTest.startTest() }) {
                    Text("开始测速")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(Color.cyan)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func metricCell(icon: String, title: String, value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(unit)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
        )
    }

    // MARK: - 2. 链路与网络属性卡片

    private var networkInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                    Text("链路与 IP 详情")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }
                Spacer()
            }

            VStack(spacing: 7) {
                infoRow(key: "IPv4", label: "内网 IP", value: model.localIPv4)
                infoRow(key: "publicIP", label: "外网 IP", value: model.publicIP)
                infoRow(key: "gateway", label: "网关 IP", value: model.gatewayIP)
                infoRow(key: "dns", label: "DNS", value: model.primaryDNS)
                infoRow(key: "proxy", label: "代理", value: model.proxy)
                infoRow(key: "link", label: "链路类型", value: model.link)
                if model.link.contains("以太网") {
                    infoRow(key: "txRate", label: "协商速率", value: "\(Int(model.txRate)) Mbps")
                } else if model.isSignalAvailable {
                    infoRow(key: "protocol", label: "无线协议", value: "\(model.wifiProtocol) · \(model.frequencyBand)")
                    infoRow(key: "signal", label: "信号强度", value: "\(model.signal) (\(model.signalDbm) dBm)")
                }
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private func infoRow(key: String, label: String, value: String) -> some View {
        Button {
            model.copyRow(key: key, value: value)
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 64, alignment: .leading)

                Spacer()

                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                if model.copiedRowKey == key {
                    Text("已复制")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.green)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 3.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    // MARK: - 3. 应用流量排行卡片

    private var appNetworkUsageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                    Text("应用流量排行")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }

                Spacer()

                Text("当日累计")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
            }

            let top5Apps = Array(model.appNetworkItems.prefix(5))
            if top5Apps.isEmpty {
                Text("暂无应用网络活动")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 6) {
                    ForEach(top5Apps) { app in
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(Color.cyan.opacity(0.15))
                                    .frame(width: 20, height: 20)
                            }

                            Text(app.name)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)

                            Spacer()

                            Text("↓ \(app.downloadSpeedFormatted)  ↑ \(app.uploadSpeedFormatted)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)

                            Text(app.totalTrafficFormatted)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .frame(width: 60, alignment: .trailing)
                        }
                        .padding(.vertical, 4.5)
                    }
                }
            }

            Divider()
                .overlay(theme.dividerColor.opacity(0.35))
                .padding(.vertical, 2)

            // Shortcut to Main Window Network tab
            Button {
                MenuBarController.shared?.closePopover(deactivateApp: false)
                MainStudioWindowController.shared.showWindow(section: .networkMonitor)
            } label: {
                HStack(spacing: 4) {
                    Spacer()
                    Text("在网络监控中查看完整流量分析")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cyan)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.cyan)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
        .padding(12)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.8)
            )
    }

    // MARK: - 底部主窗口入口

    private var openSysPulseFooterButton: some View {
        Button {
            MenuBarController.shared?.closePopover(deactivateApp: false)
            MainStudioWindowController.shared.showWindow(section: .networkMonitor)
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
}
