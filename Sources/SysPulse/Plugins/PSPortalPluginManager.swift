import Foundation
import AppKit
import CoreGraphics
import Darwin
import IOKit.pwr_mgt
import IOKit.ps
import Network
import Observation
@preconcurrency import UserNotifications

public enum PortalSleepPreventMode: String, CaseIterable, Identifiable, Sendable {
    case always = "always"
    case scheduled = "scheduled"
    case idleTimeout = "idle_timeout"

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .always: return "全天"
        case .scheduled: return "指定时段"
        case .idleTimeout: return "闲置释放"
        }
    }
}

public enum PortalPowerCondition: String, CaseIterable, Identifiable, Sendable {
    case acOnly = "ac_only"
    case always = "always"

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .acOnly: return "仅插电"
        case .always: return "插电与电池"
        }
    }
}

public enum PortalRelayMode: String, CaseIterable, Identifiable, Sendable {
    case oneWayDirect = "oneway"
    case twoWayTelemetry = "twoway"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oneWayDirect: return "单向视频直连 (推荐)"
        case .twoWayTelemetry: return "双向遥测验证"
        }
    }

    public var subtitle: String {
        switch self {
        case .oneWayDirect: return "仅劫持 Portal 上行握手，下行视频全程直连不经 Mac 限速"
        case .twoWayTelemetry: return "双向中继捕获 PS5 确认与码率回报，开播后自动交还直连"
        }
    }
}

public enum BitrateProfile: String, CaseIterable, Identifiable, Sendable {
    case mbps65 = "65 Mbps"
    case mbps100 = "100 Mbps (推荐)"
    case mbps200 = "200 Mbps (极致)"

    public var id: String { rawValue }

    public var shortTag: String {
        switch self {
        case .mbps65: return "65M"
        case .mbps100: return "100M"
        case .mbps200: return "200M"
        }
    }

    public var description: String {
        switch self {
        case .mbps65: return "清晰度显著高于官方默认，对 Wi-Fi 稳定性要求均衡"
        case .mbps100: return "官方限制近 4 倍画质，极度细腻通透，强烈推荐"
        case .mbps200: return "极致无损级码率，需要极佳的 5GHz / 6GHz Wi-Fi 环境"
        }
    }
}

public enum PluginModuleType: String, CaseIterable, Identifiable, Sendable {
    case psPortal = "ps_portal"
    case wifiLatency = "wifi_latency"
    case arpSniffer = "arp_sniffer"
    case upsManager = "ups_manager"
    case antigravityContext = "antigravity_context"
    case aiToolCleaner = "ai_tool_cleaner"
    case softwareUpdater = "software_updater"
    case accessoryLocation = "accessory_location"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .psPortal: return "PS Portal 串流画质增强"
        case .wifiLatency: return "Wi-Fi 低延迟"
        case .arpSniffer: return "局域网 ARP 嗅探与设备诊断"
        case .upsManager: return "UPS 电源管理"
        case .antigravityContext: return "Antigravity 扩展"
        case .aiToolCleaner: return "AI 工具清理与维护"
        case .softwareUpdater: return "软件更新中心"
        case .accessoryLocation: return "iOS 虚拟定位"
        }
    }

    /// 各插件当前版本号；后续涉及某插件功能或逻辑变更时对应版本自动递增 0.0.1。
    public var version: String {
        switch self {
        case .psPortal: return "0.1.7"
        case .wifiLatency: return "0.1.1"
        case .arpSniffer: return "0.1.3"
        case .upsManager: return "0.1.7"
        case .antigravityContext: return "0.2.0"
        case .aiToolCleaner: return "0.1.3"
        case .softwareUpdater: return "0.1.5"
        case .accessoryLocation: return "0.1.3"
        }
    }
}

public enum SonyDeviceRole: String, Sendable, Codable {
    case ps5Host
    case portalClient
    case unknownSony
    case other
}

public enum PortalEngineState: Equatable, Sendable {
    case disabled
    case idle
    case authorizing
    case starting
    case autoWatching
    case autoBursting
    case manualListening(remainingSeconds: Int)
    case enhancingActive(bitrateTag: String)
    case stopping
    case suspendedOutOfLAN
    case needsConfiguration
    case deviceOffline
    case alreadyStreamingHint
    case error(String)

    public var badgeText: String {
        switch self {
        case .disabled: return "未启用"
        case .idle: return "已启用"
        case .authorizing: return "等待授权..."
        case .starting: return "启动中..."
        case .autoWatching: return "自动待命中"
        case .autoBursting: return "正在连接..."
        case .manualListening(let s): return s > 0 ? "监听中 (\(s)s)" : "监听握手中..."
        case .enhancingActive: return "画质增强中"
        case .stopping: return "停止中..."
        case .suspendedOutOfLAN: return "不在家庭网络"
        case .needsConfiguration: return "待配置 IP"
        case .deviceOffline: return "设备未在线"
        case .alreadyStreamingHint: return "需重连生效"
        case .error: return "启动异常"
        }
    }

    public func subtitle(bitrateTag: String) -> String {
        switch self {
        case .disabled:
            return "插件未启用，可随时在模块开关中开启"
        case .idle:
            return "就绪 · 可一键手动监听，或开启全自动增强守望"
        case .authorizing:
            return "请在系统弹窗中输入密码或验证触控 ID"
        case .starting:
            return "正在初始化原生 BPF 旁路监听..."
        case .autoWatching:
            return "静默监听中 · Portal 唤醒后自动开启 \(bitrateTag)"
        case .autoBursting:
            return "已捕捉 Portal 连接请求，正在切换 \(bitrateTag)..."
        case .manualListening(let s):
            return "等待 Portal 点击连接（剩余 \(s)s）"
        case .enhancingActive(let tag):
            return "当前串流已开启 \(tag) 高画质 · 视频直连不经过 Mac"
        case .stopping:
            return "正在恢复局域网直连 ARP 路由..."
        case .suspendedOutOfLAN:
            return "当前不在家庭局域网，自动守望已休眠"
        case .needsConfiguration:
            return "需先扫描或填写 PS5 与 Portal IP"
        case .deviceOffline:
            return "PS5 未开机，请在唤醒主机后重试"
        case .alreadyStreamingHint:
            return "已在串流中，断开并重新连接后即可生效"
        case .error(let msg):
            return msg
        }
    }
}

public struct DiscoveredDevice: Identifiable, Sendable, Codable {
    public let id: String
    public let ip: String
    public let mac: String
    public let isLikelySony: Bool
    public let role: SonyDeviceRole
    public let hostName: String?
    public let label: String
    public let confidence: Int
    public let matchReasons: [String]
    public let interfaceName: String?

    public init(
        id: String,
        ip: String,
        mac: String,
        isLikelySony: Bool,
        role: SonyDeviceRole = .other,
        hostName: String? = nil,
        label: String,
        confidence: Int = 50,
        matchReasons: [String] = [],
        interfaceName: String? = nil
    ) {
        self.id = id
        self.ip = ip
        self.mac = mac
        self.isLikelySony = isLikelySony
        self.role = role
        self.hostName = hostName
        self.label = label
        self.confidence = confidence
        self.matchReasons = matchReasons
        self.interfaceName = interfaceName
    }
}

public struct PortalLogEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let text: String
}

@Observable
@MainActor
public final class PSPortalPluginManager {
    public static let shared = PSPortalPluginManager()

    public var activePluginType: PluginModuleType? = nil
    public var engineState: PortalEngineState = .disabled
    public var isRunning: Bool = false
    public var isStopping: Bool = false
    public var isListening: Bool = false
    public var isStreamActive: Bool = false
    public var autoWatchEnabled: Bool = false
    public var debugModeEnabled: Bool = false
    public var preventSleepInAutoWatch: Bool = true
    public var sleepPreventMode: PortalSleepPreventMode = .always
    public var scheduleStartHour: Int = 18
    public var scheduleEndHour: Int = 1
    public var idleTimeoutHours: Int = 4
    public var powerCondition: PortalPowerCondition = .acOnly
    public var lowBatteryThreshold: Int = 20
    public var allowClamshellKeepAwake: Bool = false
    public private(set) var isMacLaptop: Bool = false
    public private(set) var isSleepAssertionActive: Bool = false
    public private(set) var isClamshellKeepAwakeActive: Bool = false
    public private(set) var sleepPreventionStatusText: String = ""
    public var notificationsEnabled: Bool = true
    public var relayMode: PortalRelayMode = .oneWayDirect
    public var targetBitrate: BitrateProfile = .mbps100
    public var selectedInterface: String = "en0"
    public var activeInterfaces: [ActiveInterfaceInfo] = []
    public var selectedInterfaceInfo: ActiveInterfaceInfo? {
        activeInterfaces.first(where: { $0.name == selectedInterface })
    }
    public var ps5IP: String = ""
    public var portalIP: String = ""
    public var discoveredDevices: [DiscoveredDevice] = []
    public var isScanningDevices: Bool = false
    public var runWithAdmin: Bool = true
    public var isCheckingForUpdates: Bool = false
    public var updateStatusMessage: String? = nil
    public var logs: [PortalLogEntry] = []
    public var lastLogAppendAt: Date = .distantPast
    public var pluginVersion: String = PluginModuleType.psPortal.version
    public var pluginAuthor: String = "atameric"
    public var pluginRepo: String = "https://github.com/atameric/ps5-portal-high-bitrate"
    public var installedCommitSHA: String = "4430daa"
    public var installedCommitDate: String = "2026-10-21"
    public var installedCommitMsg: String = "docs: add October 21 Raspberry Pi and mobile update"
    public var lastError: String? = nil
    public var listenRemainingSeconds: Int? = nil
    public var cooldownRemainingSeconds: Int? = nil

    private var relayProcess: Process?
    private var outputPipe: Pipe?
    private var listenCountdownTimer: Timer?
    private var listenDeadline: Date?
    private var listenCountdownDuration: Int = 120
    private var cooldownCountdownTimer: Timer?
    private var cooldownDeadline: Date?
    private var cooldownCountdownDuration: Int = 20
    private var logLineBuffer: Data = Data()
    private var relaySessionID: UInt64 = 0
    private var resetWorkItem: DispatchWorkItem?
    private var hasExplicitInterfaceConfig: Bool = false
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.syspulse.portal.pathmonitor")
    private var pathDebounceTask: Task<Void, Never>?
    private var streamPresenceTask: Task<Void, Never>?
    private var consecutivePortalMisses: Int = 0
    private var suspendedBySleep: Bool = false
    private var sleepAssertionID: IOPMAssertionID = 0
    private var lastPortalActivityAt: Date = Date()
    private var lastSleepPolicyLogKey: String = ""
    private var internalPowerRunLoopSource: CFRunLoopSource?
    private var lowPowerModeObserver: NSObjectProtocol?
    private var sleepPolicyTimer: Timer?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var clamshellDesiredState: Bool = false
    private var clamshellApplyInFlight: Bool = false
    private var clamshellLastAppliedState: Bool = false

    nonisolated private static let privilegedEngineDirectory = "/Library/Application Support/SysPulse"
    nonisolated private static let privilegedEnginePath = "/Library/Application Support/SysPulse/portal_engine"
    nonisolated private static let clamshellStateFilePath = "/Library/Application Support/SysPulse/syspulse_psportal_clamshell.state"
    private let pidFilePath = "/Library/Application Support/SysPulse/syspulse_psportal.pid"

    private var logFilePath: String {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SysPulse", isDirectory: true)
        if !FileManager.default.fileExists(atPath: logsDir.path) {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir.appendingPathComponent("psportal.log").path
    }

    public var pluginDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SysPulse/Plugins/PSPortal", isDirectory: true)
    }

    private var configFileURL: URL {
        pluginDirectoryURL.appendingPathComponent("config.json")
    }

    private var manifestFileURL: URL {
        pluginDirectoryURL.appendingPathComponent("manifest.json")
    }

    private var engineFileURL: URL {
        let appSupportEngine = pluginDirectoryURL.appendingPathComponent("portal_engine")
        if FileManager.default.isExecutableFile(atPath: appSupportEngine.path) {
            return appSupportEngine
        }
        if let bundleEngine = Bundle.main.resourceURL?.appendingPathComponent("Plugins/PSPortal/portal_engine"),
           FileManager.default.isExecutableFile(atPath: bundleEngine.path) {
            return bundleEngine
        }
        return appSupportEngine
    }

