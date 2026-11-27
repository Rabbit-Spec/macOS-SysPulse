import AppKit
import Darwin
import Foundation
import Observation

// MARK: - 系统优化分组与任务定义

public enum SystemOptimizeGroup: String, CaseIterable, Identifiable, Sendable {
    case maintenance = "系统维护"
    case launchSpeed = "快速查看与内存"
    case databases = "系统数据库"
    case networkSearch = "搜索与网络"

    public var id: String { rawValue }

    public var title: String { rawValue }

    public var iconName: String {
        switch self {
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .launchSpeed: return "bolt.fill"
        case .databases: return "cylinder.split.1x2.fill"
        case .networkSearch: return "magnifyingglass.circle.fill"
        }
    }

    public var tintName: String {
        switch self {
        case .maintenance: return "blue"
        case .launchSpeed: return "mint"
        case .databases: return "indigo"
        case .networkSearch: return "cyan"
        }
    }
}

public enum SystemOptimizeTaskID: String, CaseIterable, Identifiable, Sendable, Codable {
    // 系统维护
    case pruneDeadAppRegistrations
    case cleanBrokenLaunchAgents
    case auditBrokenCommandLinks
    case repairBrokenPlists
    case repairSharedFileLists
    case cleanSavedState
    case cleanQuarantineEvents
    case ejectStaleDiskImages
    case auditLegacyOverrides
    case runPeriodicMaintenance
    case repairDiskPermissions

    // 快速查看与内存
    case rebuildQuickLook
    case rebuildQuickLookThumbnails
    case memoryPurge

    // 系统数据库
    case pruneNotificationDB
    case vacuumSQLiteDatabases

    // 搜索与网络
    case pruneSpotlightOrphanRules
    case flushDNSCache

    public var id: String { rawValue }

    public var group: SystemOptimizeGroup {
        switch self {
        case .pruneDeadAppRegistrations,
             .cleanBrokenLaunchAgents,
             .auditBrokenCommandLinks,
             .repairBrokenPlists,
             .repairSharedFileLists,
             .cleanSavedState,
             .cleanQuarantineEvents,
             .ejectStaleDiskImages,
             .auditLegacyOverrides,
             .runPeriodicMaintenance,
             .repairDiskPermissions:
            return .maintenance
        case .rebuildQuickLook,
             .rebuildQuickLookThumbnails,
             .memoryPurge:
            return .launchSpeed
        case .pruneNotificationDB,
             .vacuumSQLiteDatabases:
            return .databases
        case .pruneSpotlightOrphanRules,
             .flushDNSCache:
            return .networkSearch
        }
    }

    public var title: String {
        switch self {
        case .pruneDeadAppRegistrations: return "清理打开方式残留应用"
        case .cleanBrokenLaunchAgents: return "清理失效后台服务"
        case .auditBrokenCommandLinks: return "清理失效命令行软链接"
        case .repairBrokenPlists: return "隔离损坏偏好配置文件"
        case .repairSharedFileLists: return "清理损坏的最近使用列表"
        case .cleanSavedState: return "清理 30 天前旧窗口状态"
        case .cleanQuarantineEvents: return "清空下载隔离历史记录"
        case .ejectStaleDiskImages: return "弹出闲置安装镜像"
        case .auditLegacyOverrides: return "恢复休眠与校验默认策略"
        case .runPeriodicMaintenance: return "执行系统例行维护脚本"
        case .repairDiskPermissions: return "修复个人主目录读写权限"
        case .rebuildQuickLook: return "重建快速查看插件缓存"
        case .rebuildQuickLookThumbnails: return "刷新文件缩略图缓存"
        case .memoryPurge: return "按需释放闲置物理内存"
        case .pruneNotificationDB: return "清理 30 天前通知记录"
        case .vacuumSQLiteDatabases: return "压缩邮件与信息数据库"
        case .pruneSpotlightOrphanRules: return "清理残留 Spotlight 规则"
        case .flushDNSCache: return "刷新本机 DNS 解析缓存"
        }
    }

    public var descriptionText: String {
        switch self {
        case .pruneDeadAppRegistrations:
            return "回收 LaunchServices 中已卸载应用的无效注册项（保留用户默认打开方式）"
        case .cleanBrokenLaunchAgents:
            return "检查用户级 LaunchAgents 配置，将指向已卸载程序的失效项移入废纸篓"
        case .auditBrokenCommandLinks:
            return "清理 /usr/local/bin 与 Homebrew 中指向已删除 App 包的悬空软链接"
        case .repairBrokenPlists:
            return "校验 ~/Library/Preferences 配置文件完整性，自动隔离损坏文件至废纸篓"
        case .repairSharedFileLists:
            return "检查最近文稿与边栏 .sfl 列表完整性，隔离异常列表文件"
        case .cleanSavedState:
            return "移除 30 天前且未在运行的应用窗口恢复状态目录"
        case .cleanQuarantineEvents:
            return "清空 LaunchServices 下载来源隔离历史记录并整理数据库空间"
        case .ejectStaleDiskImages:
            return "自动推出空闲的只读 DMG 安装镜像（跳过系统与模拟器镜像）"
        case .auditLegacyOverrides:
            return "检查并恢复被异常改写的全局 App Nap 与磁盘镜像校验默认策略"
        case .runPeriodicMaintenance:
            return "触发 macOS 周期性日志轮转与维护任务（需系统优化权限）"
        case .repairDiskPermissions:
            return "重置当前用户主目录的所有权与 ACL 访问权限（需系统优化权限）"
        case .rebuildQuickLook:
            return "刷新 QuickLook 插件注册表，修复空格预览无响应或内容错位"
        case .rebuildQuickLookThumbnails:
            return "重建 QuickLook 缩略图缓存索引，修复访达图标预览异常"
        case .memoryPurge:
            return "仅在系统内存压力偏高时请求释放可清除文件缓存，压力正常时自动跳过"
        case .pruneNotificationDB:
            return "删除 30 天前的通知中心历史记录并执行数据库压缩"
        case .vacuumSQLiteDatabases:
            return "在邮件与信息未运行时检查完整性与碎片率，执行无损 VACUUM 整理"
        case .pruneSpotlightOrphanRules:
            return "清理 Spotlight 搜索排除规则与用户插件中失效的应用路径"
        case .flushDNSCache:
            return "刷新本地 DNS 解析缓存，解决域名解析陈旧或网页加载异常"
        }
    }

    public var requiresAdmin: Bool {
        switch self {
        case .runPeriodicMaintenance, .repairDiskPermissions, .memoryPurge:
            return true
        default:
            return false
        }
    }

    public var defaultSelected: Bool {
        !requiresAdmin
    }
}

public enum SystemQuickRepairID: String, CaseIterable, Identifiable, Sendable {
    case inputMethod
    case notifications
    case universalClipboard
    case spotlightUI
    case finderAndDock
    case controlCenter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inputMethod: return "输入法切换卡顿"
        case .notifications: return "通知中心无响应"
        case .universalClipboard: return "通用剪贴板与接力"
        case .spotlightUI: return "Spotlight 搜索面板"
        case .finderAndDock: return "访达与程序坞异常"
        case .controlCenter: return "控制中心与菜单栏"
        }
    }

    public var subtitle: String {
        switch self {
        case .inputMethod: return "刷新输入法菜单栏切换代理"
        case .notifications: return "重启通知横幅与提醒守护进程"
        case .universalClipboard: return "刷新剪贴板同步与隔空投送代理"
        case .spotlightUI: return "重启搜索前端界面（不动底层索引）"
        case .finderAndDock: return "重启访达窗口与底部程序坞动画"
        case .controlCenter: return "刷新顶部控制中心与状态切换面板"
        }
    }

    public var iconName: String {
        switch self {
        case .inputMethod: return "keyboard.fill"
        case .notifications: return "bell.badge.fill"
        case .universalClipboard: return "doc.on.clipboard.fill"
        case .spotlightUI: return "sparkle.magnifyingglass"
        case .finderAndDock: return "dock.rectangle"
        case .controlCenter: return "switch.2"
        }
    }

    public var targetProcessNames: [String] {
        switch self {
        case .inputMethod: return ["TextInputMenuAgent", "TextInputSwitcher"]
        case .notifications: return ["NotificationCenter", "usernoted"]
        case .universalClipboard: return ["pboard", "sharingd", "useractivityd"]
        case .spotlightUI: return ["Spotlight"]
        case .finderAndDock: return ["Finder", "Dock"]
        case .controlCenter: return ["ControlCenter"]
        }
    }
}

