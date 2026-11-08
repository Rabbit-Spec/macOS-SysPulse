import Foundation
import AppKit
import Darwin

/// 负责全生命周期持久化网卡流量数据，防止 macOS 重启导致统计归零。
/// 核心保证：
/// 1. 硬件网卡计数器（netstat -ib / getifaddrs）在 macOS 重启后会归零。
/// 2. 本管理器通过系统启动时间（kern.boottime）与硬件原始计数值进行对比，精确识别系统重启事件。
/// 3. 重启后将新启动周期内的增量流量自动累加至此前持久化的「今日」与「本月」累计流量中，确保数据连贯准确。
/// 4. 周期重置：每日 00:00 自动结算归零今日流量（保留本月累计）；每月 1 号 00:00 自动开启新月份累计。
/// 5. 双重持久化：Application Support JSON 文件 + UserDefaults 备份，防丢失防损坏。
public final class NetworkTrafficPersistenceManager: @unchecked Sendable {
    public static let shared = NetworkTrafficPersistenceManager()

    private let lock = NSLock()

    // 内存中实时累计数据 (以字节为单位)
    public private(set) var monthDownloadBytes: UInt64 = 0
    public private(set) var monthUploadBytes: UInt64 = 0
    public private(set) var todayDownloadBytes: UInt64 = 0
    public private(set) var todayUploadBytes: UInt64 = 0

    // 单个网卡的基准线快照
    private struct InterfaceSnapshot: Codable {
        var inBytes: UInt64
        var outBytes: UInt64
        var bootTime: Int64
    }

    // 单个应用当日流量持久化记录
    public struct AppTrafficRecord: Codable, Sendable {
        public var name: String
        public var bundleIdentifier: String?
        public var totalBytes: UInt64
        public var lastUpdated: Date

