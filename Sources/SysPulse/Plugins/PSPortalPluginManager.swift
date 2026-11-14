import Foundation
import AppKit
import Darwin
import Observation

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

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .psPortal: return "PS Portal 串流画质增强"
        case .wifiLatency: return "Wi-Fi 低延迟"
        case .arpSniffer: return "局域网 ARP 嗅探与设备诊断"
        case .upsManager: return "UPS 电源管理"
        case .antigravityContext: return "Antigravity 上下文扩容"
        }
    }
}

public enum SonyDeviceRole: String, Sendable, Codable {
    case ps5Host
    case portalClient
    case unknownSony
    case other
}

public struct DiscoveredDevice: Identifiable, Sendable, Codable {
    public let id: String
    public let ip: String
    public let mac: String
    public let isLikelySony: Bool
    public let role: SonyDeviceRole
    public let hostName: String?
    public let label: String

    public init(
        id: String,
        ip: String,
        mac: String,
        isLikelySony: Bool,
        role: SonyDeviceRole = .other,
        hostName: String? = nil,
        label: String
    ) {
        self.id = id
        self.ip = ip
        self.mac = mac
        self.isLikelySony = isLikelySony
        self.role = role
        self.hostName = hostName
        self.label = label
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
    public var isRunning: Bool = false
    public var isStopping: Bool = false
    public var isListening: Bool = false
    public var isStreamActive: Bool = false
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
    public var pluginVersion: String = "0.1.3"
    public var pluginAuthor: String = "atameric"
    public var pluginRepo: String = "https://github.com/atameric/ps5-portal-high-bitrate"
    public var installedCommitSHA: String = "4430daa"
    public var installedCommitDate: String = "2026-10-21"
    public var installedCommitMsg: String = "docs: add October 21 Raspberry Pi and mobile update"
    public var lastError: String? = nil
    public var listenRemainingSeconds: Int? = nil

    private var relayProcess: Process?
    private var outputPipe: Pipe?
    private var logWatchTimer: Timer?
    private var listenCountdownTimer: Timer?
    private var listenDeadline: Date?
    private var lastLogOffset: UInt64 = 0
    private var logLineBuffer: Data = Data()
    private var relaySessionID: UInt64 = 0
    private var resetWorkItem: DispatchWorkItem?
    private var hasExplicitInterfaceConfig: Bool = false

    nonisolated private static let privilegedEngineDirectory = "/Library/Application Support/SysPulse"
    nonisolated private static let privilegedEnginePath = "/Library/Application Support/SysPulse/portal_engine"
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
        if logs.isEmpty {
            appendLog("[SysPulse] 插件子系统加载完成：PS Portal 串流画质增强模块 (v\(pluginVersion))")
        }
    }

    public func deactivate() {
        stopRelay()
        logWatchTimer?.invalidate()
        logWatchTimer = nil
        stopListenCountdown()
        isScanningDevices = false
        discoveredDevices = []
    }

