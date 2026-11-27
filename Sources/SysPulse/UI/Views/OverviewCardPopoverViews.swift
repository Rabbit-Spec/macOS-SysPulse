import SwiftUI
import AppKit

// MARK: - 状态总览卡片右上角胶囊交互浮层集合

struct OverviewPopoverRow: View {
    let label: String
    let value: String
    var copyKey: String? = nil
    var copyValue: String? = nil
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let isCopied = (copyKey != nil && navState.copiedPopoverField == copyKey)

        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 64, alignment: .leading)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                if let copyKey, let copyValue, !copyValue.isEmpty, copyValue != "未检测", copyValue != "获取中…" {
                    Button {
                        navState.copyPopoverValue(key: copyKey, value: copyValue)
                    } label: {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isCopied ? Color(red: 0.35, green: 0.85, blue: 0.55) : theme.secondaryText)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("复制 \(label)")
                }
            }
            .layoutPriority(1)
        }
    }
}

struct OverviewPopoverContainer<Content: View>: View {
    let width: CGFloat
    let content: Content

    init(width: CGFloat = 248, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: width)
        .alwaysActiveOnHover { hovering in
            StudioWindowNavigationState.shared.handleOverviewPopoverContentHover(hovering)
            PanelCoordinator.shared.handleMenuBarPopoverContentHover(hovering)
        }
    }
}

// 1. 健康度芯片与系统规格浮层
struct HealthCardPopoverContent: View {
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let hw = MacHardwareInfo.shared
        let snapshot = SystemHealthEvaluator.shared.evaluate()
        let cpuCountText = "\(ProcessInfo.processInfo.activeProcessorCount)"
        let gpuCountText = hw.gpuCoreCount > 0 ? "\(hw.gpuCoreCount)" : "--"
        let uptimeText = "\(snapshot.uptimeDays)天 \(snapshot.uptimeHours)小时"

        OverviewPopoverContainer(width: 248) {
            OverviewPopoverRow(label: "芯片", value: hw.chipBrand, navState: navState, theme: theme)
            OverviewPopoverRow(label: "CPU 核心数", value: cpuCountText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "GPU 核心数", value: gpuCountText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "内存", value: "\(Int(round(monitor.memory.totalGB))) GB", navState: navState, theme: theme)
            OverviewPopoverRow(label: "macOS", value: hw.osVersionWithBuild, navState: navState, theme: theme)
            OverviewPopoverRow(label: "型号标识符", value: hw.modelIdentifier, navState: navState, theme: theme)
            OverviewPopoverRow(label: "已开机", value: uptimeText, navState: navState, theme: theme)
        }
    }
}

// 2. CPU 温度、双簇/三簇频率与平均负载浮层
struct CPUCardPopoverContent: View {
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let topo = MacHardwareInfo.shared.coreTopology
        let tempText = "\(Int(round(monitor.hardware.cpuTemperatureC)))°C"
        let primaryLabel = topo.hasDualTier ? "\(topo.primaryTierDisplayName)频率" : "主频"
        let secondaryLabel = topo.hasDualTier ? "\(topo.secondaryTierDisplayName)频率" : "次簇频率"
        let primaryFreq = monitor.hardware.cpuPrimaryClusterGHz.map { String(format: "%.2f GHz", $0) } ?? "--"
        let secondaryFreq = monitor.hardware.cpuSecondaryClusterGHz.map { String(format: "%.2f GHz", $0) } ?? "--"
        let loadText = String(
            format: "%.2f · %.2f · %.2f",
            monitor.hardware.cpuLoadAverage1Min,
            monitor.hardware.cpuLoadAverage5Min,
            monitor.hardware.cpuLoadAverage15Min
        )

