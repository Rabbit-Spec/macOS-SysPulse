import Foundation
import Observation
import AppKit

public enum TrafficTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "今日"
    case month = "本月"

    public var id: String { rawValue }
}

public enum AppRankingSubTab: String, CaseIterable, Identifiable, Sendable {
    case apps = "应用流量排行"
    case sockets = "活跃连接数详情"

    public var id: String { rawValue }
}

@Observable
@MainActor
public final class NetworkMonitorViewModel {
    public static let shared = NetworkMonitorViewModel()

    public enum AppTrafficSortMode: String, CaseIterable, Identifiable {
        case today = "按当日累计流量排序"
        case month = "按当月累计流量排序"
        public var id: String { rawValue }
    }

    public var selectedTimeRange: TrafficTimeRange = .today
    public var selectedRankingTab: AppRankingSubTab = .apps
    public var appTrafficSortMode: AppTrafficSortMode = .today

    // 24-Hour Traffic Data (0:00 - 23:00) in MB
    public private(set) var hourlyTrafficMB: [Double] = Array(repeating: 0.0, count: 24)

    public var peakHourIndex: Int {
        let curHour = Calendar.current.component(.hour, from: Date())
        let slice = hourlyTrafficMB.prefix(curHour + 1)
        return slice.indices.max(by: { slice[$0] < slice[$1] }) ?? curHour
    }

    public var peakHourVolumeFormatted: String {
        let curHour = Calendar.current.component(.hour, from: Date())
        let slice = hourlyTrafficMB.prefix(curHour + 1)
        let maxMB = slice.max() ?? 0.0
        if maxMB >= 1024.0 {
            return String(format: "今日峰值时段: %02d:00 (%.1f GB)", peakHourIndex, maxMB / 1024.0)
        } else if maxMB >= 1.0 {
            return String(format: "今日峰值时段: %02d:00 (%.0f MB)", peakHourIndex, maxMB)
        } else {
            return "今日时段分布平稳"
        }
    }

    // Ping / Latency Metrics
    public var internetPingMs: Int = 0
    public var routerPingMs: Int = 0
    public var dnsPingMs: Int = 0
    public var routerPingText: String = "--"
    public var dnsPingText: String = "--"
    public var pingStatusText: String = "测量中…"
    public var isMeasuringLatency: Bool = false
    public var isSpeedTestCardActive: Bool = false

    // Socket Connections & Network Hardware
    public var activeSocketCount: Int = 0
    public var activeProcessCount: Int = 0
    public var activeInterfaceCount: Int = 1
    public var packetLossPercent: Double = 0.0

    // 动态评估连接健康度（通常桌面级活跃连接在 50~350 之间，超过 500 连接视为偏高/异常）
    public var isConnectionCountNormal: Bool {
        activeSocketCount <= 500
    }

    public var connectionStatusText: String {
        isConnectionCountNormal ? "连接数正常" : "连接数异常"
    }

    // Traffic Totals
    public var todayDownloadGB: Double = 0.0
    public var todayUploadGB: Double = 0.0
    public var monthDownloadGB: Double = 0.0
    public var monthUploadGB: Double = 0.0

    public var currentTotalNumberFormatted: String {
        let totalGB = selectedTimeRange == .today ? (todayDownloadGB + todayUploadGB) : (monthDownloadGB + monthUploadGB)
        if totalGB >= 1.0 {
            return totalGB >= 10.0 ? String(format: "%.1f", totalGB) : String(format: "%.2f", totalGB)
        } else {
            let mb = totalGB * 1024.0
            return mb >= 10.0 ? String(format: "%.0f", mb) : String(format: "%.1f", max(0.0, mb))
        }
    }

    public var currentTotalUnitText: String {
        let totalGB = selectedTimeRange == .today ? (todayDownloadGB + todayUploadGB) : (monthDownloadGB + monthUploadGB)
        return totalGB >= 1.0 ? "GB 传输总量" : "MB 传输总量"
    }

    public var currentTotalGBFormatted: String {
        currentTotalNumberFormatted
    }

    public var currentDownloadFormatted: String {
        let d = selectedTimeRange == .today ? todayDownloadGB : monthDownloadGB
        if d >= 1.0 {
            return String(format: "%.1f GB", d)
        } else if d >= 0.001 {
            return String(format: "%.0f MB", d * 1024.0)
        } else {
            return "0 MB"
        }
    }

    public var currentUploadFormatted: String {
        let u = selectedTimeRange == .today ? todayUploadGB : monthUploadGB
        if u >= 1.0 {
            return String(format: "%.1f GB", u)
        } else if u >= 0.001 {
            return String(format: "%.0f MB", u * 1024.0)
        } else {
            return "0 MB"
        }
    }

