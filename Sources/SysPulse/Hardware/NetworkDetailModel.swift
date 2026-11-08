import Foundation
import CoreWLAN
import CFNetwork
import Observation
import AppKit

// MARK: - 网络链路遥测与应用流量模型

public struct AppNetworkItem: Identifiable, Sendable {
    public let id: String
    public let pid: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let icon: NSImage?
    public let downloadSpeedFormatted: String
    public let uploadSpeedFormatted: String
    public let totalTrafficFormatted: String
    public let totalBytes: UInt64

    public init(
        id: String? = nil,
        pid: Int32,
        name: String,
        bundleIdentifier: String? = nil,
        icon: NSImage? = nil,
        downloadSpeedFormatted: String,
        uploadSpeedFormatted: String,
        totalTrafficFormatted: String,
        totalBytes: UInt64 = 0
    ) {
        self.id = id ?? (pid > 0 ? "\(name)_\(pid)" : "\(name)_\(bundleIdentifier ?? "persisted_\(name)")")
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
        self.downloadSpeedFormatted = downloadSpeedFormatted
        self.uploadSpeedFormatted = uploadSpeedFormatted
        self.totalTrafficFormatted = totalTrafficFormatted
        self.totalBytes = totalBytes
    }
}

public struct ActiveSocketItem: Identifiable, Sendable {
    public let id: UUID
    public let pid: Int32
    public let processName: String
    public let proto: String
    public let localAddress: String
    public let remoteAddress: String
    public let state: String

    public init(
        id: UUID = UUID(),
        pid: Int32,
        processName: String,
        proto: String,
        localAddress: String,
        remoteAddress: String,
        state: String
    ) {
        self.id = id
        self.pid = pid
        self.processName = processName
        self.proto = proto
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.state = state
    }
}

@Observable
@MainActor
public final class NetworkDetailModel {
    public static let shared = NetworkDetailModel()

    public private(set) var activeInterfaceName: String = "en0"
    public private(set) var gatewayIP: String = "192.168.50.1"
    public private(set) var primaryDNS: String = "198.18.0.2"
    public private(set) var dnsServers: [String] = ["198.18.0.2", "192.168.50.1"]
    public private(set) var localIPv4: String = "127.0.0.1"
    public private(set) var publicIP: String = "获取中…"
    public private(set) var location: String = "获取中…"
    public private(set) var carrier: String = "获取中…"
    public private(set) var proxy: String = "直连"
    public private(set) var link: String = "以太网"
    public private(set) var ssid: String = "以太网"
    public private(set) var wifiProtocol: String = "Wi-Fi 7"
    public private(set) var vpnStatusText: String = "直连无代理"
    public private(set) var isVPNActive: Bool = false
    public private(set) var channel: Int = 44
    public private(set) var txRate: Double = 1200.0
    public private(set) var frequencyBand: String = "5 GHz"
    public private(set) var signal: String = "强"
    public private(set) var signalDbm: Int = -45
    public private(set) var isSignalAvailable: Bool = true
    public private(set) var isLoadingGeoIP: Bool = false
    public private(set) var appNetworkItems: [AppNetworkItem] = []
    public private(set) var monthAppNetworkItems: [AppNetworkItem] = []
    public private(set) var activeSockets: [ActiveSocketItem] = []
    public private(set) var lastRefreshedAt: Date = Date()
    public var copiedRowKey: String? = nil

    private var geoIPFetched: Bool = false

    private init() {
        loadPersistedApps()
        refresh()
    }

