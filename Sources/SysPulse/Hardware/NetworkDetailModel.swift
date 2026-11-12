import Foundation
import CoreWLAN
import CFNetwork
import SystemConfiguration
import Darwin
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
    public private(set) var gatewayIP: String = "获取中…"
    public private(set) var primaryDNS: String = "获取中…"
    public private(set) var dnsServers: [String] = []
    public private(set) var physicalDNSServers: [String] = []
    public private(set) var localIPv4: String = "获取中…"
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
                let icon = Self.cachedAppIcon(bundleID: entry.bundleIdentifier, pid: running?.processIdentifier ?? 0, runningApp: running)
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
                let icon = Self.cachedAppIcon(bundleID: entry.bundleIdentifier, pid: running?.processIdentifier ?? 0, runningApp: running)
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

    // MARK: - Routing & DNS Detection (Native SCDynamicStore, Zero Subprocesses)

    public struct PhysicalNetworkContext: Sendable {
        public let serviceID: String?
        public let interfaceName: String
        public let gateway: String
        public let localIPv4: String
        public let interfaceType: String?
        public let hasVPN: Bool
        public let serviceDNSServers: [String]
    }

    private nonisolated static let virtualInterfacePrefixes: [String] = [
        "utun", "tun", "tap", "ppp", "ipsec", "wg",
        "feth", "lo", "awdl", "llw", "anpi", "gif", "stf", "ap", "vnic", "vmnet"
    ]

    nonisolated public static func isVirtualInterfaceName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }
        return virtualInterfacePrefixes.contains { lower.hasPrefix($0) }
    }

    nonisolated public static func isCountablePhysicalInterfaceName(_ name: String) -> Bool {
        guard !isVirtualInterfaceName(name) else { return false }
        return name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    nonisolated private static func isValidLANIPv4(_ ip: String) -> Bool {
        !ip.isEmpty && ip != "127.0.0.1" && !ip.hasPrefix("169.254.")
    }

    nonisolated public static func resolvePhysicalInterface() -> PhysicalNetworkContext {
        // 1. Collect active UP+RUNNING IPv4 addresses and detect VPN tunnels in a single getifaddrs pass
        var activeIPv4ByIface: [String: String] = [:]
        var hasVPN = false

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(first) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let current = ptr {
                let ifa = current.pointee
                let flags = Int32(ifa.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
                let isRunning = (flags & IFF_RUNNING) != 0

                if isUp, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.ifa_name)
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let parsed = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)

                    if isValidLANIPv4(parsed) {
                        if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") || name.hasPrefix("wg") || name.hasPrefix("tun") || name.hasPrefix("tap") {
                            hasVPN = true
                        }
                        if isRunning && !isVirtualInterfaceName(name) && activeIPv4ByIface[name] == nil {
                            activeIPv4ByIface[name] = parsed
                        }
                    }
                }
                ptr = ifa.ifa_next
            }
        }

        // 2. Map BSD interface names to hardware types (Ethernet / Wi-Fi / Bridge)
        var scTypeByBSD: [String: String] = [:]
        if let scInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in scInterfaces {
                if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                   let type = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                    scTypeByBSD[bsd] = type
                }
            }
        }

        guard let store = SCDynamicStoreCreate(nil, "SysPulse.GatewayDetect" as CFString, nil, nil) else {
            let fallbackIface = activeIPv4ByIface.keys.sorted().first ?? "en0"
            return PhysicalNetworkContext(
                serviceID: nil,
                interfaceName: fallbackIface,
                gateway: "",
                localIPv4: activeIPv4ByIface[fallbackIface] ?? "127.0.0.1",
                interfaceType: scTypeByBSD[fallbackIface],
                hasVPN: hasVPN,
                serviceDNSServers: []
            )
        }

        func readServiceDNS(_ serviceID: String?) -> [String] {
            guard let serviceID, !serviceID.isEmpty else {
                return []
            }
            let keys = [
                "State:/Network/Service/\(serviceID)/DNS",
                "Setup:/Network/Service/\(serviceID)/DNS"
            ]
            for key in keys {
                if let dnsDict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                   let addrs = dnsDict["ServerAddresses"] as? [String] {
                    let cleaned = addrs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    let ipv4 = cleaned.filter { $0.contains(".") }
                    if !ipv4.isEmpty {
                        return ipv4
                    }
                    if !cleaned.isEmpty {
                        return cleaned
                    }
                }
            }
            return []
        }

        // 3. Fast path: if macOS Global/IPv4 points to a real physical interface, trust it directly
        if let globalDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            let globalIface = (globalDict["PrimaryInterface"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let globalService = (globalDict["PrimaryService"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let globalGW = (globalDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !globalIface.isEmpty,
               !isVirtualInterfaceName(globalIface),
               let activeIP = activeIPv4ByIface[globalIface] {
                var resolvedGW = globalGW
                if resolvedGW.isEmpty, let globalService,
                   let svcDict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(globalService)/IPv4" as CFString) as? [String: Any] {
                    resolvedGW = (svcDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                return PhysicalNetworkContext(
                    serviceID: globalService,
                    interfaceName: globalIface,
                    gateway: resolvedGW,
                    localIPv4: activeIP,
                    interfaceType: scTypeByBSD[globalIface],
                    hasVPN: hasVPN,
                    serviceDNSServers: readServiceDNS(globalService)
                )
            }
        }

        // 4. VPN / TUN override path (e.g. utun2 is PrimaryInterface):
        //    Follow Setup ServiceOrder to find the underlying active physical service + its real Router & IP.
        var orderedServiceIDs: [String] = []
        if let setupDict = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let order = setupDict["ServiceOrder"] as? [String] {
            orderedServiceIDs.append(contentsOf: order)
        }
        if let stateKeys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] {
            for key in stateKeys {
                // Format: State:/Network/Service/<serviceID>/IPv4
                let parts = key.split(separator: "/")
                if parts.count == 5 {
                    let sid = String(parts[3])
                    if !orderedServiceIDs.contains(sid) {
                        orderedServiceIDs.append(sid)
                    }
                }
            }
        }

        var backupWithoutRouter: PhysicalNetworkContext?

        for sid in orderedServiceIDs {
            guard let svcDict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(sid)/IPv4" as CFString) as? [String: Any] else {
                continue
            }
            let rawIface = (svcDict["ConfirmedInterfaceName"] as? String)
                ?? (svcDict["InterfaceName"] as? String)
                ?? ""
            let iface = rawIface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !iface.isEmpty, !isVirtualInterfaceName(iface) else { continue }

            // Ensure the physical interface is actually UP & has a valid LAN IPv4
            guard let activeIP = activeIPv4ByIface[iface] else {
                continue
            }

            let router = (svcDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ctx = PhysicalNetworkContext(
                serviceID: sid,
                interfaceName: iface,
                gateway: router,
                localIPv4: activeIP,
                interfaceType: scTypeByBSD[iface],
                hasVPN: hasVPN,
                serviceDNSServers: readServiceDNS(sid)
            )
            if !router.isEmpty {
                return ctx
            }
            if backupWithoutRouter == nil {
                backupWithoutRouter = ctx
            }
        }

        if let backupWithoutRouter {
            return backupWithoutRouter
        }

        // 5. Final fallback: inspect live physical interfaces sorted Ethernet -> Wi-Fi -> other en* -> bridge*
        let sortedIfaces = activeIPv4ByIface.keys.sorted { lhs, rhs in
            func rank(_ ifName: String) -> Int {
                let scType = scTypeByBSD[ifName]
                if scType == (kSCNetworkInterfaceTypeEthernet as String) { return 0 }
                if scType == (kSCNetworkInterfaceTypeIEEE80211 as String) { return 1 }
                if ifName.hasPrefix("en") { return 2 }
                return 3
            }
            let r1 = rank(lhs), r2 = rank(rhs)
            return r1 != r2 ? r1 < r2 : lhs < rhs
        }

        let bestIface = sortedIfaces.first ?? "en0"
        var bestGW = ""
        if let ifaceDict = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bestIface)/IPv4" as CFString) as? [String: Any] {
            bestGW = (ifaceDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return PhysicalNetworkContext(
            serviceID: nil,
            interfaceName: bestIface,
            gateway: bestGW,
            localIPv4: activeIPv4ByIface[bestIface] ?? "127.0.0.1",
            interfaceType: scTypeByBSD[bestIface],
            hasVPN: hasVPN,
            serviceDNSServers: []
        )
    }

    nonisolated public static func detectGatewayAndInterface() -> (gateway: String, iface: String) {
        let ctx = resolvePhysicalInterface()
        return (gateway: ctx.gateway, iface: ctx.interfaceName)
    }

    nonisolated public static func detectDNSServers() -> [String] {
        if let store = SCDynamicStoreCreate(nil, "SysPulse.DNSDetect" as CFString, nil, nil),
           let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let addrs = dict["ServerAddresses"] as? [String] {
            let cleaned = addrs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let ipv4Servers = cleaned.filter { $0.contains(".") }
            if !ipv4Servers.isEmpty {
                return ipv4Servers
            }
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        let physicalDNS = resolvePhysicalInterface().serviceDNSServers
        if !physicalDNS.isEmpty {
            return physicalDNS
        }
        return ["223.5.5.5", "114.114.114.114"]
    }

    // MARK: - Local IP & Link

    private func refreshLocalNetwork() {
        let proxyText = self.proxy
        Task.detached(priority: .utility) { [weak self] in
            let ctx = Self.resolvePhysicalInterface()
            let iface = ctx.interfaceName
            let gw = ctx.gateway
            let primaryIP = ctx.localIPv4
            let hasVPN = ctx.hasVPN
            let dnsList = Self.detectDNSServers()
            // 默认显示物理网卡自身的真实主 DNS；仅当物理服务未提供 DNS 时回退全局 DNS
            let primaryDNSVal = ctx.serviceDNSServers.first ?? dnsList.first ?? ""

            let wifiClient = CWWiFiClient.shared().interface()
            let wifiIfaceName = wifiClient?.interfaceName

            let linkText: String
            if let wifiIfaceName, iface == wifiIfaceName || ctx.interfaceType == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                linkText = "Wi-Fi"
            } else if ctx.interfaceType == (kSCNetworkInterfaceTypeEthernet as String) || iface.hasPrefix("en") {
                linkText = "以太网"
            } else if iface.hasPrefix("bridge") {
                linkText = "雷雳网桥"
            } else {
                linkText = "以太网"
            }

            let ssidText: String
            if linkText == "Wi-Fi" {
                if let name = wifiClient?.ssid(), !name.isEmpty {
                    ssidText = name
                } else {
                    ssidText = "Wi-Fi 网络"
                }
            } else if linkText == "以太网" {
                ssidText = "以太网"
            } else {
                ssidText = linkText
            }

            let vpnText: String
            if hasVPN {
                vpnText = "VPN 已开启"
            } else if proxyText != "直连" {
                vpnText = "系统代理开启"
            } else {
                vpnText = "直连无代理"
            }

            await MainActor.run {
                guard let self else { return }
                self.gatewayIP = gw.isEmpty ? "暂无" : gw
                self.activeInterfaceName = iface
                self.dnsServers = dnsList
                self.physicalDNSServers = ctx.serviceDNSServers
                self.primaryDNS = primaryDNSVal.isEmpty ? "暂无" : primaryDNSVal
                self.localIPv4 = primaryIP
                self.link = linkText
                self.ssid = ssidText
                self.isVPNActive = hasVPN
                self.vpnStatusText = vpnText
            }
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

    private final class UsageAndIconCache: @unchecked Sendable {
        static let shared = UsageAndIconCache()
        private let lock = NSLock()
        private var prevAppBytes: [Int32: (inBytes: UInt64, outBytes: UInt64, time: Date)] = [:]
        private let iconCache: NSCache<NSString, NSImage> = {
            let c = NSCache<NSString, NSImage>()
            c.countLimit = 128
            return c
        }()

        func swapPrevAppBytes(with next: [Int32: (inBytes: UInt64, outBytes: UInt64, time: Date)]) -> [Int32: (inBytes: UInt64, outBytes: UInt64, time: Date)] {
            lock.lock()
            let prev = prevAppBytes
            prevAppBytes = next
            lock.unlock()
            return prev
        }

        func cachedIcon(bundleID: String?, pid: Int32, runningApp: NSRunningApplication?) -> NSImage? {
            if let bid = bundleID as NSString?, let hit = iconCache.object(forKey: bid) {
                return hit
            }
            if let icon = runningApp?.icon {
                if let bid = bundleID as NSString? {
                    iconCache.setObject(icon, forKey: bid)
                }
                return icon
            }
            if let bundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let img = NSWorkspace.shared.icon(forFile: url.path)
                iconCache.setObject(img, forKey: bundleID as NSString)
                return img
            }
            return nil
        }
    }

    nonisolated private static func cachedAppIcon(bundleID: String?, pid: Int32, runningApp: NSRunningApplication?) -> NSImage? {
        UsageAndIconCache.shared.cachedIcon(bundleID: bundleID, pid: pid, runningApp: runningApp)
    }

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

            var nextSnapshot: [Int32: (inBytes: UInt64, outBytes: UInt64, time: Date)] = [:]
            for raw in rawItems.prefix(80) {
                nextSnapshot[raw.pid] = (raw.inB, raw.outB, now)
            }
            let prevSnapshot = UsageAndIconCache.shared.swapPrevAppBytes(with: nextSnapshot)

            var items: [AppNetworkItem] = []
            for raw in rawItems {
                let pid = raw.pid
                let runningApp = NSRunningApplication(processIdentifier: pid)
                let displayName = runningApp?.localizedName ?? Self.cleanProcessName(raw.rawName)

                // 严格过滤微小无意义系统噪音（< 10KB）与系统 NTP 守护进程 timed
                guard raw.total >= 10240, raw.rawName != "timed", displayName != "timed" else { continue }

                var downSpeed: Double = 0
                var upSpeed: Double = 0
                if let prev = prevSnapshot[pid] {
                    let dt = max(0.5, now.timeIntervalSince(prev.time))
                    if raw.inB >= prev.inBytes { downSpeed = Double(raw.inB - prev.inBytes) / dt }
                    if raw.outB >= prev.outBytes { upSpeed = Double(raw.outB - prev.outBytes) / dt }
                }

                let bundleID = runningApp?.bundleIdentifier
                let icon = Self.cachedAppIcon(bundleID: bundleID, pid: pid, runningApp: runningApp)

                NetworkTrafficPersistenceManager.shared.recordAppTraffic(
                    name: displayName,
                    bundleID: bundleID,
                    bytes: raw.total
                )

                items.append(AppNetworkItem(
                    pid: pid,
                    name: displayName,
                    bundleIdentifier: bundleID,
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
                let icon = Self.cachedAppIcon(bundleID: entry.bundleIdentifier, pid: running?.processIdentifier ?? 0, runningApp: running)
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
                let icon = Self.cachedAppIcon(bundleID: entry.bundleIdentifier, pid: running?.processIdentifier ?? 0, runningApp: running)
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

    public func refreshActiveSockets(syncSummaryTo vm: NetworkMonitorViewModel? = nil) {
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-iTCP", "-iUDP", "-n", "-P"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            var sockets: [ActiveSocketItem] = []
            var tcpEstablished = 0
            var udpCount = 0
            var activePids = Set<Int32>()

            for line in output.components(separatedBy: .newlines).dropFirst() {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 9 else { continue }
                let cmd = String(parts[0])
                guard let pid = Int32(parts[1]) else { continue }
                let proto = String(parts[7]) // TCP or UDP
                let rest = parts[8...].joined(separator: " ")

                activePids.insert(pid)
                var state = "ACTIVE"
                if rest.contains("ESTABLISHED") {
                    state = "ESTABLISHED"
                    tcpEstablished += 1
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
                    udpCount += 1
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
            let summarySockets = tcpEstablished + udpCount
            let summaryProcs = activePids.count
            let ifCount = vm != nil ? NetworkMonitorViewModel.countActiveInterfaces() : 0

            await MainActor.run {
                if !allSockets.isEmpty {
                    self.activeSockets = allSockets
                }
                if let vm {
                    vm.applySocketSummary(
                        socketCount: summarySockets,
                        processCount: summaryProcs,
                        interfaceCount: ifCount
                    )
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