    public var currentDownloadRatio: Double {
        let d = selectedTimeRange == .today ? todayDownloadGB : monthDownloadGB
        let u = selectedTimeRange == .today ? todayUploadGB : monthUploadGB
        let total = d + u
        return total > 0.0001 ? (d / total) : 0.50
    }

    public var currentUploadRatio: Double {
        let d = selectedTimeRange == .today ? todayDownloadGB : monthDownloadGB
        let u = selectedTimeRange == .today ? todayUploadGB : monthUploadGB
        let total = d + u
        return total > 0.0001 ? (u / total) : 0.50
    }

    private var lastTrafficPollTime: Date = Date.distantPast

    private init() {
        let snapshot = NetworkTrafficPersistenceManager.shared.currentSnapshot()
        applyTrafficSnapshot(snapshot)
    }

    public func refreshStats(gatewayIP: String? = nil, iface: String? = nil) {
        refreshSocketsAndInterfaces()
        refreshRealTraffic(iface: iface)
        measureRealLatencies(gatewayIP: gatewayIP)
    }

    // MARK: - 1. Real Latency Measurements (ping 网关 + 互联网 generate_204 + DNS 解析)

    public func measureRealLatencies(gatewayIP: String? = nil) {
        guard !isMeasuringLatency else { return }
        isMeasuringLatency = true

        let requestedGW = gatewayIP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetGW = (!requestedGW.isEmpty && requestedGW != "获取中…" && requestedGW != "暂无")
            ? requestedGW
            : NetworkDetailModel.detectGatewayAndInterface().gateway
        let dnsServers = NetworkDetailModel.detectDNSServers()

        Task.detached(priority: .userInitiated) {
            // 1. 路由网关 Ping (优先通过 ICMP 实测网关物理时延与丢包率，备用 TCP RTT)
            let pingRes = Self.measureICMPPing(host: targetGW)
            let gwMeasured: Double? = pingRes.avg ?? Self.measureTCPRTT(host: targetGW, port: 53, timeoutSec: 0.5).map(Double.init)
            let formattedGW: String = {
                guard let gwVal = gwMeasured, gwVal > 0 else { return "--" }
                return gwVal < 10.0 ? String(format: "%.1f", max(0.5, gwVal)) : String(format: "%.0f", gwVal)
            }()
            let gwRoundedMs = gwMeasured.map { max(1, Int(round($0))) } ?? 0
            let loss = pingRes.loss ?? 0.0

            // 2. DNS 解析时延 (发送真实 UDP 53 数据包探测 DNS 服务器响应耗时，绕过本地 mDNS 内存缓存)
            let dnsMeasured = Self.measureRealUDPResolutionTime(servers: dnsServers)
            let formattedDNS: String = {
                guard let dnsVal = dnsMeasured, dnsVal > 0 else { return "--" }
                return dnsVal < 10.0 ? String(format: "%.1f", max(1.0, dnsVal)) : String(format: "%.0f", dnsVal)
            }()
            let dnsRoundedMs = dnsMeasured.map { max(1, Int(round($0))) } ?? 0

            // 3. 互联网延迟 (测试 URL: https://connectivitycheck.platform.hicloud.com/generate_204)
            let httpRTT = await Self.measureHTTPLatency(urlString: "https://connectivitycheck.platform.hicloud.com/generate_204")

            let status: String
            if httpRTT <= 0 {
                status = "未连接"
            } else if httpRTT <= 25 {
                status = "极低抖动 · 毫秒响应"
            } else if httpRTT <= 60 {
                status = "链路通畅 · 良好"
            } else if httpRTT <= 120 {
                status = "延迟中等"
            } else {
                status = "延迟偏高"
            }

            await MainActor.run {
                self.routerPingMs = gwRoundedMs
                self.dnsPingMs = dnsRoundedMs
                self.routerPingText = formattedGW
                self.dnsPingText = formattedDNS
                self.internetPingMs = httpRTT
                self.packetLossPercent = loss
                self.pingStatusText = status
                self.isMeasuringLatency = false
            }
        }
    }