        OverviewPopoverContainer(width: 242) {
            OverviewPopoverRow(label: "CPU 温度", value: tempText, navState: navState, theme: theme)
            OverviewPopoverRow(label: primaryLabel, value: primaryFreq, navState: navState, theme: theme)
            if topo.hasDualTier || monitor.hardware.cpuSecondaryClusterGHz != nil {
                OverviewPopoverRow(label: secondaryLabel, value: secondaryFreq, navState: navState, theme: theme)
            }
            if topo.hasTripleTier, let tFreq = monitor.hardware.cpuTertiaryClusterGHz {
                OverviewPopoverRow(label: "\(topo.tertiaryTierDisplayName)频率", value: String(format: "%.2f GHz", tFreq), navState: navState, theme: theme)
            }
            if let cpuW = monitor.hardware.cpuPackageWatts, cpuW > 0 {
                OverviewPopoverRow(label: "CPU 功耗", value: String(format: "%.2f W", cpuW), navState: navState, theme: theme)
            }
            OverviewPopoverRow(label: "平均负载", value: loadText, navState: navState, theme: theme)
        }
    }
}

// 3. GPU 温度、功耗与频率浮层
struct GPUCardPopoverContent: View {
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let curTemp = max(32, Int(round(monitor.hardware.gpuTemperatureC)))
        let wattsText = String(format: "%.2f W", monitor.hardware.gpuWatts)
        let freqText = monitor.hardware.gpuFrequencyGHz.map { String(format: "%.2f GHz", $0) } ?? "--"

        OverviewPopoverContainer(width: 204) {
            OverviewPopoverRow(label: "GPU 温度", value: "\(curTemp)°C", navState: navState, theme: theme)
            OverviewPopoverRow(label: "GPU 功耗", value: wattsText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "GPU 频率", value: freqText, navState: navState, theme: theme)
        }
    }
}

// 4. 内存分布分解浮层
struct MemoryCardPopoverContent: View {
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let appText = Self.formatMemBytes(monitor.memory.appBytes)
        let wiredText = Self.formatMemBytes(monitor.memory.wiredBytes)
        let compText = Self.formatMemBytes(monitor.memory.compressedBytes)
        let cachedText = Self.formatMemBytes(monitor.memory.cachedFilesBytes)
        let swapText = monitor.memory.swapUsedBytes < 1048576 ? "0" : Self.formatMemBytes(monitor.memory.swapUsedBytes)

        OverviewPopoverContainer(width: 220) {
            OverviewPopoverRow(label: "App 内存", value: appText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "联动内存", value: wiredText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "被压缩内存", value: compText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "已缓存文件", value: cachedText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "交换空间", value: swapText, navState: navState, theme: theme)
        }
    }

    private static func formatMemBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1073741824.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1048576.0
        return String(format: "%.1f MB", max(0.0, mb))
    }
}

// 5. 供电、电池与外设电量浮层
struct PowerCardPopoverContent: View {
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var engine: PowerSourceEngine
    @Bindable var toggles: FeatureToggleManager
    @Bindable var accessories: AccessoryBatteryManager
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let power = monitor.power
        let rt = monitor.loadRuntime
        let hasInternalBattery = rt.hasInternalBattery || toggles.enableMacBookDemoMode
        let hasUPS = toggles.enablePluginUPSManager && engine.telemetry.isConnected
        let connectedAccessories = accessories.accessories.filter { $0.isConnected }