    private func startListenCountdown(seconds: Int = 120) {
        listenCountdownTimer?.invalidate()
        listenDeadline = Date().addingTimeInterval(TimeInterval(seconds))
        listenRemainingSeconds = seconds

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isListening, let deadline = self.listenDeadline else {
                    self.stopListenCountdown()
                    return
                }
                let remaining = max(0, min(seconds, Int(ceil(deadline.timeIntervalSinceNow))))
                if self.listenRemainingSeconds != remaining {
                    self.listenRemainingSeconds = remaining
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
            if !localIP.isEmpty && !entry.ifName.isEmpty && entry.ifName != targetIface {
                continue
            }
            if arpByIP[ip] != nil && ifName != targetIface {
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

    public func scanLocalDevices() {
        guard !isScanningDevices else { return }
        detectInterfaces()
        self.isScanningDevices = true
        self.appendLog("[SysPulse] 正在唤醒并探测局域网 PS5 / PS Portal 设备...")

        let targetIface = self.selectedInterface
        let localIP = self.selectedInterfaceInfo?.ip ?? ""
        let (gatewayIP, _) = NetworkDetailModel.detectGatewayAndInterface()
        let currentPS5 = self.ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPortal = self.portalIP.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let subnetInfo = ActiveInterfaceInfo.ipv4SubnetInfo(for: targetIface)
            let (targetHosts, resolvedBroadcasts) = LanDeviceSnifferEngine.resolveScanTargetHosts(
                interfaceName: targetIface,
                fallbackGatewayIP: gatewayIP
            )
            var mutableBroadcasts = resolvedBroadcasts
            if let bcast = subnetInfo?.broadcast, !bcast.isEmpty, !mutableBroadcasts.contains(bcast) {
                mutableBroadcasts.append(bcast)
            }
            let broadcastTargets = mutableBroadcasts

            // 优先定向唤醒已记录的 PS5 / Portal IP（突破无线 DTIM 深度待机省电唤醒延迟）
            let priorityIPs = Array(Set([currentPS5, currentPortal].filter {
                !$0.isEmpty && $0 != localIP && $0 != gatewayIP && Self.isValidUnicastIPv4($0)
            }))

            // 第 1 阶段：优先 IP ICMP + TCP (9295/443/80) + UDP (5353/9302) 唤醒，兼顾全网段 UDP + ICMP 扫网
            if !priorityIPs.isEmpty {
                LanDeviceSnifferEngine.probeHostsViaICMP(
                    ips: priorityIPs,
                    interfaceName: targetIface,
                    batchSize: priorityIPs.count,
                    batchDelayUs: 0
                )
                LanDeviceSnifferEngine.probeHostsViaTCP(
                    ips: priorityIPs,
                    ports: [9295, 443, 80],
                    interfaceName: targetIface,
                    batchSize: priorityIPs.count,
                    batchDelayUs: 12_000
                )
                LanDeviceSnifferEngine.probeHostsViaUDP(
                    ips: priorityIPs,
                    ports: [5353, 9302],
                    interfaceName: targetIface,
                    batchSize: priorityIPs.count,
                    batchDelayUs: 0
                )
            }

            if !targetHosts.isEmpty {
                LanDeviceSnifferEngine.probeHostsViaUDP(
                    ips: targetHosts,
                    ports: [5353, 137],
                    interfaceName: targetIface,
                    batchSize: 32,
                    batchDelayUs: 6_000
                )
                LanDeviceSnifferEngine.probeHostsViaICMP(
                    ips: targetHosts,
                    interfaceName: targetIface,
                    batchSize: 32,
                    batchDelayUs: 6_000
                )
            }
            usleep(450_000)

            var arpByIP = Self.collectPortalScanArpSnapshot(
                targetIface: targetIface,
                localIP: localIP,
                gatewayIP: gatewayIP
            )

            // 第 2 阶段：若待机 Portal 仍未从无线省电态（约 900ms DTIM 周期）唤醒入表，则补发 ICMP + TCP SYN 9295/443 再等 500ms
            let hasSavedPortalInArp = currentPortal.isEmpty || arpByIP[currentPortal] != nil
            let hasPortalCandidateInArp = arpByIP.values.contains {
                LanDeviceSnifferEngine.isPortalOUI($0.mac) || LanDeviceSnifferEngine.isSonyInteractiveOUI($0.mac)
            }
            if !hasSavedPortalInArp || !hasPortalCandidateInArp {
                let missingPriority = priorityIPs.filter { arpByIP[$0] == nil }
                let missingHosts = targetHosts.filter { arpByIP[$0] == nil }
                let wakeupIPs = missingPriority.isEmpty ? missingHosts : Array(Set(missingPriority + missingHosts))
                if !wakeupIPs.isEmpty {
                    DispatchQueue.main.async {
                        self?.appendLog("[SysPulse] 正在针对深度待机无线设备执行二次唤醒探活...")
                    }
                    LanDeviceSnifferEngine.probeHostsViaICMP(
                        ips: wakeupIPs,
                        interfaceName: targetIface,
                        batchSize: 32,
                        batchDelayUs: 8_000
                    )
                    LanDeviceSnifferEngine.probeHostsViaTCP(
                        ips: priorityIPs.isEmpty ? missingHosts : priorityIPs,
                        ports: [9295, 443],
                        interfaceName: targetIface,
                        batchSize: 24,
                        batchDelayUs: 15_000
                    )
                    usleep(500_000)
                    let refreshed = Self.collectPortalScanArpSnapshot(
                        targetIface: targetIface,
                        localIP: localIP,
                        gatewayIP: gatewayIP
                    )
                    for (ip, item) in refreshed where arpByIP[ip] == nil {
                        arpByIP[ip] = item
                    }
                }
            }

            // 第 3 阶段：并行执行 PlayStation DDP (UDP 9302) 与 多协议设备自报探测 (DNS PTR / mDNS / SSDP / NetBIOS)
            DispatchQueue.main.async {
                self?.appendLog("[SysPulse] 正在通过 DDP (9302) + 多协议自报 + SIE OUI 综合识别主机与 Portal...")
            }

            let ddpTargets = Array(Set(arpByIP.values.filter {
                LanDeviceSnifferEngine.isSonyOUI($0.mac) || LanOuiDatabase.isLocallyAdministeredMAC($0.mac)
            }.map(\.ip) + priorityIPs))
            let reportTargets = Array(arpByIP.keys)

            let ddpBox = ProbeResultBox<[String: PlayStationDDPInfo]>([:])
            let reportBox = ProbeResultBox<[String: LanPeerSelfReport]>([:])
            let probeGroup = DispatchGroup()

            probeGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let map = LanDeviceSnifferEngine.probePlayStationDDP(
                    targetIPs: ddpTargets,
                    broadcastIPs: broadcastTargets,
                    interfaceName: targetIface,
                    timeoutMs: 340
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
                        timeoutMs: 400
                    )
                    reportBox.set(reports)
                    probeGroup.leave()
                }
            }

            _ = probeGroup.wait(timeout: .now() + .milliseconds(550))
            let ddpMap = ddpBox.get()
            let selfReports = reportBox.get()

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

                let selfReportName = [report?.friendlyName, report?.model, report?.hostname]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                let combinedText = [report?.friendlyName, report?.model, report?.hostname, report?.manufacturer]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")

                let isNonHandheldSonyDevice = !combinedText.contains("portal") && (
                    combinedText.contains("bravia") ||
                    combinedText.contains("xperia") ||
                    combinedText.contains("soundbar") ||
                    combinedText.contains("speaker") ||
                    combinedText.contains("ht-") ||
                    combinedText.contains("srs-") ||
                    combinedText.contains("vpl-") ||
                    (combinedText.contains("tv") && !combinedText.contains("ps"))
                )

                let matchesPortalName = combinedText.contains("portal")
                let matchesSavedPortal = !currentPortal.isEmpty && ip == currentPortal && (isSonyOUI || isLocalAdminMAC)
                let isPortalCandidate = !isNonHandheldSonyDevice && (isPortalOUI || matchesPortalName || isSIEOUI || matchesSavedPortal)

                let role: SonyDeviceRole
                let label: String
                let resolvedHostName: String?
                let isSony: Bool

                if let ddp {
                    role = .ps5Host
                    resolvedHostName = ddp.hostName.isEmpty ? selfReportName : ddp.hostName
                    label = ddp.hostName.isEmpty ? ddp.hostType : "\(ddp.hostType) (\(ddp.hostName))"
                    isSony = true
                } else if isPortalCandidate {
                    role = .portalClient
                    resolvedHostName = selfReportName
                    if let selfReportName, !selfReportName.lowercased().contains("portal") {
                        label = "PS Portal (\(selfReportName))"
                    } else if let selfReportName {
                        label = selfReportName
                    } else if isPortalOUI {
                        label = "PS Portal"
                    } else if isSIEOUI {
                        label = "PS Portal (SIE 硬件)"
                    } else {
                        label = "PS Portal (已配置)"
                    }
                    isSony = true
                } else if isSonyOUI {
                    role = .unknownSony
                    resolvedHostName = selfReportName
                    label = selfReportName.map { "Sony \($0)" } ?? "Sony PlayStation / 影音设备"
                    isSony = true
                } else {
                    role = .other
                    resolvedHostName = selfReportName
                    label = selfReportName ?? LanOuiDatabase.shared.lookup(mac)?.displayName ?? "局域网终端"
                    isSony = false
                }

                results.append(DiscoveredDevice(
                    id: "\(ip)-\(mac)",
                    ip: ip,
                    mac: mac,
                    isLikelySony: isSony,
                    role: role,
                    hostName: resolvedHostName,
                    label: label
                ))
            }

            // 补充仅通过 UDP 9302 广播发现但暂未在 ARP 过滤命中的 PS5
            for (ip, ddp) in ddpMap where arpByIP[ip] == nil {
                results.append(DiscoveredDevice(
                    id: "\(ip)-ddp",
                    ip: ip,
                    mac: "",
                    isLikelySony: true,
                    role: .ps5Host,
                    hostName: ddp.hostName,
                    label: ddp.hostName.isEmpty ? ddp.hostType : "\(ddp.hostType) (\(ddp.hostName))"
                ))
            }

            // 排序：PS5 主机 -> PS Portal -> 其他 Sony -> 局域网终端，同级按 IPv4 数值升序
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
                let ip1 = LanDeviceSnifferEngine.ipToComparable(a.ip)
                let ip2 = LanDeviceSnifferEngine.ipToComparable(b.ip)
                if ip1 != ip2 { return ip1 < ip2 }
                return a.ip < b.ip
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discoveredDevices = results
                self.isScanningDevices = false

                let isInActiveSubnet: (String) -> Bool = { ip in
                    guard !ip.isEmpty else { return false }
                    if let subnetInfo {
                        let targetVal = LanDeviceSnifferEngine.ipToComparable(ip)
                        return targetVal != 0 && (targetVal & subnetInfo.mask) == (subnetInfo.ip & subnetInfo.mask)
                    }
                    guard !localIP.isEmpty else { return true }
                    let localPrefix = localIP.split(separator: ".").prefix(3).joined(separator: ".")
                    let targetPrefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
                    return !localPrefix.isEmpty && localPrefix == targetPrefix
                }

                let ps5Dev = results.first(where: { $0.role == .ps5Host })
                // 三级优先匹配 Portal：精准 Portal OUI / 自报含 Portal / 已保存 Portal IP > 其他 SIE 互动娱乐硬件 > 回退其他 Sony 设备
                let portalDev = results.first(where: {
                    $0.role == .portalClient && $0.ip != ps5Dev?.ip && (
                        LanDeviceSnifferEngine.isPortalOUI($0.mac) ||
                        ($0.hostName?.lowercased().contains("portal") == true) ||
                        (!currentPortal.isEmpty && $0.ip == currentPortal)
                    )
                })
                ?? results.first(where: { $0.role == .portalClient && $0.ip != ps5Dev?.ip })
                ?? results.first(where: { $0.role == .unknownSony && $0.ip != ps5Dev?.ip })

                if let ps5 = ps5Dev {
                    self.appendLog("[识别] PS5 -> \(ps5.ip)")
                    let curPS5 = self.ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
                    if curPS5.isEmpty || curPS5 == portalDev?.ip || !isInActiveSubnet(curPS5) {
                        self.ps5IP = ps5.ip
                    } else if ps5.ip != curPS5 && !results.contains(where: { $0.ip == curPS5 }) {
                        self.appendLog("[提示] 新识别到同网段 PS5 (\(ps5.ip))，若主机已换 IP 可点击上方胶囊切换。")
                    }
                }
                if let portal = portalDev {
                    self.appendLog("[识别] Portal -> \(portal.ip) (\(portal.label))")
                    let curPortal = self.portalIP.trimmingCharacters(in: .whitespacesAndNewlines)
                    if curPortal.isEmpty || curPortal == ps5Dev?.ip || !isInActiveSubnet(curPortal) {
                        self.portalIP = portal.ip
                    } else if portal.role == .portalClient && portal.ip != curPortal && !results.contains(where: { $0.ip == curPortal }) {
                        self.appendLog("[提示] 新识别到同网段 Portal (\(portal.ip))，若设备已换 IP 可点击上方胶囊切换。")
                    }
                }
                self.saveConfig()
                self.appendLog("[SysPulse] 局域网扫描完成")
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

    public func startRelay() {
        guard !isRunning && !isStopping else { return }
        bootstrapPluginDirectory()

        let trimmedPS5 = ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPortal = portalIP.trimmingCharacters(in: .whitespacesAndNewlines)
        ps5IP = trimmedPS5
        portalIP = trimmedPortal

        guard !trimmedPS5.isEmpty, !trimmedPortal.isEmpty else {
            lastError = "请先填写 PS5 IP 与 PS Portal IP（可点击「扫描局域网设备」快速识别并填入）。"
            appendLog("[错误] \(lastError!)")
            return
        }
        guard Self.isValidUnicastIPv4(trimmedPS5), Self.isValidUnicastIPv4(trimmedPortal) else {
            lastError = "请输入合法的局域网 IPv4 地址（例如 192.168.x.x）。"
            appendLog("[错误] \(lastError!)")
            return
        }
        guard trimmedPS5 != trimmedPortal else {
            lastError = "PS5 IP 与 PS Portal IP 不能相同（\(trimmedPS5)）。"
            appendLog("[错误] \(lastError!)")
            return
        }
        // 若上次 DDP 扫描已确认 PS5 与 Portal 身份但用户填反，自动对调纠偏
        if let ps5Confirmed = discoveredDevices.first(where: { $0.role == .ps5Host }),
           let portalConfirmed = discoveredDevices.first(where: { $0.role == .portalClient }) ?? discoveredDevices.first(where: { $0.role == .unknownSony }),
           trimmedPS5 == portalConfirmed.ip && trimmedPortal == ps5Confirmed.ip {
            ps5IP = ps5Confirmed.ip
            portalIP = portalConfirmed.ip
            appendLog("[SysPulse] ⚡️ 根据 DDP 识别结果检测到 PS5 与 Portal IP 填反，已自动对调纠正。")
        }
        saveConfig()

        let engine = engineFileURL.path
        guard FileManager.default.isExecutableFile(atPath: engine) else {
            lastError = "未找到插件原生中继引擎: portal_engine"
            appendLog("[错误] \(lastError!)")
            return
        }

        resetWorkItem?.cancel()
        resetWorkItem = nil
        relaySessionID &+= 1
        let currentSession = relaySessionID

        lastError = nil
        isRunning = true
        isListening = true
        isStreamActive = false
        logLineBuffer.removeAll()

        appendLog("[SysPulse] 启动 PS Portal 串流画质增强模块…")
        appendLog("[配置] 目标码率: \(targetBitrate.rawValue) | 模式: \(relayMode.rawValue) | 网卡: \(selectedInterface)")
        appendLog("[配置] PS5: \(ps5IP) | Portal: \(portalIP)")

        if runWithAdmin {
            startPrivilegedRelay(engine: engine, sessionID: currentSession)
        } else {
            startStandardRelay(engine: engine, sessionID: currentSession)
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

    private func launchPasswordlessRelay(sessionID: UInt64) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        var args = [
            "-n",
            Self.privilegedEnginePath,
            "--interface", selectedInterface,
            "--bitrate", targetBitrate.shortTag,
            "--mode", relayMode.rawValue
        ]
        if !ps5IP.isEmpty { args.append(contentsOf: ["--ps5", ps5IP]) }
        if !portalIP.isEmpty { args.append(contentsOf: ["--portal", portalIP]) }
        proc.arguments = args

        let currentLogPath = logFilePath
        FileManager.default.createFile(atPath: currentLogPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: currentLogPath)
        if let logHandle {
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }
        self.relayProcess = proc

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.relaySessionID == sessionID else { return }
                self.pollLogFile(sessionID: sessionID)
                self.flushRemainingLogBuffer(sessionID: sessionID)
                self.resetWorkItem?.cancel()
                self.resetWorkItem = nil
                self.isRunning = false
                self.isListening = false
                self.isStreamActive = false
                self.stopListenCountdown()
                self.logWatchTimer?.invalidate()
                self.logWatchTimer = nil
                self.relayProcess = nil
            }
        }

        do {
            try proc.run()
            try? logHandle?.close()
            let pid = proc.processIdentifier
            self.appendLog("[SysPulse] ✅ 管理员特权中继已在后台激活 (免密模式 · sudo PID: \(pid))。")
            self.startTailingLogFile(sessionID: sessionID)
            return true
        } catch {
            try? logHandle?.close()
            self.relayProcess = nil
            return false
        }
    }