    nonisolated private static func measureICMPPing(host: String) -> (avg: Double?, loss: Double?) {
        guard !host.isEmpty, host != "127.0.0.1" else { return (nil, nil) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ping")
        task.arguments = ["-c", "2", "-W", "800", host]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            var avgMs: Double? = nil
            var lossVal: Double? = nil
            if let output = String(data: data, encoding: .utf8) {
                if let lossRange = output.range(of: "% packet loss") {
                    let sub = output[..<lossRange.lowerBound]
                    if let lastComma = sub.lastIndex(of: ",") {
                        let numStr = sub[sub.index(after: lastComma)...].trimmingCharacters(in: .whitespaces)
                        if let l = Double(numStr) {
                            lossVal = l
                        }
                    }
                }
                if let avgRange = output.range(of: "min/avg/max") {
                    let sub = output[avgRange.lowerBound...]
                    if let eqRange = sub.range(of: "= ") {
                        let numbers = sub[eqRange.upperBound...].components(separatedBy: " ")[0]
                        let parts = numbers.split(separator: "/")
                        if parts.count >= 2, let avg = Double(parts[1]) {
                            avgMs = avg
                        }
                    }
                } else if let tRange = output.range(of: "time=") {
                    let sub = output[tRange.upperBound...]
                    if let msRange = sub.range(of: " ms") {
                        if let val = Double(sub[..<msRange.lowerBound].trimmingCharacters(in: .whitespaces)) {
                            avgMs = val
                        }
                    }
                }
            }
            return (avgMs, lossVal)
        } catch {
            return (nil, nil)
        }
    }