    private var isBootstrapped: Bool = false

    private init() {
        if FeatureToggleManager.shared.enablePluginPSPortal {
            activate()
        }
    }

    public func activate() {
        if !isBootstrapped {
            bootstrapPluginDirectory()
            loadManifest()
            loadConfig()
            isBootstrapped = true
        }
        detectInterfaces()
        if case .disabled = engineState {
            transition(to: (ps5IP.isEmpty || portalIP.isEmpty) ? .needsConfiguration : .idle)
        }
        if logs.isEmpty {
            appendLog("[SysPulse] 插件子系统加载完成：PS Portal 串流画质增强模块 (v\(pluginVersion))")
        }
        startInternalPowerObserver()
        performClamshellSelfHealIfNeeded()
        startNetworkPathMonitor()
        if autoWatchEnabled {
            ensureAutoWatchRunning(reason: "插件已激活")
        } else {
            evaluateSleepPrevention(logTransition: false)
        }
    }

    public func deactivate() {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathDebounceTask?.cancel()
        pathDebounceTask = nil
        streamPresenceTask?.cancel()
        streamPresenceTask = nil
        stopInternalPowerObserver()
        stopSleepPolicyTimer()
        releaseSleepAssertion()
        setClamshellKeepAwakeDesired(false)
        sleepPreventionStatusText = ""
        lastSleepPolicyLogKey = ""
        stopRelay()
        stopListenCountdown()
        stopCooldownCountdown()
        isScanningDevices = false
        discoveredDevices = []
        transition(to: .disabled)
    }

    private func transition(to newState: PortalEngineState) {
        engineState = newState
        switch newState {
        case .disabled, .idle, .needsConfiguration, .suspendedOutOfLAN, .deviceOffline, .error:
            isRunning = false
            isStopping = false
            isListening = false
            isStreamActive = false
        case .authorizing, .starting, .autoWatching:
            isRunning = true
            isStopping = false
            isListening = false
            isStreamActive = false
        case .autoBursting, .manualListening:
            isRunning = true
            isStopping = false
            isListening = true
            isStreamActive = false
        case .enhancingActive:
            isRunning = autoWatchEnabled
            isStopping = false
            isListening = false
            isStreamActive = true
        case .alreadyStreamingHint:
            isRunning = autoWatchEnabled
            isStopping = false
            isListening = false
            isStreamActive = false
        case .stopping:
            isStopping = true
            isListening = false
            isStreamActive = false
        }
        evaluateSleepPrevention(logTransition: true)
    }