        OverviewPopoverContainer(width: 264) {
            OverviewPopoverRow(
                label: "负载分解",
                value: String(format: "负载 %.1f W · 损耗 %.1f W", power.systemLoadWatts, power.adapterLossWatts),
                navState: navState,
                theme: theme
            )
            OverviewPopoverRow(
                label: "平均功耗",
                value: String(format: "%.1f W", power.averageWatts),
                navState: navState,
                theme: theme
            )
            OverviewPopoverRow(
                label: "直流输入",
                value: String(format: "%.1f V · %.2f A", power.dcVoltageVolts, power.dcCurrentAmps),
                navState: navState,
                theme: theme
            )

            if hasInternalBattery {
                Divider().overlay(theme.dividerColor.opacity(0.35))
                OverviewPopoverRow(label: "电池健康度", value: "\(rt.healthPercent)%", navState: navState, theme: theme)
                OverviewPopoverRow(label: "循环次数", value: "\(rt.cycleCount) 次", navState: navState, theme: theme)
                OverviewPopoverRow(label: "电池温度", value: String(format: "%.1f°C", rt.batteryTempCelsius), navState: navState, theme: theme)
                if monitor.hardware.batteryChargingWatts > 0.2 {
                    OverviewPopoverRow(
                        label: "充放电功率",
                        value: String(format: "%.1f W", monitor.hardware.batteryChargingWatts),
                        navState: navState,
                        theme: theme
                    )
                }
                OverviewPopoverRow(label: "预估续航", value: rt.formattedCurrentLoadRuntime, navState: navState, theme: theme)
            } else if hasUPS {
                Divider().overlay(theme.dividerColor.opacity(0.35))
                OverviewPopoverRow(label: "UPS 设备", value: engine.telemetry.pairedUPSDescription, navState: navState, theme: theme)
                OverviewPopoverRow(label: "市电输入", value: "\(Int(round(engine.telemetry.voltageVolts))) V", navState: navState, theme: theme)
                OverviewPopoverRow(
                    label: "应急续航",
                    value: rt.formattedCurrentLoadRuntime,
                    navState: navState,
                    theme: theme
                )
            }

            if !connectedAccessories.isEmpty {
                Divider().overlay(theme.dividerColor.opacity(0.35))
                ForEach(connectedAccessories) { item in
                    OverviewPopoverRow(
                        label: item.name,
                        value: Self.formatAccessoryValue(item),
                        navState: navState,
                        theme: theme
                    )
                }
            }
        }
    }

    private static func formatAccessoryValue(_ item: AccessoryBatteryItem) -> String {
        if item.hasMultiPartDetail,
           let openIdx = item.detailText.firstIndex(of: "("),
           let closeIdx = item.detailText.lastIndex(of: ")"),
           openIdx < closeIdx {
            let inner = item.detailText[item.detailText.index(after: openIdx)..<closeIdx]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                return inner
            }
        }
        return "\(item.batteryLevel)%"
    }
}

// 6. 磁盘读写速度与空间容量浮层
struct DiskCardPopoverContent: View {
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let readText = SystemHardwareExtendedMetrics.formatSpeed(monitor.diskIO.readBytesPerSec)
        let writeText = SystemHardwareExtendedMetrics.formatSpeed(monitor.diskIO.writeBytesPerSec)
        let freeText = String(format: "%.2f GB", monitor.hardware.statfsFreeGB)
        let usedText = String(format: "%.2f GB", monitor.hardware.statfsUsedGB)

        OverviewPopoverContainer(width: 216) {
            OverviewPopoverRow(label: "读取速度", value: readText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "写入速度", value: writeText, navState: navState, theme: theme)
            Divider().overlay(theme.dividerColor.opacity(0.35))
            OverviewPopoverRow(label: "已用空间", value: usedText, navState: navState, theme: theme)
            OverviewPopoverRow(label: "剩余可用", value: freeText, navState: navState, theme: theme)
        }
    }
}

// 6. 网络接口、公网出口与 AIGC 探测浮层
struct NetworkCardPopoverContent: View {
    @Bindable var detail: NetworkDetailModel
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let aigcValue: String = {
            if detail.isProbingChatGPTExit && detail.chatGPTExitIP == "未检测" {
                return "探测中…"
            }
            if detail.chatGPTExitRegion.isEmpty || detail.chatGPTExitIP == "不可达" || detail.chatGPTExitIP == "未检测" {
                return detail.chatGPTExitIP
            }
            return "\(detail.chatGPTExitRegion) \(detail.chatGPTExitIP)"
        }()

        OverviewPopoverContainer(width: 278) {
            OverviewPopoverRow(
                label: "IPv4",
                value: detail.localIPv4,
                copyKey: "ipv4",
                copyValue: detail.localIPv4,
                navState: navState,
                theme: theme
            )
            OverviewPopoverRow(
                label: "公网 IP",
                value: detail.publicIP,
                copyKey: "publicIP",
                copyValue: detail.publicIP,
                navState: navState,
                theme: theme
            )
            if !detail.location.isEmpty {
                OverviewPopoverRow(label: "位置", value: detail.location, navState: navState, theme: theme)
            }
            if !detail.carrier.isEmpty {
                OverviewPopoverRow(label: "运营商", value: detail.carrier, navState: navState, theme: theme)
            }
            OverviewPopoverRow(label: "代理", value: detail.proxySummaryText, navState: navState, theme: theme)
            OverviewPopoverRow(
                label: "AIGC",
                value: aigcValue,
                copyKey: "aigc",
                copyValue: detail.chatGPTExitIP == "不可达" || detail.chatGPTExitIP == "未检测" ? nil : detail.chatGPTExitIP,
                navState: navState,
                theme: theme
            )
        }
        .onAppear {
            detail.refreshIfNeeded()
        }
    }
}