    private func loadPersistedApps() {
        let saved = NetworkTrafficPersistenceManager.shared.getPersistedAppTraffic()
            .filter { $0.totalBytes >= 10240 && $0.name != "timed" }
        if !saved.isEmpty {
            self.appNetworkItems = saved.map { entry in
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleIdentifier ?? "").first
                let icon = running?.icon ?? (entry.bundleIdentifier != nil ? NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier!)?.path ?? "") : nil)
                return AppNetworkItem(
                    pid: running?.processIdentifier ?? 0,
                    name: entry.name,
                    bundleIdentifier: entry.bundleIdentifier,
                    icon: icon,
                    downloadSpeedFormatted: "< 1 KB/s",
                    uploadSpeedFormatted: "< 1 KB/s",
                    totalTrafficFormatted: Self.formatBytes(entry.totalBytes),
                    totalBytes: entry.totalBytes
                )
            }
        }

        let savedMonth = NetworkTrafficPersistenceManager.shared.getPersistedMonthAppTraffic()
            .filter { $0.totalBytes >= 10240 && $0.name != "timed" }
        if !savedMonth.isEmpty {
            self.monthAppNetworkItems = savedMonth.map { entry in
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleIdentifier ?? "").first
                let icon = running?.icon ?? (entry.bundleIdentifier != nil ? NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier!)?.path ?? "") : nil)
                return AppNetworkItem(
                    pid: running?.processIdentifier ?? 0,
                    name: entry.name,
                    bundleIdentifier: entry.bundleIdentifier,
                    icon: icon,
                    downloadSpeedFormatted: "< 1 KB/s",
                    uploadSpeedFormatted: "< 1 KB/s",
                    totalTrafficFormatted: Self.formatBytes(entry.totalBytes),
                    totalBytes: entry.totalBytes
                )
            }
        }
    }

    public func copyRow(key: String, value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        self.copiedRowKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedRowKey == key {
                self?.copiedRowKey = nil
            }
        }
    }

    public func refresh() {
        refreshLocalNetwork()
        refreshProxy()
        refreshWiFi()
        refreshAppNetworkUsage()
        refreshActiveSockets()

        if !geoIPFetched || Date().timeIntervalSince(lastRefreshedAt) > 60 {
            fetchPublicIPAndGeo()
        }
        self.lastRefreshedAt = Date()
    }

    // MARK: - Routing & DNS Detection

    nonisolated public static func detectGatewayAndInterface() -> (gateway: String, iface: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-rn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                var candidatePhysical: (gateway: String, iface: String)? = nil
                for line in output.components(separatedBy: .newlines) {
                    if line.hasPrefix("default") {
                        let parts = line.split(whereSeparator: { $0.isWhitespace })
                        if parts.count >= 4 {
                            let gw = String(parts[1])
                            let iface = String(parts.last ?? "")
                            // 优先识别物理以太网/Wi-Fi接口 (en0, en1 等)
                            if gw.contains(".") && iface.hasPrefix("en") {
                                return (gateway: gw, iface: iface)
                            }
                            if candidatePhysical == nil && gw.contains(".") && !iface.hasPrefix("utun") && !iface.hasPrefix("ppp") {
                                candidatePhysical = (gateway: gw, iface: iface)
                            }
                        }
                    }
                }
                if let cand = candidatePhysical {
                    return cand
                }
            }
        }
        return (gateway: "192.168.50.1", iface: "en0")
    }

    nonisolated public static func detectDNSServers() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        task.arguments = ["--dns"]
        let pipe = Pipe()
        task.standardOutput = pipe
        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                var servers: [String] = []
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("nameserver[") {
                        let parts = trimmed.components(separatedBy: ":")
                        if parts.count >= 2 {
                            let ip = parts[1].trimmingCharacters(in: .whitespaces)
                            if ip.contains(".") && !servers.contains(ip) {
                                servers.append(ip)
                            }
                        }
                    }
                }
                if !servers.isEmpty {
                    return servers
                }
            }
        }
        return ["198.18.0.2", "192.168.50.1"]
    }

    // MARK: - Local IP & Link

    private func refreshLocalNetwork() {
        let (gw, iface) = Self.detectGatewayAndInterface()
        self.gatewayIP = gw
        self.activeInterfaceName = iface

        let dnsList = Self.detectDNSServers()
        self.dnsServers = dnsList
        if let first = dnsList.first {
            self.primaryDNS = first
        }

        let wifiIfaceName = CWWiFiClient.shared().interface()?.interfaceName ?? "en1"

        var primaryIP: String = "127.0.0.1"
        var hasVPN: Bool = false

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let current = ptr {
                let flags = Int32(current.pointee.ifa_flags)
                let name = String(cString: current.pointee.ifa_name)

                if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 {
                    if let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                        let parsed = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if !parsed.hasPrefix("169.254.") && parsed != "127.0.0.1" {
                            if name == iface {
                                primaryIP = parsed
                            }
                            if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") || name.hasPrefix("wg") {
                                hasVPN = true
                            }
                        }
                    }
                }
                ptr = current.pointee.ifa_next
            }
        }
        self.localIPv4 = primaryIP

        // 真实物理链路判定 (严格区分以太网与 Wi-Fi)
        if iface == wifiIfaceName {
            self.link = "Wi-Fi"
        } else if iface.hasPrefix("en") {
            self.link = "以太网"
        } else if iface.hasPrefix("bridge") {
            self.link = "雷雳网桥"
        } else {
            self.link = "局域网"
        }

        // 当前网络显示：以太网优先展示以太网，Wi-Fi时展示SSID
        if self.link == "以太网" {
            self.ssid = "以太网"
        } else {
            let client = CWWiFiClient.shared()
            if let name = client.interface()?.ssid(), !name.isEmpty {
                self.ssid = name
            } else {
                self.ssid = "Wi-Fi 网络"
            }
        }

        // VPN / 代理状态判定
        self.isVPNActive = hasVPN
        if hasVPN {
            self.vpnStatusText = "VPN 已开启"
        } else if self.proxy != "直连" {
            self.vpnStatusText = "系统代理开启"
        } else {
            self.vpnStatusText = "直连无代理"
        }
    }

    // MARK: - System Proxy Detection

    private func refreshProxy() {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            self.proxy = "直连"
            return
        }

        let httpEnable = dict[kCFNetworkProxiesHTTPEnable as String] as? Int ?? 0
        let socksEnable = dict[kCFNetworkProxiesSOCKSEnable as String] as? Int ?? 0

        if httpEnable == 1, let proxyHost = dict[kCFNetworkProxiesHTTPProxy as String] as? String, let port = dict[kCFNetworkProxiesHTTPPort as String] as? Int {
            self.proxy = "\(proxyHost):\(port)"
        } else if socksEnable == 1, let proxyHost = dict[kCFNetworkProxiesSOCKSProxy as String] as? String, let port = dict[kCFNetworkProxiesSOCKSPort as String] as? Int {
            self.proxy = "SOCKS \(proxyHost):\(port)"
        } else {
            self.proxy = "直连"
        }
    }

    // MARK: - Wi-Fi Signal Strength & Interface Telemetry

    private func refreshWiFi() {
        let client = CWWiFiClient.shared()
        let iface = client.interface()
        if let iface = iface {
            // 读取 Wi-Fi 协议标准 (仅显示 Wi-Fi 版本，不显示 802.11be/ax 等技术代号)
            let mode = iface.activePHYMode().rawValue
            switch mode {
            case 1: self.wifiProtocol = "Wi-Fi 1"
            case 2: self.wifiProtocol = "Wi-Fi 2"
            case 3: self.wifiProtocol = "Wi-Fi 3"
            case 4: self.wifiProtocol = "Wi-Fi 4"
            case 5: self.wifiProtocol = "Wi-Fi 5"
            case 6:
                if let ch = iface.wlanChannel(), #available(macOS 12.0, *), ch.channelBand == .band6GHz {
                    self.wifiProtocol = "Wi-Fi 6E"
                } else {
                    self.wifiProtocol = "Wi-Fi 6"
                }
            case 7: self.wifiProtocol = "Wi-Fi 7"
            default: self.wifiProtocol = "Wi-Fi"
            }

            if self.link == "Wi-Fi" {
                if let name = iface.ssid(), !name.isEmpty {
                    self.ssid = name
                }
            }

            if let ch = iface.wlanChannel() {
                self.channel = Int(ch.channelNumber)
                if ch.channelBand == .band5GHz {
                    self.frequencyBand = "5 GHz"
                } else if ch.channelBand == .band2GHz {
                    self.frequencyBand = "2.4 GHz"
                } else if #available(macOS 12.0, *), ch.channelBand == .band6GHz {
                    self.frequencyBand = "6 GHz"
                }
            }
            let rate = iface.transmitRate()
            if rate > 0 {
                self.txRate = rate
            }
            let rssi = iface.rssiValue()
            if rssi == 0 {
                self.isSignalAvailable = false
                self.signal = "暂无"
            } else {
                self.isSignalAvailable = true
                self.signalDbm = rssi
                if rssi >= -55 {
                    self.signal = "极强"
                } else if rssi >= -65 {
                    self.signal = "强"
                } else if rssi >= -78 {
                    self.signal = "中"
                } else {
                    self.signal = "弱"
                }
            }
        } else {
            self.wifiProtocol = "暂无"
            self.isSignalAvailable = false
            self.signal = "暂无"
        }
    }

    // MARK: - Public IP Detection (仅获取互联网公网 IP，不查询国家与运营商)

    private func fetchPublicIPAndGeo() {
        guard !isLoadingGeoIP else { return }
        isLoadingGeoIP = true

        Task.detached(priority: .utility) { [weak self] in
            // 优先尝试国内直连反射节点（直接获取真实物理宽带出口 IP），备用国际节点
            let endpoints = [
                "https://myip.ipip.net",
                "http://ip.3322.net",
                "https://whois.pconline.com.cn/ipJson.jsp",
                "http://myip.ipip.net",
                "http://cip.cc",
                "https://api.ipify.org",
                "https://icanhazip.com"
            ]

            var detectedIP: String? = nil

            for urlString in endpoints {
                guard let url = URL(string: urlString) else { continue }
                var request = URLRequest(url: url, timeoutInterval: 2.5)
                request.setValue("curl/7.64.1", forHTTPHeaderField: "User-Agent")

                if let (data, resp) = try? await URLSession.shared.data(for: request),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    let text = String(decoding: data, as: UTF8.self)
                    if let ip = Self.extractIPv4(from: text) {
                        detectedIP = ip
                        break
                    }
                }
            }

            await MainActor.run {
                if let ip = detectedIP {
                    self?.publicIP = ip
                } else if self?.publicIP == "获取中…" {
                    self?.publicIP = "暂无"
                }
                self?.location = ""
                self?.carrier = ""
                self?.geoIPFetched = true
                self?.isLoadingGeoIP = false
            }
        }
    }

    nonisolated private static func extractIPv4(from text: String) -> String? {
        let pattern = #"\b(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            let candidate = nsString.substring(with: match.range)
            // Filter out private / reserved / loopback IPs
            if !candidate.hasPrefix("127.") &&
               !candidate.hasPrefix("169.254.") &&
               !candidate.hasPrefix("192.168.") &&
               !candidate.hasPrefix("10.") &&
               !candidate.hasPrefix("172.16.") &&
               !candidate.hasPrefix("172.17.") &&
               !candidate.hasPrefix("172.18.") &&
               !candidate.hasPrefix("172.19.") &&
               !candidate.hasPrefix("172.2") &&
               !candidate.hasPrefix("172.30.") &&
               !candidate.hasPrefix("172.31.") &&
               candidate != "0.0.0.0" {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Real Per-App Network Usage via nettop & Real Sockets via lsof

    private var prevAppBytes: [Int32: (inBytes: UInt64, outBytes: UInt64, time: Date)] = [:]

    public func refreshAppNetworkUsage() {
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            task.arguments = ["-P", "-L", "1", "-n", "-J", "bytes_in,bytes_out"]
            let pipe = Pipe()
            task.standardOutput = pipe
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            let now = Date()
            var rawItems: [(pid: Int32, rawName: String, inB: UInt64, outB: UInt64, total: UInt64)] = []

            for line in output.components(separatedBy: .newlines).dropFirst() {
                let cols = line.split(separator: ",").map { String($0) }
                guard cols.count >= 3 else { continue }
                let spec = cols[0]
                guard let inB = UInt64(cols[1]), let outB = UInt64(cols[2]), (inB > 0 || outB > 0) else { continue }

                if let dotIdx = spec.lastIndex(of: ".") {
                    let pidStr = String(spec[spec.index(after: dotIdx)...])
                    let nameStr = String(spec[..<dotIdx])
                    if let pid = Int32(pidStr) {
                        rawItems.append((pid: pid, rawName: nameStr, inB: inB, outB: outB, total: inB + outB))
                    }
                }
            }

            // Sort by total bytes descending
            rawItems.sort(by: { $0.total > $1.total })

            var items: [AppNetworkItem] = []
            for raw in rawItems {
                let pid = raw.pid
                let runningApp = NSRunningApplication(processIdentifier: pid)
                let displayName = runningApp?.localizedName ?? Self.cleanProcessName(raw.rawName)
                let icon = runningApp?.icon

                // 严格过滤微小无意义系统噪音（< 10KB）与系统 NTP 守护进程 timed
                guard raw.total >= 10240, raw.rawName != "timed", displayName != "timed" else { continue }

                var downSpeed: Double = 0
                var upSpeed: Double = 0
                if let prev = await MainActor.run(body: { self.prevAppBytes[pid] }) {
                    let dt = max(0.5, now.timeIntervalSince(prev.time))
                    if raw.inB >= prev.inBytes { downSpeed = Double(raw.inB - prev.inBytes) / dt }
                    if raw.outB >= prev.outBytes { upSpeed = Double(raw.outB - prev.outBytes) / dt }
                }

                await MainActor.run {
                    self.prevAppBytes[pid] = (raw.inB, raw.outB, now)
                }

                NetworkTrafficPersistenceManager.shared.recordAppTraffic(
                    name: displayName,
                    bundleID: runningApp?.bundleIdentifier,
                    bytes: raw.total
                )

                items.append(AppNetworkItem(
                    pid: pid,
                    name: displayName,
                    bundleIdentifier: runningApp?.bundleIdentifier,
                    icon: icon,
                    downloadSpeedFormatted: Self.formatSpeed(downSpeed),
                    uploadSpeedFormatted: Self.formatSpeed(upSpeed),
                    totalTrafficFormatted: Self.formatBytes(raw.total),
                    totalBytes: raw.total
                ))

                if items.count >= 50 { break }
            }

            // 合并今日已记录但在当前采样瞬间未活跃通信的应用（确保应用流量排行跨启动/全天记忆不丢失）
            let existingNames = Set(items.map { $0.name })
            let saved = NetworkTrafficPersistenceManager.shared.getPersistedAppTraffic()
            for entry in saved where !existingNames.contains(entry.name) {
                guard entry.totalBytes >= 10240, entry.name != "timed" else { continue }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleIdentifier ?? "").first
                let icon = running?.icon ?? (entry.bundleIdentifier != nil ? NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier!)?.path ?? "") : nil)
                items.append(AppNetworkItem(
                    pid: running?.processIdentifier ?? 0,
                    name: entry.name,
                    bundleIdentifier: entry.bundleIdentifier,
                    icon: icon,
                    downloadSpeedFormatted: "< 1 KB/s",
                    uploadSpeedFormatted: "< 1 KB/s",
                    totalTrafficFormatted: Self.formatBytes(entry.totalBytes),
                    totalBytes: entry.totalBytes
                ))
            }
            items.sort(by: { $0.totalBytes > $1.totalBytes })
            if items.count > 50 { items = Array(items.prefix(50)) }

            // 同样构建并排序当月累计流量数据
            let savedMonth = NetworkTrafficPersistenceManager.shared.getPersistedMonthAppTraffic()
            var monthItems: [AppNetworkItem] = []
            for entry in savedMonth {
                guard entry.totalBytes >= 10240, entry.name != "timed" else { continue }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleIdentifier ?? "").first
                let icon = running?.icon ?? (entry.bundleIdentifier != nil ? NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier!)?.path ?? "") : nil)
                monthItems.append(AppNetworkItem(
                    pid: running?.processIdentifier ?? 0,
                    name: entry.name,
                    bundleIdentifier: entry.bundleIdentifier,
                    icon: icon,
                    downloadSpeedFormatted: "< 1 KB/s",
                    uploadSpeedFormatted: "< 1 KB/s",
                    totalTrafficFormatted: Self.formatBytes(entry.totalBytes),
                    totalBytes: entry.totalBytes
                ))
            }
            monthItems.sort(by: { $0.totalBytes > $1.totalBytes })
            if monthItems.count > 50 { monthItems = Array(monthItems.prefix(50)) }

            await MainActor.run {
                self.appNetworkItems = items
                self.monthAppNetworkItems = monthItems
            }
        }
    }

    public func refreshActiveSockets() {
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-iTCP", "-iUDP", "-n", "-P"]
            let pipe = Pipe()
            task.standardOutput = pipe
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            var sockets: [ActiveSocketItem] = []
            for line in output.components(separatedBy: .newlines).dropFirst() {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 9 else { continue }
                let cmd = String(parts[0])
                guard let pid = Int32(parts[1]) else { continue }
                let proto = String(parts[7]) // TCP or UDP
                let rest = parts[8...].joined(separator: " ")

                var state = "ACTIVE"
                if rest.contains("ESTABLISHED") {
                    state = "ESTABLISHED"
                } else if rest.contains("LISTEN") {
                    state = "LISTEN"
                } else if rest.contains("SYN_SENT") {
                    state = "SYN_SENT"
                } else if rest.contains("CLOSE_WAIT") {
                    state = "CLOSE_WAIT"
                } else if rest.contains("TIME_WAIT") {
                    state = "TIME_WAIT"
                } else if proto == "UDP" {
                    state = "ACTIVE"
                }

                let addressPart = String(rest.split(whereSeparator: { $0.isWhitespace }).first ?? "")
                var local = addressPart
                var remote = ""
                if addressPart.contains("->") {
                    let ends = addressPart.components(separatedBy: "->")
                    local = ends[0]
                    remote = ends.count > 1 ? ends[1] : ""
                }

                let runningApp = NSRunningApplication(processIdentifier: pid)
                let displayName = runningApp?.localizedName ?? Self.cleanProcessName(cmd)

                let item = ActiveSocketItem(
                    pid: pid,
                    processName: displayName,
                    proto: proto,
                    localAddress: local,
                    remoteAddress: remote,
                    state: state
                )
                sockets.append(item)
            }

            // Prioritize ESTABLISHED, then ACTIVE/UDP, then LISTEN
            sockets.sort { (a, b) -> Bool in
                let priority: (String) -> Int = {
                    switch $0 {
                    case "ESTABLISHED": return 0
                    case "ACTIVE": return 1
                    case "LISTEN": return 2
                    default: return 3
                    }
                }
                return priority(a.state) < priority(b.state)
            }

            let allSockets = sockets
            await MainActor.run {
                if !allSockets.isEmpty {
                    self.activeSockets = allSockets
                }
            }
        }
    }

    nonisolated private static func cleanProcessName(_ raw: String) -> String {
        switch raw {
        case "kernel_task": return "macOS 内核"
        case "mDNSResponder": return "Bonjour 域名服务"
        case "rapportd": return "设备互联互通 (Rapport)"
        case "apsd": return "Apple 推送服务 (APNs)"
        case "netbiosd": return "NetBIOS 发现"
        case "identityservice", "identityservicesd", "identitys": return "Apple 身份验证"
        case "cloudd": return "iCloud 云存储"
        case "com.apple.WebKi": return "Safari 网页核心"
        case "homed": return "家庭中枢 (HomeKit)"
        case "sharingd": return "隔空投送与共享"
        default: return raw
        }
    }

    nonisolated private static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.0f KB", max(1.0, kb))
    }

    nonisolated private static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024.0 * 1024.0 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024.0 * 1024.0))
        } else if bytesPerSec >= 1024.0 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else {
            return "< 1 KB/s"
        }
    }
}
