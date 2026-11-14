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

/// 局域网终端主动自报信息（来自 UPnP / mDNS / NetBIOS / 路由器 DNS PTR）
public struct LanPeerSelfReport: Sendable {
    public var hostname: String?
    public var friendlyName: String?
    public var manufacturer: String?
    public var model: String?
    public var iconHint: String?

    public init(
        hostname: String? = nil,
        friendlyName: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        iconHint: String? = nil
    ) {
        self.hostname = hostname
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.model = model
        self.iconHint = iconHint
    }

    public mutating func merge(_ other: LanPeerSelfReport) {
        if friendlyName == nil || friendlyName?.isEmpty == true {
            friendlyName = other.friendlyName
        }
        if manufacturer == nil || manufacturer?.isEmpty == true {
            manufacturer = other.manufacturer
        }
        if model == nil || model?.isEmpty == true {
            model = other.model
        }
        if hostname == nil || hostname?.isEmpty == true {
            hostname = other.hostname
        }
        if iconHint == nil || iconHint?.isEmpty == true {
            iconHint = other.iconHint
        }
    }
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
    public let defaultVendor: String
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
        self.defaultVendor = vendor
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

    /// 动态获取设备显示厂商 (优先采用单设备自定义与全局厂商映射规则)
    @MainActor
    public var vendor: String {
        LanDeviceMetadataManager.shared.resolveVendor(for: mac, defaultVendor: defaultVendor)
    }

    /// 动态获取自定义档案
    @MainActor
    public var customProfile: CustomDeviceProfile? {
        LanDeviceMetadataManager.shared.getProfile(for: mac)
    }