    private func startListenCountdown(seconds: Int = 120) {
        listenCountdownTimer?.invalidate()
        listenCountdownDuration = max(1, seconds)
        listenDeadline = Date().addingTimeInterval(TimeInterval(listenCountdownDuration))
        listenRemainingSeconds = listenCountdownDuration

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isListening, let deadline = self.listenDeadline else {
                    self.stopListenCountdown()
                    return
                }
                let remaining = max(0, min(self.listenCountdownDuration, Int(ceil(deadline.timeIntervalSinceNow))))
                if self.listenRemainingSeconds != remaining {
                    self.listenRemainingSeconds = remaining
                    if case .manualListening = self.engineState {
                        self.engineState = .manualListening(remainingSeconds: remaining)
                    }
                }
                if remaining <= 0 {
                    self.listenCountdownTimer?.invalidate()
                    self.listenCountdownTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        listenCountdownTimer = timer
    }

    private func stopListenCountdown() {
        listenCountdownTimer?.invalidate()
        listenCountdownTimer = nil
        listenDeadline = nil
        listenRemainingSeconds = nil
    }

    private func startCooldownCountdown(seconds: Int = 20) {
        cooldownCountdownTimer?.invalidate()
        cooldownCountdownDuration = max(1, seconds)
        cooldownDeadline = Date().addingTimeInterval(TimeInterval(cooldownCountdownDuration))
        cooldownRemainingSeconds = cooldownCountdownDuration

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning, let deadline = self.cooldownDeadline else {
                    self.stopCooldownCountdown()
                    return
                }
                let remaining = max(0, min(self.cooldownCountdownDuration, Int(ceil(deadline.timeIntervalSinceNow))))
                if self.cooldownRemainingSeconds != remaining {
                    self.cooldownRemainingSeconds = remaining
                }
                if remaining <= 0 {
                    self.cooldownCountdownTimer?.invalidate()
                    self.cooldownCountdownTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cooldownCountdownTimer = timer
    }

    private func stopCooldownCountdown() {
        cooldownCountdownTimer?.invalidate()
        cooldownCountdownTimer = nil
        cooldownDeadline = nil
        cooldownRemainingSeconds = nil
    }

    // MARK: - 目录与资源自举

    public func bootstrapPluginDirectory() {
        let fileManager = FileManager.default
        let dir = pluginDirectoryURL

        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        guard let bundlePluginDir = Bundle.main.resourceURL?.appendingPathComponent("Plugins/PSPortal") else {
            return
        }

        // 按需初始化参考脚本，并在文件变化时增量同步原生引擎与清单
        if let items = try? fileManager.contentsOfDirectory(atPath: bundlePluginDir.path) {
            for item in items {
                let src = bundlePluginDir.appendingPathComponent(item)
                let dst = dir.appendingPathComponent(item)
                let dstExists = fileManager.fileExists(atPath: dst.path)

                if item == "portal_engine" || item == "manifest.json" {
                    if !dstExists || Self.shouldReplaceResource(src: src, dst: dst) {
                        try? fileManager.removeItem(at: dst)
                        try? fileManager.copyItem(at: src, to: dst)
                    }
                    if item == "portal_engine" {
                        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
                    }
                } else if !dstExists {
                    try? fileManager.copyItem(at: src, to: dst)
                    if item.hasSuffix(".py") {
                        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
                    }
                }
            }
        }
    }

    private static func shouldReplaceResource(src: URL, dst: URL) -> Bool {
        let fm = FileManager.default
        guard let srcAttr = try? fm.attributesOfItem(atPath: src.path),
              let dstAttr = try? fm.attributesOfItem(atPath: dst.path) else {
            return true
        }
        let srcSize = srcAttr[.size] as? NSNumber
        let dstSize = dstAttr[.size] as? NSNumber
        if srcSize != dstSize { return true }
        if let srcDate = srcAttr[.modificationDate] as? Date,
           let dstDate = dstAttr[.modificationDate] as? Date,
           abs(srcDate.timeIntervalSince(dstDate)) > 1.0 {
            return true
        }
        return false
    }

    private func writeDefaultManifest() {
        let json = """
        {
          "id": "com.syspulse.plugin.psportal",
          "name": "PS Portal 串流画质增强",
          "version": "0.1.3",
          "author": "atameric",
          "license": "GPL-3.0",
          "repo": "https://github.com/atameric/ps5-portal-high-bitrate",
          "description": "突破 PlayStation Portal 官方默认串流比特率限制，通过局域网握手阶段重写比特率参数，实现 65 Mbps / 100 Mbps / 200 Mbps 极致清晰度，无需对 PS5 或 PS Portal 进行任何越狱与硬改。",
          "entry": "portal_engine"
        }
        """
        try? json.write(to: manifestFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 属性与配置读取

    public func loadManifest() {
        guard let data = try? Data(contentsOf: manifestFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let v = json["version"] as? String { self.pluginVersion = v }
        if let a = json["author"] as? String { self.pluginAuthor = a }
        if let r = json["repo"] as? String { self.pluginRepo = r }
        if let sha = json["installedCommitSHA"] as? String { self.installedCommitSHA = sha }
        if let d = json["installedCommitDate"] as? String { self.installedCommitDate = d }
        if let m = json["installedCommitMsg"] as? String { self.installedCommitMsg = m }
    }

    public func loadConfig() {
        guard let data = try? Data(contentsOf: configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let modeRaw = json["relayMode"] as? String, let matchedMode = PortalRelayMode(rawValue: modeRaw) {
            self.relayMode = matchedMode
        }
        if let b = json["targetBitrate"] as? String {
            if let matched = BitrateProfile.allCases.first(where: { $0.shortTag == b || $0.rawValue.contains(b) }) {
                self.targetBitrate = matched
            }
        }
        let isManualInterface = (json["interfaceManualSelection"] as? Bool) ?? false
        if isManualInterface, let iface = json["interface"] as? String, !iface.isEmpty {
            self.selectedInterface = iface
            self.hasExplicitInterfaceConfig = true
        } else {
            self.hasExplicitInterfaceConfig = false
        }
        if let ps5 = json["ps5IP"] as? String, !ps5.isEmpty {
            self.ps5IP = ps5
        }
        if let portal = json["portalIP"] as? String, !portal.isEmpty {
            self.portalIP = portal
        }
        if let autoWatch = json["autoWatchEnabled"] as? Bool {
            self.autoWatchEnabled = autoWatch
        }
        if let debugMode = json["debugModeEnabled"] as? Bool {
            self.debugModeEnabled = debugMode
        }
        if let preventSleep = json["preventSleepInAutoWatch"] as? Bool {
            self.preventSleepInAutoWatch = preventSleep
        }
        if let modeRaw = json["sleepPreventMode"] as? String,
           let matchedSleepMode = PortalSleepPreventMode(rawValue: modeRaw) {
            self.sleepPreventMode = matchedSleepMode
        }
        if let sHour = json["scheduleStartHour"] as? Int {
            self.scheduleStartHour = ((sHour % 24) + 24) % 24
        }
        if let eHour = json["scheduleEndHour"] as? Int {
            self.scheduleEndHour = ((eHour % 24) + 24) % 24
        }
        if let timeoutH = json["idleTimeoutHours"] as? Int {
            self.idleTimeoutHours = max(1, min(24, timeoutH))
        }
        if let pCondRaw = json["powerCondition"] as? String,
           let matchedCond = PortalPowerCondition(rawValue: pCondRaw) {
            self.powerCondition = matchedCond
        }
        if let threshold = json["lowBatteryThreshold"] as? Int {
            self.lowBatteryThreshold = max(5, min(50, threshold))
        }
        if let clamshell = json["allowClamshellKeepAwake"] as? Bool {
            self.allowClamshellKeepAwake = clamshell
        }
        if let notif = json["notificationsEnabled"] as? Bool {
            self.notificationsEnabled = notif
        }
        if let adm = json["runWithAdmin"] as? Bool {
            self.runWithAdmin = adm
        }
    }

    public func saveConfig() {
        let dict: [String: Any] = [
            "relayMode": relayMode.rawValue,
            "targetBitrate": targetBitrate.shortTag,
            "interface": selectedInterface,
            "interfaceManualSelection": hasExplicitInterfaceConfig,
            "ps5IP": ps5IP,
            "portalIP": portalIP,
            "autoWatchEnabled": autoWatchEnabled,
            "debugModeEnabled": debugModeEnabled,
            "preventSleepInAutoWatch": preventSleepInAutoWatch,
            "sleepPreventMode": sleepPreventMode.rawValue,
            "scheduleStartHour": scheduleStartHour,
            "scheduleEndHour": scheduleEndHour,
            "idleTimeoutHours": idleTimeoutHours,
            "powerCondition": powerCondition.rawValue,
            "lowBatteryThreshold": lowBatteryThreshold,
            "allowClamshellKeepAwake": allowClamshellKeepAwake,
            "notificationsEnabled": notificationsEnabled,
            "runWithAdmin": runWithAdmin
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: configFileURL)
        }
    }

    public func reloadPlugin() {
        stopRelay()
        bootstrapPluginDirectory()
        loadManifest()
        loadConfig()
        detectInterfaces()
        appendLog("[SysPulse] 插件配置与脚本已重新载入。")
    }

    public func openPluginFolder() {
        let dir = pluginDirectoryURL
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    // MARK: - 检查插件更新

    public func checkForPluginUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusMessage = "正在连接 GitHub 比对版本..."
        appendLog("[更新] 正在连接 GitHub 比对版本...")

        Task.detached {
            var cloudSHA: String? = nil
            var cloudMsg: String = ""

            if let apiURL = URL(string: "https://api.github.com/repos/atameric/ps5-portal-high-bitrate/commits/main") {
                var request = URLRequest(url: apiURL)
                request.setValue("SysPulse-macOS-Agent", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 7.0
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sha = json["sha"] as? String {
                    cloudSHA = String(sha.prefix(7))
                    if let commitObj = json["commit"] as? [String: Any],
                       let msg = commitObj["message"] as? String {
                        cloudMsg = msg.components(separatedBy: .newlines).first ?? ""
                    }
                }
            }

            await MainActor.run {
                self.isCheckingForUpdates = false
                let localSHA = self.installedCommitSHA

                if let sha = cloudSHA {
                    if sha.lowercased() == localSHA.lowercased() {
                        // 场景 A: 本地已是官方最新版本
                        self.updateStatusMessage = "已是官方最新版本 (\(localSHA))"
                        self.appendLog("[更新] ✅ 本地已是官方最新版本！")
                        self.appendLog("├─ 本地已验证版本: [\(localSHA)] (\(self.installedCommitDate) · 稳定运行中)")
                        self.appendLog("└─ 官方远端最新版: [\(sha)] (完全同步)")
                        self.appendLog("[说明] 当前插件协议逻辑已与官方主分支保持同步。")
                    } else {
                        // 场景 B: 官方有新提交
                        self.updateStatusMessage = "官方有新提交 [\(sha)] · 随版本推送"
                        self.appendLog("[更新] 💡 发现官方主分支有新提交！")
                        self.appendLog("├─ 本地已验证版本: [\(localSHA)] (已完成实机串流测试 · 稳定运行中)")
                        self.appendLog("└─ 官方远端最新版: [\(sha)] (最新提交说明: \(cloudMsg))")
                        self.appendLog("[提示] 🛡️ 出于系统网络与串流稳定性保障，禁止本地直接在线热覆盖。")
                        self.appendLog("[说明] 新源码将在经过完整实机兼容性测试后，随 SysPulse 下一版本推送。")
                    }
                } else {
                    // 场景 C: 网络离线或异常
                    self.updateStatusMessage = "本地版本 [\(localSHA)] 正常就绪"
                    self.appendLog("[更新] ⚠️ 无法连接到 GitHub 远端，本地插件已验证版本 [\(localSHA)] 正常就绪。")
                }
            }
        }
    }

    // MARK: - 网络接口与设备扫描

    public func selectInterface(_ name: String) {
        selectedInterface = name
        hasExplicitInterfaceConfig = true
        saveConfig()
    }

    public func detectInterfaces() {
        let (list, defaultIface) = ActiveInterfaceInfo.discoverActive()
        self.activeInterfaces = list.isEmpty
            ? [ActiveInterfaceInfo(name: defaultIface.isEmpty ? "en0" : defaultIface, ip: "", label: "未检测到活跃 IP")]
            : list

        let isSelectedActive = list.contains(where: { $0.name == selectedInterface })
        if !hasExplicitInterfaceConfig || !isSelectedActive {
            if !defaultIface.isEmpty && list.contains(where: { $0.name == defaultIface }) {
                selectedInterface = defaultIface
            } else if let firstActive = list.first {
                selectedInterface = firstActive.name
            } else {
                selectedInterface = defaultIface.isEmpty ? "en0" : defaultIface
            }
        }
    }

    nonisolated private static func collectPortalScanArpSnapshot(
        targetIface: String,
        activeIfaceNames: Set<String>,
        localIP: String,
        gatewayIP: String
    ) -> [String: (ip: String, mac: String, ifName: String)] {
        var rawEntries = LanDeviceSnifferEngine.readArpTableViaKernelSysctl()
        if rawEntries.isEmpty {
            rawEntries = LanDeviceSnifferEngine.readArpTableViaCli()
        }

        var arpByIP: [String: (ip: String, mac: String, ifName: String)] = [:]
        for entry in rawEntries {
            let ip = entry.ip
            let mac = LanOuiDatabase.normalizeMAC(entry.mac) ?? entry.mac.lowercased()
            let ifName = entry.ifName.isEmpty ? targetIface : entry.ifName

            guard !ip.isEmpty, ip.contains("."),
                  !entry.isLocal, ip != localIP, ip != "127.0.0.1", ip != gatewayIP,
                  !ip.hasSuffix(".255"), !ip.hasPrefix("224."), !ip.hasPrefix("239."),
                  ip != "255.255.255.255" else { continue }
            guard mac.count == 17,
                  mac != "00:00:00:00:00:00",
                  mac != "ff:ff:ff:ff:ff:ff" else { continue }
            if !entry.ifName.isEmpty && entry.ifName != targetIface && !activeIfaceNames.contains(entry.ifName) {
                continue
            }
            if let existing = arpByIP[ip], existing.ifName == targetIface && ifName != targetIface {
                continue
            }
            arpByIP[ip] = (ip: ip, mac: mac, ifName: ifName)
        }
        return arpByIP
    }

    private final class ProbeResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T

        init(_ initial: T) {
            self.storage = initial
        }

        func set(_ value: T) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        func get() -> T {
            lock.lock()
            let copy = storage
            lock.unlock()
            return copy
        }
    }

    public func bindDiscoveredDevice(_ device: DiscoveredDevice, as roleOverride: SonyDeviceRole? = nil) {
        let role = roleOverride ?? device.role
        if let iface = device.interfaceName, !iface.isEmpty, iface != selectedInterface,
           activeInterfaces.contains(where: { $0.name == iface }) {
            selectInterface(iface)
            appendLog("[SysPulse] 🔄 已同步切换监听网卡至 \(iface)")
        }
        switch role {
        case .ps5Host:
            ps5IP = device.ip
        case .portalClient:
            portalIP = device.ip
        case .unknownSony, .other:
            break
        }
        saveConfig()
        refreshConfigurationStateIfIdle()
        if autoWatchEnabled && !isRunning {
            ensureAutoWatchRunning(reason: "设备配置更新")
        }
    }

    public func scanLocalDevices() {
        guard !isScanningDevices else { return }
        if case .autoBursting = engineState {
            appendLog("[提示] 当前正在自动触发连接握手窗口，请等待数秒后再执行扫描。")
            return
        }
        detectInterfaces()
        self.isScanningDevices = true
        self.appendLog("[SysPulse] 正在唤醒并探测局域网 PS5 / PS Portal 设备...")

        let targetIface = self.selectedInterface
        let localIP = self.selectedInterfaceInfo?.ip ?? ""
        let activeIfaceNames = Set(self.activeInterfaces.map(\.name))
        let (gatewayIP, _) = NetworkDetailModel.detectGatewayAndInterface()
        let currentPS5 = self.ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPortal = self.portalIP.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let subnetInfo = ActiveInterfaceInfo.ipv4SubnetInfo(for: targetIface)
            let (targetHosts, resolvedBroadcasts) = LanDeviceSnifferEngine.resolveScanTargetHosts(
                interfaceName: targetIface,
                fallbackGatewayIP: gatewayIP,
                extraIPs: [currentPS5, currentPortal]
            )
            var mutableBroadcasts = resolvedBroadcasts
            if let bcast = subnetInfo?.broadcast, !bcast.isEmpty, !mutableBroadcasts.contains(bcast) {
                mutableBroadcasts.append(bcast)
            }
            let broadcastTargets = mutableBroadcasts

            let priorityIPs = Array(Set([currentPS5, currentPortal].filter {
                !$0.isEmpty && $0 != localIP && $0 != gatewayIP && Self.isValidUnicastIPv4($0)
            }))

            // 第 1 阶段：优先 IP + 全网段并发唤醒
            if !priorityIPs.isEmpty {
                LanDeviceSnifferEngine.probeHostsViaICMP(ips: priorityIPs, interfaceName: targetIface, batchSize: priorityIPs.count, batchDelayUs: 0)
                LanDeviceSnifferEngine.probeHostsViaTCP(ips: priorityIPs, ports: [9295, 443, 80, 7000, 8008], interfaceName: targetIface, batchSize: priorityIPs.count, batchDelayUs: 10_000)
                LanDeviceSnifferEngine.probeHostsViaUDP(ips: priorityIPs, ports: [5353, 9302], interfaceName: targetIface, batchSize: priorityIPs.count, batchDelayUs: 0)
            }

            if !targetHosts.isEmpty {
                LanDeviceSnifferEngine.probeHostsViaUDP(ips: targetHosts, ports: [5353, 137], interfaceName: targetIface, batchSize: 32, batchDelayUs: 6_000)
                LanDeviceSnifferEngine.probeHostsViaICMP(ips: targetHosts, interfaceName: targetIface, batchSize: 32, batchDelayUs: 6_000)
            }
            usleep(450_000)

            var arpByIP = Self.collectPortalScanArpSnapshot(
                targetIface: targetIface,
                activeIfaceNames: activeIfaceNames,
                localIP: localIP,
                gatewayIP: gatewayIP
            )

            // 第 2 阶段：针对无线 DTIM 省电设备执行二次全量补漏唤醒
            let hasSavedPortalInArp = currentPortal.isEmpty || arpByIP[currentPortal] != nil
            let hasPortalCandidateInArp = arpByIP.values.contains {
                LanDeviceSnifferEngine.isPortalOUI($0.mac) ||
                LanDeviceSnifferEngine.isSonyInteractiveOUI($0.mac)
            }
            if !hasSavedPortalInArp || !hasPortalCandidateInArp {
                let missingPriority = priorityIPs.filter { arpByIP[$0] == nil }
                let missingHosts = targetHosts.filter { arpByIP[$0] == nil }
                let wakeupIPs = Array(Set(missingPriority + missingHosts))
                if !wakeupIPs.isEmpty {
                    DispatchQueue.main.async {
                        self?.appendLog("[SysPulse] 正在针对深度待机无线设备执行二次唤醒探活...")
                    }
                    LanDeviceSnifferEngine.probeHostsViaICMP(ips: wakeupIPs, interfaceName: targetIface, batchSize: 32, batchDelayUs: 7_000)
                    LanDeviceSnifferEngine.probeHostsViaTCP(ips: wakeupIPs, ports: [9295, 443], interfaceName: targetIface, batchSize: 32, batchDelayUs: 8_000)
                    usleep(550_000)
                    let refreshed = Self.collectPortalScanArpSnapshot(
                        targetIface: targetIface,
                        activeIfaceNames: activeIfaceNames,
                        localIP: localIP,
                        gatewayIP: gatewayIP
                    )
                    for (ip, item) in refreshed where arpByIP[ip] == nil {
                        arpByIP[ip] = item
                    }
                }
            }

            // 第 3 阶段：全量单播 DDP 9302 + 多协议自报 + TCP 9295/7000/8008 端口指纹并查
            DispatchQueue.main.async {
                self?.appendLog("[SysPulse] 正在通过 DDP (9302) + TCP 9295 与多协议特征识别 Sony 设备...")
            }

            let targetIfaceARPIPs = arpByIP.values.filter { $0.ifName == targetIface }.map(\.ip)
            let ddpTargets = Array(Set(targetIfaceARPIPs + priorityIPs))
            let reportTargets = Array(arpByIP.keys)

            let ddpBox = ProbeResultBox<[String: PlayStationDDPInfo]>([:])
            let reportBox = ProbeResultBox<[String: LanPeerSelfReport]>([:])
            let tcp9295Box = ProbeResultBox<Set<String>>([])
            let tcp7000Box = ProbeResultBox<Set<String>>([])
            let tcp8008Box = ProbeResultBox<Set<String>>([])
            let probeGroup = DispatchGroup()

            probeGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let map = LanDeviceSnifferEngine.probePlayStationDDP(
                    targetIPs: ddpTargets,
                    broadcastIPs: broadcastTargets,
                    interfaceName: targetIface,
                    timeoutMs: 600
                )
                ddpBox.set(map)
                probeGroup.leave()
            }

            if !reportTargets.isEmpty {
                probeGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let reports = LanDeviceSnifferEngine.probePeerSelfReports(
                        targetIPs: reportTargets,
                        gatewayIP: gatewayIP,
                        localIP: localIP,
                        interfaceName: targetIface,
                        timeoutMs: 450
                    )
                    reportBox.set(reports)
                    probeGroup.leave()
                }

                probeGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let open = LanDeviceSnifferEngine.probeHostsViaTCPWithResults(
                        ips: targetIfaceARPIPs.isEmpty ? reportTargets : targetIfaceARPIPs,
                        port: 9295,
                        interfaceName: targetIface,
                        timeoutMs: 320
                    )
                    tcp9295Box.set(open)
                    probeGroup.leave()
                }

                probeGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let open = LanDeviceSnifferEngine.probeHostsViaTCPWithResults(
                        ips: targetIfaceARPIPs.isEmpty ? reportTargets : targetIfaceARPIPs,
                        port: 7000,
                        interfaceName: targetIface,
                        timeoutMs: 220
                    )
                    tcp7000Box.set(open)
                    probeGroup.leave()
                }

                probeGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let open = LanDeviceSnifferEngine.probeHostsViaTCPWithResults(
                        ips: targetIfaceARPIPs.isEmpty ? reportTargets : targetIfaceARPIPs,
                        port: 8008,
                        interfaceName: targetIface,
                        timeoutMs: 220
                    )
                    tcp8008Box.set(open)
                    probeGroup.leave()
                }
            }

            _ = probeGroup.wait(timeout: .now() + .milliseconds(780))
            let ddpMap = ddpBox.get()
            let selfReports = reportBox.get()
            let tcp9295Open = tcp9295Box.get()
            let tcp7000Open = tcp7000Box.get()
            let tcp8008Open = tcp8008Box.get()

            var results: [DiscoveredDevice] = []
            for entry in arpByIP.values {
                let ip = entry.ip
                let mac = entry.mac
                let ddp = ddpMap[ip]
                let report = selfReports[ip]
                let isSonyOUI = LanDeviceSnifferEngine.isSonyOUI(mac)
                let isPortalOUI = LanDeviceSnifferEngine.isPortalOUI(mac)
                let isSIEOUI = LanDeviceSnifferEngine.isSonyInteractiveOUI(mac)
                let isLocalAdminMAC = LanOuiDatabase.isLocallyAdministeredMAC(mac)
                let hasTCP9295 = tcp9295Open.contains(ip)
                let isSmartTVPort = tcp7000Open.contains(ip) || tcp8008Open.contains(ip)

                let selfReportName = [report?.friendlyName, report?.model, report?.hostname]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                let combinedText = [report?.friendlyName, report?.model, report?.hostname, report?.manufacturer]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")

                let isNonHandheldSonyDevice = !combinedText.contains("portal") && (
                    LanDeviceSnifferEngine.isNonHandheldSonyText(combinedText) ||
                    combinedText.contains("speaker") ||
                    combinedText.contains("srs-") ||
                    combinedText.contains("vpl-") ||
                    (combinedText.contains("tv") && !combinedText.contains("ps")) ||
                    isSmartTVPort
                )

                var ps5Score = 0
                var ps5Reasons: [String] = []
                if ddp != nil { ps5Score += 85; ps5Reasons.append("DDP 9302") }
                if hasTCP9295 { ps5Score += 25; ps5Reasons.append("TCP 9295") }
                if isSIEOUI && (ddp != nil || hasTCP9295) { ps5Score += 10; ps5Reasons.append("SIE 硬件段") }
                if isNonHandheldSonyDevice { ps5Score -= 90 }

                var portalScore = 0
                var portalReasons: [String] = []
                if isPortalOUI { portalScore += 55; portalReasons.append("Portal OUI") }
                if combinedText.contains("portal") { portalScore += 45; portalReasons.append("主机名匹配") }
                if isSIEOUI && ddp == nil && !hasTCP9295 && !isPortalOUI { portalScore += 30; portalReasons.append("SIE 硬件段") }
                if !currentPortal.isEmpty && ip == currentPortal && (isSonyOUI || isLocalAdminMAC) {
                    portalScore += 30
                    portalReasons.append("历史 IP 吻合")
                }
                if isNonHandheldSonyDevice { portalScore -= 90 }
                if ddp != nil || hasTCP9295 { portalScore = 0 }

                let role: SonyDeviceRole
                let label: String
                let resolvedHostName: String?
                let isSony: Bool
                let confidence: Int
                let reasons: [String]

                if ddp != nil || (hasTCP9295 && !isNonHandheldSonyDevice) {
                    role = .ps5Host
                    resolvedHostName = (ddp?.hostName.isEmpty == false ? ddp?.hostName : nil) ?? selfReportName
                    if let ddp {
                        label = ddp.hostName.isEmpty ? ddp.hostType : "\(ddp.hostType) (\(ddp.hostName))"
                    } else {
                        label = resolvedHostName.map { "PS5 主机 (\($0))" } ?? "PS5 主机 (Remote Play 9295)"
                    }
                    isSony = true
                    confidence = min(100, max(10, ps5Score))
                    reasons = ps5Reasons
                } else if !isNonHandheldSonyDevice && portalScore >= 40 {
                    role = .portalClient
                    resolvedHostName = selfReportName
                    if let selfReportName, !selfReportName.lowercased().contains("portal") {
                        label = "PS Portal (\(selfReportName))"
                    } else if let selfReportName {
                        label = selfReportName
                    } else if isPortalOUI {
                        label = "PS Portal"
                    } else if isSIEOUI {
                        label = "PS Portal 候选 (SIE 硬件)"
                    } else {
                        label = "PS Portal 候选"
                    }
                    isSony = true
                    confidence = min(100, max(10, portalScore))
                    reasons = portalReasons
                } else if isSonyOUI {
                    role = .unknownSony
                    resolvedHostName = selfReportName
                    label = selfReportName.map { "Sony \($0)" } ?? "Sony 影音/PlayStation 设备"
                    isSony = true
                    confidence = isNonHandheldSonyDevice ? 10 : 30
                    reasons = isNonHandheldSonyDevice ? ["已排除非掌机外设"] : ["Sony OUI"]
                } else {
                    role = .other
                    resolvedHostName = selfReportName
                    label = selfReportName ?? LanOuiDatabase.shared.lookup(mac)?.displayName ?? "局域网终端"
                    isSony = false
                    confidence = 15
                    reasons = []
                }

                var finalReasons = reasons
                if entry.ifName != targetIface {
                    finalReasons.append("位于网卡 \(entry.ifName)")
                }

                results.append(DiscoveredDevice(
                    id: "\(ip)-\(mac)",
                    ip: ip,
                    mac: mac,
                    isLikelySony: isSony,
                    role: role,
                    hostName: resolvedHostName,
                    label: label,
                    confidence: confidence,
                    matchReasons: finalReasons,
                    interfaceName: entry.ifName
                ))
            }

            for (ip, ddp) in ddpMap where arpByIP[ip] == nil {
                results.append(DiscoveredDevice(
                    id: "\(ip)-ddp",
                    ip: ip,
                    mac: "",
                    isLikelySony: true,
                    role: .ps5Host,
                    hostName: ddp.hostName,
                    label: ddp.hostName.isEmpty ? ddp.hostType : "\(ddp.hostType) (\(ddp.hostName))",
                    confidence: 85,
                    matchReasons: ["DDP 9302"],
                    interfaceName: targetIface
                ))
            }

            results.sort { a, b in
                let rank: (SonyDeviceRole) -> Int = { role in
                    switch role {
                    case .ps5Host: return 0
                    case .portalClient: return 1
                    case .unknownSony: return 2
                    case .other: return 3
                    }
                }
                if rank(a.role) != rank(b.role) {
                    return rank(a.role) < rank(b.role)
                }
                if a.confidence != b.confidence {
                    return a.confidence > b.confidence
                }
                let ip1 = LanDeviceSnifferEngine.ipToComparable(a.ip)
                let ip2 = LanDeviceSnifferEngine.ipToComparable(b.ip)
                if ip1 != ip2 { return ip1 < ip2 }
                return a.ip < b.ip
            }

            let sonyResults = results.filter(\.isLikelySony)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discoveredDevices = sonyResults
                self.isScanningDevices = false

                let sameIfacePS5 = sonyResults.filter { $0.role == .ps5Host && ($0.interfaceName == nil || $0.interfaceName == targetIface) }
                let ps5Dev = sameIfacePS5.first ?? sonyResults.first(where: { $0.role == .ps5Host })

                // 严格筛选 Portal：严禁把 Standby SIE 设备或 unknownSony 电视盲填为 Portal；已有 IP 时绝不擅自覆写
                let sameIfacePortals = sonyResults.filter {
                    $0.role == .portalClient &&
                    $0.ip != ps5Dev?.ip &&
                    ($0.interfaceName == nil || $0.interfaceName == targetIface)
                }
                let bestPortal = sameIfacePortals.first(where: { $0.confidence >= 60 })
                    ?? sonyResults.first(where: { $0.role == .portalClient && $0.ip != ps5Dev?.ip && $0.confidence >= 60 })

                if let ps5 = ps5Dev, ps5.confidence >= 60 {
                    let reasonsTag = ps5.matchReasons.isEmpty ? "" : " [\(ps5.matchReasons.joined(separator: "·"))]"
                    self.appendLog("[识别] PS5 -> \(ps5.ip)\(reasonsTag)")
                    let curPS5 = self.ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
                    if curPS5.isEmpty {
                        self.ps5IP = ps5.ip
                    } else if ps5.ip != curPS5 {
                        self.appendLog("[提示] 发现同网段 PS5 (\(ps5.ip))，已保留当前设置的 \(curPS5)（如需更换请点击上方设备胶囊）。")
                    }
                }

                if let portal = bestPortal {
                    let reasonsTag = portal.matchReasons.isEmpty ? "" : " [\(portal.matchReasons.joined(separator: "·"))]"
                    self.appendLog("[识别] Portal -> \(portal.ip) (\(portal.label)\(reasonsTag))")
                    let curPortal = self.portalIP.trimmingCharacters(in: .whitespacesAndNewlines)
                    if curPortal.isEmpty && portal.ip != self.ps5IP.trimmingCharacters(in: .whitespacesAndNewlines) {
                        self.portalIP = portal.ip
                    } else if portal.ip != curPortal {
                        self.appendLog("[提示] 发现同网段 Portal (\(portal.ip))，已保留当前设置的 \(curPortal)（如需更换请点击上方设备胶囊）。")
                    }
                } else if let candidate = sonyResults.first(where: { $0.role == .portalClient && $0.ip != ps5Dev?.ip }) {
                    self.appendLog("[提示] 发现疑似 Portal 设备 \(candidate.ip)，请在上方列表中确认后再手动点击填入。")
                }

                self.saveConfig()
                self.refreshConfigurationStateIfIdle()
                if sonyResults.isEmpty {
                    self.appendLog("[SysPulse] 扫描完成，暂未发现 Sony / PlayStation 设备。")
                } else {
                    self.appendLog("[SysPulse] Sony 设备扫描完成（发现 \(sonyResults.count) 台 Sony 设备）")
                }
            }
        }
    }

    nonisolated private static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private static func isValidUnicastIPv4(_ ip: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return false }
        let hostOrder = UInt32(bigEndian: addr.s_addr)
        let firstOctet = (hostOrder >> 24) & 0xFF
        if firstOctet == 0 || firstOctet == 127 || firstOctet >= 224 { return false }
        if (hostOrder & 0xFFFF0000) == 0xA9FE0000 { return false } // 169.254.x.x
        return true
    }

    // MARK: - 插件运行控制

    private func refreshConfigurationStateIfIdle() {
        let hasIPs = !ps5IP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                     !portalIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch engineState {
        case .idle, .needsConfiguration, .deviceOffline:
            transition(to: hasIPs ? .idle : .needsConfiguration)
        case .error:
            if hasIPs { transition(to: .idle) }
        default:
            break
        }
    }

    public func setAutoWatchEnabled(_ enabled: Bool) {
        autoWatchEnabled = enabled
        lastPortalActivityAt = Date()
        saveConfig()
        if enabled {
            startSleepPolicyTimerIfNeeded()
            ensureAutoWatchRunning(reason: "用户开启自动增强模式")
        } else {
            wakeRecoveryTask?.cancel()
            wakeRecoveryTask = nil
            stopSleepPolicyTimer()
            releaseSleepAssertion()
            setClamshellKeepAwakeDesired(false)
            appendLog("[守望] 已关闭自动增强守望。")
            if isRunning || isStopping {
                stopRelay()
            } else {
                refreshConfigurationStateIfIdle()
            }
        }
        evaluateSleepPrevention(logTransition: true)
    }

    public func setPreventSleepInAutoWatch(_ enabled: Bool) {
        preventSleepInAutoWatch = enabled
        lastPortalActivityAt = Date()
        saveConfig()
        startSleepPolicyTimerIfNeeded()
        evaluateSleepPrevention(logTransition: true)
    }

    public func setSleepPreventMode(_ mode: PortalSleepPreventMode) {
        sleepPreventMode = mode
        lastPortalActivityAt = Date()
        saveConfig()
        startSleepPolicyTimerIfNeeded()
        evaluateSleepPrevention(logTransition: true)
    }

    public func setScheduleHours(start: Int, end: Int) {
        scheduleStartHour = ((start % 24) + 24) % 24
        scheduleEndHour = ((end % 24) + 24) % 24
        saveConfig()
        evaluateSleepPrevention(logTransition: true)
    }

    public func setIdleTimeoutHours(_ hours: Int) {
        idleTimeoutHours = max(1, min(24, hours))
        lastPortalActivityAt = Date()
        saveConfig()
        evaluateSleepPrevention(logTransition: true)
    }

    public func setPowerCondition(_ condition: PortalPowerCondition) {
        powerCondition = condition
        saveConfig()
        evaluateSleepPrevention(logTransition: true)
    }

    public func setLowBatteryThreshold(_ threshold: Int) {
        lowBatteryThreshold = max(5, min(50, threshold))
        saveConfig()
        evaluateSleepPrevention(logTransition: true)
    }

    public func setAllowClamshellKeepAwake(_ allowed: Bool) {
        allowClamshellKeepAwake = allowed
        saveConfig()
        evaluateSleepPrevention(logTransition: true)
    }

    public func setDebugModeEnabled(_ enabled: Bool) {
        debugModeEnabled = enabled
        saveConfig()
        appendLog(enabled
            ? "[DEBUG] 🔍 已开启详细抓包诊断模式（日志同步落盘至 ~/Library/Logs/SysPulse/psportal.log）"
            : "[SysPulse] 已关闭 Debug 详细诊断模式")
        if isRunning && autoWatchEnabled {
            stopRelay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.autoWatchEnabled else { return }
                self.ensureAutoWatchRunning(reason: "应用 Debug 日志开关配置")
            }
        } else if isRunning {
            appendLog("[提示] 当前手动会话仍在运行，重新启动「画质增强」后生效 Debug 底层抓包日志。")
        }
    }

    public func openDebugLogFile() {
        let path = logFilePath
        if !FileManager.default.fileExists(atPath: path) {
            let content = logs.map(\.text).joined(separator: "\n") + "\n"
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }

    public func ensureAutoWatchRunning(reason: String) {
        guard autoWatchEnabled, FeatureToggleManager.shared.enablePluginPSPortal else { return }
        guard !isStopping else { return }
        if case .autoWatching = engineState { return }
        if case .autoBursting = engineState { return }
        if case .enhancingActive = engineState { return }
        if case .starting = engineState { return }
        if case .authorizing = engineState { return }

        detectInterfaces()
        let trimmedPS5 = ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPortal = portalIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPS5.isEmpty, !trimmedPortal.isEmpty,
              Self.isValidUnicastIPv4(trimmedPS5), Self.isValidUnicastIPv4(trimmedPortal),
              trimmedPS5 != trimmedPortal else {
            transition(to: .needsConfiguration)
            appendLog("[守望] 需先完成 PS5 与 Portal IP 配置后才能启动自动待命（\(reason)）。")
            return
        }
        guard isPS5OnDirectLAN() else {
            transition(to: .suspendedOutOfLAN)
            appendLog("[守望] 当前设备不在家庭局域网直连子网内，自动守望已自动休眠。")
            return
        }
        suspendedBySleep = false
        lastPortalActivityAt = Date()
        startSleepPolicyTimerIfNeeded()
        launchRelay(watchMode: true, triggerReason: reason)
    }

    private func suspendAutoWatchForOutOfLAN(reason: String) {
        guard autoWatchEnabled else { return }
        streamPresenceTask?.cancel()
        streamPresenceTask = nil
        releaseSleepAssertion()
        setClamshellKeepAwakeDesired(false)
        if case .suspendedOutOfLAN = engineState { return }
        appendLog("[守望] \(reason)，自动切换为休眠状态并复原直连路由。")
        if isRunning {
            terminateCurrentEngineProcess(transitionTo: .suspendedOutOfLAN)
        } else {
            transition(to: .suspendedOutOfLAN)
        }
    }

    public func handleWillSleep() {
        suspendedBySleep = autoWatchEnabled
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        streamPresenceTask?.cancel()
        streamPresenceTask = nil
        stopSleepPolicyTimer()
        releaseSleepAssertion()
        setClamshellKeepAwakeDesired(false)
        if isRunning || isListening || isStreamActive {
            stopRelay()
        }
    }

    public func resumeFromWake() {
        guard FeatureToggleManager.shared.enablePluginPSPortal else { return }
        let shouldResume = autoWatchEnabled || suspendedBySleep
        suspendedBySleep = false
        guard shouldResume else { return }
        lastPortalActivityAt = Date()
        startSleepPolicyTimerIfNeeded()

        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { @MainActor [weak self] in
            let delays: [Double] = [1.0, 2.0, 3.0, 4.0, 5.0, 5.0]
            for (idx, delay) in delays.enumerated() {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                guard self.autoWatchEnabled, FeatureToggleManager.shared.enablePluginPSPortal else { return }
                if SystemSleepCoordinator.shared.isSystemAsleep || SystemSleepCoordinator.shared.isScreenAsleep {
                    return
                }
                if self.isRunning {
                    self.evaluateSleepPrevention(logTransition: false)
                    return
                }
                self.detectInterfaces()
                if self.isPS5OnDirectLAN() {
                    self.appendLog("[守望] 🌐 局域网链路已就绪（第 \(idx + 1) 次探测），正在恢复自动增强守望...")
                    self.wakeRecoveryTask = nil
                    self.ensureAutoWatchRunning(reason: "Mac 唤醒恢复")
                    return
                } else if idx == 0 {
                    self.appendLog("[守望] ⏳ Mac 已唤醒，正在等待网卡获取 IP 并连回家庭局域网...")
                }
            }
            guard let self, !Task.isCancelled, self.autoWatchEnabled else { return }
            self.wakeRecoveryTask = nil
            if !self.isRunning && !self.isPS5OnDirectLAN() {
                self.transition(to: .suspendedOutOfLAN)
                self.appendLog("[守望] ⚠️ 唤醒后暂未连入家庭直连子网，已挂起等待网络变化自动恢复。")
            }
        }
    }

    public func endEnhancementSession(reason: String = "串流结束，自动切回待命") {
        streamPresenceTask?.cancel()
        streamPresenceTask = nil
        consecutivePortalMisses = 0
        if autoWatchEnabled && relayProcess?.isRunning == true {
            transition(to: .autoWatching)
            appendLog("[守望] ℹ️ \(reason)")
        } else if autoWatchEnabled {
            transition(to: .idle)
            ensureAutoWatchRunning(reason: reason)
        } else {
            transition(to: (ps5IP.isEmpty || portalIP.isEmpty) ? .needsConfiguration : .idle)
            appendLog("[SysPulse] ℹ️ \(reason)")
        }
    }

    public func startRelay() {
        launchRelay(watchMode: false, triggerReason: "用户手动启动")
    }

    private func launchRelay(watchMode: Bool, triggerReason: String) {
        guard !isRunning && !isStopping else { return }
        bootstrapPluginDirectory()

        let trimmedPS5 = ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPortal = portalIP.trimmingCharacters(in: .whitespacesAndNewlines)
        ps5IP = trimmedPS5
        portalIP = trimmedPortal

        guard !trimmedPS5.isEmpty, !trimmedPortal.isEmpty else {
            lastError = "请先填写 PS5 IP 与 PS Portal IP（可点击「扫描局域网设备」快速识别并填入）。"
            transition(to: .needsConfiguration)
            appendLog("[错误] \(lastError!)")
            return
        }
        guard Self.isValidUnicastIPv4(trimmedPS5), Self.isValidUnicastIPv4(trimmedPortal) else {
            lastError = "请输入合法的局域网 IPv4 地址（例如 192.168.x.x）。"
            transition(to: .error(lastError!))
            appendLog("[错误] \(lastError!)")
            return
        }
        guard trimmedPS5 != trimmedPortal else {
            lastError = "PS5 IP 与 PS Portal IP 不能相同（\(trimmedPS5)）。"
            transition(to: .error(lastError!))
            appendLog("[错误] \(lastError!)")
            return
        }
        saveConfig()

        let engine = engineFileURL.path
        guard FileManager.default.isExecutableFile(atPath: engine) else {
            lastError = "未找到插件原生中继引擎: portal_engine"
            transition(to: .error(lastError!))
            appendLog("[错误] \(lastError!)")
            return
        }

        resetWorkItem?.cancel()
        resetWorkItem = nil
        streamPresenceTask?.cancel()
        streamPresenceTask = nil
        stopListenCountdown()
        stopCooldownCountdown()
        consecutivePortalMisses = 0
        relaySessionID &+= 1
        let currentSession = relaySessionID

        lastError = nil
        logLineBuffer.removeAll()
        transition(to: .starting)

        if watchMode {
            appendLog("[守望] 正在启动被动旁路守望引擎（\(triggerReason)）…")
        } else {
            appendLog("[SysPulse] 启动 PS Portal 串流画质增强模块…")
        }
        appendLog("[配置] 目标码率: \(targetBitrate.rawValue) | 模式: \(watchMode ? "watch/oneway" : relayMode.rawValue) | 网卡: \(selectedInterface)")
        appendLog("[配置] PS5: \(ps5IP) | Portal: \(portalIP)")
        appendLog("[提示] ⏳ 正在初始化网络监听通道，请稍候（就绪前请暂勿在 Portal 点击连接）...")

        if runWithAdmin {
            startPrivilegedRelay(engine: engine, sessionID: currentSession, watchMode: watchMode)
        } else {
            startStandardRelay(engine: engine, sessionID: currentSession, watchMode: watchMode)
        }
    }

    nonisolated private static func isPrivilegedEngineReady(stagedPath: String) -> Bool {
        let fm = FileManager.default
        guard let dirAttr = try? fm.attributesOfItem(atPath: privilegedEngineDirectory),
              let dirType = dirAttr[.type] as? FileAttributeType,
              dirType == .typeDirectory,
              let dirOwner = (dirAttr[.ownerAccountID] as? NSNumber)?.uint32Value,
              dirOwner == 0,
              let dirPerm = (dirAttr[.posixPermissions] as? NSNumber)?.intValue,
              (dirPerm & 0o022) == 0 else {
            return false
        }
        guard fm.isExecutableFile(atPath: privilegedEnginePath),
              let privAttr = try? fm.attributesOfItem(atPath: privilegedEnginePath),
              let privType = privAttr[.type] as? FileAttributeType,
              privType == .typeRegular,
              let privOwner = (privAttr[.ownerAccountID] as? NSNumber)?.uint32Value,
              privOwner == 0,
              let privPerm = (privAttr[.posixPermissions] as? NSNumber)?.intValue,
              (privPerm & 0o022) == 0 else {
            return false
        }
        if let stagedData = try? Data(contentsOf: URL(fileURLWithPath: stagedPath)),
           let privData = try? Data(contentsOf: URL(fileURLWithPath: privilegedEnginePath)),
           stagedData != privData {
            return false
        }
        return true
    }

    nonisolated private static func checkPasswordlessSudo() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", privilegedEnginePath, "--check-privilege"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private func buildEngineArguments(watchMode: Bool) -> [String] {
        var args = [
            "--interface", selectedInterface,
            "--bitrate", targetBitrate.shortTag,
            "--mode", watchMode ? "oneway" : relayMode.rawValue,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ]
        if !ps5IP.isEmpty { args.append(contentsOf: ["--ps5", ps5IP]) }
        if !portalIP.isEmpty { args.append(contentsOf: ["--portal", portalIP]) }
        if watchMode { args.append("--watch") }
        if debugModeEnabled { args.append("--debug") }
        return args
    }

    private func launchEngineProcess(executablePath: String, arguments: [String], sessionID: UInt64, watchMode: Bool, isSudo: Bool) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe?.fileHandleForReading.readabilityHandler = nil
        self.outputPipe = pipe
        self.relayProcess = proc

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.relaySessionID == sessionID else { return }
                self.ingestLogData(data, sessionID: sessionID)
            }
        }

        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.relaySessionID == sessionID else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.flushRemainingLogBuffer(sessionID: sessionID)
                self.resetWorkItem?.cancel()
                self.resetWorkItem = nil
                self.streamPresenceTask?.cancel()
                self.streamPresenceTask = nil
                self.stopListenCountdown()
                self.stopCooldownCountdown()
                self.relayProcess = nil

                if status == 2 && watchMode {
                    self.transition(to: .suspendedOutOfLAN)
                    return
                }
                if case .enhancingActive = self.engineState, !watchMode {
                    // 单向/手动注入成功退出后保留「画质增强中」短时展示并由 presence/reset 收尾
                    return
                }
                if case .error = self.engineState { return }
                if case .suspendedOutOfLAN = self.engineState { return }
                if case .disabled = self.engineState { return }
                self.transition(to: (self.ps5IP.isEmpty || self.portalIP.isEmpty) ? .needsConfiguration : .idle)
                if !isSudo || status != 0 {
                    self.appendLog("[SysPulse] 插件进程已安全退出 (退出码: \(status))")
                }
            }
        }

        do {
            try proc.run()
            let pid = proc.processIdentifier
            if isSudo {
                self.appendLog("[SysPulse] ✅ 串流增强引擎已激活 (直连管道 · PID: \(pid))。")
            }
            self.evaluateSleepPrevention(logTransition: true)
            return true
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.outputPipe = nil
            self.relayProcess = nil
            return false
        }
    }

    private func launchPasswordlessRelay(sessionID: UInt64, watchMode: Bool) -> Bool {
        let args = ["-n", Self.privilegedEnginePath] + buildEngineArguments(watchMode: watchMode)
        return launchEngineProcess(
            executablePath: "/usr/bin/sudo",
            arguments: args,
            sessionID: sessionID,
            watchMode: watchMode,
            isSudo: true
        )
    }

    private func startPrivilegedRelay(engine: String, sessionID: UInt64, watchMode: Bool) {
        logLineBuffer.removeAll()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isReady = Self.isPrivilegedEngineReady(stagedPath: engine) && Self.checkPasswordlessSudo()

            DispatchQueue.main.async {
                guard let self = self, self.relaySessionID == sessionID else { return }

                if isReady {
                    self.appendLog("[SysPulse] ⚡️ 检测到 PS Portal 串流增强权限已就绪，正在启动原生 BPF 引擎...")
                    if self.launchPasswordlessRelay(sessionID: sessionID, watchMode: watchMode) {
                        return
                    }
                    self.appendLog("[提示] 免密进程启动受限，正在重新配置串流增强权限...")
                }

                self.transition(to: .authorizing)
                self.appendLog("[SysPulse] 正在验证 PS Portal 串流增强权限并配置免密通道...")

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let fm = FileManager.default
                    let stageDir = URL(fileURLWithPath: "/private/tmp")
                        .appendingPathComponent("syspulse_portal_\(UUID().uuidString)", isDirectory: true)
                    let stageEngine = stageDir.appendingPathComponent("portal_engine")
                    var engineArg = engine
                    if (try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])) != nil,
                       (try? fm.copyItem(at: URL(fileURLWithPath: engine), to: stageEngine)) != nil {
                        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stageEngine.path)
                        engineArg = stageEngine.path
                    }
                    defer { try? fm.removeItem(at: stageDir) }

                    let res = SystemPermissionManager.executePrivilegedHelper(
                        args: ["--psportal-install", engineArg],
                        touchIDReason: "开启 PS Portal 串流增强权限",
                        allowBootstrapPrompt: true
                    )
                    let sudoReady = res.succeeded && Self.checkPasswordlessSudo()

                    DispatchQueue.main.async {
                        guard let self = self, self.relaySessionID == sessionID else { return }
                        if !res.succeeded {
                            let errMsg = res.errorMessage ?? "用户取消验证"
                            self.appendLog("[提示] 串流增强权限验证未完成: \(errMsg)")
                            self.lastError = "需要开启 PS Portal 串流增强权限才能启用原生 BPF 引擎（\(errMsg)）。"
                            self.appendLog("[错误] \(self.lastError!)")
                            self.resetWorkItem?.cancel()
                            self.resetWorkItem = nil
                            self.stopListenCountdown()
                            self.transition(to: .error(self.lastError!))
                        } else if sudoReady {
                            self.transition(to: .starting)
                            if self.launchPasswordlessRelay(sessionID: sessionID, watchMode: watchMode) {
                                self.appendLog("[SysPulse] ✅ 已开启 PS Portal 串流增强权限并建立免密通道。")
                            } else {
                                self.lastError = "串流增强引擎启动失败，请检查日志。"
                                self.transition(to: .error(self.lastError!))
                            }
                        } else {
                            self.lastError = "串流增强免密通道未生效，请确认当前账户属于管理员组后重试。"
                            self.appendLog("[错误] \(self.lastError!)")
                            self.resetWorkItem?.cancel()
                            self.resetWorkItem = nil
                            self.stopListenCountdown()
                            self.transition(to: .error(self.lastError!))
                        }
                    }
                }
            }
        }
    }

    private func startStandardRelay(engine: String, sessionID: UInt64, watchMode: Bool) {
        let args = buildEngineArguments(watchMode: watchMode)
        if !launchEngineProcess(executablePath: engine, arguments: args, sessionID: sessionID, watchMode: watchMode, isSudo: false) {
            stopListenCountdown()
        stopCooldownCountdown()
            lastError = "无法启动原生引擎进程"
            appendLog("[错误] \(lastError!)")
            transition(to: .error(lastError!))
        }
    }

    private func ingestLogData(_ data: Data, sessionID: UInt64) {
        logLineBuffer.append(data)
        guard let lastNewline = logLineBuffer.lastIndex(of: 0x0A) else { return }

        let completeSlice = logLineBuffer[logLineBuffer.startIndex...lastNewline]
        let remainder = Data(logLineBuffer[logLineBuffer.index(after: lastNewline)...])
        logLineBuffer = remainder

        let text = String(decoding: completeSlice, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for line in lines {
            processIncomingEngineLine(line, sessionID: sessionID)
        }
    }

    private func flushRemainingLogBuffer(sessionID: UInt64) {
        guard !logLineBuffer.isEmpty else { return }
        let text = String(decoding: logLineBuffer, as: UTF8.self)
        logLineBuffer.removeAll()
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for line in lines {
            processIncomingEngineLine(line, sessionID: sessionID)
        }
    }

    private func processIncomingEngineLine(_ line: String, sessionID: UInt64) {
        if line.hasPrefix("[EVENT] ") {
            let jsonPart = String(line.dropFirst("[EVENT] ".count))
            handleEngineEventJSON(jsonPart, sessionID: sessionID)
            return
        }
        appendLog(line)
        evaluateProcessOutput(line, sessionID: sessionID)
    }

    public func stopRelay() {
        releaseSleepAssertion()
        setClamshellKeepAwakeDesired(false)
        let fallbackState: PortalEngineState = FeatureToggleManager.shared.enablePluginPSPortal
            ? ((ps5IP.isEmpty || portalIP.isEmpty) ? .needsConfiguration : .idle)
            : .disabled
        terminateCurrentEngineProcess(transitionTo: fallbackState)
    }

    private func terminateCurrentEngineProcess(transitionTo targetState: PortalEngineState) {
        guard isRunning || isStopping || relayProcess != nil else {
            transition(to: targetState)
            return
        }
        appendLog("[SysPulse] 正在停止插件监听与引擎...")

        relaySessionID &+= 1
        let stopSessionID = relaySessionID
        transition(to: .stopping)
        stopListenCountdown()
        stopCooldownCountdown()

        resetWorkItem?.cancel()
        resetWorkItem = nil
        streamPresenceTask?.cancel()
        streamPresenceTask = nil

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        let engine = FileManager.default.isExecutableFile(atPath: Self.privilegedEnginePath)
            ? Self.privilegedEnginePath
            : engineFileURL.path
        let activeProc = relayProcess
        relayProcess = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var stoppedViaSudo = false
            if FileManager.default.isExecutableFile(atPath: engine) {
                let stopProc = Process()
                stopProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                stopProc.arguments = ["-n", engine, "--stop"]
                stopProc.standardOutput = FileHandle.nullDevice
                stopProc.standardError = FileHandle.nullDevice
                if (try? stopProc.run()) != nil {
                    stopProc.waitUntilExit()
                    stoppedViaSudo = (stopProc.terminationStatus == 0)
                }
            }

            if !stoppedViaSudo, let activeProc, activeProc.isRunning {
                activeProc.interrupt()
                Thread.sleep(forTimeInterval: 0.4)
                if activeProc.isRunning {
                    activeProc.terminate()
                }
            }

            DispatchQueue.main.async {
                guard let self, self.relaySessionID == stopSessionID else { return }
                self.flushRemainingLogBuffer(sessionID: stopSessionID)
                self.transition(to: targetState)
                if !stoppedViaSudo && FileManager.default.fileExists(atPath: self.pidFilePath) {
                    self.appendLog("[提示] 免密停止通道未就绪，若直连未恢复可点击右上角「恢复直连」。")
                } else {
                    self.appendLog("[SysPulse] 插件已停止，网络路由恢复直连。")
                }
            }
        }
    }

    /// Used during app termination to synchronously signal `portal_engine --stop` before the process exits.
    public func stopRelaySynchronouslyForTermination() {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        stopInternalPowerObserver()
        stopSleepPolicyTimer()
        releaseSleepAssertion()

        let hasPidFile = FileManager.default.fileExists(atPath: pidFilePath)
        let needsClamshellCleanup = clamshellDesiredState || isClamshellKeepAwakeActive ||
            FileManager.default.fileExists(atPath: Self.clamshellStateFilePath)
        guard isRunning || isListening || hasPidFile || needsClamshellCleanup else { return }

        stopListenCountdown()
        stopCooldownCountdown()
        resetWorkItem?.cancel()
        resetWorkItem = nil
        streamPresenceTask?.cancel()
        streamPresenceTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        let engine = FileManager.default.isExecutableFile(atPath: Self.privilegedEnginePath)
            ? Self.privilegedEnginePath
            : engineFileURL.path
        var stoppedViaSudo = false
        if FileManager.default.isExecutableFile(atPath: engine) && (isRunning || isListening || hasPidFile) {
            let stopProc = Process()
            stopProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            stopProc.arguments = ["-n", engine, "--stop"]
            stopProc.standardOutput = FileHandle.nullDevice
            stopProc.standardError = FileHandle.nullDevice
            if (try? stopProc.run()) != nil {
                stopProc.waitUntilExit()
                stoppedViaSudo = (stopProc.terminationStatus == 0)
            }
        }
        if needsClamshellCleanup && FileManager.default.isExecutableFile(atPath: engine) {
            let restoreProc = Process()
            restoreProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            restoreProc.arguments = ["-n", engine, "--clamshell-keepawake", "off"]
            restoreProc.standardOutput = FileHandle.nullDevice
            restoreProc.standardError = FileHandle.nullDevice
            if (try? restoreProc.run()) != nil {
                restoreProc.waitUntilExit()
            }
            clamshellDesiredState = false
            clamshellLastAppliedState = false
            isClamshellKeepAwakeActive = false
        }

        if !stoppedViaSudo, let activeProc = relayProcess, activeProc.isRunning {
            activeProc.interrupt()
            Thread.sleep(forTimeInterval: 0.3)
            if activeProc.isRunning {
                activeProc.terminate()
            }
        }
        relayProcess = nil
        transition(to: .disabled)
    }

    public func restoreNetworkDirect() {
        bootstrapPluginDirectory()
        let engine = FileManager.default.isExecutableFile(atPath: Self.privilegedEnginePath)
            ? Self.privilegedEnginePath
            : engineFileURL.path
        guard FileManager.default.isExecutableFile(atPath: engine) else {
            appendLog("[错误] 未找到原生引擎，无法执行网络复原。")
            return
        }
        appendLog("[SysPulse] 正在执行紧急网络直连复原 (--restore)...")
        let iface = selectedInterface
        let ps5 = ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        let portal = portalIP.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = ["-n", engine, "--restore", "--interface", iface]
            if !ps5.isEmpty { args.append(contentsOf: ["--ps5", ps5]) }
            if !portal.isEmpty { args.append(contentsOf: ["--portal", portal]) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var ok = false
            var outputData = Data()
            if (try? proc.run()) != nil {
                outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                ok = (proc.terminationStatus == 0)
            }

            if ok {
                let text = String(data: outputData, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        self?.appendLog(line)
                    }
                    self?.stopListenCountdown()
                    if let self {
                        self.transition(to: (self.ps5IP.isEmpty || self.portalIP.isEmpty) ? .needsConfiguration : .idle)
                    }
                }
            } else {
                var restoreArgs = ["--psportal-restore", engine, iface]
                if !ps5.isEmpty { restoreArgs.append(ps5) } else { restoreArgs.append("") }
                if !portal.isEmpty { restoreArgs.append(portal) }
                let restoreRes = SystemPermissionManager.executePrivilegedHelper(
                    args: restoreArgs,
                    touchIDReason: nil,
                    allowBootstrapPrompt: true
                )
                DispatchQueue.main.async {
                    if restoreRes.succeeded {
                        self?.appendLog("[SysPulse] 网络直连路由已复原。")
                        self?.stopListenCountdown()
                        if let self {
                            self.transition(to: (self.ps5IP.isEmpty || self.portalIP.isEmpty) ? .needsConfiguration : .idle)
                        }
                    } else {
                        self?.appendLog("[提示] 网络复原未完成或已取消授权。")
                    }
                }
            }
        }
    }

    // MARK: - 网络变化监听 / 状态事件 / 通知 / 串流生命周期监测

    private func startNetworkPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathDebounceTask?.cancel()
                self.pathDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self, !Task.isCancelled else { return }
                    self.handleNetworkPathStabilized()
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private func isPS5OnDirectLAN() -> Bool {
        let trimmedPS5 = ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidUnicastIPv4(trimmedPS5) else { return false }
        guard let subnet = ActiveInterfaceInfo.ipv4SubnetInfo(for: selectedInterface) else {
            return false
        }
        let targetVal = LanDeviceSnifferEngine.ipToComparable(trimmedPS5)
        return targetVal != 0 && (targetVal & subnet.mask) == (subnet.ip & subnet.mask)
    }

    private func handleNetworkPathStabilized() {
        guard FeatureToggleManager.shared.enablePluginPSPortal else { return }
        guard !SystemSleepCoordinator.shared.isSystemAsleep else { return }
        detectInterfaces()
        guard autoWatchEnabled else { return }

        if isPS5OnDirectLAN() {
            let needsRecovery: Bool
            switch engineState {
            case .suspendedOutOfLAN, .idle:
                needsRecovery = true
            default:
                needsRecovery = (wakeRecoveryTask != nil)
            }
            if needsRecovery {
                wakeRecoveryTask?.cancel()
                wakeRecoveryTask = nil
                if case .suspendedOutOfLAN = engineState {
                    appendLog("[守望] ✅ 已回到家庭局域网直连子网，正在自动恢复旁路守望...")
                    ensureAutoWatchRunning(reason: "重新连入家庭局域网")
                } else {
                    ensureAutoWatchRunning(reason: "网络链路就绪恢复守望")
                }
            }
        } else {
            wakeRecoveryTask?.cancel()
            wakeRecoveryTask = nil
            suspendAutoWatchForOutOfLAN(reason: "检测到当前网络已切换或脱离家庭子网（VPN 下只要 PS5 路由仍直连不会误休眠）")
        }
    }

    // MARK: - 自动守望期间防休眠与独立内置电池策略

    nonisolated private static func readInternalBatterySnapshot() -> (hasInternalBattery: Bool, isOnAC: Bool, batteryPercent: Int, isLowPowerMode: Bool) {
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            let providing = (IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as? String) ?? ""
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }
                let type = desc[kIOPSTypeKey] as? String ?? ""
                guard type == kIOPSInternalBatteryType else { continue }
                let stateStr = desc[kIOPSPowerSourceStateKey] as? String ?? ""
                let isOnAC = (stateStr == kIOPSACPowerValue) || (providing == kIOPSACPowerValue)
                let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
                let maxCap = max(1, desc[kIOPSMaxCapacityKey] as? Int ?? 100)
                let pct = min(100, max(0, Int((Double(cur) / Double(maxCap)) * 100.0)))
                return (true, isOnAC, pct, isLowPower)
            }
        }
        return (false, true, 100, isLowPower)
    }

    private func startInternalPowerObserver() {
        let initialSnap = Self.readInternalBatterySnapshot()
        isMacLaptop = initialSnap.hasInternalBattery

        if internalPowerRunLoopSource == nil {
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            let source = IOPSNotificationCreateRunLoopSource({ info in
                guard let info else { return }
                let mgr = Unmanaged<PSPortalPluginManager>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in
                    mgr.evaluateSleepPrevention(logTransition: true)
                }
            }, context).takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
            internalPowerRunLoopSource = source
        }

        if lowPowerModeObserver == nil {
            lowPowerModeObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluateSleepPrevention(logTransition: true)
                }
            }
        }
    }

    private func stopInternalPowerObserver() {
        if let source = internalPowerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
            internalPowerRunLoopSource = nil
        }
        if let obs = lowPowerModeObserver {
            NotificationCenter.default.removeObserver(obs)
            lowPowerModeObserver = nil
        }
    }

    private func performClamshellSelfHealIfNeeded() {
        guard FileManager.default.fileExists(atPath: Self.clamshellStateFilePath) else { return }
        if !autoWatchEnabled || !preventSleepInAutoWatch || !allowClamshellKeepAwake || !isMacLaptop {
            setClamshellKeepAwakeDesired(false, forceCheck: true)
        }
    }

    private func startSleepPolicyTimerIfNeeded() {
        guard FeatureToggleManager.shared.enablePluginPSPortal,
              autoWatchEnabled,
              preventSleepInAutoWatch,
              (sleepPreventMode == .scheduled || sleepPreventMode == .idleTimeout) else {
            stopSleepPolicyTimer()
            return
        }
        guard sleepPolicyTimer == nil else { return }
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateSleepPrevention(logTransition: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepPolicyTimer = timer
    }

    private func stopSleepPolicyTimer() {
        sleepPolicyTimer?.invalidate()
        sleepPolicyTimer = nil
    }

    private func isWithinScheduledWatchWindow() -> Bool {
        if scheduleStartHour == scheduleEndHour { return true }
        let hour = Calendar.current.component(.hour, from: Date())
        if scheduleStartHour < scheduleEndHour {
            return hour >= scheduleStartHour && hour < scheduleEndHour
        }
        return hour >= scheduleStartHour || hour < scheduleEndHour
    }

    public func evaluateSleepPrevention(logTransition: Bool) {
        let snap = Self.readInternalBatterySnapshot()
        if isMacLaptop != snap.hasInternalBattery {
            isMacLaptop = snap.hasInternalBattery
        }

        let engineEligible: Bool
        switch engineState {
        case .starting, .autoWatching, .autoBursting, .enhancingActive:
            engineEligible = true
        default:
            engineEligible = false
        }

        guard FeatureToggleManager.shared.enablePluginPSPortal,
              autoWatchEnabled,
              preventSleepInAutoWatch,
              !suspendedBySleep,
              engineEligible else {
            releaseSleepAssertion()
            setClamshellKeepAwakeDesired(false)
            if !FeatureToggleManager.shared.enablePluginPSPortal || !autoWatchEnabled {
                sleepPreventionStatusText = ""
                lastSleepPolicyLogKey = ""
            } else if !preventSleepInAutoWatch {
                sleepPreventionStatusText = "防休眠已关闭 · 允许正常休眠"
                if logTransition && lastSleepPolicyLogKey != "disabled_by_user" {
                    lastSleepPolicyLogKey = "disabled_by_user"
                    appendLog("[守望] 💤 已关闭守望防休眠，Mac 闲置时可正常进入休眠")
                }
            } else if case .suspendedOutOfLAN = engineState {
                sleepPreventionStatusText = "不在家庭网络 · 允许休眠"
                lastSleepPolicyLogKey = "out_of_lan"
            } else {
                sleepPreventionStatusText = "待命未启动 · 允许休眠"
            }
            return
        }

        var blockStatusText: String? = nil
        var blockLogKey: String? = nil
        var blockLogLine: String? = nil

        switch sleepPreventMode {
        case .always:
            break
        case .scheduled:
            if !isWithinScheduledWatchWindow() {
                let startStr = String(format: "%02d:00", scheduleStartHour)
                let endStr = String(format: "%02d:00", scheduleEndHour)
                blockStatusText = "非守望时段 · 允许休眠"
                blockLogKey = "outside_schedule_\(scheduleStartHour)_\(scheduleEndHour)"
                blockLogLine = "[守望] 🌙 当前不在守望时段（\(startStr)–\(endStr)），已允许 Mac 正常休眠"
            }
        case .idleTimeout:
            let userIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
            let portalIdle = Date().timeIntervalSince(lastPortalActivityAt)
            let effectiveIdle = min(userIdle, portalIdle)
            if effectiveIdle >= Double(idleTimeoutHours * 3600) {
                blockStatusText = "闲置超 \(idleTimeoutHours) 小时 · 允许休眠"
                blockLogKey = "idle_timeout_\(idleTimeoutHours)"
                blockLogLine = "[守望] 💤 连续 \(idleTimeoutHours) 小时未检测到操作与 Portal 活动，已允许 Mac 正常休眠"
            }
        }

        if blockStatusText == nil && snap.hasInternalBattery {
            if powerCondition == .acOnly && !snap.isOnAC {
                blockStatusText = "未接电源 · 允许休眠"
                blockLogKey = "battery_ac_only"
                blockLogLine = "[守望] 🔋 当前使用电池供电（已设为仅插电生效），已允许 Mac 正常休眠"
            } else if !snap.isOnAC && snap.batteryPercent <= lowBatteryThreshold {
                blockStatusText = "低电量 ≤\(lowBatteryThreshold)% · 允许休眠"
                blockLogKey = "low_battery_\(lowBatteryThreshold)"
                blockLogLine = "[守望] 🔋 内置电池电量（\(snap.batteryPercent)%）低于 \(lowBatteryThreshold)% 阈值，已允许 Mac 正常休眠"
            } else if !snap.isOnAC && snap.isLowPowerMode {
                blockStatusText = "系统低电量模式 · 允许休眠"
                blockLogKey = "low_power_mode"
                blockLogLine = "[守望] 🔋 macOS 低电量模式已开启，已允许 Mac 正常休眠"
            }
        }

        if let statusText = blockStatusText {
            releaseSleepAssertion()
            setClamshellKeepAwakeDesired(false)
            sleepPreventionStatusText = statusText
            if logTransition, let key = blockLogKey, let line = blockLogLine, lastSleepPolicyLogKey != key {
                lastSleepPolicyLogKey = key
                appendLog(line)
            }
            return
        }

        let wasHolding = isSleepAssertionActive
        acquireSleepAssertionIfNeeded()

        let shouldHoldClamshell = snap.hasInternalBattery &&
            allowClamshellKeepAwake &&
            isSleepAssertionActive &&
            snap.isOnAC &&
            (relayProcess?.isRunning == true)
        setClamshellKeepAwakeDesired(shouldHoldClamshell)
        refreshSleepPreventionStatusLabel()

        let activeKey = "active_\(shouldHoldClamshell ? "clamshell" : "idle")_\(sleepPreventMode.rawValue)_\(powerCondition.rawValue)"
        if logTransition && (!wasHolding || lastSleepPolicyLogKey != activeKey) {
            lastSleepPolicyLogKey = activeKey
            if shouldHoldClamshell {
                appendLog("[守望] ☕ 已开启插电合盖保持守望（拔电或离家局域网将立即恢复正常休眠）")
            } else if isSleepAssertionActive {
                let acSuffix = (snap.hasInternalBattery && powerCondition == .acOnly) ? "，仅接通电源时生效" : ""
                appendLog("[守望] ☕ 已阻止系统闲置休眠（屏幕可正常熄灭\(acSuffix)）")
            }
        }
    }

    private func refreshSleepPreventionStatusLabel() {
        guard isSleepAssertionActive else { return }
        if isClamshellKeepAwakeActive || clamshellDesiredState {
            sleepPreventionStatusText = "☕ 合盖防休眠生效中"
        } else {
            sleepPreventionStatusText = "☕ 防休眠生效中 · 屏幕可息屏"
        }
    }

    private func acquireSleepAssertionIfNeeded() {
        guard sleepAssertionID == 0 else {
            isSleepAssertionActive = true
            return
        }
        var newID: IOPMAssertionID = 0
        let res = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SysPulse PS Portal 自动增强守望" as CFString,
            &newID
        )
        if res == kIOReturnSuccess {
            sleepAssertionID = newID
            isSleepAssertionActive = true
        }
    }

    private func releaseSleepAssertion() {
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
        isSleepAssertionActive = false
    }

    private func setClamshellKeepAwakeDesired(_ desired: Bool, forceCheck: Bool = false) {
        clamshellDesiredState = desired
        if !forceCheck && clamshellLastAppliedState == desired {
            return
        }
        guard !clamshellApplyInFlight else { return }
        runNextClamshellApplyStep(forceOffIfNeeded: forceCheck && !desired)
    }

    private func runNextClamshellApplyStep(forceOffIfNeeded: Bool = false) {
        let target = clamshellDesiredState
        if !forceOffIfNeeded && clamshellLastAppliedState == target {
            return
        }
        if !target && KeepAwakeController.shared.isClamshellKeepAwakeActive {
            clamshellLastAppliedState = false
            isClamshellKeepAwakeActive = false
            refreshSleepPreventionStatusLabel()
            return
        }
        let engine = FileManager.default.isExecutableFile(atPath: Self.privilegedEnginePath)
            ? Self.privilegedEnginePath
            : engineFileURL.path
        guard FileManager.default.isExecutableFile(atPath: engine) else {
            isClamshellKeepAwakeActive = false
            return
        }
        clamshellApplyInFlight = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = ["-n", engine, "--clamshell-keepawake", target ? "on" : "off"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            var ok = false
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                ok = (proc.terminationStatus == 0)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.clamshellApplyInFlight = false
                if ok {
                    self.clamshellLastAppliedState = target
                    self.isClamshellKeepAwakeActive = target
                    self.refreshSleepPreventionStatusLabel()
                } else if !target {
                    self.isClamshellKeepAwakeActive = false
                    self.refreshSleepPreventionStatusLabel()
                }
                if self.clamshellDesiredState != target {
                    self.runNextClamshellApplyStep()
                }
            }
        }
    }

    private func handleEngineEventJSON(_ rawJSON: String, sessionID: UInt64) {
        guard sessionID == relaySessionID,
              let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "state":
            guard let stateName = obj["state"] as? String else { return }
            switch stateName {
            case "watching":
                let result = obj["result"] as? String
                stopListenCountdown()
                if result == "timeout" {
                    let cooldown = (obj["cooldown"] as? Int) ?? 20
                    startCooldownCountdown(seconds: cooldown)
                }
                if result == "enhanced", case .enhancingActive = engineState {
                    // 刚注入成功并返回静默旁路，UI 保持「画质增强中」直至串流结束探测确认
                    return
                }
                if case .autoBursting = engineState {
                    transition(to: .autoWatching)
                } else if case .starting = engineState {
                    transition(to: .autoWatching)
                } else if case .authorizing = engineState {
                    transition(to: .autoWatching)
                }
            case "bursting":
                let seconds = (obj["seconds"] as? Int) ?? 120
                lastPortalActivityAt = Date()
                stopCooldownCountdown()
                transition(to: .autoBursting)
                startListenCountdown(seconds: seconds)
            case "listening":
                let seconds = (obj["seconds"] as? Int) ?? 120
                stopCooldownCountdown()
                transition(to: .manualListening(remainingSeconds: seconds))
                startListenCountdown(seconds: seconds)
            case "out_of_lan":
                stopListenCountdown()
                stopCooldownCountdown()
                transition(to: .suspendedOutOfLAN)
            default:
                break
            }

        case "cooldown_ended":
            stopCooldownCountdown()

        case "stream_enhanced":
            let bitrateInt = (obj["bitrate"] as? Int) ?? Int((obj["bitrate"] as? String) ?? "") ?? 100
            let tag = "\(bitrateInt)M"
            lastPortalActivityAt = Date()
            stopListenCountdown()
            stopCooldownCountdown()
            saveConfig()
            transition(to: .enhancingActive(bitrateTag: tag))
            sendEnhancementNotification(bitrateTag: tag)
            startStreamPresenceMonitor()

        case "already_streaming":
            appendLog("[提示] 💡 检测到已有串流会话在运行，请断开当前串流后重新连接即可生效高码率。")
            if !isStreamActive {
                transition(to: .alreadyStreamingHint)
            }

        case "route_mismatch":
            if autoWatchEnabled {
                transition(to: .suspendedOutOfLAN)
            }

        case "error":
            let code = (obj["code"] as? String) ?? "unknown"
            lastError = "引擎运行异常 (\(code))"
            transition(to: .error(lastError!))

        default:
            break
        }
    }

    private func startStreamPresenceMonitor() {
        streamPresenceTask?.cancel()
        consecutivePortalMisses = 0
        let iface = selectedInterface
        let ps5 = ps5IP
        let portal = portalIP

        streamPresenceTask = Task.detached { [weak self] in
            // 刚注入后等待 20s 进入稳态后再定期低开销检查串流是否结束
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                let ddp = LanDeviceSnifferEngine.probePlayStationDDP(
                    targetIPs: ps5.isEmpty ? [] : [ps5],
                    broadcastIPs: [],
                    interfaceName: iface,
                    timeoutMs: 320
                )
                let ps5Standby = (ddp[ps5]?.isStandby == true)

                if !portal.isEmpty {
                    LanDeviceSnifferEngine.probeHostsViaICMP(
                        ips: [portal],
                        interfaceName: iface,
                        batchSize: 1,
                        batchDelayUs: 0
                    )
                }
                try? await Task.sleep(for: .milliseconds(350))
                let arpNow = Self.collectPortalScanArpSnapshot(
                    targetIface: iface,
                    activeIfaceNames: [iface],
                    localIP: "",
                    gatewayIP: ""
                )
                let portalAlive = !portal.isEmpty && arpNow[portal] != nil

                let shouldEnd = await MainActor.run { [weak self] () -> Bool in
                    guard let self else { return true }
                    guard case .enhancingActive = self.engineState else { return true }
                    if ps5Standby {
                        self.endEnhancementSession(reason: "检测到 PS5 已进入待机状态，自动恢复待命")
                        return true
                    }
                    if portalAlive {
                        self.consecutivePortalMisses = 0
                        return false
                    } else {
                        self.consecutivePortalMisses += 1
                        if self.consecutivePortalMisses >= 2 {
                            self.endEnhancementSession(reason: "连续两次未检测到 Portal 在线（串流已退出），自动恢复待命")
                            return true
                        }
                        return false
                    }
                }
                if shouldEnd { break }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func sendEnhancementNotification(bitrateTag: String) {
        guard notificationsEnabled,
              Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "PS Portal 画质增强已自动激活"
            content.body = "已将本次串流切换至 \(bitrateTag) 高画质 · 视频直连不经过 Mac"
            content.sound = .default
            let req = UNNotificationRequest(identifier: "syspulse.portal.enhanced.\(UUID().uuidString)", content: content, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
    }

    private func evaluateProcessOutput(_ line: String, sessionID: UInt64) {
        guard sessionID == relaySessionID else { return }
        if line.contains("增强通道已就绪") || line.contains("网络协商就绪") || line.contains("READY: connect Portal") || line.contains("EXPERIMENT READY") || line.contains("BASELINE READY") {
            stopCooldownCountdown()
            transition(to: .manualListening(remainingSeconds: 120))
            startListenCountdown(seconds: 120)
        } else if line.contains("PS5 reported high target bitrate") || line.contains("Target confirmed") || line.contains("[ACCEPTED]") || line.contains("已确认并接受高码率协商") || line.contains("并保持视频直连") || line.contains("已提前交还直连") {
            stopListenCountdown()
            stopCooldownCountdown()
            saveConfig()
            transition(to: .enhancingActive(bitrateTag: targetBitrate.shortTag))
            startStreamPresenceMonitor()
            if !autoWatchEnabled {
                scheduleRelayReset(after: 1.5, sessionID: sessionID)
            }
        } else if line.contains("检测到设备 MAC 冲突") || line.contains("已中止中继以保护网络") || line.hasPrefix("[错误]") {
            stopListenCountdown()
        stopCooldownCountdown()
            lastError = line
            transition(to: .error(line))
            scheduleRelayReset(after: 0.4, sessionID: sessionID)
        } else if line.contains("未生效") || line.contains("未检测到 PS Portal 握手请求") || line.contains("NOT APPLIED") {
            stopListenCountdown()
        stopCooldownCountdown()
            lastError = "未检测到 PS Portal 握手请求（120 秒内未收到连接，或 Portal 仍处于休眠状态）。"
            transition(to: .idle)
            scheduleRelayReset(after: 0.8, sessionID: sessionID)
        } else if line.contains("未确认目标码率") || line.contains("UNCONFIRMED") {
            stopListenCountdown()
        stopCooldownCountdown()
            lastError = "握手修改已发送，但未能在规定时间内检测到 PS5 连续 3 次高码率遥测确认。"
            transition(to: .idle)
            scheduleRelayReset(after: 0.8, sessionID: sessionID)
        } else if line.contains("RESTORATION FAILED") || line.contains("路由恢复异常") {
            stopListenCountdown()
        stopCooldownCountdown()
            lastError = "网络恢复异常，请检查网络配置。"
            transition(to: .error(lastError!))
            scheduleRelayReset(after: 0.8, sessionID: sessionID)
        } else if !autoWatchEnabled && (line.contains("报告存档:") || line.contains("report.json") || line.contains("引擎模式:")) {
            scheduleRelayReset(after: 1.0, sessionID: sessionID)
        }
    }

    private func scheduleRelayReset(after delay: TimeInterval, sessionID: UInt64) {
        resetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.relaySessionID == sessionID else { return }
            self.flushRemainingLogBuffer(sessionID: sessionID)
            self.stopListenCountdown()
            self.relayProcess = nil
            self.resetWorkItem = nil
            if case .enhancingActive = self.engineState {
                // 保持画质增强中状态由 presence monitor 收尾
                return
            }
            if case .error = self.engineState { return }
            self.transition(to: (self.ps5IP.isEmpty || self.portalIP.isEmpty) ? .needsConfiguration : .idle)
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func appendLog(_ text: String) {
        lastLogAppendAt = Date()
        let formattedLine: String
        if debugModeEnabled {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            formattedLine = text.hasPrefix("[DEBUG") ? text : "[\(df.string(from: Date()))] \(text)"
        } else {
            formattedLine = text
        }
        logs.append(PortalLogEntry(text: formattedLine))
        let maxLogs = debugModeEnabled ? 2000 : 300
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }

        // Debug 模式下同步追加写入本地磁盘日志文件 ~/Library/Logs/SysPulse/psportal.log
        if debugModeEnabled {
            let path = logFilePath
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let sz = attrs[.size] as? Int64, sz > 2 * 1024 * 1024 {
                let bak = path + ".old"
                try? fm.removeItem(atPath: bak)
                try? fm.moveItem(atPath: path, toPath: bak)
            }
            if let data = (formattedLine + "\n").data(using: .utf8) {
                if fm.fileExists(atPath: path), let fh = FileHandle(forWritingAtPath: path) {
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: data)
                    try? fh.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func copyLogs() {
        let content = logs.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
