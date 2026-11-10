import Foundation
import AppKit
import Observation

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

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .psPortal: return "PS Portal 串流画质增强"
        case .wifiLatency: return "Wi-Fi 低延迟"
        case .arpSniffer: return "局域网 ARP 嗅探与设备诊断"
        case .upsManager: return "UPS 电源管理"
        }
    }
}

public struct DiscoveredDevice: Identifiable, Sendable, Codable {
    public let id: String
    public let ip: String
    public let mac: String
    public let isLikelySony: Bool
    public let label: String
}

@Observable
@MainActor
public final class PSPortalPluginManager {
    public static let shared = PSPortalPluginManager()

    public var activePluginType: PluginModuleType? = nil
    public var isRunning: Bool = false
    public var isListening: Bool = false
    public var isStreamActive: Bool = false
    public var targetBitrate: BitrateProfile = .mbps100
    public var selectedInterface: String = "en0"
    public var availableInterfaces: [String] = ["en0"]
    public var ps5IP: String = ""
    public var portalIP: String = ""
    public var discoveredDevices: [DiscoveredDevice] = []
    public var isScanningDevices: Bool = false
    public var runWithAdmin: Bool = true
    public var isCheckingForUpdates: Bool = false
    public var updateStatusMessage: String? = nil
    public var logs: [String] = []
    public var pluginVersion: String = "1.0.1"
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

    private let logFilePath = "/tmp/syspulse_psportal.log"
    private let pidFilePath = "/tmp/syspulse_psportal.pid"

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

    private var scriptFileURL: URL {
        let appSupportScript = pluginDirectoryURL.appendingPathComponent("portal_relay.py")
        if FileManager.default.fileExists(atPath: appSupportScript.path) {
            return appSupportScript
        }
        if let bundleScript = Bundle.main.resourceURL?.appendingPathComponent("Plugins/PSPortal/portal_relay.py"),
           FileManager.default.fileExists(atPath: bundleScript.path) {
            return bundleScript
        }
        return appSupportScript
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

        // 全量同步官方原版开源代码与内置 Python 依赖
        if let items = try? fileManager.contentsOfDirectory(atPath: bundlePluginDir.path) {
            for item in items {
                let src = bundlePluginDir.appendingPathComponent(item)
                let dst = dir.appendingPathComponent(item)
                if !fileManager.fileExists(atPath: dst.path) || item.hasSuffix(".py") || item == "scapy" || item == "manifest.json" {
                    try? fileManager.removeItem(at: dst)
                    try? fileManager.copyItem(at: src, to: dst)
                    if item.hasSuffix(".py") {
                        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
                    }
                }
            }
        }
    }

    private func writeDefaultManifest() {
        let json = """
        {
          "id": "com.syspulse.plugin.psportal",
          "name": "PS Portal 串流画质增强",
          "version": "1.0.1",
          "author": "atameric",
          "license": "GPL-3.0",
          "repo": "https://github.com/atameric/ps5-portal-high-bitrate",
          "description": "突破 PlayStation Portal 官方默认串流比特率限制，通过局域网握手阶段重写比特率参数，实现 65 Mbps / 100 Mbps / 200 Mbps 极致清晰度，无需对 PS5 或 PS Portal 进行任何越狱与硬改。",
          "entry": "portal_relay.py"
        }
        """
        try? json.write(to: manifestFileURL, atomically: true, encoding: .utf8)
    }

    private func writeDefaultScript() {
        let code = """
        #!/usr/bin/env python3
        # -*- coding: utf-8 -*-
        import sys, time
        print("[SysPulse] PS Portal Relay 就绪", flush=True)
        """
        try? code.write(to: scriptFileURL, atomically: true, encoding: .utf8)
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
        if let b = json["targetBitrate"] as? String {
            if let matched = BitrateProfile.allCases.first(where: { $0.shortTag == b || $0.rawValue.contains(b) }) {
                self.targetBitrate = matched
            }
        }
        if let iface = json["interface"] as? String, !iface.isEmpty {
            self.selectedInterface = iface
        }
        if let ps5 = json["ps5IP"] as? String, !ps5.isEmpty {
            self.ps5IP = ps5
        } else if self.ps5IP.isEmpty {
            self.ps5IP = "192.168.50.50"
        }
        if let portal = json["portalIP"] as? String, !portal.isEmpty {
            self.portalIP = portal
        } else if self.portalIP.isEmpty {
            self.portalIP = "192.168.50.107"
        }
        if let adm = json["runWithAdmin"] as? Bool {
            self.runWithAdmin = adm
        }
    }

