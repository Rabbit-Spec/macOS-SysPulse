import SwiftUI
import AppKit
import Observation
import SystemConfiguration
import Darwin

// MARK: - 系统运行诊断数据模型

public struct DiagnosticIssueItem: Identifiable, Sendable {
    public let id = UUID()
    public let level: String
    public let message: String
    public let actionTitle: String
    public let actionKind: IssueActionKind

    public enum IssueActionKind: Sendable {
        case fullDiskAccess
        case notifications
        case automation
        case upsHelper
    }
}

public struct SystemDiagnosticsSnapshot: Sendable {
    public let generatedAt: String
    public let appVersionString: String

    public let macOSVersion: String
    public let chipName: String
    public let modelIdentifier: String
    public let architecture: String
    public let localeIdentifier: String
    public let bundleIdentifier: String
    public let displaySummary: String
    public let installPath: String

    public let cpuPercent: String
    public let loadAvg: String
    public let memorySummary: String
    public let memoryPressure: String
    public let thermalState: String
    public let temperatureSensors: String
    public let fansSummary: String
    public let diskRootSummary: String
    public let batteryAndUPSSummary: String
    public let systemPowerSummary: String
    public let lowPowerMode: String
    public let uptimeSummary: String
    public let healthScore: String
    public let healthFactors: String
    public let volumesSummary: String
    public let networkTunnels: String

    public let fullDiskAccess: String
    public let notificationsPermission: String
    public let appleEventsPermission: String

    public let helperScriptStatus: String
    public let deleteMode: String
    public let menuBarHUD: String
    public let keepAwakeStatus: String
    public let fanControlMode: String
    public let wifiLowLatencyStatus: String
    public let upsProtectionStatus: String
    public let diskGuardianStatus: String
    public let proxySummary: String

    public let sipStatus: String
    public let architectureMode: String
    public let sandboxed: String
    public let authorInfo: String

    public let runtimeAppVersion: String
    public let operationsLogStatus: String
    public let recentOperations: String

    public let issues: [DiagnosticIssueItem]