public enum OptimizeTaskInspection: Sendable, Equatable {
    case pending
    case actionable(detail: String)
    case healthy(detail: String)
    case unavailable(detail: String)

    public var badgeText: String {
        switch self {
        case .pending: return "待体检"
        case .actionable: return "待优化"
        case .healthy: return "状态正常"
        case .unavailable: return "不适用"
        }
    }

    public var detailText: String {
        switch self {
        case .pending: return "等待预检快照"
        case .actionable(let d): return d
        case .healthy(let d): return d
        case .unavailable(let d): return d
        }
    }

    public var isActionable: Bool {
        if case .actionable = self { return true }
        return false
    }
}

public enum OptimizeTaskOutcome: Sendable, Equatable {
    case completed(detail: String)
    case skipped(reason: String)
    case failed(reason: String)

    public var badgeText: String {
        switch self {
        case .completed: return "已完成"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        }
    }

    public var detailText: String {
        switch self {
        case .completed(let d): return d
        case .skipped(let r): return r
        case .failed(let r): return r
        }
    }
}

public struct OptimizeRunSummary: Sendable, Equatable {
    public let completedCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let duration: TimeInterval
    public let timestamp: Date
}

// MARK: - 系统快照探测上下文 (Non-isolated)

private struct OptimizerInspectionContext: Sendable {
    let brokenUserLaunchAgents: [URL]
    let brokenSystemLaunchAgents: [URL]
    let brokenWritableSymlinks: [URL]
    let brokenProtectedSymlinks: [URL]
    let brokenPlists: [URL]
    let brokenSharedFileLists: [URL]
    let staleSavedStates: [URL]
    let quarantineEventCount: Int
    let staleDMGs: [(device: String, mountPoint: String)]
    let legacyOverridesFound: [String]
    let hasPeriodicBinary: Bool
    let periodicRanRecently: Bool
    let homeAbnormalPermissionCount: Int
    let isMemoryPressureHigh: Bool
    let memoryPressureLabel: String
    let swapUsedBytes: UInt64
    let staleNotificationCount: Int
    let notificationDBPath: String?
    let vacuumCandidateDBs: [URL]
    let orphanSpotlightImporters: [URL]
    let orphanSpotlightRules: [String]
    let hasStaleSpotlightRules: Bool
    let helperAuthorized: Bool
}

// MARK: - 系统优化与维护引擎

@Observable
@MainActor
public final class SystemOptimizerEngine {
    public static let shared = SystemOptimizerEngine()

    public var isInspecting: Bool = false
    public var isOptimizing: Bool = false
    public var isRequestingPermanentAuth: Bool = false
    public var showingInitialAuthGuidance: Bool = false
    public var currentRunningTaskTitle: String? = nil
    public var progressValue: Double = 0.0

    public var selectedGroupFilter: SystemOptimizeGroup? = nil
    public var showWhitelistedOnly: Bool = false

    public var selectedTaskIDs: Set<SystemOptimizeTaskID> = Set(SystemOptimizeTaskID.allCases.filter(\.defaultSelected)) {
        didSet { saveSelectionPersistence() }
    }
    public var whitelistedTaskIDs: Set<SystemOptimizeTaskID> = [] {
        didSet { saveWhitelistPersistence() }
    }

    public var inspections: [SystemOptimizeTaskID: OptimizeTaskInspection] = [:]
    public var lastOutcomes: [SystemOptimizeTaskID: OptimizeTaskOutcome] = [:]
    public var lastSummary: OptimizeRunSummary? = nil
    public var lastError: String? = nil

    public var runningRepairID: SystemQuickRepairID? = nil
    public var refreshedRepairIDs: Set<SystemQuickRepairID> = []

    private var hasInspectedInitial: Bool = false
    private let defaultsSelectionKey = "SP_Optimizer_SelectedTasks"
    private let defaultsWhitelistKey = "SP_Optimizer_WhitelistedTasks"
    private let defaultsInitialAuthPromptedKey = "SP_Optimizer_PromptedInitialAuth"

    private init() {
        loadPersistence()
    }

    // MARK: - 持久化

    private func loadPersistence() {
        let d = UserDefaults.standard
        if let savedSel = d.stringArray(forKey: defaultsSelectionKey) {
            selectedTaskIDs = Set(savedSel.compactMap(SystemOptimizeTaskID.init(rawValue:)))
        }
        if let savedWhite = d.stringArray(forKey: defaultsWhitelistKey) {
            whitelistedTaskIDs = Set(savedWhite.compactMap(SystemOptimizeTaskID.init(rawValue:)))
        }
    }

    private func saveSelectionPersistence() {
        UserDefaults.standard.set(selectedTaskIDs.map(\.rawValue), forKey: defaultsSelectionKey)
    }

    private func saveWhitelistPersistence() {
        UserDefaults.standard.set(whitelistedTaskIDs.map(\.rawValue), forKey: defaultsWhitelistKey)
    }

    // MARK: - 计算辅助

    public var filteredTasks: [SystemOptimizeTaskID] {
        SystemOptimizeTaskID.allCases.filter { task in
            if showWhitelistedOnly && !whitelistedTaskIDs.contains(task) {
                return false
            }
            if let group = selectedGroupFilter, task.group != group {
                return false
            }
            return true
        }
    }

    public var actionableCount: Int {
        SystemOptimizeTaskID.allCases.filter { task in
            !whitelistedTaskIDs.contains(task) && (inspections[task]?.isActionable ?? false)
        }.count
    }

    public var selectedActionableCount: Int {
        selectedTaskIDs.filter { task in
            !whitelistedTaskIDs.contains(task) && (inspections[task]?.isActionable ?? false)
        }.count
    }

    public func toggleTaskSelection(_ id: SystemOptimizeTaskID) {
        if selectedTaskIDs.contains(id) {
            selectedTaskIDs.remove(id)
        } else {
            selectedTaskIDs.insert(id)
        }
    }

    public func toggleWhitelist(_ id: SystemOptimizeTaskID) {
        if whitelistedTaskIDs.contains(id) {
            whitelistedTaskIDs.remove(id)
        } else {
            whitelistedTaskIDs.insert(id)
            selectedTaskIDs.remove(id)
        }
    }

    public func selectRecommended() {
        let includeAdmin = SystemPermissionManager.shared.optimizerHelperStatus.isAuthorized
        selectedTaskIDs = Set(SystemOptimizeTaskID.allCases.filter { task in
            !whitelistedTaskIDs.contains(task) && (includeAdmin || task.defaultSelected)
        })
    }

    public func selectAll() {
        selectedTaskIDs = Set(SystemOptimizeTaskID.allCases.filter { !whitelistedTaskIDs.contains($0) })
    }

    public func deselectAll() {
        selectedTaskIDs.removeAll()
    }

    // MARK: - 永久特权授权管理

    public func syncPermanentAuthorizationGranted() {
        for task in SystemOptimizeTaskID.allCases where task.requiresAdmin && !whitelistedTaskIDs.contains(task) {
            selectedTaskIDs.insert(task)
        }
        showingInitialAuthGuidance = false
        inspectAll()
    }

    public func syncPermanentAuthorizationRevoked() {
        inspectAll()
    }

    public func requestPermanentAuthorizationFromUI() {
        guard !isRequestingPermanentAuth else { return }
        isRequestingPermanentAuth = true
        showingInitialAuthGuidance = false
        lastError = nil
        SystemPermissionManager.shared.requestOptimizerHelperPermission { [weak self] ok in
            guard let self else { return }
            self.isRequestingPermanentAuth = false
            if !ok {
                self.lastError = "未开启系统优化权限，可继续运行常规维护项或稍后在「设置」中开启。"
            }
        }
    }

    // MARK: - 进入页面与系统预检