    /// 是否被用户自定义过
    @MainActor
    public var isCustomized: Bool {
        guard let profile = customProfile else { return false }
        return profile.customName != nil || profile.customVendor != nil || profile.customIcon != nil
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

/// 局域网 ARP 嗅探与设备诊断引擎
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

    // 设备编辑状态
    public var editingMAC: String? = nil
    public var editingNameInput: String = ""
    public var editingVendorInput: String = ""
    public var applyVendorRuleToAll: Bool = false
    public var showVendorRulesPanel: Bool = false
    public var ruleMatchInput: String = ""
    public var ruleTargetInput: String = ""
    public var showPresetIconPicker: Bool = false

    /// 预设 SF Symbol 图标列表
    public static let presetIcons: [String] = [
        "gamecontroller.fill", "gamecontroller", "tv.fill", "iphone", "ipad",
        "laptopcomputer", "desktopcomputer", "wifi.router", "network",
        "speaker.wave.3.fill", "printer.fill", "camera.fill", "lightbulb.fill",
        "powerplug.fill", "cpu", "server.rack", "apple.logo", "book.fill"
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
            $0.vendor.lowercased().contains(q) ||
            $0.defaultVendor.lowercased().contains(q)
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
        editingVendorInput = ""
        applyVendorRuleToAll = false
        showVendorRulesPanel = false
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

            // 读取最终 ARP 表并并行执行多协议设备自报探测 (DDP / DNS PTR / mDNS / SSDP+UPnP / NetBIOS)
            let preDDP = Self.collectCurrentArpDevices(
                existing: accumulatedByIP,
                targetIface: targetIface,
                gatewayIP: gatewayIP,
                localIPSet: localIPSet,
                localComputerName: localComputerName,
                ddpMap: [:],
                selfReports: [:]
            )
            let discoveredIPs = preDDP.sortedItems.map(\.ip).filter { ip in
                ip.contains(".") && ip != "127.0.0.1" && !localIPSet.contains(ip) && !ip.hasSuffix(".255") && !ip.hasPrefix("224.") && !ip.hasPrefix("239.")
            }
            let ddpTargetIPs = discoveredIPs.filter { $0 != gatewayIP }
            let ddpMap = Self.probePlayStationDDP(
                targetIPs: ddpTargetIPs,
                broadcastIPs: ddpBroadcasts,
                interfaceName: targetIface,
                timeoutMs: 260
            )
            let selfReports = Self.probePeerSelfReports(
                targetIPs: discoveredIPs,
                gatewayIP: gatewayIP,
                localIP: targetLocalIP,
                interfaceName: targetIface,
                timeoutMs: 420
            )
            let finalSnapshot = Self.collectCurrentArpDevices(
                existing: preDDP.byIP,
                targetIface: targetIface,
                gatewayIP: gatewayIP,
                localIPSet: localIPSet,
                localComputerName: localComputerName,
                ddpMap: ddpMap,
                selfReports: selfReports
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
        ddpMap: [String: PlayStationDDPInfo],
        selfReports: [String: LanPeerSelfReport] = [:]
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
            let mac = LanOuiDatabase.normalizeMAC(entry.mac) ?? entry.mac.lowercased()
            let ifName = entry.ifName.isEmpty ? targetIface : entry.ifName

            guard !mac.contains("00:00:00:00:00:00") && !mac.contains("ff:ff:ff:ff:ff:ff") && mac.count == 17 else { continue }
            guard !ip.hasPrefix("224.") && !ip.hasPrefix("239.") && ip != "255.255.255.255" else { continue }

            let hasFreshDiscovery = (ddpMap[ip] != nil || selfReports[ip] != nil)
            // 优先保留目标物理网卡条目；当已有同网卡条目且没有新自报/DDP 信息时不重复覆盖
            if mapByIP[ip] != nil {
                if preferredIfaceMatched.contains(ip) && !hasFreshDiscovery {
                    continue
                }
                if !preferredIfaceMatched.contains(ip) && ifName != targetIface && !hasFreshDiscovery {
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
                ddp: ddpMap[ip],
                selfReport: selfReports[ip]
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

        // 若某设备在前几轮已入表但在最终轮次前从 ARP 短暂超时移除，仍补齐 DDP / 自报信息
        for (ip, existingItem) in mapByIP {
            guard ddpMap[ip] != nil || selfReports[ip] != nil else { continue }
            let (deviceName, vendor, icon) = identifyDevice(
                ip: ip,
                mac: existingItem.mac,
                isGateway: existingItem.isGateway,
                isLocal: existingItem.isLocalHost,
                localName: localComputerName,
                ddp: ddpMap[ip],
                selfReport: selfReports[ip]
            )
            if deviceName != existingItem.defaultName || vendor != existingItem.defaultVendor || icon != existingItem.defaultIcon {
                mapByIP[ip] = LanDeviceItem(
                    id: existingItem.id,
                    ip: existingItem.ip,
                    mac: existingItem.mac,
                    defaultName: deviceName,
                    vendor: vendor,
                    interface: existingItem.interface,
                    isGateway: existingItem.isGateway,
                    isLocalHost: existingItem.isLocalHost,
                    defaultIcon: icon,
                    lastSeen: existingItem.lastSeen
                )
            }
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

    /// 分批向网段 1~254 发送无阻塞 UDP 探测以触发 ARP 解析
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
    nonisolated public static func probeHostsViaUDP(
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
    nonisolated public static func probeHostsViaICMP(
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
    nonisolated public static func probeHostsViaTCP(
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

    /// 统一 Sony PlayStation / Portal IEEE OUI 判定（联动 5.4 万条权威 OUI 库）
    nonisolated public static func isSonyOUI(_ mac: String) -> Bool {
        let oui = String((LanOuiDatabase.normalizeMAC(mac) ?? mac).prefix(8)).lowercased()
        let sonyOUIs: Set<String> = [
            "00:04:1f", "00:13:15", "00:15:c1", "00:19:c5", "00:1d:0d",
            "00:1f:a7", "00:24:8d", "00:d9:d1", "00:e4:21", "28:0d:fc",
            "28:40:dd", "2c:cc:44", "40:16:7e", "70:9e:29", "78:c8:81",
            "84:20:96", "98:fa:2e", "a8:47:4a", "a8:e3:ee", "b4:0a:d8",
            "bc:60:a7", "c8:63:f1", "cc:de:80", "d4:4b:5e", "e8:9e:b4",
            "f8:46:1c", "fc:0f:e6"
        ]
        if sonyOUIs.contains(oui) { return true }
        if let match = LanOuiDatabase.shared.lookup(mac) {
            return match.shortVendor == "Sony" || match.fullOrg.lowercased().contains("sony")
        }
        return false
    }

    nonisolated public static func isPortalOUI(_ mac: String) -> Bool {
        let oui = String((LanOuiDatabase.normalizeMAC(mac) ?? mac).prefix(8)).lowercased()
        return oui == "98:fa:2e" || oui == "a8:47:4a"
    }

    /// 识别 Sony Interactive Entertainment (SIE 互动娱乐) 专属游戏硬件号段（PS5 / PS Portal / PS4 等）
    nonisolated public static func isSonyInteractiveOUI(_ mac: String) -> Bool {
        if isPortalOUI(mac) { return true }
        if let match = LanOuiDatabase.shared.lookup(mac) {
            return match.fullOrg.lowercased().contains("sony interactive entertainment")
        }
        return false
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

    // MARK: - 多协议局域网设备主动自报探测 (DNS PTR / mDNS / SSDP+UPnP / NetBIOS)

    private final class ThreadSafeReportStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: LanPeerSelfReport] = [:]

        func merge(_ incoming: [String: LanPeerSelfReport]) {
            guard !incoming.isEmpty else { return }
            lock.lock()
            for (ip, rep) in incoming {
                if var existing = storage[ip] {
                    existing.merge(rep)
                    storage[ip] = existing
                } else {
                    storage[ip] = rep
                }
            }
            lock.unlock()
        }

        func snapshot() -> [String: LanPeerSelfReport] {
            lock.lock()
            let copy = storage
            lock.unlock()
            return copy
        }
    }

    private final class ThreadSafeXmlResultStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: LanPeerSelfReport] = [:]

        func set(_ ip: String, report: LanPeerSelfReport) {
            lock.lock()
            if var existing = storage[ip] {
                var fresh = report
                fresh.merge(existing)
                existing = fresh
                storage[ip] = existing
            } else {
                storage[ip] = report
            }
            lock.unlock()
        }

        func snapshot() -> [String: LanPeerSelfReport] {
            lock.lock()
            let copy = storage
            lock.unlock()
            return copy
        }
    }

    /// 并行执行 DNS PTR、mDNS、SSDP+UPnP、NetBIOS 自报探测，严格受限于 timeoutMs 内返回
    nonisolated public static func probePeerSelfReports(
        targetIPs: [String],
        gatewayIP: String,
        localIP: String,
        interfaceName: String?,
        timeoutMs: Int = 420
    ) -> [String: LanPeerSelfReport] {
        guard !targetIPs.isEmpty else { return [:] }

        let store = ThreadSafeReportStore()
        let group = DispatchGroup()
        let dnsTimeout = min(240, timeoutMs)
        let nbTimeout = min(220, timeoutMs)
        let mdnsTimeout = min(320, timeoutMs)

        // 先后顺序影响合并优先级：先合并 UPnP -> mDNS -> NetBIOS -> DNS PTR，因此各自并发跑完后按可信度依次合并
        let upnpStore = ThreadSafeReportStore()
        let mdnsStore = ThreadSafeReportStore()
        let nbStore = ThreadSafeReportStore()
        let ptrStore = ThreadSafeReportStore()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeSSDPAndUPnP(
                targetIPs: targetIPs,
                interfaceName: interfaceName,
                localIP: localIP,
                timeoutMs: timeoutMs
            )
            upnpStore.merge(res)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeMDNS(
                targetIPs: targetIPs,
                interfaceName: interfaceName,
                localIP: localIP,
                timeoutMs: mdnsTimeout
            )
            mdnsStore.merge(res)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeNetBIOSNames(
                targetIPs: targetIPs,
                interfaceName: interfaceName,
                timeoutMs: nbTimeout
            )
            nbStore.merge(res)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeDnsPTR(
                targetIPs: targetIPs,
                gatewayIP: gatewayIP,
                interfaceName: interfaceName,
                timeoutMs: dnsTimeout
            )
            ptrStore.merge(res)
            group.leave()
        }

        _ = group.wait(timeout: .now() + .milliseconds(max(200, timeoutMs + 120)))

        // 按权威优先级由高到低合并：UPnP -> mDNS -> NetBIOS -> DNS PTR
        store.merge(upnpStore.snapshot())
        store.merge(mdnsStore.snapshot())
        store.merge(nbStore.snapshot())
        store.merge(ptrStore.snapshot())
        return store.snapshot()
    }

    /// 1) 向路由器及系统 DNS 服务器发起 RFC 1035 IP 反向 PTR 查询，获取 DHCP Option 12 主机名
    nonisolated private static func probeDnsPTR(
        targetIPs: [String],
        gatewayIP: String,
        interfaceName: String?,
        timeoutMs: Int = 240
    ) -> [String: LanPeerSelfReport] {
        var dnsServers: [String] = []
        var resolvSuffixes: [String] = []
        if isValidIPv4(gatewayIP), !gatewayIP.hasPrefix("127.") {
            dnsServers.append(gatewayIP)
        }
        if let resolv = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) {
            for line in resolv.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 2 else { continue }
                let directive = parts[0].lowercased()
                if directive == "nameserver" {
                    let ip = String(parts[1])
                    if isValidIPv4(ip), !ip.hasPrefix("127."), !dnsServers.contains(ip) {
                        dnsServers.append(ip)
                    }
                } else if directive == "domain" || directive == "search" {
                    for token in parts.dropFirst() {
                        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                        if !cleaned.isEmpty && cleaned.count >= 2 {
                            let dotSuffix = ".\(cleaned)"
                            if !resolvSuffixes.contains(dotSuffix) {
                                resolvSuffixes.append(dotSuffix)
                            }
                        }
                    }
                }
            }
        }
        // 只保留最多 2 台本地/系统 DNS 避免无谓放大包量
        let servers = Array(dnsServers.prefix(2))
        guard !servers.isEmpty else { return [:] }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        var txToIP: [UInt16: String] = [:]
        var nextTx: UInt16 = UInt16.random(in: 1000...60000)

        for ip in targetIPs {
            guard let ptrDomain = reverseArpaDomain(for: ip) else { continue }
            for srv in servers {
                var srvAddr = sockaddr_in()
                srvAddr.sin_family = sa_family_t(AF_INET)
                srvAddr.sin_port = in_port_t(53).bigEndian
                guard inet_pton(AF_INET, srv, &srvAddr.sin_addr) == 1 else { continue }

                nextTx &+= 1
                if nextTx == 0 { nextTx = 1 }
                txToIP[nextTx] = ip
                let pkt = buildDnsQueryPacket(
                    txID: nextTx,
                    qnameLabels: ptrDomain,
                    qtype: 12, // PTR
                    qclass: 1  // IN
                )
                withUnsafePointer(to: &srvAddr) { saPtr in
                    saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var rawHostByIP: [String: String] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(50, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline && rawHostByIP.count < targetIPs.count {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(40, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 12 else { continue }
            let packet = Array(recvBuf.prefix(n))
            let txID = (UInt16(packet[0]) << 8) | UInt16(packet[1])
            let flags = (UInt16(packet[2]) << 8) | UInt16(packet[3])
            let rcode = flags & 0x000F
            guard (flags & 0x8000) != 0, rcode == 0 else { continue }

            let parsed = parseDnsPacket(packet)
            let matchedIP = txToIP[txID]
            for rr in parsed.answers where rr.type == 12 {
                let targetIP = ipFromReverseArpa(rr.name) ?? matchedIP
                guard let ip = targetIP, let ptrHost = rr.ptrTarget else { continue }
                let trimmedRaw = ptrHost.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n"))
                guard !trimmedRaw.isEmpty else { continue }
                if rawHostByIP[ip] == nil {
                    rawHostByIP[ip] = trimmedRaw
                }
            }
        }

        // 动态提取路由器局域网后缀（如 .GT-BN96X / .OpenWrt / resolv search 域）
        var dynamicSuffixes = resolvSuffixes
        if let gwRaw = rawHostByIP[gatewayIP],
           let dotIdx = gwRaw.firstIndex(of: ".") {
            let suffix = String(gwRaw[dotIdx...]).lowercased()
            if suffix.count >= 2 && !dynamicSuffixes.contains(suffix) {
                dynamicSuffixes.append(suffix)
            }
        }
        var labelSuffixCounts: [String: Int] = [:]
        let excludedPublicTLDs: Set<String> = ["com", "net", "org", "cn", "edu", "gov", "io"]
        for rawHost in rawHostByIP.values {
            let parts = rawHost.split(separator: ".")
            if parts.count >= 2, let last = parts.last {
                let lowLast = last.lowercased()
                if !excludedPublicTLDs.contains(lowLast) {
                    labelSuffixCounts[".\(lowLast)", default: 0] += 1
                }
            }
        }
        for (suffix, count) in labelSuffixCounts where count >= 2 && !dynamicSuffixes.contains(suffix) {
            dynamicSuffixes.append(suffix)
        }

        var reports: [String: LanPeerSelfReport] = [:]
        for (ip, rawHost) in rawHostByIP {
            if let cleaned = cleanHostname(rawHost, extraSuffixes: dynamicSuffixes) {
                reports[ip] = LanPeerSelfReport(hostname: cleaned)
            }
        }
        return reports
    }

    /// 2) mDNS / Bonjour 组播 + 单播主动查询（解析 A / PTR / SRV / TXT 元数据）
    nonisolated private static func probeMDNS(
        targetIPs: [String],
        interfaceName: String?,
        localIP: String?,
        timeoutMs: Int = 320
    ) -> [String: LanPeerSelfReport] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName, multicastLocalIP: localIP)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        var mdnsMulticast = sockaddr_in()
        mdnsMulticast.sin_family = sa_family_t(AF_INET)
        mdnsMulticast.sin_port = in_port_t(5353).bigEndian
        inet_pton(AF_INET, "224.0.0.251", &mdnsMulticast.sin_addr)

        let serviceTypes = [
            ["_hap", "_tcp", "local"],
            ["_airplay", "_tcp", "local"],
            ["_companion-link", "_tcp", "local"],
            ["_miio", "_udp", "local"],
            ["_smb", "_tcp", "local"],
            ["_device-info", "_tcp", "local"],
            ["_googlecast", "_tcp", "local"],
            ["_ipp", "_tcp", "local"],
            ["_printer", "_tcp", "local"]
        ]
        for svc in serviceTypes {
            // QCLASS = 0x8001 (QU unicast-response bit) 让对端直接回包到我们的临时 UDP 端口，无需抢占 5353
            let pkt = buildDnsQueryPacket(txID: 0, qnameLabels: svc, qtype: 12, qclass: 0x8001)
            withUnsafePointer(to: &mdnsMulticast) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // 向已发现设备直接单播反向 PTR 查询，拿到精确的 .local 主机名
        for ip in targetIPs {
            guard let rev = reverseArpaDomain(for: ip) else { continue }
            var peerAddr = sockaddr_in()
            peerAddr.sin_family = sa_family_t(AF_INET)
            peerAddr.sin_port = in_port_t(5353).bigEndian
            guard inet_pton(AF_INET, ip, &peerAddr.sin_addr) == 1 else { continue }
            let pkt = buildDnsQueryPacket(txID: 0, qnameLabels: rev, qtype: 12, qclass: 0x8001)
            withUnsafePointer(to: &peerAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var reports: [String: LanPeerSelfReport] = [:]
        var hostToIP: [String: String] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 4096)
        let targetSet = Set(targetIPs)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(60, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(40, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 12 else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = senderAddr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(decoding: ipBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

            let parsed = parseDnsPacket(Array(recvBuf.prefix(n)))
            let allRRs = parsed.answers + parsed.additionals

            // 1. 收集 A 记录建立本包与累计 hostname.local -> IP 映射
            var packetHosts: Set<String> = []
            for rr in allRRs where rr.type == 1 {
                if let ip = rr.ipv4, targetSet.contains(ip) {
                    let hostKey = rr.name.lowercased()
                    hostToIP[hostKey] = ip
                    packetHosts.insert(ip)
                    if let cleaned = cleanHostname(rr.name) {
                        var rep = reports[ip] ?? LanPeerSelfReport()
                        rep.merge(LanPeerSelfReport(hostname: cleaned))
                        reports[ip] = rep
                    }
                }
            }

            // 2. 收集 SRV 记录绑定 serviceInstance -> targetHost
            var serviceToHost: [String: String] = [:]
            for rr in allRRs where rr.type == 33 {
                if let target = rr.srvTarget {
                    serviceToHost[rr.name.lowercased()] = target.lowercased()
                }
            }

            // 3. 解析 PTR：反向 ARP PTR 与服务实例命名
            for rr in allRRs where rr.type == 12 {
                if let revIP = ipFromReverseArpa(rr.name),
                   let ptrTarget = rr.ptrTarget,
                   let cleaned = cleanHostname(ptrTarget) {
                    var rep = reports[revIP] ?? LanPeerSelfReport()
                    rep.merge(LanPeerSelfReport(hostname: cleaned))
                    reports[revIP] = rep
                    hostToIP[ptrTarget.lowercased()] = revIP
                } else if let ptrTarget = rr.ptrTarget {
                    let instKey = ptrTarget.lowercased()
                    let srvHost = serviceToHost[instKey]
                    let resolvedIP = srvHost.flatMap { hostToIP[$0] }
                        ?? (packetHosts.count == 1 ? packetHosts.first : (packetHosts.isEmpty && targetSet.contains(senderIP) ? senderIP : nil))
                    if let ip = resolvedIP, let repFromSvc = extractReportFromServiceInstance(ptrTarget) {
                        var rep = reports[ip] ?? LanPeerSelfReport()
                        rep.merge(repFromSvc)
                        reports[ip] = rep
                    }
                }
            }

            // 4. 解析 TXT 键值对 (md=, fn=, mf=, am=, ty=, mfg=, mdl=)
            for rr in allRRs where rr.type == 16 && !rr.txtPairs.isEmpty {
                let rrKey = rr.name.lowercased()
                let srvHost = serviceToHost[rrKey]
                let resolvedIP = srvHost.flatMap { hostToIP[$0] }
                    ?? hostToIP[rrKey]
                    ?? (packetHosts.count == 1 ? packetHosts.first : (packetHosts.isEmpty && targetSet.contains(senderIP) ? senderIP : nil))
                guard let ip = resolvedIP else { continue }

                var parsedRep = extractReportFromServiceInstance(rr.name) ?? LanPeerSelfReport()
                for (k, v) in rr.txtPairs {
                    let key = k.lowercased()
                    let val = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !val.isEmpty else { continue }
                    switch key {
                    case "fn", "n":
                        if val != "1" && val.count >= 2 {
                            parsedRep.friendlyName = parsedRep.friendlyName ?? val
                        }
                    case "md", "model", "mdl", "usb_mdl":
                        parsedRep.model = parsedRep.model ?? val
                    case "mf", "manufacturer", "mfg", "usb_mfg":
                        parsedRep.manufacturer = parsedRep.manufacturer ?? val
                    case "am":
                        parsedRep.model = parsedRep.model ?? readableAppleModel(val)
                        parsedRep.manufacturer = parsedRep.manufacturer ?? "Apple"
                    case "ty":
                        parsedRep.friendlyName = parsedRep.friendlyName ?? val
                    default:
                        break
                    }
                }
                var existing = reports[ip] ?? LanPeerSelfReport()
                existing.merge(parsedRep)
                reports[ip] = existing
            }
        }

        return reports
    }

    /// 3) SSDP (UDP 1900) 组播 + 单播发现，并并发抓取 HTTP UPnP XML 设备描述文件
    nonisolated private static func probeSSDPAndUPnP(
        targetIPs: [String],
        interfaceName: String?,
        localIP: String?,
        timeoutMs: Int = 420
    ) -> [String: LanPeerSelfReport] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName, multicastLocalIP: localIP)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let payloads: [[UInt8]] = [
            Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: upnp:rootdevice\r\n\r\n".utf8),
            Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n".utf8)
        ]

        var ssdpAddr = sockaddr_in()
        ssdpAddr.sin_family = sa_family_t(AF_INET)
        ssdpAddr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &ssdpAddr.sin_addr)
        for pkt in payloads {
            withUnsafePointer(to: &ssdpAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // 同时向已发现主机发送单播 M-SEARCH，兼容开启组播隔离的路由器/电视
        for ip in targetIPs.prefix(128) {
            var unicastAddr = sockaddr_in()
            unicastAddr.sin_family = sa_family_t(AF_INET)
            unicastAddr.sin_port = in_port_t(1900).bigEndian
            guard inet_pton(AF_INET, ip, &unicastAddr.sin_addr) == 1 else { continue }
            withUnsafePointer(to: &unicastAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, payloads[0], payloads[0].count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var locationByIP: [String: URL] = [:]
        var fallbackServerReport: [String: LanPeerSelfReport] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        let udpListenMs = min(210, max(100, timeoutMs / 2))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(udpListenMs) * 1_000_000
        let targetSet = Set(targetIPs)

        while DispatchTime.now().uptimeNanoseconds < deadline {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(35, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

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
            var locationRaw = ""
            var serverHeader = ""
            for line in text.components(separatedBy: .newlines) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "location" { locationRaw = val }
                else if key == "server" { serverHeader = val }
            }

            if !locationRaw.isEmpty,
               let url = URL(string: locationRaw),
               url.scheme?.lowercased() == "http",
               let host = url.host,
               host == senderIP || targetSet.contains(host),
               locationByIP[senderIP] == nil {
                locationByIP[senderIP] = url
            }
            if !serverHeader.isEmpty, fallbackServerReport[senderIP] == nil {
                if let srvVendor = inferVendorFromText(serverHeader) {
                    fallbackServerReport[senderIP] = LanPeerSelfReport(manufacturer: srvVendor)
                }
            }
        }

        guard !locationByIP.isEmpty else { return fallbackServerReport }

        // 并发抓取 UPnP XML（单请求 <= 320ms）
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.32
        cfg.timeoutIntervalForResource = 0.36
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let xmlStore = ThreadSafeXmlResultStore()
        let fetchGroup = DispatchGroup()

        for (ip, url) in locationByIP.prefix(24) {
            fetchGroup.enter()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 0.32)
            req.httpMethod = "GET"
            session.dataTask(with: req) { data, _, _ in
                defer { fetchGroup.leave() }
                guard let data, !data.isEmpty else { return }
                let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                guard !xml.isEmpty else { return }

                let friendly = extractXmlTag("friendlyName", from: xml)
                let manufacturer = extractXmlTag("manufacturer", from: xml)
                let modelName = extractXmlTag("modelName", from: xml)
                let deviceType = extractXmlTag("deviceType", from: xml)
                let iconHint = iconHintFromUpnpDeviceType(deviceType)

                let validFriendly = isMeaningfulDeviceName(friendly) ? friendly : nil
                let validModel = isMeaningfulDeviceName(modelName) ? modelName : nil
                let validMfg = isMeaningfulDeviceName(manufacturer) ? manufacturer : nil

                if validFriendly != nil || validModel != nil || validMfg != nil {
                    xmlStore.set(ip, report: LanPeerSelfReport(
                        friendlyName: validFriendly,
                        manufacturer: validMfg,
                        model: validModel,
                        iconHint: iconHint
                    ))
                }
            }.resume()
        }

        _ = fetchGroup.wait(timeout: .now() + .milliseconds(360))
        var merged = xmlStore.snapshot()
        for (ip, fallback) in fallbackServerReport {
            if var existing = merged[ip] {
                existing.merge(fallback)
                merged[ip] = existing
            } else {
                merged[ip] = fallback
            }
        }
        return merged
    }

    /// 4) NetBIOS Node Status (UDP 137) 主动查询（获取 Windows / NAS / 打印机 / 游戏机主机名）
    nonisolated private static func probeNetBIOSNames(
        targetIPs: [String],
        interfaceName: String?,
        timeoutMs: Int = 220
    ) -> [String: LanPeerSelfReport] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        // 50-byte NBSTAT "*" wildcard query template
        var nbQuery: [UInt8] = [
            0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x20, 0x43, 0x4b, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00,
            0x00, 0x21, 0x00, 0x01
        ]

        var txToIP: [UInt16: String] = [:]
        var nextTx: UInt16 = UInt16.random(in: 100...30000)

        for ip in targetIPs {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(137).bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            nextTx &+= 1
            if nextTx == 0 { nextTx = 1 }
            txToIP[nextTx] = ip
            nbQuery[0] = UInt8(nextTx >> 8)
            nbQuery[1] = UInt8(nextTx & 0xFF)
            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, nbQuery, nbQuery.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var reports: [String: LanPeerSelfReport] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 1500)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(50, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline && reports.count < targetIPs.count {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(35, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 57 else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = senderAddr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(decoding: ipBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            let packet = Array(recvBuf.prefix(n))
            let txID = (UInt16(packet[0]) << 8) | UInt16(packet[1])
            let resolvedIP = senderIP.isEmpty ? (txToIP[txID] ?? "") : senderIP
            guard !resolvedIP.isEmpty else { continue }

            if let host = parseNetBIOSNodeStatusName(packet) {
                reports[resolvedIP] = LanPeerSelfReport(hostname: host)
            }
        }

        return reports
    }

    // MARK: - 协议报文轻量编解码与辅助解析

    private struct ParsedDnsRR: Sendable {
        let name: String
        let type: UInt16
        let ptrTarget: String?
        let srvTarget: String?
        let ipv4: String?
        let txtPairs: [(String, String)]
    }

    nonisolated private static func isValidIPv4(_ ip: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, ip, &addr) == 1
    }

    nonisolated private static func reverseArpaDomain(for ip: String) -> [String]? {
        let parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return [parts[3], parts[2], parts[1], parts[0], "in-addr", "arpa"]
    }

    nonisolated private static func ipFromReverseArpa(_ domain: String) -> String? {
        let low = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard low.hasSuffix(".in-addr.arpa") else { return nil }
        let stem = String(low.dropLast(".in-addr.arpa".count))
        let octets = stem.split(separator: ".").map(String.init)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return "\(octets[3]).\(octets[2]).\(octets[1]).\(octets[0])"
    }

    nonisolated private static func buildDnsQueryPacket(
        txID: UInt16,
        qnameLabels: [String],
        qtype: UInt16,
        qclass: UInt16
    ) -> [UInt8] {
        var pkt: [UInt8] = [
            UInt8(txID >> 8), UInt8(txID & 0xFF),
            txID == 0 ? 0x00 : 0x01, 0x00, // RD=1 for unicast DNS, 0 for mDNS
            0x00, 0x01, // QDCOUNT=1
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        for label in qnameLabels {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty && bytes.count <= 63 else { continue }
            pkt.append(UInt8(bytes.count))
            pkt.append(contentsOf: bytes)
        }
        pkt.append(0x00)
        pkt.append(contentsOf: [
            UInt8(qtype >> 8), UInt8(qtype & 0xFF),
            UInt8(qclass >> 8), UInt8(qclass & 0xFF)
        ])
        return pkt
    }

    nonisolated private static func readDnsName(from packet: [UInt8], offset startOffset: Int) -> (name: String, nextOffset: Int)? {
        var labels: [String] = []
        var offset = startOffset
        var jumped = false
        var endOffset = startOffset
        var jumps = 0

        while offset < packet.count {
            let lenByte = packet[offset]
            if lenByte == 0 {
                if !jumped { endOffset = offset + 1 }
                break
            }
            if (lenByte & 0xC0) == 0xC0 {
                guard offset + 1 < packet.count else { return nil }
                let ptr = (Int(lenByte & 0x3F) << 8) | Int(packet[offset + 1])
                if !jumped {
                    endOffset = offset + 2
                    jumped = true
                }
                jumps += 1
                guard jumps <= 16, ptr < packet.count else { return nil }
                offset = ptr
                continue
            }
            let len = Int(lenByte & 0x3F)
            offset += 1
            guard offset + len <= packet.count else { return nil }
            let label = String(decoding: packet[offset..<(offset + len)], as: UTF8.self)
            labels.append(label)
            offset += len
            if !jumped { endOffset = offset }
        }

        return (labels.joined(separator: "."), max(startOffset + 1, endOffset))
    }

    nonisolated private static func parseDnsPacket(_ packet: [UInt8]) -> (answers: [ParsedDnsRR], additionals: [ParsedDnsRR]) {
        guard packet.count >= 12 else { return ([], []) }
        let qdCount = Int((UInt16(packet[4]) << 8) | UInt16(packet[5]))
        let anCount = Int((UInt16(packet[6]) << 8) | UInt16(packet[7]))
        let nsCount = Int((UInt16(packet[8]) << 8) | UInt16(packet[9]))
        let arCount = Int((UInt16(packet[10]) << 8) | UInt16(packet[11]))

        var cursor = 12
        for _ in 0..<min(qdCount, 32) {
            guard let (_, next) = readDnsName(from: packet, offset: cursor), next + 4 <= packet.count else {
                return ([], [])
            }
            cursor = next + 4
        }

        var answers: [ParsedDnsRR] = []
        var additionals: [ParsedDnsRR] = []
        let totalRRs = min(anCount + nsCount + arCount, 128)

        for idx in 0..<totalRRs {
            guard let (rrName, next) = readDnsName(from: packet, offset: cursor), next + 10 <= packet.count else {
                break
            }
            let rtype = (UInt16(packet[next]) << 8) | UInt16(packet[next + 1])
            let rdlen = Int((UInt16(packet[next + 8]) << 8) | UInt16(packet[next + 9]))
            let rdataStart = next + 10
            let rdataEnd = rdataStart + rdlen
            guard rdataEnd <= packet.count else { break }

            var ptrTarget: String? = nil
            var srvTarget: String? = nil
            var ipv4: String? = nil
            var txtPairs: [(String, String)] = []

            switch rtype {
            case 1 where rdlen == 4: // A
                ipv4 = "\(packet[rdataStart]).\(packet[rdataStart + 1]).\(packet[rdataStart + 2]).\(packet[rdataStart + 3])"
            case 12: // PTR
                if let (target, _) = readDnsName(from: packet, offset: rdataStart) {
                    ptrTarget = target
                }
            case 33 where rdlen > 6: // SRV
                if let (target, _) = readDnsName(from: packet, offset: rdataStart + 6) {
                    srvTarget = target
                }
            case 16: // TXT
                var txtPos = rdataStart
                while txtPos < rdataEnd {
                    let slen = Int(packet[txtPos])
                    txtPos += 1
                    guard txtPos + slen <= rdataEnd else { break }
                    let s = String(decoding: packet[txtPos..<(txtPos + slen)], as: UTF8.self)
                    txtPos += slen
                    if let eqIdx = s.firstIndex(of: "=") {
                        let k = String(s[..<eqIdx])
                        let v = String(s[s.index(after: eqIdx)...])
                        txtPairs.append((k, v))
                    }
                }
            default:
                break
            }

            let rr = ParsedDnsRR(name: rrName, type: rtype, ptrTarget: ptrTarget, srvTarget: srvTarget, ipv4: ipv4, txtPairs: txtPairs)
            if idx < anCount {
                answers.append(rr)
            } else {
                additionals.append(rr)
            }
            cursor = rdataEnd
        }

        return (answers, additionals)
    }

    nonisolated private static func parseNetBIOSNodeStatusName(_ packet: [UInt8]) -> String? {
        guard packet.count > 12 else { return nil }
        let anCount = Int((UInt16(packet[6]) << 8) | UInt16(packet[7]))
        guard anCount >= 1 else { return nil }

        var cursor = 12
        let qdCount = Int((UInt16(packet[4]) << 8) | UInt16(packet[5]))
        for _ in 0..<qdCount {
            guard let (_, next) = readDnsName(from: packet, offset: cursor), next + 4 <= packet.count else { return nil }
            cursor = next + 4
        }

        guard let (_, afterName) = readDnsName(from: packet, offset: cursor), afterName + 10 < packet.count else { return nil }
        let rdlen = Int((UInt16(packet[afterName + 8]) << 8) | UInt16(packet[afterName + 9]))
        let rdataStart = afterName + 10
        guard rdataStart < packet.count, rdataStart + rdlen <= packet.count else { return nil }

        let numNames = Int(packet[rdataStart])
        var pos = rdataStart + 1
        var fallbackName: String? = nil

        for _ in 0..<min(numNames, 32) {
            guard pos + 18 <= packet.count else { break }
            let rawName = String(decoding: packet[pos..<(pos + 15)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.controlCharacters))
            let suffix = packet[pos + 15]
            let flags = (UInt16(packet[pos + 16]) << 8) | UInt16(packet[pos + 17])
            pos += 18

            let isGroup = (flags & 0x8000) != 0
            guard !isGroup, !rawName.isEmpty, !rawName.hasPrefix("__MSBROWSE__") else { continue }
            if suffix == 0x00 { return rawName }
            if suffix == 0x20 && fallbackName == nil { fallbackName = rawName }
        }
        return fallbackName
    }

    nonisolated private static func cleanHostname(_ raw: String, extraSuffixes: [String] = []) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") {
            host.removeLast()
        }
        let allSuffixes = ([".localdomain", ".local", ".lan", ".home", ".arpa"] + extraSuffixes)
            .sorted { $0.count > $1.count }
        for suffix in allSuffixes {
            let lowSuffix = suffix.lowercased()
            if !lowSuffix.isEmpty && host.lowercased().hasSuffix(lowSuffix) && host.count > lowSuffix.count {
                host = String(host.dropLast(lowSuffix.count))
                break
            }
        }
        // Collapse repeated `<A>.<A>` labels (e.g. `GT-BN96X.GT-BN96X` -> `GT-BN96X`)
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 2 && !labels[0].isEmpty && labels[0].lowercased() == labels[1].lowercased() {
            host = String(labels[0])
        }
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count >= 2 else { return nil }
        if isValidIPv4(host) { return nil }
        let lower = host.lowercased()
        if lower == "localhost" || lower == "in-addr" || lower == "ip6" { return nil }
        return host
    }

    nonisolated private static func extractReportFromServiceInstance(_ full: String) -> LanPeerSelfReport? {
        guard let range = full.range(of: "._", options: .caseInsensitive) else { return nil }
        var instance = String(full[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let svcTail = String(full[range.lowerBound...]).lowercased()

        // 剥离 AirPlay / RAOP 前缀如 "A1B2C3D4E5F6@客厅音响"
        if let atIdx = instance.firstIndex(of: "@") {
            let prefixPart = instance[..<atIdx]
            if prefixPart.count == 12 && prefixPart.allSatisfy({ $0.isHexDigit }) {
                instance = String(instance[instance.index(after: atIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 小米 _miio._udp 实例名通常形如 "zhimi-airpurifier-mb4_miio123456"
        if svcTail.contains("._miio.") {
            let cleanModel = instance.components(separatedBy: "_miio").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let validName = (cleanModel?.isEmpty == false) ? cleanModel : nil
            return LanPeerSelfReport(
                friendlyName: validName,
                manufacturer: "Xiaomi",
                model: validName,
                iconHint: "sensor.tag.radiowaves.forward"
            )
        }

        let cleanInst = (instance.isEmpty || instance.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "-" }) ? nil : instance
        var manufacturer: String? = nil
        var icon: String? = nil
        if svcTail.contains("._airplay.") || svcTail.contains("._companion-link.") || svcTail.contains("._raop.") {
            icon = "apple.logo"
        } else if svcTail.contains("._ipp.") || svcTail.contains("._printer.") {
            icon = "printer.fill"
        } else if svcTail.contains("._smb.") {
            icon = "externaldrive.connected.to.line.below"
        } else if svcTail.contains("._googlecast.") {
            manufacturer = "Google"
            icon = "tv.fill"
        } else if svcTail.contains("._hap.") {
            icon = "house.fill"
        }

        guard cleanInst != nil || manufacturer != nil else { return nil }
        return LanPeerSelfReport(friendlyName: cleanInst, manufacturer: manufacturer, iconHint: icon)
    }

    nonisolated private static func readableAppleModel(_ model: String) -> String {
        let low = model.lowercased()
        if low.hasPrefix("audioaccessory") { return "HomePod" }
        if low.hasPrefix("appletv") { return "Apple TV" }
        if low.hasPrefix("macbookpro") { return "MacBook Pro" }
        if low.hasPrefix("macbookair") { return "MacBook Air" }
        if low.hasPrefix("macmini") { return "Mac mini" }
        if low.hasPrefix("macstudio") { return "Mac Studio" }
        if low.hasPrefix("imac") { return "iMac" }
        if low.hasPrefix("iphone") { return "iPhone" }
        if low.hasPrefix("ipad") { return "iPad" }
        return model
    }

    nonisolated private static func extractXmlTag(_ tag: String, from xml: String) -> String? {
        let token = "<\(tag)"
        var searchStart = xml.startIndex
        while searchStart < xml.endIndex,
              let openStart = xml.range(of: token, options: .caseInsensitive, range: searchStart..<xml.endIndex) {
            if openStart.upperBound < xml.endIndex {
                let nextChar = xml[openStart.upperBound]
                if nextChar != ">" && !nextChar.isWhitespace && nextChar != "/" {
                    searchStart = openStart.upperBound
                    continue
                }
            }
            guard let tagEnd = xml[openStart.upperBound...].firstIndex(of: ">") else {
                return nil
            }
            let valueStart = xml.index(after: tagEnd)
            guard let closeRange = xml.range(of: "</\(tag)>", options: .caseInsensitive, range: valueStart..<xml.endIndex) else {
                return nil
            }
            var raw = String(xml[valueStart..<closeRange.lowerBound])
            raw = raw
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    nonisolated private static func isMeaningfulDeviceName(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return false
        }
        let low = v.lowercased()
        let genericNames: Set<String> = [
            "linux", "unix", "upnp", "device", "unknown", "none", "null", "na", "n/a", "root", "localhost"
        ]
        return !genericNames.contains(low)
    }

    nonisolated private static func iconHintFromUpnpDeviceType(_ deviceType: String?) -> String? {
        guard let dt = deviceType?.lowercased() else { return nil }
        if dt.contains("internetgateway") || dt.contains("wandevice") || dt.contains("router") {
            return "wifi.router"
        }
        if dt.contains("mediarenderer") || dt.contains("tv") {
            return "tv.fill"
        }
        if dt.contains("mediaserver") {
            return "externaldrive.connected.to.line.below"
        }
        if dt.contains("printer") || dt.contains("scanner") {
            return "printer.fill"
        }
        return nil
    }

    nonisolated private static func inferVendorFromText(_ text: String) -> String? {
        let low = text.lowercased()
        let pairs: [(String, String)] = [
            ("apple", "Apple"), ("macbook", "Apple"), ("iphone", "Apple"), ("ipad", "Apple"), ("homepod", "Apple"),
            ("mac studio", "Apple"), ("mac mini", "Apple"), ("imac", "Apple"), ("mac1", "Apple"), ("bunnys-", "Apple"),
            ("sony", "Sony"), ("playstation", "Sony"),
            ("synology", "Synology"), ("qnap", "QNAP"),
            ("asus", "ASUS"), ("merlin", "ASUS"),
            ("xiaomi", "Xiaomi"), ("mijia", "Xiaomi"), ("redmi", "Xiaomi"), ("zhimi", "Xiaomi"),
            ("mismart", "Xiaomi"), ("midjd", "Xiaomi"), ("chunmi", "Xiaomi"), ("dmaker", "Xiaomi"),
            ("zimi", "Xiaomi"), ("cuco", "Xiaomi"), ("yeelink", "Xiaomi"), ("_mibt", "Xiaomi"),
            ("mjxdd", "Xiaomi"), ("mjtd", "Xiaomi"), ("roborock", "Roborock"),
            ("aqara", "Aqara"), ("lumi", "Aqara"), ("ktbl", "Aqara"), ("zhwg", "Aqara"), ("znsxj", "Aqara"),
            ("narwal", "Narwal"),
            ("huawei", "Huawei"), ("honor", "Honor"),
            ("tp-link", "TP-Link"), ("sonos", "Sonos"),
            ("nintendo", "Nintendo"), ("samsung", "Samsung"), ("lg ", "LG"), ("lgwebos", "LG"),
            ("google", "Google"), ("amazon", "Amazon"), ("microsoft", "Microsoft"), ("surface", "Microsoft"),
            ("hikvision", "Hikvision"), ("ezviz", "EZVIZ"), ("dahua", "Dahua"),
            ("hp ", "HP"), ("epson", "Epson"), ("brother", "Brother"), ("canon", "Canon"),
            ("ireader", "iReader"), ("zhangyue", "iReader"), ("ocean-", "iReader")
        ]
        for (needle, brand) in pairs where low.contains(needle) {
            return brand
        }
        return nil
    }

    nonisolated private static func shortenReportedManufacturer(_ raw: String) -> String {
        if let known = inferVendorFromText(raw) {
            return known
        }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [", Inc.", ", Inc", " Inc.", " Inc", " Co., Ltd.", " Co.,Ltd.", " Co., Ltd", " Ltd.", " Ltd", " Corporation", " Corp.", " LLC", " GmbH", " Technology"] {
            if let r = s.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if s.count > 20 {
            s = String(s.prefix(20)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? raw : s
    }

    nonisolated private static func inferIconFromSelfReport(_ report: LanPeerSelfReport, defaultIcon: String) -> String {
        if let hint = report.iconHint, !hint.isEmpty {
            return hint
        }
        let combined = [report.friendlyName, report.model, report.hostname]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if combined.contains("iphone") { return "iphone" }
        if combined.contains("ipad") { return "ipad" }
        if combined.contains("watch") { return "applewatch" }
        if combined.contains("macbook") || combined.contains("macbookpro") || combined.contains("macbookair") || combined.contains("surface") { return "laptopcomputer" }
        if combined.contains("imac") || combined.contains("macmini") || combined.contains("mac mini") || combined.contains("macstudio") || combined.contains("mac studio") || combined.contains("mac-pro") || combined.contains("desktop-") || combined.contains("win-") {
            return "desktopcomputer"
        }
        if combined.contains("homepod") { return "homepod.fill" }
        if combined.contains("appletv") || combined.contains("apple-tv") || combined.contains("bravia") || combined.contains("webos") || combined.contains("tv") {
            return "tv.fill"
        }
        if combined.contains("synology") || combined.contains("qnap") || combined.contains("nas") {
            return "externaldrive.connected.to.line.below"
        }
        if combined.contains("printer") || combined.contains("laserjet") || combined.contains("epson") || combined.contains("brother") {
            return "printer.fill"
        }
        if combined.contains("router") || combined.contains("rt-") || combined.contains("ax") || combined.contains("openwrt") {
            return "wifi.router"
        }
        if combined.contains("camera") || combined.contains("cam") || combined.contains("ipc") {
            return "video.fill"
        }
        if combined.contains("ocean-") || combined.contains("ireader") || combined.contains("kindle") || combined.contains("boox") {
            return "book.fill"
        }
        return defaultIcon
    }

    /// 权威 IEEE OUI + 多协议自报信息融合识别（绝不凭错误 OUI 猜测终端类别）
    nonisolated public static func identifyDevice(
        ip: String,
        mac: String,
        isGateway: Bool,
        isLocal: Bool,
        localName: String = "",
        ddp: PlayStationDDPInfo? = nil,
        selfReport: LanPeerSelfReport? = nil
    ) -> (name: String, vendor: String, icon: String) {
        let ouiMatch = LanOuiDatabase.shared.lookup(mac)

        if isGateway {
            let vendor = selfReport?.manufacturer.flatMap { isMeaningfulDeviceName($0) ? shortenReportedManufacturer($0) : nil }
                ?? ouiMatch?.shortVendor
                ?? "Router"

            let name: String
            if let friendly = selfReport?.friendlyName, isMeaningfulDeviceName(friendly) {
                name = friendly
            } else if let model = selfReport?.model, isMeaningfulDeviceName(model) {
                name = model
            } else if let ouiMatch, !ouiMatch.isLocallyAdministered {
                name = "\(ouiMatch.shortVendor) 路由器"
            } else {
                name = "默认网关路由器"
            }
            return (name, vendor, "network.badge.shield.half.filled")
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

        // 优先采信设备主动自报的名称、型号与厂商
        if let report = selfReport {
            let primaryName = [report.friendlyName, report.model, report.hostname]
                .compactMap { $0 }
                .first { isMeaningfulDeviceName($0) }

            let reportedVendor: String? = {
                if let mfg = report.manufacturer, isMeaningfulDeviceName(mfg) {
                    return shortenReportedManufacturer(mfg)
                }
                let hintText = [report.friendlyName, report.model, report.hostname]
                    .compactMap { $0 }
                    .joined(separator: " ")
                if !hintText.isEmpty {
                    return inferVendorFromText(hintText)
                }
                return nil
            }()

            if let primaryName {
                let finalVendor: String
                if let reportedVendor {
                    finalVendor = reportedVendor
                } else if isPortalOUI(mac) || isSonyOUI(mac) {
                    finalVendor = "Sony"
                } else if let ouiMatch {
                    finalVendor = ouiMatch.shortVendor
                } else {
                    finalVendor = "未知厂商"
                }

                let defaultIcon = ouiMatch?.suggestedIcon ?? "network"
                let finalIcon = inferIconFromSelfReport(report, defaultIcon: defaultIcon)
                return (primaryName, finalVendor, finalIcon)
            }
        }

        // 无设备自报时，严格回退至 Sony 专用 OUI 与权威 5.4 万条 IEEE OUI 库
        if isPortalOUI(mac) {
            return ("PlayStation Portal", "Sony", "gamecontroller")
        }
        if isSonyOUI(mac) {
            return ("PlayStation 终端", "Sony", "gamecontroller.fill")
        }

        if let ouiMatch {
            let reportedOnlyVendor = selfReport?.manufacturer.flatMap { isMeaningfulDeviceName($0) ? shortenReportedManufacturer($0) : nil }
            return (ouiMatch.displayName, reportedOnlyVendor ?? ouiMatch.shortVendor, ouiMatch.suggestedIcon)
        }

        let normPrefix = (LanOuiDatabase.normalizeMAC(mac) ?? mac).prefix(8).uppercased()
        return ("未知设备 (\(normPrefix))", "未知厂商", "network")
    }

    // MARK: - 自定义编辑交互方法

    public func startEditing(dev: LanDeviceItem) {
        self.editingMAC = dev.mac
        self.editingNameInput = dev.name
        self.editingVendorInput = dev.vendor
        self.applyVendorRuleToAll = false
        self.showPresetIconPicker = false
    }

    public func cancelEditing() {
        self.editingMAC = nil
        self.editingNameInput = ""
        self.editingVendorInput = ""
        self.applyVendorRuleToAll = false
        self.showPresetIconPicker = false
    }

    public func saveEditingName() {
        guard let mac = editingMAC else { return }
        let targetDev = discoveredDevices.first(where: { $0.mac == mac })
        LanDeviceMetadataManager.shared.setCustomNameAndVendor(
            for: mac,
            name: editingNameInput,
            vendor: editingVendorInput,
            defaultName: targetDev?.defaultName,
            defaultVendor: targetDev?.defaultVendor ?? "",
            applyRuleToVendor: applyVendorRuleToAll
        )
        let ruleNotice = applyVendorRuleToAll && !(targetDev?.defaultVendor.isEmpty ?? true) && targetDev?.defaultVendor != "未知厂商"
            ? " · 已保存全局厂商映射规则"
            : ""
        self.editingMAC = nil
        self.editingNameInput = ""
        self.editingVendorInput = ""
        self.applyVendorRuleToAll = false
        self.showPresetIconPicker = false
        showNotice("已保存设备信息\(ruleNotice)", duration: 2.2)
    }

    public func addVendorRuleFromInputs() {
        let matchKey = ruleMatchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetVendor = ruleTargetInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !matchKey.isEmpty, !targetVendor.isEmpty else {
            showNotice("请输入原厂商名称/MAC 前缀以及目标厂商名称", duration: 2.2)
            return
        }
        LanDeviceMetadataManager.shared.addOrUpdateVendorRule(matchKey: matchKey, targetVendor: targetVendor)
        self.ruleMatchInput = ""
        self.ruleTargetInput = ""
        showNotice("已添加厂商规则：\(matchKey) → \(targetVendor)", duration: 2.4)
    }

    public func removeVendorRule(_ rule: VendorMappingRule) {
        LanDeviceMetadataManager.shared.removeVendorRule(matchKey: rule.matchKey)
        showNotice("已移除厂商规则：\(rule.matchKey)", duration: 2.0)
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
        self.editingVendorInput = ""
        self.applyVendorRuleToAll = false
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