    public func toMarkdownReport() -> String {
        var lines: [String] = []
        lines.append("# SysPulse Doctor Report")
        lines.append("Generated: \(generatedAt)")
        lines.append("App: \(appVersionString)")
        lines.append("")
        lines.append("## Environment")
        lines.append("- macOS: \(macOSVersion)")
        lines.append("- Chip: \(chipName)")
        lines.append("- Model: \(modelIdentifier)")
        lines.append("- Architecture: \(architecture)")
        lines.append("- Locale: \(localeIdentifier)")
        lines.append("- Bundle: \(bundleIdentifier)")
        lines.append("- Display: \(displaySummary)")
        lines.append("- Install: \(installPath)")
        lines.append("")
        lines.append("## System")
        lines.append("- CPU: \(cpuPercent)")
        lines.append("- Load avg: \(loadAvg)")
        lines.append("- Memory: \(memorySummary)")
        lines.append("- Memory pressure: \(memoryPressure)")
        lines.append("- Thermal state: \(thermalState)")
        lines.append("- Temperature sensors: \(temperatureSensors)")
        lines.append("- Fans: \(fansSummary)")
        lines.append("- Disk /: \(diskRootSummary)")
        lines.append("- Battery / UPS: \(batteryAndUPSSummary)")
        lines.append("- System power: \(systemPowerSummary)")
        lines.append("- Low Power Mode: \(lowPowerMode)")
        lines.append("- Uptime: \(uptimeSummary)")
        lines.append("- Health score: \(healthScore)")
        lines.append("- Health factors: \(healthFactors)")
        lines.append("- Volumes: \(volumesSummary)")
        lines.append("- Network tunnels: \(networkTunnels)")
        lines.append("")
        lines.append("## Permissions")
        lines.append("- Full Disk Access: \(fullDiskAccess)")
        lines.append("- Notifications: \(notificationsPermission)")
        lines.append("- Apple Events (Automation): \(appleEventsPermission)")
        lines.append("")
        lines.append("## Configuration")
        lines.append("- Helper tool: \(helperScriptStatus)")
        lines.append("- Delete mode: \(deleteMode)")
        lines.append("- Menu bar HUD: \(menuBarHUD)")
        lines.append("- Keep Awake: \(keepAwakeStatus)")
        lines.append("- Fan mode: \(fanControlMode)")
        lines.append("- Wi-Fi Low Latency: \(wifiLowLatencyStatus)")
        lines.append("- UPS Protection: \(upsProtectionStatus)")
        lines.append("- Disk Guardian: \(diskGuardianStatus)")
        lines.append("- Proxy: \(proxySummary)")
        lines.append("")
        lines.append("## Security")
        lines.append("- SIP: \(sipStatus)")
        lines.append("- Architecture mode: \(architectureMode)")
        lines.append("- Sandboxed: \(sandboxed)")
        lines.append("- Update feed: https://github.com/Rabbit-Spec/macOS-SysPulse/releases")
        lines.append("- Author: \(authorInfo)")
        lines.append("")
        lines.append("## Runtime")
        lines.append("- App version: \(runtimeAppVersion)")
        lines.append("- Operations log: \(operationsLogStatus)")
        lines.append("- Recent operations: \(recentOperations)")
        lines.append("")
        lines.append("## Detected Issues")
        if issues.isEmpty {
            lines.append("- [ok] 运行环境与系统权限状态正常。")
        } else {
            for issue in issues {
                lines.append("- [\(issue.level)] \(issue.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

@Observable
@MainActor
public final class SystemDiagnosticsCollector {
    public static let shared = SystemDiagnosticsCollector()

    public var snapshot: SystemDiagnosticsSnapshot?
    public var didCopyReport: Bool = false
    public var isRefreshing: Bool = false

    private init() {}

    public func refresh() {
        self.snapshot = collect()
    }

    public func collect() -> SystemDiagnosticsSnapshot {
        let permissions = SystemPermissionManager.shared
        permissions.checkAllPermissions()

        let monitor = SystemResourceMonitor.shared
        let engine = PowerSourceEngine.shared
        let toggles = FeatureToggleManager.shared
        let cleaner = SystemCleanerEngine.shared
        let keepAwake = KeepAwakeController.shared
        let fan = FanController.shared
        let wifiLL = WiFiLowLatencyManager.shared
        let upsSettings = SystemUPSSettingsManager.shared
        let diskGuardian = DiskGuardian.shared
        let health = SystemHealthEvaluator.shared.evaluate()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let tzHours = TimeZone.current.secondsFromGMT() / 3600
        let tzSign = tzHours >= 0 ? "+" : ""
        let generatedAt = "\(df.string(from: Date())) GMT\(tzSign)\(tzHours)"

        let ver = AppMetadata.version
        let buildNum = ver.split(separator: ".").last.map(String.init) ?? "107"
        let appVersionString = "\(ver) (build \(buildNum))"

        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        let chipName = MacHardwareInfo.shared.chipBrand
        let modelIdentifier = MacHardwareInfo.shared.modelIdentifier
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif

        let rawLocale = Locale.preferredLanguages.first ?? Locale.current.identifier
        let localeIdentifier = rawLocale.replacingOccurrences(of: "-CN", with: "")
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.SysPulse.app"
        let displaySummary = Self.queryDisplaySummary()
        let installPath = Self.formatTildePath(Bundle.main.bundleURL.path)

        let cpuPercent = String(format: "%.1f%%", monitor.power.cpuTotalPercent)
        var loads = [Double](repeating: 0.0, count: 3)
        getloadavg(&loads, 3)
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let loadAvg = String(format: "%.2f, %.2f, %.2f (%d cores)", loads[0], loads[1], loads[2], coreCount)

        let usedMemStr = String(format: "%.2f GB", monitor.memory.usedGB)
            .replacingOccurrences(of: ".00 ", with: " ")
        let totalMemStr = String(format: "%.0f GB", monitor.memory.totalGB)
        let memorySummary = "\(usedMemStr) / \(totalMemStr) (\(monitor.memory.usedPercent)%)"

        let memoryPressure: String = {
            switch monitor.memory.pressure {
            case .normal: return "normal"
            case .warning: return "warning"
            case .critical: return "critical"
            }
        }()

        let thermalState: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "nominal"
            }
        }()

        let cpuTemp = Int(round(monitor.hardware.cpuTemperatureC))
        let gpuTemp = Int(round(monitor.hardware.gpuTemperatureC))
        let temperatureSensors = "CPU \(cpuTemp)°C · GPU \(gpuTemp)°C"

        let fanCount = Self.detectFanCount()
        let fansSummary: String = {
            if fanCount <= 0 || !monitor.hardware.isFanSupported {
                return "0 fans detected · passive cooling"
            }
            return "\(fanCount) fans detected · primary \(monitor.hardware.fanSpeedRPM) RPM"
        }()

        let diskUsed = String(format: "%.2f GB", monitor.hardware.statfsUsedGB)
        let diskTotal = String(format: "%.2f GB", monitor.hardware.statfsTotalGB)
        let diskRootSummary = "\(diskUsed) / \(diskTotal) (\(monitor.hardware.statfsUsedPercent)%)"

        let batteryAndUPSSummary: String = {
            if engine.telemetry.isConnected {
                let stateStr = engine.telemetry.state.isAC ? (engine.telemetry.isCharging ? "Charging" : "AC Online") : "On Battery"
                return "\(engine.telemetry.batteryLevel)% · \(stateStr) (\(engine.telemetry.deviceName) · \(Int(engine.telemetry.voltageVolts))V)"
            } else if monitor.loadRuntime.hasInternalBattery {
                let stateStr = monitor.loadRuntime.isInternalCharging ? "Charging" : (monitor.loadRuntime.isInternalPluggedIn ? "AC Attached" : "Discharging")
                return "\(monitor.loadRuntime.internalBatteryPercent)% · \(stateStr)"
            } else {
                return "100% · AC Online"
            }
        }()

        let curW = monitor.power.totalSystemWatts
        let peakW = max(monitor.power.peakWatts, curW)
        let systemPowerSummary = String(format: "%.1f W (peak %.1f W)", curW, peakW)
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        let uptimeSummary = "\(health.uptimeDays)d \(health.uptimeHours)h"
        let healthScore = "\(health.score)/100"
        let healthFactors: String = {
            if health.factors.isEmpty {
                return "none"
            }
            return health.factors.map { "\($0.description) -\($0.penalty)" }.joined(separator: " · ")
        }()

        let volumesSummary = Self.queryMountedVolumes()
        let networkTunnels = Self.queryNetworkTunnels()

        let fdaGranted = permissions.fullDiskAccessStatus == .authorized
        let notifGranted = permissions.notificationStatus == .authorized
        let autoGranted = permissions.automationStatus == .authorized
        let fullDiskAccess = fdaGranted ? "granted" : "not granted"
        let notificationsPermission = notifGranted ? "granted" : "not granted"
        let appleEventsPermission = autoGranted ? "granted" : "not granted"

        let helperInstalled = FileManager.default.isExecutableFile(atPath: "/Library/Application Support/SysPulse/SysPulseUPSHelper")
        let helperScriptStatus = helperInstalled ? "installed" : "not installed"
        let deleteMode = (cleaner.deleteMode == .moveToTrash) ? "moveToTrash" : "permanent"
        let hudOn = toggles.menuBarShowCpuGpu || toggles.menuBarShowMemTemp || toggles.menuBarShowNetworkSpeed || toggles.menuBarShowSystemWatts
        let menuBarHUD = hudOn ? "on" : "off"
        let keepAwakeStatus = keepAwake.isActive ? "on (\(keepAwake.currentBehavior.rawValue))" : "off"
        let fanControlMode: String = {
            switch fan.activeMode {
            case .auto: return "auto"
            case .cool: return "cool (50%)"
            case .maxCool: return "maxCool (100%)"
            }
        }()
        let wifiLowLatencyStatus = wifiLL.isLowLatencyActive ? "on (awdl0 down)" : "off"
        let upsProtectionStatus = upsSettings.softwareProtectionEnabled ? "on (\(upsSettings.protectionAction))" : "off"
        let diskGuardianStatus = diskGuardian.isAutoEjectEnabled ? "on (\(diskGuardian.delayMinutes)m delay)" : "off"
        let proxySummary = Self.querySystemProxy()

        let sipStatus = Self.querySIPStatus()
        let architectureMode = "native \(arch)"
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let sandboxed = isSandboxed ? "yes" : "no"
        let authorInfo = "Rabbit-Spec · 汤圆_Lyric (https://space.bilibili.com/7135720)"

        let operationsLogStatus = "ok"
        let recentOperations = "\(engine.events.count) in last log window"

        var issues: [DiagnosticIssueItem] = []
        if !fdaGranted {
            issues.append(
                DiagnosticIssueItem(
                    level: "warn",
                    message: "未开启磁盘访问权限，部分项目无法扫描或清理。",
                    actionTitle: "前往设置",
                    actionKind: .fullDiskAccess
                )
            )
        }
        if !notifGranted {
            issues.append(
                DiagnosticIssueItem(
                    level: "warn",
                    message: "未开启桌面通知权限，UPS 断电与低电量横幅提醒无法弹出。",
                    actionTitle: "前往设置",
                    actionKind: .notifications
                )
            )
        }
        if !autoGranted {
            issues.append(
                DiagnosticIssueItem(
                    level: "warn",
                    message: "未授权 Apple Events 自动化控制，断电保护指令可能受限。",
                    actionTitle: "前往设置",
                    actionKind: .automation
                )
            )
        }

        let snapshot = SystemDiagnosticsSnapshot(
            generatedAt: generatedAt,
            appVersionString: appVersionString,
            macOSVersion: macOSVersion,
            chipName: chipName,
            modelIdentifier: modelIdentifier,
            architecture: arch,
            localeIdentifier: localeIdentifier,
            bundleIdentifier: bundleIdentifier,
            displaySummary: displaySummary,
            installPath: installPath,
            cpuPercent: cpuPercent,
            loadAvg: loadAvg,
            memorySummary: memorySummary,
            memoryPressure: memoryPressure,
            thermalState: thermalState,
            temperatureSensors: temperatureSensors,
            fansSummary: fansSummary,
            diskRootSummary: diskRootSummary,
            batteryAndUPSSummary: batteryAndUPSSummary,
            systemPowerSummary: systemPowerSummary,
            lowPowerMode: lowPowerMode,
            uptimeSummary: uptimeSummary,
            healthScore: healthScore,
            healthFactors: healthFactors,
            volumesSummary: volumesSummary,
            networkTunnels: networkTunnels,
            fullDiskAccess: fullDiskAccess,
            notificationsPermission: notificationsPermission,
            appleEventsPermission: appleEventsPermission,
            helperScriptStatus: helperScriptStatus,
            deleteMode: deleteMode,
            menuBarHUD: menuBarHUD,
            keepAwakeStatus: keepAwakeStatus,
            fanControlMode: fanControlMode,
            wifiLowLatencyStatus: wifiLowLatencyStatus,
            upsProtectionStatus: upsProtectionStatus,
            diskGuardianStatus: diskGuardianStatus,
            proxySummary: proxySummary,
            sipStatus: sipStatus,
            architectureMode: architectureMode,
            sandboxed: sandboxed,
            authorInfo: authorInfo,
            runtimeAppVersion: appVersionString,
            operationsLogStatus: operationsLogStatus,
            recentOperations: recentOperations,
            issues: issues
        )

        Self.writeOperationsLogFile(snapshot: snapshot, events: engine.events)
        return snapshot
    }

    // MARK: - Low-Level System Queries

    private static func formatTildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func queryDisplaySummary() -> String {
        let screens = NSScreen.screens
        guard let main = NSScreen.main ?? screens.first else {
            return "1 connected"
        }
        let w = Int(round(main.frame.width))
        let h = Int(round(main.frame.height))
        let scale = Int(round(main.backingScaleFactor))
        return "\(screens.count) connected · \(w)×\(h) @ \(scale)x"
    }

    private static func detectFanCount() -> Int {
        let isLaptop = MacHardwareInfo.shared.isLaptop
        let brand = MacHardwareInfo.shared.platformName.lowercased()
        if brand.contains("air") {
            return 0
        }
        if brand.contains("studio") || brand.contains("pro") || isLaptop {
            return 2
        }
        return 1
    }

    private static func queryMountedVolumes() -> String {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return "Macintosh HD"
        }
        var items: [String] = []
        for url in urls {
            if url.path.hasPrefix("/System/Volumes/") || url.path.hasPrefix("/private/") {
                continue
            }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = vals.volumeName ?? url.lastPathComponent
            if url.path == "/" {
                items.append(name)
            } else if vals.volumeIsLocal == false {
                items.append("\(name) (network)")
            } else {
                items.append("\(name) (external)")
            }
        }
        return items.isEmpty ? "Macintosh HD" : items.joined(separator: " · ")
    }

    private static func queryNetworkTunnels() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return "none"
        }
        defer { freeifaddrs(first) }

        var utunStates: [String: Bool] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("utun") {
                let flags = Int32(cur.pointee.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
                let hasAddr: Bool = {
                    guard let addr = cur.pointee.ifa_addr else { return false }
                    let fam = Int32(addr.pointee.sa_family)
                    return fam == AF_INET || fam == AF_INET6
                }()
                let prev = utunStates[name] ?? false
                utunStates[name] = prev || (isUp && hasAddr)
            }
            ptr = cur.pointee.ifa_next
        }

        if utunStates.isEmpty {
            return "none"
        }

        let sortedNames = utunStates.keys.sorted { a, b in
            let numA = Int(a.dropFirst(4)) ?? 0
            let numB = Int(b.dropFirst(4)) ?? 0
            return numA < numB
        }

        let active = sortedNames.filter { utunStates[$0] == true }
        let inactive = sortedNames.filter { utunStates[$0] == false }

        var parts: [String] = []
        if !active.isEmpty {
            parts.append("\(active.joined(separator: ", ")) (active)")
        }
        if !inactive.isEmpty {
            parts.append("\(inactive.joined(separator: ", ")) (inactive)")
        }
        return parts.joined(separator: " · ")
    }