    public func checkOnEntry() {
        SystemPermissionManager.shared.checkOptimizerHelperPermission()
        if !hasInspectedInitial && !isInspecting && !isOptimizing {
            hasInspectedInitial = true
            let helperAuthorized = (SystemPermissionManager.checkInstalledOptimizeHelperStatus() == .authorized)
            if helperAuthorized && UserDefaults.standard.stringArray(forKey: defaultsSelectionKey) == nil {
                selectedTaskIDs = Set(SystemOptimizeTaskID.allCases.filter { !whitelistedTaskIDs.contains($0) })
            } else if !helperAuthorized && !UserDefaults.standard.bool(forKey: defaultsInitialAuthPromptedKey) {
                UserDefaults.standard.set(true, forKey: defaultsInitialAuthPromptedKey)
                showingInitialAuthGuidance = true
            }
            inspectAll()
        }
    }

    public func inspectAll() {
        guard !isInspecting && !isOptimizing else { return }
        isInspecting = true
        lastError = nil

        let pressureLabel = SystemResourceMonitor.shared.memory.pressureLabel
        let fdaGranted = (SystemPermissionManager.shared.fullDiskAccessStatus == .authorized)

        Task.detached(priority: .userInitiated) { [weak self] in
            let helperAuth = (SystemPermissionManager.checkInstalledOptimizeHelperStatus() == .authorized)
            let ctx = Self.collectInspectionContext(
                memoryPressureLabel: pressureLabel,
                fdaGranted: fdaGranted,
                helperAuthorized: helperAuth
            )
            let result = Self.buildInspections(from: ctx, fdaGranted: fdaGranted)

            await MainActor.run {
                guard let self else { return }
                self.inspections = result
                self.isInspecting = false
            }
        }
    }

    // MARK: - 执行一键系统优化

    public func runOptimization() {
        guard !isOptimizing && !isInspecting else { return }
        let orderedTasks = SystemOptimizeTaskID.allCases.filter { selectedTaskIDs.contains($0) }
        guard !orderedTasks.isEmpty else {
            lastError = "请先勾选至少一项系统维护任务"
            return
        }

        isOptimizing = true
        lastError = nil
        lastSummary = nil
        lastOutcomes = [:]
        progressValue = 0.04
        currentRunningTaskTitle = "正在构建系统预检快照…"

        let whitelist = whitelistedTaskIDs
        let pressureLabel = SystemResourceMonitor.shared.memory.pressureLabel
        let fdaGranted = (SystemPermissionManager.shared.fullDiskAccessStatus == .authorized)

        Task.detached(priority: .userInitiated) { [weak self] in
            let startTime = Date()
            var helperAuth = (SystemPermissionManager.checkInstalledOptimizeHelperStatus() == .authorized)
            let ctx = Self.collectInspectionContext(
                memoryPressureLabel: pressureLabel,
                fdaGranted: fdaGranted,
                helperAuthorized: helperAuth
            )
            let initialInspections = Self.buildInspections(from: ctx, fdaGranted: fdaGranted)

            var outcomes: [SystemOptimizeTaskID: OptimizeTaskOutcome] = [:]

            let needsAdminForCheckedTasks = orderedTasks.contains { task in
                guard !whitelist.contains(task) else { return false }
                if task.requiresAdmin {
                    if case .actionable = initialInspections[task] { return true }
                }
                return false
            }

            if needsAdminForCheckedTasks && !helperAuth {
                await MainActor.run {
                    self?.currentRunningTaskTitle = "正在请求系统优化权限…"
                }
                if SystemPermissionManager.installOptimizePrivilegedHelper(),
                   SystemPermissionManager.checkInstalledOptimizeHelperStatus() == .authorized {
                    helperAuth = true
                    await MainActor.run {
                        SystemPermissionManager.shared.checkOptimizerHelperPermission()
                    }
                }
            }

            let canUseHelper = helperAuth
            let shouldFlushMDNS = orderedTasks.contains(.flushDNSCache) && !whitelist.contains(.flushDNSCache) && canUseHelper

            let totalSteps = Double(max(1, orderedTasks.count))
            for (index, task) in orderedTasks.enumerated() {
                await MainActor.run {
                    self?.currentRunningTaskTitle = task.title
                    self?.progressValue = max(0.06, Double(index) / totalSteps)
                }

                if whitelist.contains(task) {
                    outcomes[task] = .skipped(reason: "已在优化保护名单中，已跳过")
                    continue
                }

                let outcome: OptimizeTaskOutcome
                if task.requiresAdmin {
                    if case .healthy(let detail) = initialInspections[task] {
                        outcome = .skipped(reason: detail)
                    } else if case .unavailable(let detail) = initialInspections[task] {
                        outcome = .skipped(reason: detail)
                    } else if canUseHelper {
                        outcome = Self.executeAdminTaskViaHelper(task)
                    } else {
                        outcome = .skipped(reason: "未开启系统优化权限，已安全跳过")
                    }
                } else {
                    outcome = Self.executeUserTask(
                        task,
                        ctx: ctx,
                        fdaGranted: fdaGranted,
                        helperAuthorized: canUseHelper,
                        extraMDNSFlushed: shouldFlushMDNS
                    )
                }
                outcomes[task] = outcome

                let partialOutcomes = outcomes
                await MainActor.run {
                    self?.lastOutcomes = partialOutcomes
                }
            }

            let refreshedPressure = await MainActor.run { SystemResourceMonitor.shared.memory.pressureLabel }
            let postHelperAuth = (SystemPermissionManager.checkInstalledOptimizeHelperStatus() == .authorized)
            let postCtx = Self.collectInspectionContext(
                memoryPressureLabel: refreshedPressure,
                fdaGranted: fdaGranted,
                helperAuthorized: postHelperAuth
            )
            let postInspections = Self.buildInspections(from: postCtx, fdaGranted: fdaGranted)

            let duration = Date().timeIntervalSince(startTime)
            var completedCount = 0
            var skippedCount = 0
            var failedCount = 0
            for out in outcomes.values {
                switch out {
                case .completed: completedCount += 1
                case .skipped: skippedCount += 1
                case .failed: failedCount += 1
                }
            }

            let summary = OptimizeRunSummary(
                completedCount: completedCount,
                skippedCount: skippedCount,
                failedCount: failedCount,
                duration: duration,
                timestamp: Date()
            )
            Self.appendOperationLog(summary: summary)

            await MainActor.run {
                guard let self else { return }
                self.inspections = postInspections
                self.lastOutcomes = outcomes
                self.lastSummary = summary
                self.progressValue = 1.0
                self.currentRunningTaskTitle = nil
                self.isOptimizing = false
            }
        }
    }

    // MARK: - 修复小毛病（独立按需重启局部守护进程）