        public init(name: String, bundleIdentifier: String?, totalBytes: UInt64, lastUpdated: Date = Date()) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.totalBytes = totalBytes
            self.lastUpdated = lastUpdated
        }
    }

    // 内部持久化数据模型
    private struct PersistenceState: Codable {
        var monthKey: String              // 例如 "2026-11"
        var dayKey: String                // 例如 "2026-11-07"
        var monthDownloadBytes: UInt64
        var monthUploadBytes: UInt64
        var todayDownloadBytes: UInt64
        var todayUploadBytes: UInt64
        var hourlyBytes: [UInt64]?        // 24 小时真实吞吐分布 (0..23时)
        var appTrafficRecords: [String: AppTrafficRecord]? // 每日应用流量记录 (按 key 索引)
        var monthAppTrafficRecords: [String: AppTrafficRecord]? // 当月应用流量记录 (按 key 索引)
        var interfaceSnapshots: [String: InterfaceSnapshot]
        var lastBootTime: Int64
        var lastSavedDate: Date
    }

    private var state: PersistenceState
    private var lastDiskSaveTime: Date = Date.distantPast
    public private(set) var hourlyBytes: [UInt64] = Array(repeating: 0, count: 24)

    // MARK: - Storage Path

    private static var storageFileURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SysPulse", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("network_traffic_history.json")
    }

    // MARK: - Initialization

    private init() {
        let now = Date()
        let curMonth = Self.currentMonthKey(from: now)
        let curDay = Self.currentDayKey(from: now)
        let curBoot = Self.currentBootTime()

        // 尝试从磁盘 JSON 文件恢复
        if let loaded = Self.loadFromDisk() {
            self.state = loaded
        } else if let loadedUD = Self.loadFromUserDefaults() {
            // 降级从 UserDefaults 恢复
            self.state = loadedUD
        } else {
            // 全新状态
            self.state = PersistenceState(
                monthKey: curMonth,
                dayKey: curDay,
                monthDownloadBytes: 0,
                monthUploadBytes: 0,
                todayDownloadBytes: 0,
                todayUploadBytes: 0,
                interfaceSnapshots: [:],
                lastBootTime: curBoot,
                lastSavedDate: now
            )
        }

        // 检查加载出来的数据是否已经跨月或跨日
        if self.state.monthKey != curMonth {
            // 新月份到了（下个月 1 号 00:00）
            self.state.monthKey = curMonth
            self.state.dayKey = curDay
            self.state.monthDownloadBytes = 0
            self.state.monthUploadBytes = 0
            self.state.todayDownloadBytes = 0
            self.state.todayUploadBytes = 0
            self.state.hourlyBytes = Array(repeating: 0, count: 24)
            self.state.appTrafficRecords = [:]
            self.state.monthAppTrafficRecords = [:]
            self.state.interfaceSnapshots = [:]
            self.state.lastBootTime = curBoot
        } else if self.state.dayKey != curDay {
            // 同月但跨日，清零今日流量（保留本月累计，并重置当日小时流量与应用排行）
            self.state.dayKey = curDay
            self.state.todayDownloadBytes = 0
            self.state.todayUploadBytes = 0
            self.state.hourlyBytes = Array(repeating: 0, count: 24)
            self.state.appTrafficRecords = [:]
        } else {
            // 同日同月：彻底清洗旧版本遗留的 timed 及微小系统噪音数据
            if let records = self.state.appTrafficRecords {
                self.state.appTrafficRecords = records.filter { key, val in
                    key != "timed" && val.name.lowercased() != "timed" && val.totalBytes >= 10240
                }
            }
            if let monthRecords = self.state.monthAppTrafficRecords {
                self.state.monthAppTrafficRecords = monthRecords.filter { key, val in
                    key != "timed" && val.name.lowercased() != "timed" && val.totalBytes >= 10240
                }
            }
        }

        self.monthDownloadBytes = self.state.monthDownloadBytes
        self.monthUploadBytes = self.state.monthUploadBytes
        self.todayDownloadBytes = self.state.todayDownloadBytes
        self.todayUploadBytes = self.state.todayUploadBytes

        if let hb = self.state.hourlyBytes, hb.count == 24 {
            self.hourlyBytes = hb
        } else {
            var defaultHourly = [UInt64](repeating: 0, count: 24)
            let curHour = Calendar.current.component(.hour, from: now)
            if curHour < 24 {
                defaultHourly[curHour] = self.todayDownloadBytes + self.todayUploadBytes
            }
            self.hourlyBytes = defaultHourly
            self.state.hourlyBytes = defaultHourly
        }

        persistToDisk(force: true)

        // 注册退出与失焦通知，确保正常退出或切入后台时立即刷盘
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.persistToDisk(force: true)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.persistToDisk(force: true)
        }
    }

    // MARK: - Core Traffic Recording

    /// 记录并累计硬件网卡吞吐数据，自动识别并抵消 macOS 重启导致的归零
    public func recordTraffic(iface: String, hardwareIn: UInt64, hardwareOut: UInt64) {
        guard hardwareIn > 0 || hardwareOut > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let curMonth = Self.currentMonthKey(from: now)
        let curDay = Self.currentDayKey(from: now)
        let curBoot = Self.currentBootTime()

        // 1. 检查自然月跨越（只有到下个月 1 号 0 点 0 分才开始重新记录）
        if state.monthKey != curMonth {
            state.monthKey = curMonth
            state.dayKey = curDay
            state.monthDownloadBytes = 0
            state.monthUploadBytes = 0
            state.todayDownloadBytes = 0
            state.todayUploadBytes = 0
            state.hourlyBytes = Array(repeating: 0, count: 24)
            state.interfaceSnapshots[iface] = InterfaceSnapshot(inBytes: hardwareIn, outBytes: hardwareOut, bootTime: curBoot)
            state.lastBootTime = curBoot
            syncPublicProperties()
            persistToDisk(force: true)
            return
        }

        // 2. 检查自然日跨越（今日 0 点 0 分重置今日流量，保留本月累计）
        if state.dayKey != curDay {
            state.dayKey = curDay
            state.todayDownloadBytes = 0
            state.todayUploadBytes = 0
            state.hourlyBytes = Array(repeating: 0, count: 24)
        }

        // 3. 首次运行初始基准线迁移
        guard let prevSnapshot = state.interfaceSnapshots[iface] else {
            // 首次记录该网卡
            if state.monthDownloadBytes == 0 && state.monthUploadBytes == 0 {
                // 本月累计初始化为当前硬件已有吞吐
                state.monthDownloadBytes = hardwareIn
                state.monthUploadBytes = hardwareOut
            }

            // 检查系统是否是在今天才开机的：
            // 若今天开机，则开机以来的吞吐确实属于今日；
            // 若早已于数天前开机，硬件吞吐属于多日历史总和，今日流量从 0 起算。
            let isBootedToday = Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(curBoot)))
            if isBootedToday && state.todayDownloadBytes == 0 {
                state.todayDownloadBytes = hardwareIn
                state.todayUploadBytes = hardwareOut
            } else {
                state.todayDownloadBytes = 0
                state.todayUploadBytes = 0
            }

            state.interfaceSnapshots[iface] = InterfaceSnapshot(inBytes: hardwareIn, outBytes: hardwareOut, bootTime: curBoot)
            state.lastBootTime = curBoot
            syncPublicProperties()
            persistToDisk(force: true)
            return
        }

        // 4. 计算增量并精准识别 macOS 重启
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0

        // 判断条件：启动时间变更 或 硬件计数器发生回退归零（系统重启后网卡计数从0开始）
        let isRebooted = (curBoot != prevSnapshot.bootTime) || (hardwareIn < prevSnapshot.inBytes) || (hardwareOut < prevSnapshot.outBytes)

        if isRebooted {
            deltaIn = hardwareIn
            deltaOut = hardwareOut
        } else {
            // 正常同一次开机运行中的差值增量
            deltaIn = hardwareIn >= prevSnapshot.inBytes ? (hardwareIn - prevSnapshot.inBytes) : 0
            deltaOut = hardwareOut >= prevSnapshot.outBytes ? (hardwareOut - prevSnapshot.outBytes) : 0
        }

        // 5. 累加流量到今日与本月，并精准记录到当前自然小时
        state.todayDownloadBytes += deltaIn
        state.todayUploadBytes += deltaOut
        state.monthDownloadBytes += deltaIn
        state.monthUploadBytes += deltaOut

        if deltaIn > 0 || deltaOut > 0 {
            let curHour = Calendar.current.component(.hour, from: now)
            if curHour < 24 {
                var hb = state.hourlyBytes ?? Array(repeating: 0, count: 24)
                if hb.count < 24 { hb = Array(repeating: 0, count: 24) }
                hb[curHour] += (deltaIn + deltaOut)
                state.hourlyBytes = hb
            }
        }

        // 6. 更新基线快照
        state.interfaceSnapshots[iface] = InterfaceSnapshot(inBytes: hardwareIn, outBytes: hardwareOut, bootTime: curBoot)
        state.lastBootTime = curBoot

        syncPublicProperties()

        // 7. 磁盘保存（节流控制：有增量且间隔 >= 1秒，或增量巨大时写盘）
        if (deltaIn > 0 || deltaOut > 0) && (now.timeIntervalSince(lastDiskSaveTime) >= 1.0 || (deltaIn + deltaOut) > 500_000) {
            persistToDisk(force: false)
        }
    }

    private func syncPublicProperties() {
        self.monthDownloadBytes = state.monthDownloadBytes
        self.monthUploadBytes = state.monthUploadBytes
        self.todayDownloadBytes = state.todayDownloadBytes
        self.todayUploadBytes = state.todayUploadBytes
        self.hourlyBytes = state.hourlyBytes ?? Array(repeating: 0, count: 24)
    }

    // MARK: - App Traffic Persistence (应用流量记忆)

    public func recordAppTraffic(name: String, bundleID: String?, bytes: UInt64) {
        // 过滤微小系统噪音（小于 10 KB）以及系统级时间同步守护进程 timed
        guard bytes >= 10240, name != "timed" else { return }
        lock.lock()
        defer { lock.unlock() }
        var records = state.appTrafficRecords ?? [:]
        var monthRecords = state.monthAppTrafficRecords ?? [:]
        // 清理历史中可能存在的 timed 脏数据
        records.removeValue(forKey: "timed")
        monthRecords.removeValue(forKey: "timed")
        let key = bundleID ?? name

        // 1. 当日流量
        let prevDailyBytes = records[key]?.totalBytes ?? 0
        let delta = bytes > prevDailyBytes ? (bytes - prevDailyBytes) : 0
        if var existing = records[key] {
            existing.totalBytes = max(existing.totalBytes, bytes)
            existing.lastUpdated = Date()
            records[key] = existing
        } else {
            records[key] = AppTrafficRecord(name: name, bundleIdentifier: bundleID, totalBytes: bytes)
        }
        state.appTrafficRecords = records

        // 2. 当月累计流量 (跨天累加)
        if var mExisting = monthRecords[key] {
            mExisting.totalBytes += delta
            mExisting.lastUpdated = Date()
            monthRecords[key] = mExisting
        } else {
            let initialMonthBytes = max(bytes, prevDailyBytes)
            monthRecords[key] = AppTrafficRecord(name: name, bundleIdentifier: bundleID, totalBytes: initialMonthBytes)
        }
        state.monthAppTrafficRecords = monthRecords
    }

    public func getPersistedAppTraffic() -> [AppTrafficRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let records = state.appTrafficRecords else { return [] }
        return Array(records.values)
            .filter { $0.totalBytes >= 10240 && $0.name != "timed" }
            .sorted(by: { $0.totalBytes > $1.totalBytes })
    }

    public func getPersistedMonthAppTraffic() -> [AppTrafficRecord] {
        lock.lock()
        defer { lock.unlock() }
        var monthRecords = state.monthAppTrafficRecords ?? [:]
        // 兜底保障：融合今日实时记录，确保任何时刻切换至月排行都能展现完整准确的排序
        if let daily = state.appTrafficRecords {
            for (key, dRecord) in daily {
                if var m = monthRecords[key] {
                    if m.totalBytes < dRecord.totalBytes {
                        m.totalBytes = dRecord.totalBytes
                        monthRecords[key] = m
                    }
                } else {
                    monthRecords[key] = dRecord
                }
            }
        }
        return Array(monthRecords.values)
            .filter { $0.totalBytes >= 10240 && $0.name != "timed" }
            .sorted(by: { $0.totalBytes > $1.totalBytes })
    }

    // MARK: - Disk & UserDefaults Persistence

    public func persistToDisk(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastDiskSaveTime) < 1.0 {
            return
        }
        lastDiskSaveTime = now
        state.lastSavedDate = now

        let stateToSave = self.state

        // 1. 保存到 JSON 文件 (原子写入)
        if let data = try? JSONEncoder().encode(stateToSave) {
            try? data.write(to: Self.storageFileURL, options: .atomic)
        }

        // 2. 备份至 UserDefaults (双重保障，即使文件系统波动也能完整恢复)
        let d = UserDefaults.standard
        d.set(stateToSave.monthKey, forKey: "SP_Net_MonthKey")
        d.set(stateToSave.dayKey, forKey: "SP_Net_DayKey")
        d.set(String(stateToSave.monthDownloadBytes), forKey: "SP_Net_MonthIn")
        d.set(String(stateToSave.monthUploadBytes), forKey: "SP_Net_MonthOut")
        d.set(String(stateToSave.todayDownloadBytes), forKey: "SP_Net_TodayIn")
        d.set(String(stateToSave.todayUploadBytes), forKey: "SP_Net_TodayOut")
        d.set(stateToSave.lastBootTime, forKey: "SP_Net_LastBootTime")
        if let hb = stateToSave.hourlyBytes,
           let hbData = try? JSONEncoder().encode(hb) {
            d.set(hbData, forKey: "SP_Net_HourlyBytes")
        }
        if let apps = stateToSave.appTrafficRecords,
           let appsData = try? JSONEncoder().encode(apps) {
            d.set(appsData, forKey: "SP_Net_AppTraffic")
        }
        if let monthApps = stateToSave.monthAppTrafficRecords,
           let monthAppsData = try? JSONEncoder().encode(monthApps) {
            d.set(monthAppsData, forKey: "SP_Net_MonthAppTraffic")
        }
        d.synchronize()
    }

    private static func loadFromDisk() -> PersistenceState? {
        let fileURL = storageFileURL
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistenceState.self, from: data)
    }

    private static func loadFromUserDefaults() -> PersistenceState? {
        let d = UserDefaults.standard
        guard let monthKey = d.string(forKey: "SP_Net_MonthKey"),
              let dayKey = d.string(forKey: "SP_Net_DayKey") else {
            return nil
        }

        let mIn = UInt64(d.string(forKey: "SP_Net_MonthIn") ?? "") ?? 0
        let mOut = UInt64(d.string(forKey: "SP_Net_MonthOut") ?? "") ?? 0
        let tIn = UInt64(d.string(forKey: "SP_Net_TodayIn") ?? "") ?? 0
        let tOut = UInt64(d.string(forKey: "SP_Net_TodayOut") ?? "") ?? 0
        let boot = Int64(d.integer(forKey: "SP_Net_LastBootTime"))

        guard mIn > 0 || mOut > 0 || tIn > 0 || tOut > 0 else { return nil }

        var hourly: [UInt64]? = nil
        if let hbData = d.data(forKey: "SP_Net_HourlyBytes"),
           let decoded = try? JSONDecoder().decode([UInt64].self, from: hbData) {
            hourly = decoded
        }

        var apps: [String: AppTrafficRecord]? = nil
        if let appsData = d.data(forKey: "SP_Net_AppTraffic"),
           let decoded = try? JSONDecoder().decode([String: AppTrafficRecord].self, from: appsData) {
            apps = decoded
        }

        var monthApps: [String: AppTrafficRecord]? = nil
        if let monthAppsData = d.data(forKey: "SP_Net_MonthAppTraffic"),
           let decoded = try? JSONDecoder().decode([String: AppTrafficRecord].self, from: monthAppsData) {
            monthApps = decoded
        }

        return PersistenceState(
            monthKey: monthKey,
            dayKey: dayKey,
            monthDownloadBytes: mIn,
            monthUploadBytes: mOut,
            todayDownloadBytes: tIn,
            todayUploadBytes: tOut,
            hourlyBytes: hourly,
            appTrafficRecords: apps,
            monthAppTrafficRecords: monthApps,
            interfaceSnapshots: [:],
            lastBootTime: boot > 0 ? boot : currentBootTime(),
            lastSavedDate: Date()
        )
    }

    // MARK: - Utilities

    public static func currentBootTime() -> Int64 {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 && boottime.tv_sec > 0 {
            return Int64(boottime.tv_sec)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        return Int64(Date().timeIntervalSince1970 - uptime)
    }

    public static func currentMonthKey(from date: Date = Date()) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        return String(format: "%04d-%02d", y, m)
    }

    public static func currentDayKey(from date: Date = Date()) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