    private static func querySystemProxy() -> String {
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return "none"
        }
        if let httpsEn = dict[kSCPropNetProxiesHTTPSEnable as String] as? Int, httpsEn == 1,
           let host = dict[kSCPropNetProxiesHTTPSProxy as String] as? String,
           let port = dict[kSCPropNetProxiesHTTPSPort as String] as? Int {
            return "HTTPS \(host):\(port)"
        }
        if let httpEn = dict[kSCPropNetProxiesHTTPEnable as String] as? Int, httpEn == 1,
           let host = dict[kSCPropNetProxiesHTTPProxy as String] as? String,
           let port = dict[kSCPropNetProxiesHTTPPort as String] as? Int {
            return "HTTP \(host):\(port)"
        }
        if let socksEn = dict[kSCPropNetProxiesSOCKSEnable as String] as? Int, socksEn == 1,
           let host = dict[kSCPropNetProxiesSOCKSProxy as String] as? String,
           let port = dict[kSCPropNetProxiesSOCKSPort as String] as? Int {
            return "SOCKS \(host):\(port)"
        }
        return "none"
    }

    private static func querySIPStatus() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        proc.arguments = ["status"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(decoding: data, as: UTF8.self).lowercased()
            if str.contains("disabled") {
                return "disabled"
            }
        } catch {}
        return "enabled"
    }

    public static var operationsLogURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SysPulse", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("operations.log")
    }

    private static func writeOperationsLogFile(snapshot: SystemDiagnosticsSnapshot, events: [PowerEvent]) {
        var content = snapshot.toMarkdownReport()
        content += "\n\n## Recent Power & Clean Operations Log\n"
        if events.isEmpty {
            content += "- No recorded events in current window.\n"
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for ev in events {
                content += "- [\(df.string(from: ev.timestamp))] [\(ev.type.rawValue)] \(ev.details)\n"
            }
        }
        try? content.write(to: operationsLogURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - 系统运行诊断弹窗视图

public struct SystemDiagnosticsModalView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var collector = SystemDiagnosticsCollector.shared
    let theme: LiquidGlassTheme
    let onClose: () -> Void

    private var snapshot: SystemDiagnosticsSnapshot {
        collector.snapshot ?? collector.collect()
    }

    private var mintAccent: Color {
        Color(red: 0.32, green: 0.84, blue: 0.62)
    }

    public init(theme: LiquidGlassTheme, onClose: @escaping () -> Void) {
        self.theme = theme
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部标题栏
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("系统诊断")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)

                    Text("查看 Mac 与 SysPulse 的运行状态，反馈问题时可附上这份报告")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            // 2. 诊断详情滚动区
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    if !snapshot.issues.isEmpty {
                        pendingIssuesCard
                    }

                    diagnosticSectionCard(icon: "laptopcomputer", title: "环境") {
                        diagnosticRow("macOS", snapshot.macOSVersion)
                        diagnosticRow("Chip", snapshot.chipName)
                        diagnosticRow("Model", snapshot.modelIdentifier)
                        diagnosticRow("Architecture", snapshot.architecture)
                        diagnosticRow("Locale", snapshot.localeIdentifier)
                        diagnosticRow("Bundle", snapshot.bundleIdentifier)
                        diagnosticRow("Display", snapshot.displaySummary)
                        diagnosticRow("Install", snapshot.installPath)
                    }

                    diagnosticSectionCard(icon: "gauge.with.needle", title: "系统状态") {
                        diagnosticRow("CPU", snapshot.cpuPercent)
                        diagnosticRow("Load avg", snapshot.loadAvg)
                        diagnosticRow("Memory", snapshot.memorySummary)
                        diagnosticRow("Memory pressure", snapshot.memoryPressure)
                        diagnosticRow("Thermal state", snapshot.thermalState)
                        diagnosticRow("Temperature sensors", snapshot.temperatureSensors)
                        diagnosticRow("Fans", snapshot.fansSummary)
                        diagnosticRow("Disk /", snapshot.diskRootSummary)
                        diagnosticRow("Battery / UPS", snapshot.batteryAndUPSSummary)
                        diagnosticRow("System power", snapshot.systemPowerSummary)
                        diagnosticRow("Low Power Mode", snapshot.lowPowerMode)
                        diagnosticRow("Uptime", snapshot.uptimeSummary)
                        diagnosticRow("Health score", snapshot.healthScore)
                        diagnosticRow("Health factors", snapshot.healthFactors)
                        diagnosticRow("Volumes", snapshot.volumesSummary)
                        diagnosticRow("Network tunnels", snapshot.networkTunnels)
                    }

                    diagnosticSectionCard(icon: "lock", title: "权限") {
                        diagnosticRow("Full Disk Access", snapshot.fullDiskAccess)
                        diagnosticRow("Notifications", snapshot.notificationsPermission)
                        diagnosticRow("Apple Events", snapshot.appleEventsPermission)
                    }

                    diagnosticSectionCard(icon: "gearshape", title: "配置") {
                        diagnosticRow("Helper tool", snapshot.helperScriptStatus)
                        diagnosticRow("Delete mode", snapshot.deleteMode)
                        diagnosticRow("Menu bar HUD", snapshot.menuBarHUD)
                        diagnosticRow("Keep Awake", snapshot.keepAwakeStatus)
                        diagnosticRow("Fan mode", snapshot.fanControlMode)
                        diagnosticRow("Wi-Fi Low Latency", snapshot.wifiLowLatencyStatus)
                        diagnosticRow("UPS Protection", snapshot.upsProtectionStatus)
                        diagnosticRow("Disk Guardian", snapshot.diskGuardianStatus)
                        diagnosticRow("Proxy", snapshot.proxySummary)
                    }

                    diagnosticSectionCard(icon: "shield", title: "安全") {
                        diagnosticRow("SIP", snapshot.sipStatus)
                        diagnosticRow("Architecture mode", snapshot.architectureMode)
                        diagnosticRow("Sandboxed", snapshot.sandboxed)
                        diagnosticRow("Update feed", "https://github.com/Rabbit-Spec/macOS-SysPulse/releases")
                        diagnosticRow("Author", snapshot.authorInfo)
                    }

                    diagnosticSectionCard(icon: "cube", title: "SYSPULSE 运行状态") {
                        diagnosticRow("App version", snapshot.runtimeAppVersion)
                        diagnosticRow("Operations log", snapshot.operationsLogStatus)
                        diagnosticRow("Recent operations", snapshot.recentOperations)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            Divider()
                .overlay(theme.dividerColor.opacity(0.45))

            // 3. 底部操作栏
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        collector.isRefreshing = true
                        collector.refresh()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        collector.isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .rotationEffect(.degrees(collector.isRefreshing ? 360 : 0))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                                .overlay(
                                    Circle().strokeBorder(theme.cardBorder, lineWidth: 0.7)
                                )
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("重新检测系统诊断数据")

                Button {
                    let logURL = SystemDiagnosticsCollector.operationsLogURL
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                } label: {
                    Text("在访达中显示操作日志")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Spacer()

                Button {
                    let report = snapshot.toMarkdownReport()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        collector.didCopyReport = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            collector.didCopyReport = false
                        }
                    }
                } label: {
                    Text(collector.didCopyReport ? "已复制报告" : "复制报告")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                                .overlay(
                                    Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.8)
                                )
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .onAppear {
            collector.refresh()
        }
    }

    // MARK: - Pending Issues Card (待处理项)

    private var pendingIssuesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("待处理项")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(theme.secondaryText)

            VStack(spacing: 8) {
                ForEach(snapshot.issues) { issue in
                    HStack(alignment: .center, spacing: 12) {
                        Text(issue.message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        Button {
                            handleIssueAction(issue.actionKind)
                        } label: {
                            Text(issue.actionTitle)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(mintAccent)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func handleIssueAction(_ kind: DiagnosticIssueItem.IssueActionKind) {
        let perms = SystemPermissionManager.shared
        switch kind {
        case .fullDiskAccess:
            perms.openFullDiskAccessSettings()
        case .notifications:
            if perms.notificationStatus == .notDetermined {
                perms.requestNotificationPermission()
            } else {
                perms.openNotificationSettings()
            }
        case .automation:
            perms.requestAutomationPermission()
        case .upsHelper:
            SystemUPSSettingsManager.shared.commitChangesToSystem(forceAuthorize: true) {
                self.collector.refresh()
            }
        }
    }

    // MARK: - Section Card Builder

    private func diagnosticSectionCard<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(mintAccent)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 140, alignment: .leading)

            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 0.8)
            )
    }
}