    private func startPrivilegedRelay(engine: String, sessionID: UInt64) {
        try? "".write(toFile: logFilePath, atomically: true, encoding: .utf8)
        lastLogOffset = 0
        logLineBuffer.removeAll()

        // 检测系统目录 /Library/Application Support/SysPulse/portal_engine 是否已就绪且具备 sudo 免密特权
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isReady = Self.isPrivilegedEngineReady(stagedPath: engine) && Self.checkPasswordlessSudo()

            DispatchQueue.main.async {
                guard let self = self, self.relaySessionID == sessionID else { return }

                if isReady {
                    self.appendLog("[SysPulse] ⚡️ 检测到系统免密特权已激活，正在启动原生 BPF 注入引擎...")
                    if self.launchPasswordlessRelay(sessionID: sessionID) {
                        return
                    }
                    self.appendLog("[提示] 免密进程启动受限，尝试重新安装特权组件...")
                }

                // 首次安装或升级引擎：通过 AppleScript 将原生引擎安装至 root 专属目录并写入 sudoers
                self.appendLog("[SysPulse] 正在申请 macOS 系统管理员特权以安装原生 BPF 引擎并建立免密通道...")

                let privDir = Self.shellSingleQuoted(Self.privilegedEngineDirectory)
                let privEngine = Self.shellSingleQuoted(Self.privilegedEnginePath)
                let stagedEngine = Self.shellSingleQuoted(engine)
                let installCmd = [
                    "mkdir -p \(privDir)",
                    "chown root:wheel \(privDir)",
                    "chmod 755 \(privDir)",
                    "cp -f \(stagedEngine) \(privEngine)",
                    "chown root:wheel \(privEngine)",
                    "chmod 755 \(privEngine)",
                    "\(privEngine) --install-sudoers"
                ].joined(separator: " && ")

                let appleScript = "do shell script \"\(Self.appleScriptEscaped(installCmd))\" with administrator privileges"

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    var errorDict: NSDictionary?
                    let scriptObj = NSAppleScript(source: appleScript)
                    scriptObj?.executeAndReturnError(&errorDict)
                    let sudoReady = (errorDict == nil) && Self.checkPasswordlessSudo()

                    DispatchQueue.main.async {
                        guard let self = self, self.relaySessionID == sessionID else { return }
                        if let err = errorDict {
                            let errMsg = err[NSAppleScript.errorMessage] as? String ?? "用户取消授权"
                            self.appendLog("[提示] 特权授权未完成: \(errMsg)")
                            self.lastError = "需要管理员特权才能启用原生 BPF / ARP 注入（\(errMsg)）。"
                            self.appendLog("[错误] \(self.lastError!)")
                            self.resetWorkItem?.cancel()
                            self.resetWorkItem = nil
                            self.isRunning = false
                            self.isListening = false
                            self.isStreamActive = false
                            self.stopListenCountdown()
                        } else if sudoReady && self.launchPasswordlessRelay(sessionID: sessionID) {
                            self.appendLog("[SysPulse] ✅ 已完成系统级特权安装并建立免密通道。")
                        } else {
                            self.lastError = "免密特权通道未生效，请确认当前账户属于管理员组后重试。"
                            self.appendLog("[错误] \(self.lastError!)")
                            self.resetWorkItem?.cancel()
                            self.resetWorkItem = nil
                            self.isRunning = false
                            self.isListening = false
                            self.isStreamActive = false
                            self.stopListenCountdown()
                        }
                    }
                }
            }
        }
    }

    private func startStandardRelay(engine: String, sessionID: UInt64) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: engine)
        var args = [
            "--interface", selectedInterface,
            "--bitrate", targetBitrate.shortTag,
            "--mode", relayMode.rawValue
        ]
        if !ps5IP.isEmpty { args.append(contentsOf: ["--ps5", ps5IP]) }
        if !portalIP.isEmpty { args.append(contentsOf: ["--portal", portalIP]) }
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe = pipe
        self.relayProcess = proc

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else { return }
            Task { @MainActor in
                guard self.relaySessionID == sessionID else { return }
                self.ingestLogData(data, sessionID: sessionID)
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self = self, self.relaySessionID == sessionID else { return }
                self.flushRemainingLogBuffer(sessionID: sessionID)
                self.resetWorkItem?.cancel()
                self.resetWorkItem = nil
                self.isRunning = false
                self.isListening = false
                self.isStreamActive = false
                self.stopListenCountdown()
                self.relayProcess = nil
                self.appendLog("[SysPulse] 插件进程已安全退出 (退出码: \(p.terminationStatus))")
            }
        }

        do {
            try proc.run()
        } catch {
            isRunning = false
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "无法启动原生引擎进程: \(error.localizedDescription)"
            appendLog("[错误] \(lastError!)")
        }
    }

    private func startTailingLogFile(sessionID: UInt64) {
        logWatchTimer?.invalidate()
        lastLogOffset = 0
        logLineBuffer.removeAll()
        logWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.relaySessionID == sessionID else { return }
                self.pollLogFile(sessionID: sessionID)
            }
        }
    }

    private func pollLogFile(sessionID: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: logFilePath) else { return }
        defer { try? handle.close() }
        handle.seek(toFileOffset: lastLogOffset)
        let data = handle.readDataToEndOfFile()
        if !data.isEmpty {
            lastLogOffset += UInt64(data.count)
            ingestLogData(data, sessionID: sessionID)
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
            appendLog(line)
            evaluateProcessOutput(line, sessionID: sessionID)
        }
    }

    private func flushRemainingLogBuffer(sessionID: UInt64) {
        guard !logLineBuffer.isEmpty else { return }
        let text = String(decoding: logLineBuffer, as: UTF8.self)
        logLineBuffer.removeAll()
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for line in lines {
            appendLog(line)
            evaluateProcessOutput(line, sessionID: sessionID)
        }
    }

    public func stopRelay() {
        guard isRunning && !isStopping else { return }
        appendLog("[SysPulse] 正在停止插件监听与中继...")

        let sessionID = relaySessionID
        isStopping = true
        isListening = false
        isStreamActive = false
        stopListenCountdown()

        resetWorkItem?.cancel()
        resetWorkItem = nil

        logWatchTimer?.invalidate()
        logWatchTimer = nil

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        let engine = FileManager.default.isExecutableFile(atPath: Self.privilegedEnginePath)
            ? Self.privilegedEnginePath
            : engineFileURL.path
        let activeProc = relayProcess

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
                Thread.sleep(forTimeInterval: 0.5)
                if activeProc.isRunning {
                    activeProc.terminate()
                }
            }

            DispatchQueue.main.async {
                guard let self = self, self.relaySessionID == sessionID else { return }
                self.pollLogFile(sessionID: sessionID)
                self.flushRemainingLogBuffer(sessionID: sessionID)
                self.relayProcess = nil
                self.isStopping = false
                self.isRunning = false
                self.isListening = false
                self.isStreamActive = false
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
        let hasPidFile = FileManager.default.fileExists(atPath: pidFilePath)
        guard isRunning || isListening || hasPidFile else { return }

        logWatchTimer?.invalidate()
        logWatchTimer = nil
        stopListenCountdown()
        resetWorkItem?.cancel()
        resetWorkItem = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        let engine = FileManager.default.isExecutableFile(atPath: Self.privilegedEnginePath)
            ? Self.privilegedEnginePath
            : engineFileURL.path
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

        if !stoppedViaSudo, let activeProc = relayProcess, activeProc.isRunning {
            activeProc.interrupt()
            Thread.sleep(forTimeInterval: 0.3)
            if activeProc.isRunning {
                activeProc.terminate()
            }
        }
        relayProcess = nil
        isRunning = false
        isListening = false
        isStreamActive = false
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
                    self?.isRunning = false
                    self?.isStopping = false
                    self?.isListening = false
                    self?.isStreamActive = false
                    self?.stopListenCountdown()
                }
            } else {
                var shellCmd = "\(Self.shellSingleQuoted(engine)) --restore --interface \(Self.shellSingleQuoted(iface))"
                if !ps5.isEmpty { shellCmd += " --ps5 \(Self.shellSingleQuoted(ps5))" }
                if !portal.isEmpty { shellCmd += " --portal \(Self.shellSingleQuoted(portal))" }
                var errDict: NSDictionary?
                NSAppleScript(source: "do shell script \"\(Self.appleScriptEscaped(shellCmd))\" with administrator privileges")?.executeAndReturnError(&errDict)
                DispatchQueue.main.async {
                    if errDict == nil {
                        self?.appendLog("[SysPulse] 网络直连路由已复原。")
                        self?.isRunning = false
                        self?.isStopping = false
                        self?.isListening = false
                        self?.isStreamActive = false
                        self?.stopListenCountdown()
                    } else {
                        self?.appendLog("[提示] 网络复原未完成或已取消授权。")
                    }
                }
            }
        }
    }

    private func evaluateProcessOutput(_ line: String, sessionID: UInt64) {
        if line.contains("网络协商就绪") || line.contains("READY: connect Portal") || line.contains("EXPERIMENT READY") || line.contains("BASELINE READY") {
            isListening = true
            isStreamActive = false
            startListenCountdown(seconds: 120)
        } else if line.contains("PS5 reported high target bitrate") || line.contains("Target confirmed") || line.contains("[ACCEPTED]") || line.contains("已确认并接受高码率协商") || line.contains("并保持视频直连") || line.contains("已提前交还直连") {
            isStreamActive = true
            isListening = false
            stopListenCountdown()
            scheduleRelayReset(after: 1.5, sessionID: sessionID)
        } else if line.contains("检测到设备 MAC 冲突") || line.contains("已中止中继以保护网络") || line.hasPrefix("[错误]") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = line
            scheduleRelayReset(after: 0.4, sessionID: sessionID)
        } else if line.contains("未生效") || line.contains("未检测到 PS Portal 握手请求") || line.contains("NOT APPLIED") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "未检测到 PS Portal 握手请求（120 秒内未收到连接，或 Portal 仍处于休眠状态）。"
            scheduleRelayReset(after: 0.8, sessionID: sessionID)
        } else if line.contains("未确认目标码率") || line.contains("UNCONFIRMED") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "握手修改已发送，但未能在规定时间内检测到 PS5 连续 3 次高码率遥测确认。"
            scheduleRelayReset(after: 0.8, sessionID: sessionID)
        } else if line.contains("RESTORATION FAILED") || line.contains("路由恢复异常") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "网络恢复异常，请检查网络配置。"
            scheduleRelayReset(after: 0.8, sessionID: sessionID)
        } else if line.contains("报告存档:") || line.contains("report.json") || line.contains("引擎模式:") {
            scheduleRelayReset(after: 1.0, sessionID: sessionID)
        }
    }

    private func scheduleRelayReset(after delay: TimeInterval, sessionID: UInt64) {
        resetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.relaySessionID == sessionID else { return }
            self.flushRemainingLogBuffer(sessionID: sessionID)
            self.isRunning = false
            self.isStopping = false
            self.isListening = false
            self.stopListenCountdown()
            self.relayProcess = nil
            self.logWatchTimer?.invalidate()
            self.logWatchTimer = nil
            self.resetWorkItem = nil
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func appendLog(_ text: String) {
        logs.append(PortalLogEntry(text: text))
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
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
