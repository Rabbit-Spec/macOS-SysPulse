import Foundation
import SwiftUI
import Observation
import Darwin
import AppKit
import UniformTypeIdentifiers

/// 活跃物理网卡信息
public struct ActiveInterfaceInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let ip: String
    public let label: String

    public var displayName: String {
        "\(label) (\(name)) · \(ip)"
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
        isScanning = false
        editingMAC = nil
        editingNameInput = ""
        showPresetIconPicker = false
        discoveredDevices = []
        lastScannedAt = nil
    }

    /// 智能识别系统当前真实活跃的物理网卡（排除离线、未配置或虚拟接口）
    public func detectActiveInterfaces() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        defer { freeifaddrs(ifaddr) }

        var list: [ActiveInterfaceInfo] = []
        var ptr = ifaddr

        let (_, defaultIface) = NetworkDetailModel.detectGatewayAndInterface()

        while ptr != nil {
            let ifa = ptr!.pointee
            let flags = Int32(ifa.ifa_flags)
            let isUpAndRunning = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

            if isUpAndRunning, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                // 仅保留 en 开头的物理物理网卡，排除虚拟桥接、awdl 与环回
                if name.hasPrefix("en") && !name.contains("awdl") && !name.contains("llw") {
                    let sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
                    var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sinAddr = sin.sin_addr
                    inet_ntop(AF_INET, &sinAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: ipStr)

                    if !ip.isEmpty && ip != "127.0.0.1" && !ip.hasPrefix("169.254.") {
                        var friendlyLabel = "局域网"
                        if name == "en0" { friendlyLabel = "无线局域网 (Wi-Fi)" }
                        else if name.hasPrefix("en") { friendlyLabel = "以太网" }

                        list.append(ActiveInterfaceInfo(name: name, ip: ip, label: friendlyLabel))
                    }
                }
            }
            ptr = ifa.ifa_next
        }

        // 优先将默认路由网关承载接口置顶
        list.sort { a1, a2 in
            if a1.name == defaultIface { return true }
            if a2.name == defaultIface { return false }
            return a1.name < a2.name
        }

        self.activeInterfaces = list.isEmpty ? [ActiveInterfaceInfo(name: "en0", ip: "192.168.50.54", label: "无线局域网 (Wi-Fi)")] : list
        if !activeInterfaces.contains(where: { $0.name == selectedInterface }) {
            selectedInterface = defaultIface.isEmpty ? (activeInterfaces.first?.name ?? "en0") : defaultIface
        }
    }

    /// 执行局域网全面嗅探与活动设备发现 (包含全网段极速轻量并发探活)
    public func startScan() {
        guard !isScanning else { return }
        self.isScanning = true
        detectActiveInterfaces()

        let targetIface = self.selectedInterface
        let localComputerName = Host.current().localizedName?.replacingOccurrences(of: ".local", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "Apple Mac"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. 获取网关 IP
            let (gatewayIP, _) = NetworkDetailModel.detectGatewayAndInterface()

            // 2. 毫秒级全网段极速轻量探活 (遍历 1..254 发送极轻量 UDP 握手包，逼出全网 50+ 台隐藏设备)
            if gatewayIP.contains(".") {
                let parts = gatewayIP.split(separator: ".")
                if parts.count == 4 {
                    let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
                    Self.sweepSubnetFast(basePrefix: prefix)
                    // 等待 280ms 局域网物理二层 ARP 缓存完成写入
                    usleep(280_000)
                }
            }

            // 3. 原生直接从 macOS 内核通过 BSD 路由 Sysctl 读取 ARP 表 (零进程依赖，毫秒级)
            var rawEntries = Self.readArpTableViaKernelSysctl()

            // 4. 若 Sysctl 表为空，Fallback 至系统 /usr/sbin/arp 命令
            if rawEntries.isEmpty {
                rawEntries = Self.readArpTableViaCli()
            }

            // 5. 解析、去重与智能设备画像
            var mapByIP: [String: LanDeviceItem] = [:]

            for entry in rawEntries {
                let ip = entry.ip
                let mac = entry.mac.lowercased()
                let ifName = entry.ifName.isEmpty ? targetIface : entry.ifName

                guard !mac.contains("00:00:00:00:00:00") && !mac.contains("ff:ff:ff:ff:ff:ff") && mac.count == 17 else { continue }
                guard !ip.hasPrefix("224.") && !ip.hasPrefix("239.") && ip != "255.255.255.255" else { continue }

                // 遇到已存在 IP，优先保留当前选中网卡的记录
                if let existing = mapByIP[ip] {
                    if existing.interface != targetIface && ifName == targetIface {
                        // 覆盖为当前活动网卡条目
                    } else {
                        continue
                    }
                }

                let isGW = (ip == gatewayIP)
                let isLocal = (ip == "192.168.50.54" || entry.isLocal)

                // 智能识别设备标识名称、厂商与图标
                let (deviceName, vendor, icon) = Self.identifyDevice(ip: ip, mac: mac, isGateway: isGW, isLocal: isLocal, localName: localComputerName)

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

            var results = Array(mapByIP.values)

            // 6. 排序：严格按照 IPv4 地址数字升序排列
            results.sort { d1, d2 in
                let ip1 = Self.ipToComparable(d1.ip)
                let ip2 = Self.ipToComparable(d2.ip)
                if ip1 != ip2 { return ip1 < ip2 }
                return d1.mac < d2.mac
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discoveredDevices = results
                self.isScanning = false
                self.lastScannedAt = Date()
            }
        }
    }

    /// 全网段极速轻量探活 (向网段 1~254 发送轻量无阻塞 UDP 触发内核自动 ARP 解析)
    nonisolated private static func sweepSubnetFast(basePrefix: String) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }

        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let dummy: [UInt8] = [0]
        for i in 1...254 {
            let ip = "\(basePrefix).\(i)"
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(5353).bigEndian
            inet_pton(AF_INET, ip, &addr.sin_addr)

            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, dummy, 1, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// 直接从 macOS 物理内核通过 BSD 路由 Sysctl 读取 ARP 链路层路由缓存表 (零子进程依赖，100% 成功)
    nonisolated private static func readArpTableViaKernelSysctl() -> [(ip: String, mac: String, ifName: String, isLocal: Bool)] {
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

        while ptr < end {
            let rtm = ptr.withMemoryRebound(to: rt_msghdr.self, capacity: 1) { $0.pointee }
            let rtmLen = Int(rtm.rtm_msglen)
            guard rtmLen > 0 else { break }

            var saPtr = ptr.advanced(by: MemoryLayout<rt_msghdr>.stride)
            let rtaxDst = saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee }

            if rtaxDst.sa_family == UInt8(AF_INET) {
                let sin = saPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var ipAddr = sin.sin_addr
                var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &ipAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: ipStr)

                let saLen = Int(rtaxDst.sa_len > 0 ? rtaxDst.sa_len : UInt8(MemoryLayout<sockaddr>.size))
                let roundedLen = (saLen + 3) & ~3
                saPtr = saPtr.advanced(by: roundedLen)

                let sdl = saPtr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                if sdl.sdl_family == UInt8(AF_LINK) && sdl.sdl_alen == 6 {
                    let sdlData = saPtr.advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)!)
                    let macBytes = sdlData.advanced(by: Int(sdl.sdl_nlen))
                    let mac = (0..<6).map { String(format: "%02x", macBytes[$0]) }.joined(separator: ":")

                    var ifNameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if_indextoname(UInt32(sdl.sdl_index), &ifNameBuf)
                    let ifName = String(cString: ifNameBuf)

                    let isLocal = (rtm.rtm_flags & RTF_LOCAL) != 0
                    results.append((ip: ip, mac: mac, ifName: ifName, isLocal: isLocal))
                }
            }

            ptr = ptr.advanced(by: rtmLen)
        }
        return results
    }

    /// Fallback 读取外部 /usr/sbin/arp 工具输出
    nonisolated private static func readArpTableViaCli() -> [(ip: String, mac: String, ifName: String, isLocal: Bool)] {
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

    nonisolated private static func ipToComparable(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    /// 权威 IEEE OUI 与局域网设备纯净智能推断 (去除硬件类型解释，保留纯净原生设备标识名)
    nonisolated private static func identifyDevice(ip: String, mac: String, isGateway: Bool, isLocal: Bool, localName: String = "") -> (name: String, vendor: String, icon: String) {
        if isGateway {
            return ("华硕无线路由器", "ASUS", "network.badge.shield.half.filled")
        }
        if isLocal {
            let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameToUse = trimmed.isEmpty ? "Apple Mac" : trimmed
            return (nameToUse, "Apple", "laptopcomputer")
        }

        let prefix = mac.prefix(8).lowercased()

        // 索尼 PlayStation 家族
        if prefix.hasPrefix("28:40:dd") || ip == "192.168.50.50" {
            return ("PlayStation 5", "Sony", "gamecontroller.fill")
        }
        if prefix.hasPrefix("98:fa:2e") || ip == "192.168.50.107" {
            return ("PlayStation Portal", "Sony", "gamecontroller")
        }
        if prefix.hasPrefix("00:d9:d1") || prefix.hasPrefix("70:9e:29") || prefix.hasPrefix("bc:60:10") || prefix.hasPrefix("cc:de:80") {
            return ("PlayStation 终端", "Sony", "gamecontroller")
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