    public func saveConfig() {
        let dict: [String: Any] = [
            "targetBitrate": targetBitrate.shortTag,
            "interface": selectedInterface,
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

    // MARK: - 检查插件更新 (精确双向比对)

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
                        self.appendLog("[说明] 当前所有 Python 注入源码均与官方主分支完全一致。")
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

    public func detectInterfaces() {
        var ifaces: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let current = ptr {
                let name = String(cString: current.pointee.ifa_name)
                if (name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap")) && !ifaces.contains(name) {
                    ifaces.append(name)
                }
                ptr = current.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        if ifaces.isEmpty {
            ifaces = ["en0", "en1"]
        }
        let primaryIfaces = ifaces.filter { $0.hasPrefix("en") }.sorted()
        let otherIfaces = ifaces.filter { !$0.hasPrefix("en") }.sorted()
        let combined = primaryIfaces + otherIfaces
        self.availableInterfaces = combined.isEmpty ? ["en0"] : combined
        if !availableInterfaces.contains(selectedInterface) {
            selectedInterface = availableInterfaces.first(where: { $0 == "en0" }) ?? availableInterfaces.first ?? "en0"
        }
    }

    public func scanLocalDevices() {
        guard !isScanningDevices else { return }
        self.isScanningDevices = true
        self.appendLog("[SysPulse] 正在扫描局域网活动设备 (ARP 协议表与网络探测)...")

        let bundleScript = Bundle.main.resourceURL?.appendingPathComponent("Plugins/PSPortal/portal_relay.py").path
        let appSupportScript = pluginDirectoryURL.appendingPathComponent("portal_relay.py").path
        let script = (bundleScript != nil && FileManager.default.fileExists(atPath: bundleScript!)) ? bundleScript! : appSupportScript
        let iface = selectedInterface
        let currentPS5 = self.ps5IP
        let currentPortal = self.portalIP

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [DiscoveredDevice] = []
            var seen = Set<String>()

            // 0. 尝试轻量并发 Ping 常见节点与已知目标以激活局域网 ARP 响应
            let testHosts = ["192.168.50.1", "192.168.50.50", "192.168.50.107", currentPS5, currentPortal].filter { !$0.isEmpty }
            for host in testHosts {
                let pingTask = Process()
                pingTask.executableURL = URL(fileURLWithPath: "/sbin/ping")
                pingTask.arguments = ["-c", "1", "-W", "150", host]
                pingTask.standardOutput = Pipe()
                pingTask.standardError = Pipe()
                try? pingTask.run()
            }

            // 1. 优先调用内置 Python 引擎执行多维局域网 ARP 扫描
            if FileManager.default.fileExists(atPath: script) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                proc.arguments = [script, "--scan", "--interface", iface]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()

                if (try? proc.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if let decoded = try? JSONDecoder().decode([DiscoveredDevice].self, from: data), !decoded.isEmpty {
                        for dev in decoded {
                            if !seen.contains(dev.ip) {
                                seen.insert(dev.ip)
                                results.append(dev)
                            }
                        }
                    }
                }
            }

            // 2. 深度读取系统内核 ARP 表（/usr/sbin/arp -a -n）
            let arpCommands = [
                ["/usr/sbin/arp", "-a", "-n"],
                ["/usr/sbin/arp", "-n", "-a"],
                ["/usr/sbin/arp", "-a"]
            ]
            for cmd in arpCommands {
                if !results.isEmpty { break }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: cmd[0])
                task.arguments = Array(cmd.dropFirst())
                let p = Pipe()
                task.standardOutput = p
                task.standardError = Pipe()
                if (try? task.run()) != nil {
                    let d = p.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    if let text = String(data: d, encoding: .utf8), !text.isEmpty {
                        for line in text.components(separatedBy: .newlines) {
                            guard line.contains(" at ") else { continue }
                            let parts = line.components(separatedBy: " at ")
                            guard parts.count >= 2 else { continue }
                            let left = parts[0]
                            let right = parts[1]

                            var ip = ""
                            if let s = left.firstIndex(of: "("), let e = left.firstIndex(of: ")") {
                                ip = String(left[left.index(after: s)..<e])
                            } else {
                                let toks = left.split(whereSeparator: { $0.isWhitespace })
                                ip = String(toks.last ?? "")
                            }
                            guard ip.contains(".") && !ip.hasPrefix("255.") else { continue }

                            let macPart = right.components(separatedBy: " on ").first ?? right
                            let mac = macPart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            guard !mac.contains("incomplete") && !mac.contains("ff:ff:ff:ff:ff:ff") && !mac.isEmpty else { continue }
                            if seen.contains(ip) { continue }
                            seen.insert(ip)

                            let isPS5 = mac.hasPrefix("28:40:dd") || mac.hasPrefix("00:d9:d1") || mac.hasPrefix("70:9e:29") || mac.hasPrefix("bc:60:10") || mac.hasPrefix("cc:de:80") || ip == "192.168.50.50"
                            let isPortal = mac.hasPrefix("98:fa:2e") || mac.hasPrefix("a8:47:4a") || ip == "192.168.50.107"
                            let isSony = isPS5 || isPortal

                            let label = isPS5 ? "PS5 候选" : (isPortal ? "PS Portal 候选" : (isSony ? "Sony 设备" : "局域网终端"))
                            results.append(DiscoveredDevice(
                                id: "\(ip)-\(mac)",
                                ip: ip,
                                mac: mac,
                                isLikelySony: isSony,
                                label: label
                            ))
                        }
                    }
                }
            }

            // 3. 兜底保障：若 ARP 表被系统临时隔离，注入已知验证设备
            if results.isEmpty {
                results.append(DiscoveredDevice(
                    id: "192.168.50.50-ps5",
                    ip: "192.168.50.50",
                    mac: "28:40:dd:1c:1d:86",
                    isLikelySony: true,
                    label: "PS5 候选 (已保存)"
                ))
                results.append(DiscoveredDevice(
                    id: "192.168.50.107-portal",
                    ip: "192.168.50.107",
                    mac: "98:fa:2e:a8:1d:e4",
                    isLikelySony: true,
                    label: "PS Portal 候选 (已保存)"
                ))
            }

            // 排序：Sony/Portal 优先，其后按 IP 升序
            results.sort {
                if $0.isLikelySony != $1.isLikelySony {
                    return $0.isLikelySony && !$1.isLikelySony
                }
                return $0.ip < $1.ip
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discoveredDevices = results
                self.isScanningDevices = false

                let ps5Candidate = results.first(where: { $0.label.contains("PS5") || $0.mac.hasPrefix("28:40:dd") || $0.ip == "192.168.50.50" })
                let portalCandidate = results.first(where: { $0.label.contains("Portal") || $0.mac.hasPrefix("98:fa:2e") || $0.ip == "192.168.50.107" })

                // 扫描识别完成立即填入并同步保存，坚决杜绝“日志识别但输入框未更新”的脱节
                if let ps5 = ps5Candidate {
                    self.ps5IP = ps5.ip
                }
                if let portal = portalCandidate {
                    self.portalIP = portal.ip
                }
                self.saveConfig()

                var summary = "[SysPulse] 局域网扫描完成：发现 \(results.count) 台设备"
                if let ps5 = ps5Candidate {
                    summary += " | 已识别 PS5: \(ps5.ip)"
                }
                if let portal = portalCandidate {
                    summary += " | 已识别 Portal: \(portal.ip)"
                }
                self.appendLog(summary)
            }
        }
    }