    public func runQuickRepair(_ id: SystemQuickRepairID) {
        guard runningRepairID == nil else { return }
        runningRepairID = id
        lastError = nil

        let procNames = id.targetProcessNames
        Task.detached(priority: .userInitiated) { [weak self] in
            for proc in procNames {
                _ = Self.runCommand("/usr/bin/killall", args: [proc])
            }
            if id == .spotlightUI {
                // 重新激活 Spotlight 界面代理（不动索引数据库）
                _ = Self.runCommand("/usr/bin/open", args: ["-g", "-b", "com.apple.Spotlight"])
            }
            try? await Task.sleep(nanoseconds: 450_000_000)

            await MainActor.run {
                guard let self else { return }
                self.runningRepairID = nil
                self.refreshedRepairIDs.insert(id)
                Self.appendQuickRepairLog(title: id.title)
            }

            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                _ = self?.refreshedRepairIDs.remove(id)
            }
        }
    }

    // MARK: - Non-isolated 系统只读预检

    private nonisolated static func collectInspectionContext(
        memoryPressureLabel: String,
        fdaGranted: Bool,
        helperAuthorized: Bool
    ) -> OptimizerInspectionContext {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let protection = CleanProtectionStore.shared
        let mountedVolumes = Set((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [])

        // 1. 失效用户级 & 系统级 LaunchAgents
        let brokenUserAgents = scanBrokenLaunchAgents(
            in: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            mountedVolumes: mountedVolumes,
            protection: protection
        )
        let brokenSystemAgents = scanBrokenLaunchAgents(
            in: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            mountedVolumes: mountedVolumes,
            protection: protection
        )

        // 2. 悬空 CLI 软链接 (/opt/homebrew/{bin,sbin} & /usr/local/{bin,sbin})
        var brokenWritableLinks: [URL] = []
        var brokenProtectedLinks: [URL] = []
        for binDir in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"] {
            let dirURL = URL(fileURLWithPath: binDir, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            let dirWritable = fm.isWritableFile(atPath: binDir)
            for item in items {
                var st = Darwin.stat()
                guard Darwin.lstat(item.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { continue }
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: item.path) else { continue }
                let resolvedDest: String
                if dest.hasPrefix("/") {
                    resolvedDest = dest
                } else {
                    resolvedDest = dirURL.appendingPathComponent(dest).standardized.path
                }
                if resolvedDest.contains(".app/") && !fm.fileExists(atPath: resolvedDest) {
                    if protection.isProtected(path: item.path) { continue }
                    if dirWritable {
                        brokenWritableLinks.append(item)
                    } else {
                        brokenProtectedLinks.append(item)
                    }
                }
            }
        }

        // 3. 损坏的 Preferences plist
        var brokenPlists: [URL] = []
        let prefsDir = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        if let prefFiles = try? fm.contentsOfDirectory(at: prefsDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) {
            for url in prefFiles where url.pathExtension.lowercased() == "plist" {
                let name = url.lastPathComponent
                if name.hasPrefix(".GlobalPreferences")
                    || name == "loginwindow.plist"
                    || name.hasPrefix("com.apple.ContextStoreAgent")
                    || protection.isProtected(path: url.path) {
                    continue
                }
                let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard attrs?.isRegularFile == true, (attrs?.fileSize ?? 0) > 0 else { continue }
                if let data = try? Data(contentsOf: url) {
                    if (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                        brokenPlists.append(url)
                    }
                }
            }
        }

        // 4. 损坏的 SharedFileList (.sfl2 / .sfl3 / .sfl4)
        var brokenSFL: [URL] = []
        let sflDir = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)
        if let sflFiles = try? fm.contentsOfDirectory(at: sflDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for url in sflFiles {
                let ext = url.pathExtension.lowercased()
                guard ext.hasPrefix("sfl") else { continue }
                if protection.isProtected(path: url.path) { continue }
                let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard attrs?.isRegularFile == true, (attrs?.fileSize ?? 0) > 0 else { continue }
                if let data = try? Data(contentsOf: url) {
                    if (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                        brokenSFL.append(url)
                    }
                }
            }
        }

        // 5. 超过 30 天的旧窗口保存状态
        var staleSavedStates: [URL] = []
        let savedStateDir = home.appendingPathComponent("Library/Saved Application State", isDirectory: true)
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let cutoff30d = Date().addingTimeInterval(-30 * 86400)
        if let states = try? fm.contentsOfDirectory(at: savedStateDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for stateURL in states where stateURL.pathExtension == "savedState" {
                if protection.isProtected(path: stateURL.path) { continue }
                let bid = stateURL.deletingPathExtension().lastPathComponent
                if runningBundleIDs.contains(bid) { continue }
                let rv = try? stateURL.resourceValues(forKeys: [.contentModificationDateKey])
                if let mdate = rv?.contentModificationDate, mdate < cutoff30d {
                    staleSavedStates.append(stateURL)
                }
            }
        }

        // 6. QuarantineEventsV2 计数
        var quarantineCount = 0
        let quarantineDB = home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
        if fm.fileExists(atPath: quarantineDB.path) {
            let res = runCommand("/usr/bin/sqlite3", args: [quarantineDB.path, "SELECT COUNT(*) FROM LSQuarantineEvent;"])
            if res.exitCode == 0 {
                quarantineCount = Int(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }

        // 7. 闲置可推出 DMG 镜像
        let staleDMGs = findStaleMountedDMGs()

        // 8. 遗留 App Nap / 磁盘镜像校验覆盖策略
        var legacyOverrides: [String] = []
        if let appSleepDisabled = CFPreferencesCopyValue("NSAppSleepDisabled" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool,
           appSleepDisabled {
            legacyOverrides.append("NSAppSleepDisabled")
        }
        for key in ["skip-verify", "skip-verify-locked", "skip-verify-remote"] {
            if let val = CFPreferencesCopyValue(key as CFString, "com.apple.frameworks.diskimages" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool,
               val {
                legacyOverrides.append(key)
            }
        }

        // 9. periodic 二进制与 24 小时执行日志预检 (/var/log/daily.out)
        let hasPeriodic = fm.isExecutableFile(atPath: "/usr/sbin/periodic")
        var periodicRanRecently = false
        if hasPeriodic,
           let attrs = try? fm.attributesOfItem(atPath: "/var/log/daily.out"),
           let mdate = attrs[.modificationDate] as? Date {
            periodicRanRecently = Date().timeIntervalSince(mdate) < 86_400
        }

        // 10. 个人主目录与 ~/Library 所有权和写权限预检
        let homeAbnormalCount = checkHomeDirectoryPermissions(home: home)

        // 11. 内存压力与 Swap 使用量综合评估
        let swapUsedBytes = querySwapUsedBytes()
        let pressureHigh = (memoryPressureLabel == "警告" || memoryPressureLabel == "严重" || swapUsedBytes >= 2 * 1024 * 1024 * 1024)

        // 12. 通知中心 30 天前记录数
        var staleNotifCount = 0
        var notifDBPath: String? = nil
        if let dbURL = resolveNotificationDBURL(), fm.isReadableFile(atPath: dbURL.path) {
            notifDBPath = dbURL.path
            staleNotifCount = queryStaleNotificationCount(dbPath: dbURL.path)
        }

        // 13. 邮件与信息 SQLite 数据库可压缩候选
        var vacuumDBs: [URL] = []
        let mailRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
        let msgRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.MobileSMS" }
        if !mailRunning {
            let mailRoot = home.appendingPathComponent("Library/Mail", isDirectory: true)
            if let dirs = try? fm.contentsOfDirectory(at: mailRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for vdir in dirs where vdir.lastPathComponent.hasPrefix("V") {
                    let envIdx = vdir.appendingPathComponent("MailData/Envelope Index")
                    if fm.isWritableFile(atPath: envIdx.path), sqliteNeedsVacuum(path: envIdx.path) {
                        vacuumDBs.append(envIdx)
                    }
                }
            }
        }
        if !msgRunning && fdaGranted {
            let chatDB = home.appendingPathComponent("Library/Messages/chat.db")
            if fm.isWritableFile(atPath: chatDB.path), sqliteNeedsVacuum(path: chatDB.path) {
                vacuumDBs.append(chatDB)
            }
        }

        // 14. Spotlight 用户无效导入器、失效 Exclusions 与 EnabledPreferenceRules 孤立 Bundle 规则
        var orphanImporters: [URL] = []
        let userSpotlightDir = home.appendingPathComponent("Library/Spotlight", isDirectory: true)
        if let importers = try? fm.contentsOfDirectory(at: userSpotlightDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for imp in importers where imp.pathExtension == "mdimporter" {
                let execDir = imp.appendingPathComponent("Contents/MacOS")
                if !fm.fileExists(atPath: execDir.path) {
                    orphanImporters.append(imp)
                }
            }
        }
        let orphanRules = findOrphanSpotlightPreferenceRules()
        let hasStaleSpotlightRules = checkStaleSpotlightExclusionRules(home: home)

        return OptimizerInspectionContext(
            brokenUserLaunchAgents: brokenUserAgents,
            brokenSystemLaunchAgents: brokenSystemAgents,
            brokenWritableSymlinks: brokenWritableLinks,
            brokenProtectedSymlinks: brokenProtectedLinks,
            brokenPlists: brokenPlists,
            brokenSharedFileLists: brokenSFL,
            staleSavedStates: staleSavedStates,
            quarantineEventCount: quarantineCount,
            staleDMGs: staleDMGs,
            legacyOverridesFound: legacyOverrides,
            hasPeriodicBinary: hasPeriodic,
            periodicRanRecently: periodicRanRecently,
            homeAbnormalPermissionCount: homeAbnormalCount,
            isMemoryPressureHigh: pressureHigh,
            memoryPressureLabel: memoryPressureLabel,
            swapUsedBytes: swapUsedBytes,
            staleNotificationCount: staleNotifCount,
            notificationDBPath: notifDBPath,
            vacuumCandidateDBs: vacuumDBs,
            orphanSpotlightImporters: orphanImporters,
            orphanSpotlightRules: orphanRules,
            hasStaleSpotlightRules: hasStaleSpotlightRules,
            helperAuthorized: helperAuthorized
        )
    }

    private nonisolated static func scanBrokenLaunchAgents(
        in dir: URL,
        mountedVolumes: Set<String>,
        protection: CleanProtectionStore
    ) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [URL] = []
        for file in files where file.pathExtension.lowercased() == "plist" {
            let name = file.lastPathComponent
            if name.hasPrefix("com.apple.") || name.hasPrefix("com.rabbit.syspulse") || name.hasPrefix("com.antigravity.") {
                continue
            }
            if protection.isProtected(path: file.path) { continue }
            guard let data = try? Data(contentsOf: file),
                  let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }
            let program = (dict["Program"] as? String) ?? ((dict["ProgramArguments"] as? [String])?.first)
            guard let execPath = program, !execPath.isEmpty, execPath.hasPrefix("/") else { continue }
            if execPath.hasPrefix("/Volumes/") {
                let comps = URL(fileURLWithPath: execPath).pathComponents
                if comps.count >= 3, !mountedVolumes.contains(comps[2]) {
                    continue
                }
            }
            if !fm.fileExists(atPath: execPath) {
                results.append(file)
            }
        }
        return results
    }

    private nonisolated static func buildInspections(
        from ctx: OptimizerInspectionContext,
        fdaGranted: Bool
    ) -> [SystemOptimizeTaskID: OptimizeTaskInspection] {
        var map: [SystemOptimizeTaskID: OptimizeTaskInspection] = [:]

        map[.pruneDeadAppRegistrations] = .actionable(detail: "可回收 LaunchServices 无效打开方式注册项")

        let actionableAgents = ctx.brokenUserLaunchAgents.count + (ctx.helperAuthorized ? ctx.brokenSystemLaunchAgents.count : 0)
        if actionableAgents > 0 {
            map[.cleanBrokenLaunchAgents] = .actionable(detail: "发现 \(actionableAgents) 个指向已删除程序的失效后台项")
        } else if !ctx.brokenSystemLaunchAgents.isEmpty {
            map[.cleanBrokenLaunchAgents] = .healthy(detail: "用户后台项正常（\(ctx.brokenSystemLaunchAgents.count) 个系统级失效项需开启系统优化权限后清理）")
        } else {
            map[.cleanBrokenLaunchAgents] = .healthy(detail: "所有用户与系统后台服务配置均有效")
        }

        let actionableLinks = ctx.brokenWritableSymlinks.count + (ctx.helperAuthorized ? ctx.brokenProtectedSymlinks.count : 0)
        if actionableLinks > 0 {
            map[.auditBrokenCommandLinks] = .actionable(detail: "发现 \(actionableLinks) 个可清理的失效命令行软链接")
        } else if !ctx.brokenProtectedSymlinks.isEmpty {
            map[.auditBrokenCommandLinks] = .healthy(detail: "发现 \(ctx.brokenProtectedSymlinks.count) 个受保护目录失效软链接（开启系统优化权限可清理）")
        } else {
            map[.auditBrokenCommandLinks] = .healthy(detail: "命令行 bin / sbin 目录无悬空应用软链接")
        }

        if ctx.brokenPlists.isEmpty {
            map[.repairBrokenPlists] = .healthy(detail: "偏好设置配置文件结构完整")
        } else {
            map[.repairBrokenPlists] = .actionable(detail: "检测到 \(ctx.brokenPlists.count) 个结构损坏的 plist 配置文件")
        }

        if ctx.brokenSharedFileLists.isEmpty {
            map[.repairSharedFileLists] = .healthy(detail: "最近使用与边栏列表均正常")
        } else {
            map[.repairSharedFileLists] = .actionable(detail: "检测到 \(ctx.brokenSharedFileLists.count) 个损坏的共享列表文件")
        }

        if ctx.staleSavedStates.isEmpty {
            map[.cleanSavedState] = .healthy(detail: "无超过 30 天的冗余窗口保存状态")
        } else {
            map[.cleanSavedState] = .actionable(detail: "发现 \(ctx.staleSavedStates.count) 个超过 30 天的旧窗口状态")
        }

        if ctx.quarantineEventCount > 0 {
            map[.cleanQuarantineEvents] = .actionable(detail: "存在 \(ctx.quarantineEventCount) 条下载隔离历史记录")
        } else {
            map[.cleanQuarantineEvents] = .healthy(detail: "下载隔离记录已为空")
        }

        if ctx.staleDMGs.isEmpty {
            map[.ejectStaleDiskImages] = .healthy(detail: "当前无闲置挂载的 DMG 安装镜像")
        } else {
            map[.ejectStaleDiskImages] = .actionable(detail: "检测到 \(ctx.staleDMGs.count) 个可安全推出的闲置 DMG 镜像")
        }

        if ctx.legacyOverridesFound.isEmpty {
            map[.auditLegacyOverrides] = .healthy(detail: "App Nap 与镜像校验策略均为系统默认")
        } else {
            map[.auditLegacyOverrides] = .actionable(detail: "发现 \(ctx.legacyOverridesFound.count) 项异常覆盖开关：\(ctx.legacyOverridesFound.joined(separator: ", "))")
        }

        if !ctx.hasPeriodicBinary {
            map[.runPeriodicMaintenance] = .healthy(detail: "当前 macOS 已由 launchd 自动托管周期维护")
        } else if ctx.periodicRanRecently {
            map[.runPeriodicMaintenance] = .healthy(detail: "系统 24 小时内已完成周期例行维护")
        } else {
            map[.runPeriodicMaintenance] = .actionable(detail: "可执行 daily / weekly / monthly 系统维护脚本")
        }

        if ctx.homeAbnormalPermissionCount > 0 {
            map[.repairDiskPermissions] = .actionable(detail: "检测到 \(ctx.homeAbnormalPermissionCount) 处个人主目录所有权或写入权限异常")
        } else {
            map[.repairDiskPermissions] = .healthy(detail: "个人主目录所有权与读写权限均正常")
        }

        map[.rebuildQuickLook] = .actionable(detail: "可刷新 QuickLook 预览生成器插件缓存")
        map[.rebuildQuickLookThumbnails] = .actionable(detail: "可刷新文件缩略图与图标服务缓存")

        if ctx.isMemoryPressureHigh {
            let swapStr = ByteCountFormatter.string(fromByteCount: Int64(ctx.swapUsedBytes), countStyle: .memory)
            map[.memoryPurge] = .actionable(detail: "内存压力「\(ctx.memoryPressureLabel)」/ 交换占用 \(swapStr)，建议释放缓存")
        } else {
            map[.memoryPurge] = .healthy(detail: "当前内存压力\(ctx.memoryPressureLabel)且 Swap 正常，系统会自动回收")
        }

        if ctx.notificationDBPath == nil {
            map[.pruneNotificationDB] = .unavailable(detail: "当前账户暂无可读取的通知中心数据库")
        } else if ctx.staleNotificationCount > 0 {
            map[.pruneNotificationDB] = .actionable(detail: "发现 \(ctx.staleNotificationCount) 条超过 30 天的历史通知记录")
        } else {
            map[.pruneNotificationDB] = .healthy(detail: "近 30 天内无积压过期通知记录")
        }

        if !ctx.vacuumCandidateDBs.isEmpty {
            map[.vacuumSQLiteDatabases] = .actionable(detail: "发现 \(ctx.vacuumCandidateDBs.count) 个可整理碎片的系统数据库")
        } else if !fdaGranted {
            map[.vacuumSQLiteDatabases] = .healthy(detail: "已检邮件库无需压缩（授权完全磁盘访问可兼检信息库）")
        } else {
            map[.vacuumSQLiteDatabases] = .healthy(detail: "邮件与信息数据库碎片率低，状态良好")
        }

        let spotlightIssueCount = ctx.orphanSpotlightImporters.count + ctx.orphanSpotlightRules.count + (ctx.hasStaleSpotlightRules ? 1 : 0)
        if spotlightIssueCount > 0 {
            if !ctx.orphanSpotlightRules.isEmpty {
                map[.pruneSpotlightOrphanRules] = .actionable(detail: "发现 \(ctx.orphanSpotlightRules.count) 条已卸载 App 的 Spotlight 规则及失效插件")
            } else if !ctx.orphanSpotlightImporters.isEmpty {
                map[.pruneSpotlightOrphanRules] = .actionable(detail: "发现 \(ctx.orphanSpotlightImporters.count) 个失效 Spotlight 插件或排除规则")
            } else {
                map[.pruneSpotlightOrphanRules] = .actionable(detail: "发现失效的 Spotlight 排除路径规则")
            }
        } else {
            map[.pruneSpotlightOrphanRules] = .healthy(detail: "Spotlight 索引规则与插件均有效")
        }

        map[.flushDNSCache] = .actionable(detail: "可刷新本地 DNS 域名解析缓存")

        return map
    }

    // MARK: - 特权助手与用户态任务执行器

    private nonisolated static func executeAdminTaskViaHelper(_ task: SystemOptimizeTaskID) -> OptimizeTaskOutcome {
        let helper = SystemPermissionManager.installedOptimizeHelperPath
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            return .failed(reason: "系统优化权限组件尚未就绪")
        }
        switch task {
        case .runPeriodicMaintenance:
            let res = runCommand(helper, args: ["--periodic"], timeout: 60.0)
            if res.timedOut { return .failed(reason: "周期维护脚本执行超时已熔断") }
            return res.exitCode == 0
                ? .completed(detail: "已通过系统优化权限完成系统周期例行维护")
                : .failed(reason: "周期维护执行失败 (退出码 \(res.exitCode))")

        case .repairDiskPermissions:
            let uid = getuid()
            let res = runCommand(helper, args: ["--repair-permissions", "\(uid)"], timeout: 60.0)
            if res.timedOut { return .failed(reason: "权限修复执行超时已熔断") }
            return res.exitCode == 0
                ? .completed(detail: "已修复个人主目录所有权与 ACL 权限")
                : .failed(reason: "权限修复执行失败 (退出码 \(res.exitCode))")

        case .memoryPurge:
            let res = runCommand(helper, args: ["--purge"], timeout: 20.0)
            if res.timedOut { return .failed(reason: "内存释放执行超时") }
            return res.exitCode == 0
                ? .completed(detail: "已释放闲置可清除物理内存")
                : .failed(reason: "内存释放失败 (退出码 \(res.exitCode))")

        default:
            return .skipped(reason: "常规维护项")
        }
    }

    private nonisolated static func executeUserTask(
        _ task: SystemOptimizeTaskID,
        ctx: OptimizerInspectionContext,
        fdaGranted: Bool,
        helperAuthorized: Bool,
        extraMDNSFlushed: Bool
    ) -> OptimizeTaskOutcome {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        switch task {
        case .pruneDeadAppRegistrations:
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
            guard fm.isExecutableFile(atPath: lsregister) else {
                return .skipped(reason: "系统 lsregister 工具不可用")
            }
            let res = runCommand(lsregister, args: ["-gc"], timeout: 45.0)
            if res.timedOut { return .failed(reason: "lsregister 执行超时") }
            return res.exitCode == 0
                ? .completed(detail: "已回收打开方式列表中的无效应用注册")
                : .failed(reason: "lsregister 返回状态码 \(res.exitCode)")

        case .cleanBrokenLaunchAgents:
            let systemAgents = helperAuthorized ? ctx.brokenSystemLaunchAgents : []
            guard !ctx.brokenUserLaunchAgents.isEmpty || !systemAgents.isEmpty else {
                return .skipped(reason: "系统状态正常，无失效后台服务")
            }
            var moved = 0
            let uid = getuid()
            for agentURL in ctx.brokenUserLaunchAgents {
                let label = agentURL.deletingPathExtension().lastPathComponent
                _ = runCommand("/bin/launchctl", args: ["bootout", "gui/\(uid)/\(label)"])
                if (try? fm.trashItem(at: agentURL, resultingItemURL: nil)) != nil {
                    moved += 1
                }
            }
            if !systemAgents.isEmpty {
                let trashDir = home.appendingPathComponent(".Trash", isDirectory: true)
                for agentURL in systemAgents {
                    let base = agentURL.deletingPathExtension().lastPathComponent
                    var dest = trashDir.appendingPathComponent(agentURL.lastPathComponent)
                    if fm.fileExists(atPath: dest.path) {
                        dest = trashDir.appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970)).plist")
                    }
                    let res = runCommand(
                        SystemPermissionManager.installedOptimizeHelperPath,
                        args: ["--trash-broken-system-agent", agentURL.path, dest.path],
                        timeout: 15.0
                    )
                    if res.exitCode == 0 {
                        moved += 1
                    }
                }
            }
            return moved > 0
                ? .completed(detail: "已将 \(moved) 个失效后台配置移入废纸篓")
                : .failed(reason: "未能移除失效 LaunchAgent 配置")

        case .auditBrokenCommandLinks:
            let protectedLinks = helperAuthorized ? ctx.brokenProtectedSymlinks : []
            if ctx.brokenWritableSymlinks.isEmpty && protectedLinks.isEmpty {
                if !ctx.brokenProtectedSymlinks.isEmpty {
                    return .skipped(reason: "已删除 App 留下 \(ctx.brokenProtectedSymlinks.count) 个受保护目录软链接（需系统优化权限）")
                }
                return .skipped(reason: "系统状态正常，无悬空命令行软链接")
            }
            var removed = 0
            for linkURL in ctx.brokenWritableSymlinks {
                if (try? fm.removeItem(at: linkURL)) != nil {
                    removed += 1
                }
            }
            for linkURL in protectedLinks {
                let res = runCommand(
                    SystemPermissionManager.installedOptimizeHelperPath,
                    args: ["--remove-broken-symlink", linkURL.path],
                    timeout: 10.0
                )
                if res.exitCode == 0 {
                    removed += 1
                }
            }
            return removed > 0
                ? .completed(detail: "已清理 \(removed) 个指向已卸载 App 的失效软链接")
                : .failed(reason: "清理悬空软链接失败")

        case .repairBrokenPlists:
            guard !ctx.brokenPlists.isEmpty else {
                return .skipped(reason: "系统状态正常，未发现损坏配置文件")
            }
            var moved = 0
            for plistURL in ctx.brokenPlists {
                if (try? fm.trashItem(at: plistURL, resultingItemURL: nil)) != nil {
                    moved += 1
                }
            }
            return moved > 0
                ? .completed(detail: "已将 \(moved) 个损坏 plist 隔离至废纸篓")
                : .failed(reason: "无法隔离损坏配置文件")

        case .repairSharedFileLists:
            guard !ctx.brokenSharedFileLists.isEmpty else {
                return .skipped(reason: "系统状态正常，最近使用列表完好")
            }
            var moved = 0
            for url in ctx.brokenSharedFileLists {
                if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil {
                    moved += 1
                }
            }
            return moved > 0
                ? .completed(detail: "已隔离 \(moved) 个损坏的共享列表文件")
                : .failed(reason: "隔离共享列表文件失败")

        case .cleanSavedState:
            guard !ctx.staleSavedStates.isEmpty else {
                return .skipped(reason: "系统状态正常，无 30 天前旧窗口状态")
            }
            var moved = 0
            for url in ctx.staleSavedStates {
                if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil {
                    moved += 1
                }
            }
            return moved > 0
                ? .completed(detail: "已将 \(moved) 个过期窗口状态目录移入废纸篓")
                : .failed(reason: "清理旧窗口状态失败")

        case .cleanQuarantineEvents:
            guard ctx.quarantineEventCount > 0 else {
                return .skipped(reason: "下载隔离记录为空，无需清理")
            }
            let dbPath = home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2").path
            let res = runCommand("/usr/bin/sqlite3", args: [dbPath, "DELETE FROM LSQuarantineEvent; VACUUM;"], timeout: 30.0)
            return res.exitCode == 0
                ? .completed(detail: "已清空 \(ctx.quarantineEventCount) 条下载隔离记录并压缩数据库")
                : .failed(reason: "无法写入 QuarantineEventsV2 数据库")

        case .ejectStaleDiskImages:
            guard !ctx.staleDMGs.isEmpty else {
                return .skipped(reason: "当前无闲置挂载的 DMG 安装镜像")
            }
            var ejected = 0
            for img in ctx.staleDMGs {
                let res = runCommand("/usr/bin/hdiutil", args: ["detach", img.mountPoint, "-quiet"])
                if res.exitCode == 0 {
                    ejected += 1
                }
            }
            return ejected > 0
                ? .completed(detail: "已安全推出 \(ejected) 个闲置 DMG 磁盘镜像")
                : .skipped(reason: "闲置磁盘镜像当前正被其他进程占用")

        case .auditLegacyOverrides:
            guard !ctx.legacyOverridesFound.isEmpty else {
                return .skipped(reason: "系统状态正常，策略均为默认值")
            }
            if ctx.legacyOverridesFound.contains("NSAppSleepDisabled") {
                _ = runCommand("/usr/bin/defaults", args: ["delete", "NSGlobalDomain", "NSAppSleepDisabled"])
            }
            for key in ["skip-verify", "skip-verify-locked", "skip-verify-remote"] where ctx.legacyOverridesFound.contains(key) {
                _ = runCommand("/usr/bin/defaults", args: ["delete", "com.apple.frameworks.diskimages", key])
            }
            return .completed(detail: "已恢复 \(ctx.legacyOverridesFound.count) 项异常系统默认策略")

        case .rebuildQuickLook:
            let res = runCommand("/usr/bin/qlmanage", args: ["-r"], timeout: 20.0)
            if res.timedOut { return .failed(reason: "qlmanage -r 执行超时") }
            return res.exitCode == 0
                ? .completed(detail: "已重建 QuickLook 快速查看插件缓存")
                : .failed(reason: "qlmanage -r 执行失败")

        case .rebuildQuickLookThumbnails:
            let res = runCommand("/usr/bin/qlmanage", args: ["-r", "cache"], timeout: 25.0)
            let extraCleared = purgeThumbnailAndIconCaches()
            if res.timedOut { return .failed(reason: "缩略图缓存刷新超时") }
            if res.exitCode == 0 {
                return .completed(detail: extraCleared > 0 ? "已刷新文件缩略图与 \(extraCleared) 项图标缓存" : "已刷新文件缩略图缓存索引")
            }
            return .failed(reason: "qlmanage -r cache 执行失败")

        case .pruneNotificationDB:
            guard let dbPath = ctx.notificationDBPath else {
                return .skipped(reason: "无法访问通知中心数据库")
            }
            guard ctx.staleNotificationCount > 0 else {
                return .skipped(reason: "无超过 30 天的通知记录")
            }
            let cutoff = notificationCutoffTimestamp(dbPath: dbPath)
            let sql = "DELETE FROM record WHERE delivered_date < \(cutoff); PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"
            let res = runCommand("/usr/bin/sqlite3", args: [dbPath, sql], timeout: 30.0)
            return res.exitCode == 0
                ? .completed(detail: "已清理 \(ctx.staleNotificationCount) 条超期通知记录")
                : .skipped(reason: "通知数据库正被系统服务占用，已安全跳过")

        case .vacuumSQLiteDatabases:
            guard !ctx.vacuumCandidateDBs.isEmpty else {
                if !fdaGranted {
                    return .skipped(reason: "邮件库无需压缩（未授权完全磁盘访问已跳过信息库）")
                }
                return .skipped(reason: "数据库碎片率正常，无需压缩")
            }
            var vacuumed = 0
            for dbURL in ctx.vacuumCandidateDBs {
                let res = runCommand("/usr/bin/sqlite3", args: [dbURL.path, "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"], timeout: 45.0)
                if res.exitCode == 0 {
                    vacuumed += 1
                }
            }
            return vacuumed > 0
                ? .completed(detail: "已无损压缩整理 \(vacuumed) 个系统数据库")
                : .skipped(reason: "数据库正在被使用，已跳过整理")

        case .pruneSpotlightOrphanRules:
            guard !ctx.orphanSpotlightImporters.isEmpty || !ctx.orphanSpotlightRules.isEmpty || ctx.hasStaleSpotlightRules else {
                return .skipped(reason: "系统状态正常，Spotlight 规则均有效")
            }
            var cleaned = 0
            for imp in ctx.orphanSpotlightImporters {
                if (try? fm.trashItem(at: imp, resultingItemURL: nil)) != nil {
                    cleaned += 1
                }
            }
            if !ctx.orphanSpotlightRules.isEmpty {
                cleaned += pruneSpotlightPreferenceRules(orphanKeys: Set(ctx.orphanSpotlightRules))
            }
            if ctx.hasStaleSpotlightRules {
                cleaned += pruneSpotlightPlistExclusions(home: home)
            }
            return cleaned > 0
                ? .completed(detail: "已清理 \(cleaned) 项失效 Spotlight 规则或插件")
                : .skipped(reason: "无需要清理的 Spotlight 规则")

        case .flushDNSCache:
            let res = runCommand("/usr/bin/dscacheutil", args: ["-flushcache"], timeout: 15.0)
            var mdnsDone = false
            if extraMDNSFlushed {
                let helperRes = runCommand(SystemPermissionManager.installedOptimizeHelperPath, args: ["--flush-mdns"], timeout: 10.0)
                mdnsDone = (helperRes.exitCode == 0)
            }
            if res.exitCode == 0 {
                return .completed(detail: mdnsDone ? "已彻底刷新 DNS 解析缓存与 mDNSResponder" : "已刷新本地 DNS 解析缓存")
            }
            return .failed(reason: "dscacheutil 返回退出码 \(res.exitCode)")

        case .runPeriodicMaintenance, .repairDiskPermissions, .memoryPurge:
            return .skipped(reason: "由系统优化权限组件执行")
        }
    }

    // MARK: - 底层探测与工具函数

    private nonisolated static func checkHomeDirectoryPermissions(home: URL) -> Int {
        let uid = getuid()
        let keySubpaths = [
            "",
            "Library",
            "Library/Preferences",
            "Library/Application Support",
            "Library/Caches",
            "Library/Saved Application State",
            "Library/LaunchAgents",
            "Library/Containers"
        ]
        var abnormal = 0
        for sub in keySubpaths {
            let target = sub.isEmpty ? home.path : home.appendingPathComponent(sub).path
            var st = Darwin.stat()
            if Darwin.lstat(target, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK {
                if st.st_uid != uid || ((st.st_mode & S_IFMT) == S_IFDIR && (st.st_mode & S_IWUSR) == 0) {
                    abnormal += 1
                }
            }
        }
        let fm = FileManager.default
        for scanSub in ["Library", "Library/Preferences"] {
            let dirURL = home.appendingPathComponent(scanSub, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(atPath: dirURL.path) else { continue }
            for name in items {
                let path = dirURL.appendingPathComponent(name).path
                var st = Darwin.stat()
                if Darwin.lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK {
                    if st.st_uid != uid {
                        abnormal += 1
                    }
                }
            }
        }
        return abnormal
    }

    private nonisolated static func querySwapUsedBytes() -> UInt64 {
        var swap = Darwin.xsw_usage()
        var size = MemoryLayout<Darwin.xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            return swap.xsu_used
        }
        return 0
    }

    private nonisolated static func purgeThumbnailAndIconCaches() -> Int {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        guard len > 0 else { return 0 }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let cacheRoot = String(bytes: bytes, encoding: .utf8) else { return 0 }

        let fm = FileManager.default
        var removedCount = 0
        for sub in ["com.apple.QuickLook.thumbnailcache", "com.apple.iconservices"] {
            let dirURL = URL(fileURLWithPath: cacheRoot, isDirectory: true).appendingPathComponent(sub, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: []) else { continue }
            for item in items {
                if (try? fm.removeItem(at: item)) != nil {
                    removedCount += 1
                }
            }
        }
        return removedCount
    }

    private nonisolated static func findOrphanSpotlightPreferenceRules() -> [String] {
        guard let rawRules = CFPreferencesCopyAppValue("EnabledPreferenceRules" as CFString, "com.apple.Spotlight" as CFString) as? [String] else {
            return []
        }
        let ws = NSWorkspace.shared
        var orphans: [String] = []
        for rule in rawRules {
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.contains(".") else { continue }
            if trimmed.hasPrefix("com.apple.")
                || trimmed.hasPrefix("System.")
                || trimmed.hasPrefix("MENU_")
                || trimmed.hasPrefix("public.")
                || trimmed.hasPrefix("kMDItem") {
                continue
            }
            if ws.urlForApplication(withBundleIdentifier: trimmed) == nil {
                orphans.append(trimmed)
            }
        }
        return orphans
    }

    private nonisolated static func pruneSpotlightPreferenceRules(orphanKeys: Set<String>) -> Int {
        guard !orphanKeys.isEmpty,
              let rawRules = CFPreferencesCopyAppValue("EnabledPreferenceRules" as CFString, "com.apple.Spotlight" as CFString) as? [String] else {
            return 0
        }
        let kept = rawRules.filter { !orphanKeys.contains($0) }
        let removed = rawRules.count - kept.count
        guard removed > 0 else { return 0 }
        CFPreferencesSetAppValue("EnabledPreferenceRules" as CFString, kept as CFArray, "com.apple.Spotlight" as CFString)
        CFPreferencesAppSynchronize("com.apple.Spotlight" as CFString)
        return removed
    }

    private nonisolated static func findStaleMountedDMGs() -> [(device: String, mountPoint: String)] {
        let res = runCommand("/usr/bin/hdiutil", args: ["info", "-plist"])
        guard res.exitCode == 0,
              let data = res.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            return []
        }

        var results: [(String, String)] = []
        for img in images {
            let imgPath = (img["image-path"] as? String) ?? ""
            let writable = (img["writeable"] as? Bool) ?? false
            // 仅自动推出只读 .dmg，不碰可写稀疏映像与 CoreSimulator 运行时
            guard !writable, imgPath.lowercased().hasSuffix(".dmg") else { continue }
            if imgPath.contains("CoreSimulator") || imgPath.hasPrefix("/Library/Developer/") { continue }
            guard let entities = img["system-entities"] as? [[String: Any]] else { continue }
            for ent in entities {
                if let mount = ent["mount-point"] as? String,
                   mount.hasPrefix("/Volumes/"),
                   !mount.contains("Simulator") {
                    let dev = (ent["dev-entry"] as? String) ?? mount
                    results.append((dev, mount))
                    break
                }
            }
        }
        return results
    }

    private nonisolated static func resolveNotificationDBURL() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_DIR, &buf, buf.count)
        guard len > 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let darwinDir = String(bytes: bytes, encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: darwinDir, isDirectory: true)
            .appendingPathComponent("com.apple.notificationcenter/db2/db", isDirectory: false)
    }

    private nonisolated static func notificationCutoffTimestamp(dbPath: String) -> Double {
        let maxRes = runCommand("/usr/bin/sqlite3", args: [dbPath, "SELECT COALESCE(MAX(delivered_date), 0) FROM record;"])
        let maxVal = Double(maxRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        // macOS 通知中心一般使用 CoreFoundation 绝对时间戳 (自 2001-01-01，当前 ~8e8)，部分版本使用 Unix 时间戳 (~1.7e9)
        if maxVal >= 1_500_000_000 {
            return Date().timeIntervalSince1970 - (30 * 86400)
        }
        return CFAbsoluteTimeGetCurrent() - (30 * 86400)
    }

    private nonisolated static func queryStaleNotificationCount(dbPath: String) -> Int {
        let tableCheck = runCommand("/usr/bin/sqlite3", args: [dbPath, "SELECT name FROM sqlite_master WHERE type='table' AND name='record';"])
        guard tableCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "record" else { return 0 }
        let cutoff = notificationCutoffTimestamp(dbPath: dbPath)
        let res = runCommand("/usr/bin/sqlite3", args: [dbPath, "SELECT COUNT(*) FROM record WHERE delivered_date < \(cutoff);"])
        return Int(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private nonisolated static func sqliteNeedsVacuum(path: String) -> Bool {
        let integrity = runCommand("/usr/bin/sqlite3", args: [path, "PRAGMA integrity_check;"])
        guard integrity.exitCode == 0,
              integrity.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" else {
            return false
        }
        let freeRes = runCommand("/usr/bin/sqlite3", args: [path, "PRAGMA freelist_count; PRAGMA page_count;"])
        let lines = freeRes.stdout.components(separatedBy: .newlines).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard lines.count >= 2, lines[1] > 0 else { return false }
        let freelist = lines[0]
        let pages = lines[1]
        return freelist >= 64 && (Double(freelist) / Double(pages)) >= 0.05
    }

    private nonisolated static func checkStaleSpotlightExclusionRules(home: URL) -> Bool {
        let plistURL = home.appendingPathComponent("Library/Preferences/com.apple.Spotlight.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let exclusions = dict["Exclusions"] as? [String] else {
            return false
        }
        let fm = FileManager.default
        return exclusions.contains { path in
            path.hasPrefix("/") && !path.hasPrefix("/Volumes/") && !fm.fileExists(atPath: path)
        }
    }

    private nonisolated static func pruneSpotlightPlistExclusions(home: URL) -> Int {
        let plistURL = home.appendingPathComponent("Library/Preferences/com.apple.Spotlight.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var dict = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil) as? [String: Any],
              let exclusions = dict["Exclusions"] as? [String] else {
            return 0
        }
        let fm = FileManager.default
        let kept = exclusions.filter { path in
            !path.hasPrefix("/") || path.hasPrefix("/Volumes/") || fm.fileExists(atPath: path)
        }
        let removedCount = exclusions.count - kept.count
        guard removedCount > 0 else { return 0 }
        dict["Exclusions"] = kept
        if let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) {
            try? out.write(to: plistURL, options: .atomic)
        }
        return removedCount
    }

    private nonisolated static func runCommand(
        _ executable: String,
        args: [String],
        timeout: TimeInterval = 20.0
    ) -> (exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let doneSema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            doneSema.signal()
        }

        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            return (-1, "", error.localizedDescription, false)
        }

        let outBox = OutputDataBox()
        let errBox = OutputDataBox()
        let ioGroup = DispatchGroup()

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            ioGroup.leave()
        }
        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            ioGroup.leave()
        }

        let waitResult = doneSema.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            proc.terminate()
            _ = doneSema.wait(timeout: .now() + 1.5)
            _ = ioGroup.wait(timeout: .now() + 0.5)
            return (-2, outBox.string(), "操作超时已自动熔断", true)
        }

        _ = ioGroup.wait(timeout: .now() + 2.0)
        return (
            proc.terminationStatus,
            outBox.string(),
            errBox.string(),
            false
        )
    }

    private final class OutputDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ newData: Data) {
            lock.lock()
            data = newData
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let copy = data
            lock.unlock()
            return String(data: copy, encoding: .utf8) ?? ""
        }
    }

    private nonisolated static func appendOperationLog(summary: OptimizeRunSummary) {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let logURL = appSup.appendingPathComponent("SysPulse/operations.log")
        let df = ISO8601DateFormatter()
        let line = "[\(df.string(from: summary.timestamp))] [SYSTEM_OPTIMIZE] completed=\(summary.completedCount) skipped=\(summary.skippedCount) failed=\(summary.failedCount) duration=\(String(format: "%.2fs", summary.duration))\n"
        if let data = line.data(using: .utf8) {
            if fm.fileExists(atPath: logURL.path), let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                _ = try? fh.write(contentsOf: data)
            } else {
                try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    private nonisolated static func appendQuickRepairLog(title: String) {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let logURL = appSup.appendingPathComponent("SysPulse/operations.log")
        let df = ISO8601DateFormatter()
        let line = "[\(df.string(from: Date()))] [QUICK_REPAIR] target=\"\(title)\"\n"
        if let data = line.data(using: .utf8), fm.fileExists(atPath: logURL.path), let fh = try? FileHandle(forWritingTo: logURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: data)
        }
    }
}