    nonisolated private static func measureRealUDPResolutionTime(servers: [String]) -> Double? {
        // 排除局域网路由网关(192.168.*, 10.*, 172.16-31.*)与 Fake-IP(198.18.*)，优先实测互联网公网递归 DNS 节点
        let externalServers = servers.filter {
            !$0.hasPrefix("198.18.") &&
            !$0.hasPrefix("192.168.") &&
            !$0.hasPrefix("10.") &&
            !$0.hasPrefix("172.") &&
            !$0.hasPrefix("127.") &&
            !$0.isEmpty
        }
        let candidateList = externalServers + ["223.5.5.5", "119.29.29.29", "114.114.114.114"]
        for server in candidateList {
            let start = CFAbsoluteTimeGetCurrent()
            var hints = addrinfo(
                ai_flags: AI_NUMERICHOST,
                ai_family: AF_INET,
                ai_socktype: SOCK_DGRAM,
                ai_protocol: IPPROTO_UDP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(server, "53", &hints, &res) == 0, let addr = res else { continue }
            defer { freeaddrinfo(res) }
            let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            guard sock >= 0 else { continue }
            defer { close(sock) }

            // DNS header query for connectivitycheck.platform.hicloud.com
            var packet: [UInt8] = [
                0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                17
            ]
            packet.append(contentsOf: "connectivitycheck".utf8)
            packet.append(8)
            packet.append(contentsOf: "platform".utf8)
            packet.append(7)
            packet.append(contentsOf: "hicloud".utf8)
            packet.append(3)
            packet.append(contentsOf: "com".utf8)
            packet.append(0)
            packet.append(contentsOf: [0x00, 0x01, 0x00, 0x01])

            _ = sendto(sock, packet, packet.count, 0, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let p = poll(&pfd, 1, 1000)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            if p > 0 {
                var buf = [UInt8](repeating: 0, count: 512)
                let n = recv(sock, &buf, buf.count, 0)
                if n > 12 {
                    return elapsed
                }
            }
        }
        return nil
    }

    private nonisolated static let latencySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 3.0
        return URLSession(configuration: config)
    }()

    nonisolated private static func measureHTTPLatency(urlString: String = "https://connectivitycheck.platform.hicloud.com/generate_204", timeoutSec: Double = 3.0) async -> Int {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let sep = urlString.contains("?") ? "&" : "?"
        let uniqueUrlString = "\(urlString)\(sep)_t=\(timestamp)"
        guard let url = URL(string: uniqueUrlString) else { return 0 }

        var request = URLRequest(url: url, timeoutInterval: timeoutSec)
        request.httpMethod = "GET"
        request.setValue("SysPulse/1.0", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = CFAbsoluteTimeGetCurrent()
        if let (_, resp) = try? await latencySession.data(for: request),
           let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return max(1, Int(round(elapsed)))
        }
        if let tcpRTT = measureTCPRTT(host: url.host ?? "connectivitycheck.platform.hicloud.com", port: 443, timeoutSec: 1.0) {
            return tcpRTT
        }
        return 0
    }

    nonisolated private static func measureTCPRTT(host: String, port: UInt16, timeoutSec: Double = 0.6) -> Int? {
        guard !host.isEmpty && host != "127.0.0.1" else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let addr = res else {
            return nil
        }
        defer { freeaddrinfo(res) }

        let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        // Set non-blocking socket
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        _ = connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen)

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollRes = poll(&pfd, 1, Int32(timeoutSec * 1000.0))
        if pollRes > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
            // Even if port 53 is closed, receiving ECONNREFUSED (RST) means packet completed a full round-trip!
            if err == 0 || err == ECONNREFUSED {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                return max(1, Int(round(elapsed)))
            }
        }
        return nil
    }

    // MARK: - 2. Cumulative Traffic & 24h Trend

    public func refreshRealTraffic(iface: String? = nil) {
        let activeIface = iface ?? NetworkDetailModel.detectGatewayAndInterface().iface
        Task.detached(priority: .utility) {
            let (inBytes, outBytes) = Self.fetchInterfaceBytes(iface: activeIface)
            if inBytes > 0 || outBytes > 0 {
                // 1. 提交至持久化管理器，由其进行重启检测、增量累加与自然月跨越清零
                NetworkTrafficPersistenceManager.shared.recordTraffic(
                    iface: activeIface,
                    hardwareIn: inBytes,
                    hardwareOut: outBytes
                )

                let snapshot = NetworkTrafficPersistenceManager.shared.currentSnapshot()
                await MainActor.run {
                    self.applyTrafficSnapshot(snapshot)
                }
            } else {
                let snapshot = NetworkTrafficPersistenceManager.shared.currentSnapshot()
                await MainActor.run {
                    self.applyTrafficSnapshot(snapshot)
                }
            }
        }
    }

    public nonisolated static func fetchInterfaceBytes(iface: String) -> (inBytes: UInt64, outBytes: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return (0, 0)
        }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            if let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: current.pointee.ifa_name)
                if name == iface, let data = current.pointee.ifa_data {
                    let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                    return (UInt64(ifData.ifi_ibytes), UInt64(ifData.ifi_obytes))
                }
            }
            ptr = current.pointee.ifa_next
        }
        return (0, 0)
    }

    public nonisolated static func countActiveInterfaces() -> Int {
        var activeIfaces = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let current = ptr {
                let flags = Int32(current.pointee.ifa_flags)
                let name = String(cString: current.pointee.ifa_name)
                if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 && (flags & IFF_RUNNING) != 0 {
                    if let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                        let ip = String(decoding: host.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
                        if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && ip != "0.0.0.0" {
                            activeIfaces.insert(name)
                        }
                    }
                }
                ptr = current.pointee.ifa_next
            }
        }
        let physicalIfaces = activeIfaces.filter { $0.hasPrefix("en") }
        return max(1, physicalIfaces.isEmpty ? activeIfaces.count : physicalIfaces.count)
    }

    public func applySocketSummary(socketCount: Int, processCount: Int, interfaceCount: Int) {
        if socketCount > 0 {
            self.activeSocketCount = socketCount
        }
        if processCount > 0 {
            self.activeProcessCount = processCount
        }
        if interfaceCount > 0 {
            self.activeInterfaceCount = interfaceCount
        }
    }

    private func applyTrafficSnapshot(_ snapshot: NetworkTrafficPersistenceManager.TrafficTotalsSnapshot) {
        let tInGB = Double(snapshot.todayDownloadBytes) / (1024.0 * 1024.0 * 1024.0)
        let tOutGB = Double(snapshot.todayUploadBytes) / (1024.0 * 1024.0 * 1024.0)
        let mInGB = Double(snapshot.monthDownloadBytes) / (1024.0 * 1024.0 * 1024.0)
        let mOutGB = Double(snapshot.monthUploadBytes) / (1024.0 * 1024.0 * 1024.0)

        self.todayDownloadGB = tInGB
        self.todayUploadGB = tOutGB
        self.monthDownloadGB = mInGB
        self.monthUploadGB = mOutGB

        let curHour = Calendar.current.component(.hour, from: Date())
        var rawMB = snapshot.hourlyBytes.map { Double($0) / (1024.0 * 1024.0) }
        if rawMB.count < 24 {
            rawMB = Array(repeating: 0.0, count: 24)
        }
        let todayMB = (tInGB + tOutGB) * 1024.0
        let sumMB = rawMB.reduce(0, +)
        if sumMB < 0.1 && todayMB > 0 && curHour < 24 {
            rawMB[curHour] = todayMB
        }
        self.hourlyTrafficMB = rawMB
    }

    // MARK: - 3. Active Sockets & Interfaces (lsof 进程网络拓扑实时动态遥测)

    public func refreshSocketsAndInterfaces() {
        NetworkDetailModel.shared.refreshActiveSockets(syncSummaryTo: self)
    }
}