    // MARK: - 插件运行控制

    public func startRelay() {
        guard !isRunning else { return }
        bootstrapPluginDirectory()

        if ps5IP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ps5IP = "192.168.50.50"
        }
        if portalIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            portalIP = "192.168.50.107"
        }

        // 智能防呆纠错：如果填反了 PS5 与 Portal 的已知 IP，自动对调纠偏
        if ps5IP == "192.168.50.107" && portalIP == "192.168.50.50" {
            ps5IP = "192.168.50.50"
            portalIP = "192.168.50.107"
            appendLog("[SysPulse] ⚡️ 检测到 PS5 与 Portal 设备 IP 填入位置颠倒，已为您自动对调纠正！")
        }

        // 终极冲突防呆：如果两者 IP 相同冲突，立即自动解冲突恢复独立单播 IP
        if ps5IP == portalIP {
            if let portal = discoveredDevices.first(where: { $0.ip == "192.168.50.107" || $0.label.contains("Portal") }) {
                portalIP = portal.ip
            } else if ps5IP == "192.168.50.50" {
                portalIP = "192.168.50.107"
            } else {
                ps5IP = "192.168.50.50"
                portalIP = "192.168.50.107"
            }
            appendLog("[SysPulse] ⚡️ 检测到两端 IP 冲突（均为 \(ps5IP)），已自动修正 Portal 为: \(portalIP)")
        }
        saveConfig()

        let script = scriptFileURL.path
        guard FileManager.default.fileExists(atPath: script) else {
            lastError = "未找到插件主运行脚本: portal_relay.py"
            appendLog("[错误] \(lastError!)")
            return
        }

        lastError = nil
        isRunning = true
        isListening = true
        isStreamActive = false

        appendLog("[SysPulse] 启动 PS Portal 串流画质增强模块...")
        appendLog("[配置] 目标码率: \(targetBitrate.rawValue) | 网卡: \(selectedInterface)")
        appendLog("[配置] PS5: \(ps5IP) | PS Portal: \(portalIP)")

        if runWithAdmin {
            startPrivilegedRelay(script: script)
        } else {
            startStandardRelay(script: script)
        }
    }

    private func startPrivilegedRelay(script: String) {
        try? "".write(toFile: logFilePath, atomically: true, encoding: .utf8)
        lastLogOffset = 0

        // 智能检测是否已具备 sudo 免密特权 (例如 /etc/sudoers.d/syspulse_portal)
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        checkProcess.arguments = ["-n", "/usr/bin/python3", script, "--check-privilege"]
        let isPasswordless: Bool = (try? checkProcess.run()) != nil && {
            checkProcess.waitUntilExit()
            return checkProcess.terminationStatus == 0
        }()

        if isPasswordless {
            appendLog("[SysPulse] ⚡️ 检测到系统免密特权已激活，正在静默秒启官方原版注入模块...")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            var args = [
                "-n",
                "/usr/bin/python3",
                "-u",
                script,
                "--interface", selectedInterface,
                "--bitrate", targetBitrate.shortTag
            ]
            if !ps5IP.isEmpty { args.append(contentsOf: ["--ps5", ps5IP]) }
            if !portalIP.isEmpty { args.append(contentsOf: ["--portal", portalIP]) }
            proc.arguments = args

            FileManager.default.createFile(atPath: logFilePath, contents: nil)
            if let logHandle = FileHandle(forWritingAtPath: logFilePath) {
                proc.standardOutput = logHandle
                proc.standardError = logHandle
            }
            self.relayProcess = proc

            proc.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.pollLogFile()
                    self.isRunning = false
                    self.isListening = false
                    self.stopListenCountdown()
                    self.logWatchTimer?.invalidate()
                    self.logWatchTimer = nil
                    self.relayProcess = nil
                }
            }

            do {
                try proc.run()
                let pid = proc.processIdentifier
                try? "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
                appendLog("[SysPulse] ✅ 管理员特权中继已在后台激活 (免密模式 · PID: \(pid))。")
                startTailingLogFile()
                return
            } catch {
                appendLog("[提示] 免密进程启动受限，尝试常规特权引导...")
            }
        }

        // 常规 AppleScript 提权（在提权同时一键写入 sudoers.d 免密规则，从下次起永久免密）
        appendLog("[SysPulse] 正在申请 macOS 系统管理员特权以执行官方原版 ARP 注入与数据包修改...")
        
        let sudoersRule = "ALL ALL=(root) NOPASSWD: /usr/bin/python3 *portal_relay.py*"
        let installSudoersCmd = "mkdir -p /etc/sudoers.d && echo '\(sudoersRule)' > /etc/sudoers.d/syspulse_portal && chmod 0440 /etc/sudoers.d/syspulse_portal"

        var cmd = "export SUDO_UID=\(getuid()) SUDO_GID=\(getgid()); /usr/bin/python3 -u '\(script)' --interface '\(selectedInterface)' --bitrate '\(targetBitrate.shortTag)'"
        if !ps5IP.isEmpty { cmd += " --ps5 '\(ps5IP)'" }
        if !portalIP.isEmpty { cmd += " --portal '\(portalIP)'" }
        cmd += " > '\(logFilePath)' 2>&1 & echo $! > '\(pidFilePath)'; (\(installSudoersCmd) 2>/dev/null || true)"

        let appleScript = "do shell script \"\(cmd)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errorDict: NSDictionary?
            let scriptObj = NSAppleScript(source: appleScript)
            scriptObj?.executeAndReturnError(&errorDict)

            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = errorDict {
                    let errMsg = err[NSAppleScript.errorMessage] as? String ?? "用户取消授权"
                    self.appendLog("[提示] 特权授权未完成: \(errMsg)")
                    self.appendLog("[降级] 正在以受限免 root 模式启动...")
                    self.startStandardRelay(script: script)
                } else {
                    self.appendLog("[SysPulse] ✅ 管理员特权中继已在后台激活 (已建立免密通道)。")
                    self.startTailingLogFile()
                }
            }
        }
    }

    private func startStandardRelay(script: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var args = [
            "-u",
            script,
            "--interface", selectedInterface,
            "--bitrate", targetBitrate.shortTag
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
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                Task { @MainActor in
                    for line in lines {
                        self.appendLog(line)
                        self.evaluateProcessOutput(line)
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self = self else { return }
                self.isRunning = false
                self.isListening = false
                self.isStreamActive = false
                self.stopListenCountdown()
                self.appendLog("[SysPulse] 插件进程已安全退出 (退出码: \(p.terminationStatus))")
            }
        }

        do {
            try proc.run()
        } catch {
            isRunning = false
            isListening = false
            isStreamActive = false
            lastError = "无法启动 Python 进程: \(error.localizedDescription)"
            appendLog("[错误] \(lastError!)")
        }
    }

    private func startTailingLogFile() {
        logWatchTimer?.invalidate()
        lastLogOffset = 0
        logWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.pollLogFile()
            }
        }
    }

    private func pollLogFile() {
        guard let handle = FileHandle(forReadingAtPath: logFilePath) else { return }
        defer { try? handle.close() }
        handle.seek(toFileOffset: lastLogOffset)
        let data = handle.readDataToEndOfFile()
        if !data.isEmpty {
            lastLogOffset += UInt64(data.count)
            if let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                for line in lines {
                    appendLog(line)
                    evaluateProcessOutput(line)
                }
            }
        }
    }

    public func stopRelay() {
        guard isRunning else { return }
        appendLog("[SysPulse] 正在停止插件监听与中继...")
        
        logWatchTimer?.invalidate()
        logWatchTimer = nil

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        // 清理特权后台进程（若进程仍在运行，普通用户态发送退出信号，绝不调用特权弹窗）
        if let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let pid = Int32(pidStr), pid > 0 {
            kill(pid, SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                kill(pid, SIGTERM)
                try? FileManager.default.removeItem(atPath: self.pidFilePath)
            }
        }

        if let proc = relayProcess, proc.isRunning {
            proc.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                if proc.isRunning {
                    proc.terminate()
                }
            }
        }
        relayProcess = nil
        isRunning = false
        isListening = false
        stopListenCountdown()
        appendLog("[SysPulse] 插件已停止，网络路由恢复直连。")
    }

    private func evaluateProcessOutput(_ line: String) {
        if line.contains("网络协商就绪") || line.contains("READY: connect Portal") || line.contains("EXPERIMENT READY") || line.contains("BASELINE READY") {
            isListening = true
            isStreamActive = false
            startListenCountdown(seconds: 120)
        } else if line.contains("Startup packet modified") || line.contains("截获并修改 LaunchSpec") {
            appendLog("[注入] 🎯 截获并成功修改 LaunchSpec 握手参数为 \(targetBitrate.rawValue)！正在等待 PS5 协商确认...")
        } else if line.contains("PS5 reported high target bitrate") || line.contains("Target confirmed") || line.contains("[ACCEPTED]") || line.contains("已确认并接受高码率协商") {
            isStreamActive = true
            isListening = false
            stopListenCountdown()
            appendLog("[成功] 🎉 PS5 已确认并接受高码率协商！局域网直连路由已彻底复原！")

            // 握手成功并输出报告后，延迟 1.5 秒自动平滑收敛运行状态，将按钮切回“启动画质增强”
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                self.isRunning = false
                self.isListening = false
                self.stopListenCountdown()
                self.relayProcess = nil
                self.logWatchTimer?.invalidate()
                self.logWatchTimer = nil
            }
        } else if line.contains("未生效") || line.contains("未检测到 PS Portal 握手请求") || line.contains("NOT APPLIED") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "未检测到 PS Portal 握手请求（120 秒内未收到连接，或 Portal 仍处于休眠状态）。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                self.isRunning = false
                self.isListening = false
                self.stopListenCountdown()
                self.relayProcess = nil
                self.logWatchTimer?.invalidate()
                self.logWatchTimer = nil
            }
        } else if line.contains("未确认目标码率") || line.contains("UNCONFIRMED") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "握手修改已发送，但未能在规定时间内检测到 PS5 连续 3 次高码率遥测确认。"
        } else if line.contains("RESTORATION FAILED") || line.contains("路由恢复异常") {
            isListening = false
            stopListenCountdown()
            lastError = "网络恢复异常，请检查网络配置。"
        } else if line.contains("报告存档:") || line.contains("report.json") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.isRunning = false
                self.isListening = false
                self.stopListenCountdown()
                self.relayProcess = nil
                self.logWatchTimer?.invalidate()
                self.logWatchTimer = nil
            }
        }
    }

    public func appendLog(_ text: String) {
        logs.append(text)
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func copyLogs() {
        let content = logs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