// 7. 多风扇转速与存储温度浮层
struct FanCardPopoverContent: View {
    @Bindable var monitor: SystemResourceMonitor
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme

    var body: some View {
        let fanRPMs = monitor.hardware.perFanRPMs
        let storageTempText = monitor.hardware.storageTemperatureC.map { "\(Int(round($0)))°C" } ?? "--"

        OverviewPopoverContainer(width: 204) {
            if fanRPMs.isEmpty {
                OverviewPopoverRow(label: "风扇转速", value: "\(monitor.hardware.fanSpeedRPM) RPM", navState: navState, theme: theme)
            } else {
                ForEach(fanRPMs.indices, id: \.self) { idx in
                    OverviewPopoverRow(label: "风扇 \(idx + 1)", value: "\(fanRPMs[idx]) RPM", navState: navState, theme: theme)
                }
            }
            OverviewPopoverRow(label: "存储温度", value: storageTempText, navState: navState, theme: theme)
        }
    }
}

// 8. 菜单栏高占用进程透视浮层
struct MenuBarProcessPopoverContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var vm: ProcessInspectorViewModel
    @Bindable var navState: StudioWindowNavigationState
    let theme: LiquidGlassTheme
    let onClose: () -> Void

    var body: some View {
        let isProtected = ProcessInspectorService.isProtected(pid: vm.app.pid, name: vm.app.name)

        OverviewPopoverContainer(width: 318) {
            HStack(spacing: 8) {
                Image(nsImage: AppIconLookupCache.shared.icon(forPID: vm.app.pid))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))

                Text(vm.app.name)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("PID \(vm.app.pid)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    )
            }

            Divider().overlay(theme.dividerColor.opacity(0.35))

            OverviewPopoverRow(
                label: "CPU · 内存",
                value: String(format: "%.1f%% · %@", vm.app.cpuPercent, vm.app.formattedMemory),
                navState: navState,
                theme: theme
            )

            if let snap = vm.snapshot {
                OverviewPopoverRow(
                    label: "线程 · 句柄",
                    value: "\(snap.threadCount) · \(snap.openFileCount)",
                    navState: navState,
                    theme: theme
                )
                OverviewPopoverRow(
                    label: "运行时长",
                    value: snap.uptimeFormatted,
                    navState: navState,
                    theme: theme
                )
                OverviewPopoverRow(
                    label: "磁盘 I/O",
                    value: snap.formattedDiskIO,
                    navState: navState,
                    theme: theme
                )

                Text(snap.executablePath)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 290, alignment: .leading)
                    .help(snap.executablePath)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取进程详情…")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
            }

            Divider().overlay(theme.dividerColor.opacity(0.35))

            HStack(spacing: 6) {
                actionCapsuleButton(
                    title: "访达定位",
                    tint: theme.primaryText,
                    fill: colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                    disabled: false
                ) {
                    vm.revealInFinder()
                }

                Spacer(minLength: 0)

                actionCapsuleButton(
                    title: "退出",
                    tint: isProtected ? theme.secondaryText.opacity(0.45) : theme.primaryText,
                    fill: colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                    disabled: isProtected
                ) {
                    vm.terminate(force: false, onDismiss: onClose)
                }

                actionCapsuleButton(
                    title: vm.confirmForceKill ? "确认强退" : "强制退出",
                    tint: isProtected ? Color.red.opacity(0.4) : Color(red: 0.96, green: 0.42, blue: 0.38),
                    fill: isProtected
                        ? Color.red.opacity(0.08)
                        : (vm.confirmForceKill ? Color.red.opacity(0.28) : Color(red: 0.96, green: 0.36, blue: 0.32).opacity(0.16)),
                    disabled: isProtected
                ) {
                    vm.terminate(force: true, onDismiss: onClose)
                }
            }
        }
        .onAppear {
            vm.load()
        }
    }

    private func actionCapsuleButton(
        title: String,
        tint: Color,
        fill: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(Capsule(style: .continuous).fill(fill))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .pointingHandOnHover()
    }
}
