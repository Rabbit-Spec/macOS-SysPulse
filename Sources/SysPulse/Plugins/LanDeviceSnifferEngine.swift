import Foundation
import SwiftUI
import Observation
import Darwin
import AppKit
import SystemConfiguration
import UniformTypeIdentifiers

/// PlayStation 设备发现协议 (DDP UDP 9302) 返回信息
public struct PlayStationDDPInfo: Sendable {
    public let ip: String
    public let hostType: String
    public let hostName: String
    public let systemVersion: String
    public let isStandby: Bool
}

/// 活跃物理网卡信息
public struct ActiveInterfaceInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let ip: String
    public let label: String

    public var displayName: String {
        ip.isEmpty ? "\(label) (\(name))" : "\(label) (\(name)) · \(ip)"
    }

    public var compactDisplayName: String {
        ip.isEmpty ? name : "\(name) · \(ip)"
    }

    /// 统一探测当前真实活跃且已分配有效 IPv4 的物理网卡，并将系统默认网关出口置顶
    nonisolated public static func discoverActive() -> (interfaces: [ActiveInterfaceInfo], defaultInterface: String) {
        var bsdTypeMap: [String: String] = [:]
        if let scInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in scInterfaces {
                if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                   let type = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                    bsdTypeMap[bsd] = type
                }
            }
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ([], "") }
        defer { freeifaddrs(ifaddr) }

        var list: [ActiveInterfaceInfo] = []
        var seenNames = Set<String>()
        let (_, defaultIface) = NetworkDetailModel.detectGatewayAndInterface()

        var ptr = ifaddr
        while let current = ptr {
            let ifa = current.pointee
            let flags = Int32(ifa.ifa_flags)
            let isUpAndRunning = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0

            if isUpAndRunning, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if NetworkDetailModel.isCountablePhysicalInterfaceName(name) && !seenNames.contains(name) {
                    let sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
                    var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sinAddr = sin.sin_addr
                    inet_ntop(AF_INET, &sinAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(decoding: ipStr.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

                    if !ip.isEmpty && ip != "127.0.0.1" && !ip.hasPrefix("169.254.") {
                        seenNames.insert(name)
                        let scType = bsdTypeMap[name]
                        let friendlyLabel: String
                        if scType == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                            friendlyLabel = "无线局域网"
                        } else if scType == (kSCNetworkInterfaceTypeEthernet as String) {
                            friendlyLabel = "以太网"
                        } else if name.hasPrefix("bridge") {
                            friendlyLabel = "雷雳网桥"
                        } else {
                            friendlyLabel = "以太网"
                        }
                        list.append(ActiveInterfaceInfo(name: name, ip: ip, label: friendlyLabel))
                    }
                }
            }
            ptr = ifa.ifa_next
        }

        list.sort { a1, a2 in
            if a1.name == defaultIface { return true }
            if a2.name == defaultIface { return false }
            return a1.name < a2.name
        }

        return (list, defaultIface)
    }

    /// 获取指定物理网卡的真实子网掩码与子网广播 IPv4（避免多网段下写死 .255）
    nonisolated public static func ipv4SubnetInfo(for interfaceName: String) -> (ip: UInt32, mask: UInt32, broadcast: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let ifa = current.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               let maskAddr = ifa.ifa_netmask, maskAddr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == interfaceName {
                let ipHost = UInt32(bigEndian: UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
                let maskHost = UInt32(bigEndian: UnsafeRawPointer(maskAddr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
                let bcastHost = (ipHost & maskHost) | ~maskHost
                var bcastNet = in_addr(s_addr: bcastHost.bigEndian)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &bcastNet, &buf, socklen_t(INET_ADDRSTRLEN))
                let bcastStr = String(decoding: buf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
                return (ip: ipHost, mask: maskHost, broadcast: bcastStr)
            }
            ptr = ifa.ifa_next
        }
        return nil
    }
}

/// 局域网设备数据项模型
public struct LanDeviceItem: Identifiable, Sendable {
    public let id: String
    public let ip: String
    public let mac: String
    public let defaultName: String
    public let vendor: String
    public let interface: String
    public let isGateway: Bool
    public let isLocalHost: Bool
    public let defaultIcon: String
    public let lastSeen: Date

    public init(
        id: String,
        ip: String,
        mac: String,
        defaultName: String,
        vendor: String,
        interface: String = "en0",
        isGateway: Bool,
        isLocalHost: Bool,
        defaultIcon: String,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.ip = ip
        self.mac = mac
        self.defaultName = defaultName
        self.vendor = vendor
        self.interface = interface
        self.isGateway = isGateway
        self.isLocalHost = isLocalHost
        self.defaultIcon = defaultIcon
        self.lastSeen = lastSeen
    }

    /// 动态获取设备呈现名称 (优先采用用户持久化绑定的自定义名称)
    @MainActor
    public var name: String {
        LanDeviceMetadataManager.shared.getProfile(for: mac)?.customName ?? defaultName
    }

    /// 动态获取自定义档案
    @MainActor
    public var customProfile: CustomDeviceProfile? {
        LanDeviceMetadataManager.shared.getProfile(for: mac)
    }

    /// 是否被用户自定义过
    @MainActor
    public var isCustomized: Bool {
        customProfile != nil
    }
}

/// 后台扫描取消令牌，避免旧任务覆盖新结果
private final class ScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let val = cancelled
        lock.unlock()
        return val
    }
}

/// 独立的局域网 ARP 嗅探与设备诊断引擎 (完全独立解耦，不依赖任何第三方或 Portal 逻辑)
@Observable
@MainActor
public final class LanDeviceSnifferEngine {
    public static let shared = LanDeviceSnifferEngine()

