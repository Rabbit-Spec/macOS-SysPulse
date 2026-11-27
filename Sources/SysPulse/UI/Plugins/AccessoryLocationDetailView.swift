import AppKit
import CoreLocation
import MapKit
import SwiftUI

public struct AccessoryLocationDetailView: View {
    @Bindable var manager = AccessoryLocationPluginManager.shared
    let theme: LiquidGlassTheme
    @Environment(\.colorScheme) private var colorScheme

    public init(theme: LiquidGlassTheme) {
        self.theme = theme
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                headerSummaryCard
                mapPickerColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlAndLogColumn
                .frame(width: 376)
                .frame(maxHeight: .infinity)
        }
        .onAppear {
            manager.refreshMFiStatus()
            manager.refreshDevices()
        }
    }

    // MARK: - 顶部概览与状态流

    private var headerSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                PluginArtworkIconView(
                    kind: .accessoryLocation,
                    size: 56,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("iOS 虚拟定位")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Text("iAP2 · MFi-v3")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.pink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.pink.opacity(0.14)))

                        if manager.isRunning {
                            Text(manager.stage.shortTitle)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(manager.stage == .streaming ? Color.green : Color.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill((manager.stage == .streaming ? Color.green : Color.orange).opacity(0.16))
                                )
                        }
                    }

                    HStack(spacing: 4) {
                        Text("开源项目：")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                        Button {
                            if let url = URL(string: "https://github.com/aur3l14no/accessory-location") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("https://github.com/aur3l14no/accessory-location")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.pink)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }

                    Text(manager.lastErrorMessage ?? manager.statusMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(manager.lastErrorMessage != nil ? Color.red : theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 10) {
                    if manager.isRunning && manager.remainingSeconds > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 11))
                            Text(formatCountdown(manager.remainingSeconds))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.pillFill))
                    }

                    Button {
                        manager.toggleSession()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: manager.isRunning ? "stop.fill" : "location.north.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(manager.isRunning ? "停止定位注入" : "启动定位注入")
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                manager.isRunning
                                    ? LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
                                    : LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(!manager.isRunning && (!manager.mfiStatus.isConfigured || manager.selectedDevice == nil))
                    .opacity((!manager.isRunning && (!manager.mfiStatus.isConfigured || manager.selectedDevice == nil)) ? 0.55 : 1.0)
                }
            }

            Divider().opacity(0.25)

            HStack(spacing: 5) {
                ForEach(AccessoryProtocolStage.allCases.filter { $0 != .idle }) { step in
                    stagePill(step)
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    statChip(label: "已发句", value: "\(manager.packetsSentCount)")
                    statChip(label: "更新", value: manager.lastSentTimeString)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private func stagePill(_ step: AccessoryProtocolStage) -> some View {
        let isCompleted = manager.stage.rawValue > step.rawValue
        let isCurrent = manager.stage == step && manager.isRunning
        let accent: Color = isCompleted ? .green : (isCurrent ? .pink : theme.secondaryText.opacity(0.5))

        return HStack(spacing: 4) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text("\(step.rawValue). \(step.title)")
                .font(.system(size: 10, weight: isCurrent ? .bold : .medium, design: .rounded))
                .foregroundStyle(isCurrent || isCompleted ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule()
                .fill(isCurrent ? accent.opacity(0.16) : theme.pillFill)
                .overlay(Capsule().strokeBorder(isCurrent ? accent.opacity(0.45) : Color.clear, lineWidth: 0.8))
        )
    }

    private func statChip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
        }
    }

    // MARK: - 左栏：地图选点、国内纠偏与收藏夹

    private var mapPickerColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 搜索栏
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                    TextField("搜索城市、街道或地标（点击地图任意点直接选点）", text: $manager.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit {
                            manager.searchPlace()
                        }
                    if !manager.searchQuery.isEmpty {
                        Button {
                            manager.searchQuery = ""
                            manager.searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.pillFill))

                Button {
                    manager.searchPlace()
                } label: {
                    HStack(spacing: 4) {
                        if manager.isSearchingPlace {
                            ProgressView().controlSize(.mini)
                        }
                        Text("搜索")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.pillFill))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            if !manager.searchResults.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(manager.searchResults) { item in
                            Button {
                                manager.selectSearchSuggestion(item)
                            } label: {
                                HStack {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(Color.pink)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(theme.primaryText)
                                        Text(item.subtitle)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(theme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(theme.pillFill))
                            }
                            .buttonStyle(.plain)
                            .pointingHandOnHover()
                        }
                    }
                }
                .frame(maxHeight: 115)
            }

            // 交互式 MapKit 地图
            MapReader { proxy in
                Map(position: $manager.cameraPosition) {
                    Marker("目标位置", coordinate: manager.pickedCoordinate2D)
                        .tint(.pink)
                }
                .mapStyle(.standard(elevation: .flat))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapZoomStepper()
                }
                .onTapGesture(coordinateSpace: .local) { screenPoint in
                    if let coord = proxy.convert(screenPoint, from: .local) {
                        manager.updatePickedCoordinate(latitude: coord.latitude, longitude: coord.longitude)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
                )
            }
            .frame(minHeight: 230, maxHeight: .infinity)

            // 经纬度手工微调与国内地图纠偏
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("纬度")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        TextField("39.908700", text: $manager.manualLatitudeInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 96)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.pillFill))
                            .onSubmit { manager.applyManualCoordinateInputs() }
                    }

                    HStack(spacing: 4) {
                        Text("经度")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        TextField("116.397500", text: $manager.manualLongitudeInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 102)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.pillFill))
                            .onSubmit { manager.applyManualCoordinateInputs() }
                    }

                    HStack(spacing: 4) {
                        Text("海拔")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        TextField("15", value: $manager.altitudeMeters, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 48)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.pillFill))
                        Text("m")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Button("应用坐标") {
                        manager.applyManualCoordinateInputs()
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.pink.opacity(0.14)))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Spacer()
                }

                HStack(spacing: 10) {
                    Toggle(isOn: $manager.gcj02CorrectionEnabled) {
                        Text("中国地图坐标系纠偏（GCJ-02 → WGS-84）")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Spacer()

                    let wgs = manager.effectiveWGS84Coordinate
                    Text("注入 WGS-84: \(String(format: "%.6f", wgs.latitude)), \(String(format: "%.6f", wgs.longitude))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Divider().opacity(0.25)

            // 常用地点收藏夹
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("常用坐标")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    TextField("输入收藏备注名…", text: $manager.newBookmarkName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(maxWidth: 160)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.pillFill))

                    Button {
                        manager.addCurrentAsBookmark()
                    } label: {
                        Label("收藏当前点", systemImage: "bookmark.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.pillFill))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(manager.bookmarks) { item in
                            HStack(spacing: 4) {
                                Button {
                                    manager.applyBookmark(item)
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(item.isGCJ02 ? Color.orange : Color.blue)
                                            .frame(width: 5, height: 5)
                                        Text(item.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(theme.primaryText)
                                    }
                                }
                                .buttonStyle(.plain)
                                .pointingHandOnHover()

                                Button {
                                    manager.removeBookmark(item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .pointingHandOnHover()
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(theme.pillFill))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    // MARK: - 右栏：设备传输 + MFi 凭据 + 协议日志

    private var controlAndLogColumn: some View {
        VStack(spacing: 12) {
            deviceConnectionCard
            mfiVaultCard
            troubleshootingAndLogCard
                .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var deviceConnectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("连接方式与目标设备", systemImage: "cable.connector")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button {
                    manager.refreshDevices()
                } label: {
                    HStack(spacing: 4) {
                        if manager.isRefreshingDevices {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        Text("刷新")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.pillFill))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            HStack(spacing: 6) {
                ForEach(AccessoryTransportMode.allCases) { mode in
                    let selected = manager.transportMode == mode
                    Button {
                        guard !manager.isRunning else { return }
                        manager.transportMode = mode
                        manager.savePreferences()
                        manager.refreshDevices()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode == .usb ? "cable.connector.horizontal" : "dot.radiowaves.left.and.right")
                                .font(.system(size: 11))
                            Text(mode.title)
                                .font(.system(size: 11.5, weight: selected ? .bold : .medium, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selected ? .white : theme.primaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Color.pink : theme.pillFill)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isRunning)
                }
            }

            if manager.discoveredDevices.isEmpty {
                Text(
                    manager.transportMode == .usb
                        ? "未发现 USB 设备：请用数据线连接 iPhone，并在设备端点击“信任此电脑”。"
                        : "未发现已配对蓝牙设备：请先在 macOS 系统蓝牙设置中完成 iPhone 配对。"
                )
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.pillFill))
            } else if manager.discoveredDevices.count > 2 {
                ScrollView(.vertical, showsIndicators: true) {
                    deviceRowsList
                }
                .frame(maxHeight: 92)
            } else {
                deviceRowsList
            }

            HStack(spacing: 6) {
                Text("运行时长")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                ForEach(AccessorySessionDuration.allCases) { dur in
                    let active = manager.sessionDuration == dur
                    Button {
                        manager.sessionDuration = dur
                        manager.savePreferences()
                    } label: {
                        Text(dur.title)
                            .font(.system(size: 10.5, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? .white : theme.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(active ? Color.pink : theme.pillFill))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isRunning)
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var deviceRowsList: some View {
        VStack(spacing: 5) {
            ForEach(manager.discoveredDevices) { dev in
                let selected = manager.selectedDeviceID == dev.id
                Button {
                    guard !manager.isRunning else { return }
                    manager.selectedDeviceID = dev.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.pink : theme.secondaryText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dev.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.primaryText)
                            Text(dev.badgeText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? Color.pink.opacity(0.14) : theme.pillFill)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .disabled(manager.isRunning)
            }
        }
    }

    private var mfiVaultCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("MFi-v3 配件鉴权凭据", systemImage: manager.mfiStatus.isConfigured ? "checkmark.shield.fill" : "key.shield.fill")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(manager.mfiStatus.isConfigured ? "已验证激活" : "未配置")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(manager.mfiStatus.isConfigured ? Color.green : Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill((manager.mfiStatus.isConfigured ? Color.green : Color.orange).opacity(0.16))
                    )
            }

            if manager.mfiStatus.isConfigured {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.green)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("MFi-v3 硬件鉴权凭据已激活")
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green)
                        Text(manager.mfiStatus.sourceLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        HStack(spacing: 6) {
                            Text("P7B 证书链 \(manager.mfiStatus.certificateBytes)B")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                            Text("P-256 私钥 \(manager.mfiStatus.keyBytes)B · 验签通过")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.green.opacity(0.35), lineWidth: 0.9)
                        )
                )

                HStack(spacing: 6) {
                    Button {
                        manager.downloadAndExtractDiPlayV027()
                    } label: {
                        HStack(spacing: 4) {
                            if manager.isImportingMFi {
                                ProgressView().controlSize(.mini)
                            }
                            Text("重新提取 DiPlay")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.pillFill))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isImportingMFi)

                    Button("更换 APK") {
                        manager.chooseLocalAPKAndImport()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.pillFill))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isImportingMFi)

                    Button("更换 .p7b/.pk8") {
                        manager.chooseManualCertificateAndKey()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.pillFill))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Spacer(minLength: 0)

                    Button {
                        manager.clearMFiCredentials()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("清除")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("尚未配置 MFi 鉴权凭据，请先提取或导入")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange)
                        Text("不含任何内置私钥。支持一键提取 DiPlay v0.2.7 公开离线凭据或手动导入 P7B + PK8。")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.9)
                        )
                )

                HStack(spacing: 6) {
                    Button {
                        manager.downloadAndExtractDiPlayV027()
                    } label: {
                        HStack(spacing: 4) {
                            if manager.isImportingMFi {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 11))
                            }
                            Text("一键提取 DiPlay v0.2.7")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.indigo))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isImportingMFi)

                    Button("本地 APK") {
                        manager.chooseLocalAPKAndImport()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.pillFill))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isImportingMFi)

                    Button(".p7b/.pk8") {
                        manager.chooseManualCertificateAndKey()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.pillFill))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }

            if let msg = manager.mfiImportMessage {
                HStack(spacing: 5) {
                    Image(systemName: manager.mfiStatus.isConfigured ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(manager.mfiStatus.isConfigured ? Color.green : Color.orange)
                    Text(msg)
                        .font(.system(size: 10.5))
                        .foregroundStyle(manager.mfiStatus.isConfigured ? Color.green : theme.secondaryText)
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private var troubleshootingAndLogCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("诊断日志与使用提示", systemImage: "terminal.fill")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                if !manager.logs.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            manager.copyLogsToClipboard()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: manager.didCopyLogs ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(manager.didCopyLogs ? "已复制" : "复制日志")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(manager.didCopyLogs ? Color.green : theme.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(manager.didCopyLogs ? Color.green.opacity(0.14) : theme.pillFill))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()

                        Button {
                            manager.clearLogs()
                        } label: {
                            Text("清空")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(theme.pillFill))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("1. 连接前准备：确保 iPhone 已解锁并信任此 Mac，开启「飞行模式」并保持 Wi-Fi 打开（阻止蜂窝数据基站定位干扰）。")
                Text("2. 重启定位服务刷新缓存：状态亮起「4. NMEA 定位注入」后，前往 iPhone「设置 → 隐私与安全性 → 定位服务」，关闭定位服务等待 10 秒后再重新开启。")
                Text("3. 恢复真实位置：点击「停止定位注入」或断开连接后，关闭飞行模式后重新开关一次定位服务，即可恢复真实硬件定位。")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? Color.orange : Color(red: 0.82, green: 0.38, blue: 0.04))
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.8)
                    )
            )

            Divider().opacity(0.2)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if manager.logs.isEmpty {
                        Text("暂无会话日志，点击右上角“启动定位注入”后实时显示 iAP2 握手过程。")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        ForEach(manager.logs) { entry in
                            HStack(alignment: .top, spacing: 5) {
                                Text(entry.timestamp)
                                    .foregroundStyle(theme.secondaryText.opacity(0.75))
                                Text("[\(entry.level)]")
                                    .foregroundStyle(logLevelColor(entry.level))
                                    .bold()
                                Text(entry.message)
                                    .foregroundStyle(theme.primaryText)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private func logLevelColor(_ level: String) -> Color {
        switch level {
        case "OK": return .green
        case "ERR": return .red
        case "WARN": return .orange
        default: return .cyan
        }
    }

    private func formatCountdown(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