    public var discoveredDevices: [LanDeviceItem] = []
    public var isScanning: Bool = false
    public var lastScannedAt: Date? = nil
    public var selectedInterface: String = "en0"
    public var activeInterfaces: [ActiveInterfaceInfo] = []
    public var selectedInterfaceInfo: ActiveInterfaceInfo? {
        activeInterfaces.first(where: { $0.name == selectedInterface })
    }
    private var hasExplicitInterfaceSelection: Bool = false
    private var activeScanToken: ScanToken? = nil
    public var searchQuery: String = ""
    public var copiedNotice: String? = nil

    // 设备编辑状态 (纯响应式数据流，彻底摒弃 @State)
    public var editingMAC: String? = nil
    public var editingNameInput: String = ""
    public var showPresetIconPicker: Bool = false

    /// 常用精品预设 SF Symbol 图标库
    public static let presetIcons: [String] = [
        "gamecontroller.fill", "gamecontroller", "tv.fill", "iphone", "ipad",
        "laptopcomputer", "desktopcomputer", "wifi.router", "network",
        "speaker.wave.3.fill", "printer.fill", "camera.fill", "lightbulb.fill",
        "powerplug.fill", "cpu", "server.rack", "apple.logo"
    ]

    /// 根据搜索过滤后的设备列表
    public var filteredDevices: [LanDeviceItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return discoveredDevices }
        return discoveredDevices.filter {
            $0.name.lowercased().contains(q) ||
            $0.defaultName.lowercased().contains(q) ||
            $0.ip.contains(q) ||
            $0.mac.lowercased().contains(q) ||
            $0.vendor.lowercased().contains(q)
        }
    }

    /// 展示顶部绿色状态通知气泡
    public func showNotice(_ notice: String, duration: TimeInterval = 2.2) {
        self.copiedNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.copiedNotice == notice {
                self?.copiedNotice = nil
            }
        }
    }

    /// 复制信息至系统剪贴板并触发简短通知
    public func copyToClipboard(_ text: String, notice: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showNotice(notice, duration: 1.8)
    }

    private init() {
        if FeatureToggleManager.shared.enablePluginARPSniffer {
            detectActiveInterfaces()
        }
    }

    public func activate() {
        detectActiveInterfaces()
        if discoveredDevices.isEmpty && !isScanning {
            startScan()
        }
    }

    public func deactivate() {
        activeScanToken?.cancel()
        activeScanToken = nil
        isScanning = false
        editingMAC = nil
        editingNameInput = ""
        showPresetIconPicker = false
        discoveredDevices = []
        lastScannedAt = nil
    }

    /// 手动切换嗅探网卡并触发重新扫描
    public func selectInterface(_ name: String) {
        selectedInterface = name
        hasExplicitInterfaceSelection = true
        startScan()
    }

    /// 智能识别系统当前真实活跃的物理网卡（排除离线、未配置或虚拟接口）
    public func detectActiveInterfaces() {
        let (list, defaultIface) = ActiveInterfaceInfo.discoverActive()
        self.activeInterfaces = list.isEmpty
            ? [ActiveInterfaceInfo(name: defaultIface.isEmpty ? "en0" : defaultIface, ip: "", label: "未检测到活跃 IP")]
            : list

        let isSelectedActive = list.contains(where: { $0.name == selectedInterface })
        if !hasExplicitInterfaceSelection || !isSelectedActive {
            if !defaultIface.isEmpty && list.contains(where: { $0.name == defaultIface }) {
                selectedInterface = defaultIface
            } else if let firstActive = list.first {
                selectedInterface = firstActive.name
            } else {
                selectedInterface = defaultIface.isEmpty ? "en0" : defaultIface
            }
        }
    }

    /// 执行局域网全面嗅探与活动设备发现 (绑物理网卡 + 分批多协议唤醒 + 渐进增量刷新)
    public func startScan() {
        guard !isScanning else { return }
        detectActiveInterfaces()
        self.isScanning = true

        activeScanToken?.cancel()
        let token = ScanToken()
        activeScanToken = token

        let targetIface = self.selectedInterface
        let targetLocalIP = self.selectedInterfaceInfo?.ip ?? ""
        let localIPSet = Set(self.activeInterfaces.map(\.ip).filter { !$0.isEmpty })
        let localComputerName = Host.current().localizedName?
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Apple Mac"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (gatewayIP, _) = NetworkDetailModel.detectGatewayAndInterface()
            let (targetHosts, ddpBroadcasts) = Self.resolveScanTargetHosts(
                interfaceName: targetIface,
                fallbackGatewayIP: gatewayIP
            )

            var accumulatedByIP: [String: LanDeviceItem] = [:]

            // 开场 mDNS / SSDP 组播唤醒
            Self.sendMulticastDiscovery(interfaceName: targetIface, localIP: targetLocalIP)

            // 第 1 轮：全网段分批 UDP 轻量探活，320ms 后先出首屏
            Self.probeHostsViaUDP(
                ips: targetHosts,
                ports: [5353, 137],
                interfaceName: targetIface,
                batchSize: 32,
                batchDelayUs: 8_000,
                isCancelled: { token.isCancelled }
            )
            Self.sleepInterruptibly(microseconds: 320_000, isCancelled: { token.isCancelled })
            if token.isCancelled { return }

            let round1 = Self.collectCurrentArpDevices(
                existing: accumulatedByIP,
                targetIface: targetIface,
                gatewayIP: gatewayIP,
                localIPSet: localIPSet,
                localComputerName: localComputerName,
                ddpMap: [:]
            )
            accumulatedByIP = round1.byIP
            let r1Items = round1.sortedItems
            DispatchQueue.main.async {
                self?.applyScanSnapshot(items: r1Items, markFinished: false, token: token)
            }

            // 第 2 轮：只对仍未发现的 IP 补发 ICMP Ping + SSDP/mDNS UDP
            let missingRound2 = targetHosts.filter { accumulatedByIP[$0] == nil }
            if !missingRound2.isEmpty && !token.isCancelled {
                Self.probeHostsViaICMP(
                    ips: missingRound2,
                    interfaceName: targetIface,
                    batchSize: 32,
                    batchDelayUs: 10_000,
                    isCancelled: { token.isCancelled }
                )
                Self.probeHostsViaUDP(
                    ips: missingRound2,
                    ports: [5353, 1900],
                    interfaceName: targetIface,
                    batchSize: 32,
                    batchDelayUs: 8_000,
                    isCancelled: { token.isCancelled }
                )
                Self.sleepInterruptibly(microseconds: 450_000, isCancelled: { token.isCancelled })
                if token.isCancelled { return }

                let round2 = Self.collectCurrentArpDevices(
                    existing: accumulatedByIP,
                    targetIface: targetIface,
                    gatewayIP: gatewayIP,
                    localIPSet: localIPSet,
                    localComputerName: localComputerName,
                    ddpMap: [:]
                )
                accumulatedByIP = round2.byIP
                let r2Items = round2.sortedItems
                DispatchQueue.main.async {
                    self?.applyScanSnapshot(items: r2Items, markFinished: false, token: token)
                }
            }

            // 第 3 轮：对深睡/无线省电长尾设备，用轻量非阻塞 TCP SYN + ICMP 补刀
            let missingRound3 = targetHosts.filter { accumulatedByIP[$0] == nil }
            if !missingRound3.isEmpty && !token.isCancelled {
                Self.probeHostsViaTCP(
                    ips: missingRound3,
                    ports: [80, 443, 62078],
                    interfaceName: targetIface,
                    batchSize: 24,
                    batchDelayUs: 15_000,
                    isCancelled: { token.isCancelled }
                )
                Self.probeHostsViaICMP(
                    ips: missingRound3,
                    interfaceName: targetIface,
                    batchSize: 32,
                    batchDelayUs: 10_000,
                    isCancelled: { token.isCancelled }
                )
                Self.sleepInterruptibly(microseconds: 650_000, isCancelled: { token.isCancelled })
                if token.isCancelled { return }
            }

            // 读取最终 ARP 表并做 PlayStation DDP (UDP 9302) 精准主机名探测
            let preDDP = Self.collectCurrentArpDevices(
                existing: accumulatedByIP,
                targetIface: targetIface,
                gatewayIP: gatewayIP,
                localIPSet: localIPSet,
                localComputerName: localComputerName,
                ddpMap: [:]
            )
            let candidateIPs = preDDP.sortedItems.map(\.ip).filter { ip in
                ip.contains(".") && ip != "127.0.0.1" && ip != gatewayIP && !ip.hasSuffix(".255") && !ip.hasPrefix("224.") && !ip.hasPrefix("239.")
            }
            let ddpMap = Self.probePlayStationDDP(
                targetIPs: candidateIPs,
                broadcastIPs: ddpBroadcasts,
                interfaceName: targetIface,
                timeoutMs: 260
            )
            let finalSnapshot = Self.collectCurrentArpDevices(
                existing: preDDP.byIP,
                targetIface: targetIface,
                gatewayIP: gatewayIP,
                localIPSet: localIPSet,
                localComputerName: localComputerName,
                ddpMap: ddpMap
            )
            let finalItems = finalSnapshot.sortedItems
            DispatchQueue.main.async {
                self?.applyScanSnapshot(items: finalItems, markFinished: true, token: token)
            }
        }
    }

    private func applyScanSnapshot(items: [LanDeviceItem], markFinished: Bool, token: ScanToken) {
        guard !token.isCancelled else { return }
        self.discoveredDevices = items
        if markFinished {
            self.isScanning = false
            self.lastScannedAt = Date()
        }
    }

    /// 汇总当前内核 ARP 表（含 CLI 兜底），并与既有轮次结果合并去重排序
    nonisolated private static func collectCurrentArpDevices(
        existing: [String: LanDeviceItem],
        targetIface: String,
        gatewayIP: String,
        localIPSet: Set<String>,
        localComputerName: String,
        ddpMap: [String: PlayStationDDPInfo]
    ) -> (byIP: [String: LanDeviceItem], sortedItems: [LanDeviceItem]) {
        var rawEntries = readArpTableViaKernelSysctl()
        if rawEntries.isEmpty {
            rawEntries = readArpTableViaCli()
        }

        var mapByIP = existing
        var preferredIfaceMatched: Set<String> = []
        for (ip, item) in existing where item.interface == targetIface {
            preferredIfaceMatched.insert(ip)
        }

        for entry in rawEntries {
            let ip = entry.ip
            let mac = entry.mac.lowercased()
            let ifName = entry.ifName.isEmpty ? targetIface : entry.ifName

            guard !mac.contains("00:00:00:00:00:00") && !mac.contains("ff:ff:ff:ff:ff:ff") && mac.count == 17 else { continue }
            guard !ip.hasPrefix("224.") && !ip.hasPrefix("239.") && ip != "255.255.255.255" else { continue }

            // 优先保留目标物理网卡条目；当已有同网卡条目且没有新 DDP 信息时不重复覆盖
            if mapByIP[ip] != nil {
                if preferredIfaceMatched.contains(ip) && ddpMap[ip] == nil {
                    continue
                }
                if !preferredIfaceMatched.contains(ip) && ifName != targetIface && ddpMap[ip] == nil {
                    continue
                }
            }
            if ifName == targetIface {
                preferredIfaceMatched.insert(ip)
            }

            let isGW = (ip == gatewayIP)
            let isLocal = (localIPSet.contains(ip) || entry.isLocal)
            let (deviceName, vendor, icon) = identifyDevice(
                ip: ip,
                mac: mac,
                isGateway: isGW,
                isLocal: isLocal,
                localName: localComputerName,
                ddp: ddpMap[ip]
            )

            mapByIP[ip] = LanDeviceItem(
                id: "\(ip)-\(mac)",
                ip: ip,
                mac: mac,
                defaultName: deviceName,
                vendor: vendor,
                interface: ifName,
                isGateway: isGW,
                isLocalHost: isLocal,
                defaultIcon: icon
            )
        }

        let sorted = mapByIP.values.sorted { d1, d2 in
            let ip1 = ipToComparable(d1.ip)
            let ip2 = ipToComparable(d2.ip)
            if ip1 != ip2 { return ip1 < ip2 }
            return d1.mac < d2.mac
        }
        return (byIP: mapByIP, sortedItems: sorted)
    }

    /// 根据选中网卡的真实子网掩码推算待探测主机 IP 列表（超大子网自动收敛至所属 /24）
    nonisolated public static func resolveScanTargetHosts(
        interfaceName: String,
        fallbackGatewayIP: String
    ) -> (hosts: [String], broadcastIPs: [String]) {
        if let info = ActiveInterfaceInfo.ipv4SubnetInfo(for: interfaceName) {
            let network = info.ip & info.mask
            let broadcast = network | ~info.mask
            let totalRange = broadcast > network ? (broadcast - network) : 0
            let rangeStart: UInt32
            let rangeEnd: UInt32
            if totalRange > 1 && totalRange <= 1024 {
                rangeStart = network + 1
                rangeEnd = broadcast - 1
            } else {
                let slash24Net = info.ip & 0xFFFFFF00
                rangeStart = slash24Net + 1
                rangeEnd = slash24Net + 254
            }

            var hosts: [String] = []
            hosts.reserveCapacity(Int(rangeEnd - rangeStart + 1))
            var cursor = rangeStart
            while cursor <= rangeEnd {
                if cursor != info.ip {
                    hosts.append(ipv4String(fromHostOrder: cursor))
                }
                if cursor == UInt32.max { break }
                cursor += 1
            }
            return (hosts, Array(Set(["255.255.255.255", info.broadcast])))
        }

        let parts = fallbackGatewayIP.split(separator: ".")
        guard parts.count == 4 else { return ([], ["255.255.255.255"]) }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        let hosts = (1...254).map { "\(prefix).\($0)" }
        return (hosts, ["255.255.255.255", "\(prefix).255"])
    }

    nonisolated private static func ipv4String(fromHostOrder ipHost: UInt32) -> String {
        var netAddr = in_addr(s_addr: ipHost.bigEndian)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &netAddr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    nonisolated private static func bindSocket(
        _ sock: Int32,
        toInterface interfaceName: String?,
        multicastLocalIP: String? = nil
    ) {
        if let interfaceName, !interfaceName.isEmpty {
            var ifIndex = if_nametoindex(interfaceName)
            if ifIndex != 0 {
                setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            }
        }
        if let multicastLocalIP, !multicastLocalIP.isEmpty {
            var localAddr = in_addr()
            if inet_pton(AF_INET, multicastLocalIP, &localAddr) == 1 {
                setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF, &localAddr, socklen_t(MemoryLayout<in_addr>.size))
            }
        }
    }

    nonisolated private static func sleepInterruptibly(microseconds: useconds_t, isCancelled: () -> Bool) {
        let step: useconds_t = 40_000
        var remaining = microseconds
        while remaining > 0 {
            if isCancelled() { return }
            let slice = min(step, remaining)
            usleep(slice)
            remaining -= slice
        }
    }

    /// 发送 mDNS + SSDP 组播探测，优先唤醒 Apple 设备与智能家居网关
    nonisolated private static func sendMulticastDiscovery(interfaceName: String?, localIP: String?) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName, multicastLocalIP: localIP)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        // mDNS PTR: _services._dns-sd._udp.local
        var mdnsQuery: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for label in ["_services", "_dns-sd", "_udp", "local"] {
            let bytes = Array(label.utf8)
            mdnsQuery.append(UInt8(bytes.count))
            mdnsQuery.append(contentsOf: bytes)
        }
        mdnsQuery.append(contentsOf: [0x00, 0x00, 0x0c, 0x00, 0x01])

        var mdnsAddr = sockaddr_in()
        mdnsAddr.sin_family = sa_family_t(AF_INET)
        mdnsAddr.sin_port = in_port_t(5353).bigEndian
        inet_pton(AF_INET, "224.0.0.251", &mdnsAddr.sin_addr)
        withUnsafePointer(to: &mdnsAddr) { saPtr in
            saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                _ = sendto(sock, mdnsQuery, mdnsQuery.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // SSDP M-SEARCH
        let ssdpPayload = Array(
            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n".utf8
        )
        var ssdpAddr = sockaddr_in()
        ssdpAddr.sin_family = sa_family_t(AF_INET)
        ssdpAddr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &ssdpAddr.sin_addr)
        withUnsafePointer(to: &ssdpAddr) { saPtr in
            saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                _ = sendto(sock, ssdpPayload, ssdpPayload.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// 全网段极速轻量探活 (分批向网段 1~254 发送轻量无阻塞 UDP 触发内核自动 ARP 解析)
    nonisolated public static func sweepSubnetFast(basePrefix: String, interfaceName: String? = nil) {
        let targets = (1...254).map { "\(basePrefix).\($0)" }
        probeHostsViaUDP(
            ips: targets,
            ports: [5353],
            interfaceName: interfaceName,
            batchSize: 32,
            batchDelayUs: 6_000
        )
    }

    /// 分批限流发送轻量 UDP 探包，避免内核待解析 ARP 队列及 AP 广播队列溢出丢包
    nonisolated private static func probeHostsViaUDP(
        ips: [String],
        ports: [UInt16],
        interfaceName: String?,
        batchSize: Int = 32,
        batchDelayUs: useconds_t = 8_000,
        isCancelled: (() -> Bool)? = nil
    ) {
        guard !ips.isEmpty, !ports.isEmpty else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let dummy: [UInt8] = [0]
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)

        for startIdx in stride(from: 0, to: ips.count, by: max(1, batchSize)) {
            if isCancelled?() == true { return }
            let endIdx = min(startIdx + max(1, batchSize), ips.count)
            for idx in startIdx..<endIdx {
                guard inet_pton(AF_INET, ips[idx], &addr.sin_addr) == 1 else { continue }
                for port in ports {
                    addr.sin_port = in_port_t(port).bigEndian
                    withUnsafePointer(to: &addr) { saPtr in
                        saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                            _ = sendto(sock, dummy, 1, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            if endIdx < ips.count && batchDelayUs > 0 {
                usleep(batchDelayUs)
            }
        }
    }

    /// 非特权 ICMP Echo 分批探活，针对上一轮未入表主机触发 ARP 解析
    nonisolated private static func probeHostsViaICMP(
        ips: [String],
        interfaceName: String?,
        batchSize: Int = 32,
        batchDelayUs: useconds_t = 10_000,
        isCancelled: (() -> Bool)? = nil
    ) {
        guard !ips.isEmpty else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard sock >= 0 else { return }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        let pid = UInt16(getpid() & 0xFFFF)

        for startIdx in stride(from: 0, to: ips.count, by: max(1, batchSize)) {
            if isCancelled?() == true { return }
            let endIdx = min(startIdx + max(1, batchSize), ips.count)
            for idx in startIdx..<endIdx {
                guard inet_pton(AF_INET, ips[idx], &addr.sin_addr) == 1 else { continue }
                let seq = UInt16((idx + 1) & 0xFFFF)
                let packet = buildICMPEchoRequest(identifier: pid, sequence: seq)
                withUnsafePointer(to: &addr) { saPtr in
                    saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        _ = sendto(sock, packet, packet.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if endIdx < ips.count && batchDelayUs > 0 {
                usleep(batchDelayUs)
            }
        }
    }

    nonisolated private static func buildICMPEchoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            8, 0,       // Type 8 (Echo Request), Code 0
            0, 0,       // Checksum placeholder
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF)
        ]
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count, by: 2) {
            sum += (UInt32(packet[i]) << 8) | UInt32(packet[i + 1])
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        let checksum = ~UInt16(sum & 0xFFFF)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)
        return packet
    }

    /// 轻量非阻塞 TCP SYN 试探，分批唤醒休眠移动端/Web 设备并触发二层 ARP 解析
    nonisolated private static func probeHostsViaTCP(
        ips: [String],
        ports: [UInt16],
        interfaceName: String?,
        batchSize: Int = 24,
        batchDelayUs: useconds_t = 15_000,
        isCancelled: (() -> Bool)? = nil
    ) {
        guard !ips.isEmpty, !ports.isEmpty else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)

        for port in ports {
            if isCancelled?() == true { return }
            addr.sin_port = in_port_t(port).bigEndian

            for startIdx in stride(from: 0, to: ips.count, by: max(1, batchSize)) {
                if isCancelled?() == true { return }
                let endIdx = min(startIdx + max(1, batchSize), ips.count)
                var openFds: [Int32] = []
                openFds.reserveCapacity(endIdx - startIdx)

                for idx in startIdx..<endIdx {
                    guard inet_pton(AF_INET, ips[idx], &addr.sin_addr) == 1 else { continue }
                    let sock = socket(AF_INET, SOCK_STREAM, 0)
                    guard sock >= 0 else { continue }
                    bindSocket(sock, toInterface: interfaceName)
                    _ = fcntl(sock, F_SETFL, O_NONBLOCK)
                    _ = withUnsafePointer(to: &addr) { saPtr in
                        saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                            connect(sock, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    openFds.append(sock)
                }

                if batchDelayUs > 0 {
                    usleep(batchDelayUs)
                }
                for fd in openFds {
                    close(fd)
                }
            }
        }
    }

    /// 直接从 macOS 物理内核通过 BSD 路由 Sysctl 读取 ARP 链路层路由缓存表
    nonisolated public static func readArpTableViaKernelSysctl() -> [(ip: String, mac: String, ifName: String, isLocal: Bool)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len: size_t = 0
        if sysctl(&mib, 6, nil, &len, nil, 0) < 0 || len == 0 {
            return []
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
        defer { buffer.deallocate() }

        if sysctl(&mib, 6, buffer, &len, nil, 0) < 0 {
            return []
        }

        var results: [(ip: String, mac: String, ifName: String, isLocal: Bool)] = []
        var ptr = buffer
        let end = buffer.advanced(by: len)
        let rtmHeaderSize = MemoryLayout<rt_msghdr>.stride
        let sdlDataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8

        while ptr.advanced(by: rtmHeaderSize) <= end {
            let rtm = ptr.withMemoryRebound(to: rt_msghdr.self, capacity: 1) { $0.pointee }
            let rtmLen = Int(rtm.rtm_msglen)
            guard rtmLen >= rtmHeaderSize else { break }
            let msgEnd = ptr.advanced(by: rtmLen)
            guard msgEnd <= end else { break }

            defer { ptr = msgEnd }

            let addrsMask = rtm.rtm_addrs
            guard (addrsMask & RTA_DST) != 0, (addrsMask & RTA_GATEWAY) != 0 else { continue }

            var saPtr = ptr.advanced(by: rtmHeaderSize)
            guard saPtr.advanced(by: MemoryLayout<sockaddr_in>.size) <= msgEnd else { continue }

            let rtaxDst = saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee }
            guard rtaxDst.sa_family == UInt8(AF_INET) else { continue }

            let sin = saPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var ipAddr = sin.sin_addr
            var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &ipAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
            let ip = String(decoding: ipStr.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

            let rawLen = Int(rtaxDst.sa_len)
            let roundedLen = rawLen > 0 ? ((rawLen + 3) & ~3) : MemoryLayout<UInt32>.size
            saPtr = saPtr.advanced(by: roundedLen)

            guard saPtr.advanced(by: sdlDataOffset) <= msgEnd else { continue }
            let sdl = saPtr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
            guard sdl.sdl_family == UInt8(AF_LINK) && sdl.sdl_alen == 6 else { continue }

            let sdlData = saPtr.advanced(by: sdlDataOffset)
            let nlen = Int(sdl.sdl_nlen)
            guard sdlData.advanced(by: nlen + 6) <= msgEnd else { continue }

            let macBytes = sdlData.advanced(by: nlen)
            let mac = (0..<6).map { String(format: "%02x", macBytes[$0]) }.joined(separator: ":")

            var ifNameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if_indextoname(UInt32(sdl.sdl_index), &ifNameBuf)
            let ifName = String(decoding: ifNameBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

            let isLocal = (rtm.rtm_flags & RTF_LOCAL) != 0
            results.append((ip: ip, mac: mac, ifName: ifName, isLocal: isLocal))
        }
        return results
    }

    /// Fallback 读取外部 /usr/sbin/arp 工具输出
    nonisolated public static func readArpTableViaCli() -> [(ip: String, mac: String, ifName: String, isLocal: Bool)] {
        var rawLines: [String] = []
        let arpTask = Process()
        arpTask.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        arpTask.arguments = ["-n", "-a"]
        let p = Pipe()
        arpTask.standardOutput = p
        arpTask.standardError = Pipe()

        if (try? arpTask.run()) != nil {
            let data = p.fileHandleForReading.readDataToEndOfFile()
            arpTask.waitUntilExit()
            if let text = String(data: data, encoding: .utf8) {
                rawLines = text.components(separatedBy: .newlines)
            }
        }

        var results: [(ip: String, mac: String, ifName: String, isLocal: Bool)] = []
        for line in rawLines {
            guard line.contains(" at ") && line.contains("(") && line.contains(")") else { continue }
            let parts = line.components(separatedBy: " at ")
            guard parts.count >= 2 else { continue }

            let left = parts[0]
            let right = parts[1]

            guard let startIdx = left.firstIndex(of: "("),
                  let endIdx = left.firstIndex(of: ")") else { continue }
            let ip = String(left[left.index(after: startIdx)..<endIdx]).trimmingCharacters(in: .whitespaces)

            let macRaw = (right.components(separatedBy: " on ").first ?? right).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !macRaw.contains("incomplete") && !macRaw.contains("ff:ff:ff:ff:ff:ff") && !macRaw.isEmpty else { continue }

            let macParts = macRaw.split(separator: ":").map { part -> String in
                part.count == 1 ? "0\(part)" : String(part)
            }
            guard macParts.count == 6 else { continue }
            let formattedMAC = macParts.joined(separator: ":")

            var ifName = ""
            if let onIdx = right.range(of: " on ") {
                let sub = right[onIdx.upperBound...]
                ifName = sub.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            let isLocal = line.contains("permanent")
            results.append((ip: ip, mac: formattedMAC, ifName: ifName, isLocal: isLocal))
        }
        return results
    }

    nonisolated private static func devicePriority(_ d: LanDeviceItem) -> Int {
        if d.defaultName.contains("PlayStation") || d.defaultName.contains("PS5") || d.defaultName.contains("Portal") { return 1 }
        if d.defaultName.contains("Nintendo") || d.defaultName.contains("Switch") { return 2 }
        if d.defaultName.contains("Apple") || d.defaultName.contains("Mac") { return 3 }
        if d.defaultName.contains("PC") || d.defaultName.contains("Intel") { return 4 }
        return 10
    }

    nonisolated public static func ipToComparable(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    /// 统一 Sony PlayStation / Portal IEEE OUI 判定
    nonisolated public static func isSonyOUI(_ mac: String) -> Bool {
        let oui = String(mac.prefix(8)).lowercased()
        let sonyOUIs: Set<String> = [
            "00:04:1f", "00:13:15", "00:15:c1", "00:19:c5", "00:1d:0d",
            "00:1f:a7", "00:24:8d", "00:d9:d1", "00:e4:21", "28:0d:fc",
            "28:40:dd", "2c:cc:44", "40:16:7e", "70:9e:29", "78:c8:81",
            "84:20:96", "98:fa:2e", "a8:47:4a", "a8:e3:ee", "b4:0a:d8",
            "bc:60:a7", "c8:63:f1", "cc:de:80", "d4:4b:5e", "e8:9e:b4",
            "f8:46:1c", "fc:0f:e6"
        ]
        return sonyOUIs.contains(oui)
    }

    nonisolated public static func isPortalOUI(_ mac: String) -> Bool {
        let oui = String(mac.prefix(8)).lowercased()
        return oui == "98:fa:2e" || oui == "a8:47:4a"
    }

    /// PlayStation Device Discovery Protocol (UDP 9302) 主动探测，精准识别 PS5 主机与主机名
    nonisolated public static func probePlayStationDDP(
        targetIPs: [String],
        broadcastIPs: [String] = ["255.255.255.255"],
        interfaceName: String? = nil,
        timeoutMs: Int = 280
    ) -> [String: PlayStationDDPInfo] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        if let interfaceName, !interfaceName.isEmpty {
            var ifIndex = if_nametoindex(interfaceName)
            if ifIndex != 0 {
                setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            }
        }

        var broadcastEnable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let payload = Array("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n".utf8)
        let allTargets = Array(Set(targetIPs + broadcastIPs))
        for ip in allTargets {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9302).bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, payload, payload.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String: PlayStationDDPInfo] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(50, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(50, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            let ready = poll(&pfd, 1, remMs)
            if ready <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 0 else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = senderAddr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(decoding: ipBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            guard !senderIP.isEmpty else { continue }

            let text = String(decoding: recvBuf.prefix(n), as: UTF8.self)
            let lines = text.components(separatedBy: .newlines)
            let statusLine = lines.first ?? ""
            let isStandby = statusLine.contains("620")

            var hostType = ""
            var hostName = ""
            var sysVer = ""
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "host-type" { hostType = val }
                else if key == "host-name" { hostName = val }
                else if key == "system-version" { sysVer = val }
            }

            if !hostType.isEmpty {
                found[senderIP] = PlayStationDDPInfo(
                    ip: senderIP,
                    hostType: hostType,
                    hostName: hostName,
                    systemVersion: sysVer,
                    isStandby: isStandby
                )
            }
        }
        return found
    }

    /// 权威 IEEE OUI 与局域网设备纯净智能推断 (去除硬件类型解释，保留纯净原生设备标识名)
    nonisolated private static func identifyDevice(
        ip: String,
        mac: String,
        isGateway: Bool,
        isLocal: Bool,
        localName: String = "",
        ddp: PlayStationDDPInfo? = nil
    ) -> (name: String, vendor: String, icon: String) {
        if isGateway {
            let prefix = String(mac.prefix(8)).lowercased()
            let asusOUIs: Set<String> = [
                "a0:36:bc", "04:92:26", "04:d4:c4", "10:c3:7b", "1c:87:2c",
                "2c:fd:a1", "38:d5:47", "40:b0:76", "50:46:5d", "60:45:cb",
                "70:8b:cd", "74:d0:2b", "ac:22:0b", "ac:9e:17", "b0:6e:bf",
                "bc:ee:7b", "d8:50:e6", "f0:79:59", "f8:32:e4"
            ]
            if asusOUIs.contains(prefix) {
                return ("华硕无线路由器", "ASUS", "network.badge.shield.half.filled")
            }
            return ("默认网关路由器", "Router", "network.badge.shield.half.filled")
        }
        if isLocal {
            let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameToUse = trimmed.isEmpty ? "Apple Mac" : trimmed
            return (nameToUse, "Apple", "laptopcomputer")
        }

        if let ddp {
            let display = ddp.hostName.isEmpty ? ddp.hostType : ddp.hostName
            return (display, "Sony", "tv.fill")
        }

        let prefix = mac.prefix(8).lowercased()

        // 索尼 PlayStation 家族 (DDP 未响应时的 OUI 兜底推断)
        if isPortalOUI(prefix) {
            return ("PlayStation Portal", "Sony", "gamecontroller")
        }
        if isSonyOUI(prefix) {
            return ("PlayStation 终端", "Sony", "gamecontroller.fill")
        }

        // 苹果设备
        if prefix.hasPrefix("bc:89:c1") || prefix.hasPrefix("ba:eb:32") || prefix.hasPrefix("48:9e:9d") ||
           prefix.hasPrefix("b4:60:ed") || prefix.hasPrefix("6c:80:ab") || prefix.hasPrefix("c0:95:6d") ||
           prefix.hasPrefix("28:16:a8") {
            return ("Apple 设备", "Apple", "apple.logo")
        }

        // 任天堂
        if prefix.hasPrefix("64:9e:31") {
            return ("Nintendo Switch", "Nintendo", "gamecontroller")
        }

        // 乐鑫智能家居模组
        if prefix.hasPrefix("54:ef:44") || prefix.hasPrefix("ec:4d:3e") {
            return ("乐鑫智能硬件", "Espressif", "cpu")
        }

        // 英特尔 PC
        if prefix.hasPrefix("c8:5c:cc") {
            return ("Intel 电脑终端", "Intel", "desktopcomputer")
        }

        // 华为
        if prefix.hasPrefix("cc:b5:d1") {
            return ("华为智能终端", "Huawei", "wave.3.forward")
        }

        // 小米
        if prefix.hasPrefix("78:df:72") || prefix.hasPrefix("64:90:c1") {
            return ("小米智能设备", "Xiaomi", "house.fill")
        }

        // Sonos 音响
        if prefix.hasPrefix("20:37:f0") {
            return ("Sonos 音响", "Sonos", "speaker.wave.3.fill")
        }

        // 亚马逊 Echo
        if prefix.hasPrefix("dc:ed:83") {
            return ("Amazon 智能硬件", "Amazon", "dot.radiowaves.left.and.right")
        }

        return ("局域网终端", "LAN", "network")
    }

    // MARK: - 自定义编辑交互方法

    public func startEditing(dev: LanDeviceItem) {
        self.editingMAC = dev.mac
        self.editingNameInput = dev.name
        self.showPresetIconPicker = false
    }

    public func cancelEditing() {
        self.editingMAC = nil
        self.editingNameInput = ""
        self.showPresetIconPicker = false
    }

    public func saveEditingName() {
        guard let mac = editingMAC else { return }
        LanDeviceMetadataManager.shared.setCustomName(for: mac, name: editingNameInput)
        self.editingMAC = nil
        self.editingNameInput = ""
        self.showPresetIconPicker = false
    }

    public func selectPresetIcon(icon: String) {
        guard let mac = editingMAC else { return }
        LanDeviceMetadataManager.shared.setCustomPresetIcon(for: mac, icon: icon)
    }

    public func promptUploadIconFile() {
        guard let mac = editingMAC else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "选择设备自定义图标"
        panel.prompt = "使用此图片"

        if panel.runModal() == .OK, let url = panel.url {
            LanDeviceMetadataManager.shared.setCustomImageFile(for: mac, sourceURL: url)
        }
    }

    public func resetToDefault() {
        guard let mac = editingMAC else { return }
        LanDeviceMetadataManager.shared.resetProfile(for: mac)
        self.editingMAC = nil
        self.editingNameInput = ""
        self.showPresetIconPicker = false
    }

    // MARK: - DHCP 备份 CSV 批量导入改名

    public func promptImportDHCPBackup() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.commaSeparatedText, .plainText]
        if let csvType = UTType(filenameExtension: "csv") {
            types.insert(csvType, at: 0)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "导入路由器 DHCP 静态分配备份"
        panel.message = "选择包含 MAC 地址与设备名称的 CSV 文件（如 dhcp_manual_list.csv）"
        panel.prompt = "导入并匹配改名"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let content = Self.readTextFileAutoEncoding(url: url) else {
            showNotice("无法读取所选文件内容", duration: 3.0)
            return
        }

        let mappings = Self.parseDHCPCSV(content: content)
        guard !mappings.isEmpty else {
            showNotice("未解析到有效的 MAC 与设备名称记录", duration: 3.0)
            return
        }

        let importedCount = LanDeviceMetadataManager.shared.batchSetCustomNames(mappings)
        let importedMacSet = Set(mappings.compactMap { LanDeviceMetadataManager.normalizeMAC($0.mac) })
        let matchedOnlineCount = discoveredDevices.filter {
            if let norm = LanDeviceMetadataManager.normalizeMAC($0.mac) {
                return importedMacSet.contains(norm)
            }
            return false
        }.count

        showNotice("已导入 \(importedCount) 条 DHCP 名称 · 当前匹配 \(matchedOnlineCount) 台设备", duration: 3.6)
    }

    private static func readTextFileAutoEncoding(url: URL) -> String? {
        if let str = try? String(contentsOf: url, encoding: .utf8) {
            return str
        }
        if let str = try? String(contentsOf: url, encoding: .utf16) {
            return str
        }
        if let data = try? Data(contentsOf: url) {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    private static func parseDHCPCSV(content: String) -> [(mac: String, name: String)] {
        let cleaned = content.replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        let parsedRows = lines.map { parseCSVLine($0) }
        guard let firstRow = parsedRows.first else { return [] }

        let lowerHeader = firstRow.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let macHeaderCandidates = ["mac address", "mac", "physical address", "hw address", "硬件地址", "物理地址", "mac地址"]
        let nameHeaderCandidates = ["client name", "device name", "name", "remark", "alias", "设备名称", "备注", "设备名"]
        let hostHeaderCandidates = ["hostname", "host name", "host", "主机名"]

        let macCol = lowerHeader.firstIndex(where: { macHeaderCandidates.contains($0) })
        let nameCol = lowerHeader.firstIndex(where: { nameHeaderCandidates.contains($0) })
        let hostCol = lowerHeader.firstIndex(where: { hostHeaderCandidates.contains($0) })

        let hasExplicitHeader = (macCol != nil)
        let dataRows = hasExplicitHeader ? Array(parsedRows.dropFirst()) : parsedRows

        var results: [(mac: String, name: String)] = []
        for row in dataRows {
            let macIdx = macCol ?? 0
            guard macIdx < row.count, let normMAC = LanDeviceMetadataManager.normalizeMAC(row[macIdx]) else {
                continue
            }

            var resolvedName = ""
            if let nIdx = nameCol, nIdx < row.count {
                resolvedName = row[nIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if resolvedName.isEmpty, let hIdx = hostCol, hIdx < row.count {
                resolvedName = row[hIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !hasExplicitHeader && resolvedName.isEmpty {
                // 无表头兜底：例如 5 列格式 [MAC, IP, DNS, Hostname, ClientName] 或 2 列 [MAC, Name]
                if row.count >= 5 {
                    let clientName = row[4].trimmingCharacters(in: .whitespacesAndNewlines)
                    let hostName = row[3].trimmingCharacters(in: .whitespacesAndNewlines)
                    resolvedName = clientName.isEmpty ? hostName : clientName
                } else if row.count >= 2 {
                    resolvedName = row.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            }

            if !resolvedName.isEmpty {
                results.append((mac: normMAC, name: resolvedName))
            }
        }
        return results
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var idx = line.startIndex

        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\"" {
                let nextIdx = line.index(after: idx)
                if inQuotes && nextIdx < line.endIndex && line[nextIdx] == "\"" {
                    current.append("\"")
                    idx = line.index(after: nextIdx)
                    continue
                } else {
                    inQuotes.toggle()
                }
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            idx = line.index(after: idx)
        }
        fields.append(current)
        return fields
    }
}
