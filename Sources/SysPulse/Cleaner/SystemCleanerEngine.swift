import Foundation
import SwiftUI
import AppKit
import Observation

public struct CleanerRunningConflict: Identifiable, Sendable, Equatable {
    public let id: String // bundleID
    public let appName: String
    public let itemNames: [String]
}

public struct CleanerUndoProtectionNotice: Sendable, Equatable {
    public let itemName: String
    public let addedPattern: String
}

@Observable
@MainActor
public final class SystemCleanerEngine {
    public static let shared = SystemCleanerEngine()

    public var status: CleanScanStatus = .idle
    public var scannedItems: [CleanItem] = []
    public var selectedItemIDs: Set<UUID> = []
    public var lastFreedBytes: Int64 = 0
    public var lastCleanDate: Date? = nil
    public var deselectedPaths: Set<String> = []
    public var deselectedCategories: Set<String> = []
    public var currentScanPath: String = ""
    public var scanProgressValue: Double = 0.0
    public var scanStageIndex: Int = 0
    public var scanDiscoveredCount: Int = 0
    public var scanDiscoveredBytes: Int64 = 0

    /// 最近一次清理的结构化回执（成功 / 跳过原因 / 失败原因）
    public var lastExecutionSummary: CleanExecutionSummary? = nil
    public var showExecutionDetails: Bool = true

    /// 清理前检测到的运行中属主 App 冲突
    public var pendingRunningConflicts: [CleanerRunningConflict] = []
    public var isRunningConflictDialogPresented: Bool = false

    /// 行内一键“清理保护”撤销条
    public var undoProtectionNotice: CleanerUndoProtectionNotice? = nil

    public var deleteMode: CleanDeleteMode = .moveToTrash {
        didSet {
            UserDefaults.standard.set(deleteMode.rawValue, forKey: "SP_Cleaner_DeleteMode")
        }
    }
    public var autoScanOnEnter: Bool = true {
        didSet {
            UserDefaults.standard.set(autoScanOnEnter, forKey: "SP_Cleaner_AutoScanOnEnter")
        }
    }

    private var currentTask: Task<Void, Never>? = nil
    private var suppressAutoScanInSession: Bool = false

    public init() {
        let savedFreed = UserDefaults.standard.integer(forKey: "PG_Clean_LastFreedBytes")
        if savedFreed > 0 {
            self.lastFreedBytes = Int64(savedFreed)
        }
        if let savedDate = UserDefaults.standard.object(forKey: "PG_Clean_LastDate") as? Date {
            self.lastCleanDate = savedDate
        }
        FolderNotesCatalog.shared.preloadInBackground()
        if let savedDeselected = UserDefaults.standard.stringArray(forKey: "PG_Clean_DeselectedPaths") {
            self.deselectedPaths = Set(savedDeselected)
        }
        if let savedDeselectedCats = UserDefaults.standard.stringArray(forKey: "SP_Clean_DeselectedCategories") {
            self.deselectedCategories = Set(savedDeselectedCats)
        }
        if let savedMode = UserDefaults.standard.string(forKey: "SP_Cleaner_DeleteMode"),
           let mode = CleanDeleteMode(rawValue: savedMode) {
            self.deleteMode = mode
        }
        if UserDefaults.standard.object(forKey: "SP_Cleaner_AutoScanOnEnter") != nil {
            self.autoScanOnEnter = UserDefaults.standard.bool(forKey: "SP_Cleaner_AutoScanOnEnter")
        }
    }

    public var isScanning: Bool {
        if case .scanning = status { return true }
        return false
    }

    public var isCleaning: Bool {
        if case .cleaning = status { return true }
        return false
    }

    // MARK: - Computed Properties

    public var selectableScannedItems: [CleanItem] {
        scannedItems.filter(\.isSelectable)
    }

    public var totalScannedBytes: Int64 {
        selectableScannedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var selectedBytes: Int64 {
        scannedItems.filter { selectedItemIDs.contains($0.id) && $0.isSelectable }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var itemsByCategory: [CleanCategory: [CleanItem]] {
        Dictionary(grouping: scannedItems, by: { $0.category })
    }

    public func categoryBytes(_ cat: CleanCategory) -> Int64 {
        (itemsByCategory[cat] ?? []).filter(\.isSelectable).reduce(0) { $0 + $1.sizeBytes }
    }

    public func count(for bucket: CleanReviewBucket?) -> Int {
        guard let bucket else { return scannedItems.count }
        return scannedItems.filter { $0.bucket == bucket }.count
    }

    public var formattedSelectedBytes: String {
        formatBytes(selectedBytes)
    }

    public var formattedTotalScannedBytes: String {
        formatBytes(totalScannedBytes)
    }

    public var formattedLastFreedBytes: String {
        formatBytes(lastFreedBytes)
    }

    public var effectiveScannedItemsForMenuBar: [CleanItem] {
        scannedItems.filter { $0.isSelectable && !isItemDeselected(item: $0) && selectedItemIDs.contains($0.id) }
    }

    public var effectiveScannedBytesForMenuBar: Int64 {
        effectiveScannedItemsForMenuBar.reduce(0) { $0 + $1.sizeBytes }
    }

    public var formattedEffectiveScannedBytesForMenuBar: String {
        formatBytes(effectiveScannedBytesForMenuBar)
    }

    public var lastCleanDescription: String {
        guard let date = lastCleanDate else {
            return "还没清理过"
        }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            return "今天 \(df.string(from: date)) 已清理"
        } else {
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm"
            return "上次清理于 \(df.string(from: date))"
        }
    }

    // MARK: - Selection & Presets

    public func isCategorySelected(_ category: CleanCategory) -> Bool {
        !deselectedCategories.contains(category.rawValue)
    }

    public func toggleCategorySelection(_ category: CleanCategory) {
        if deselectedCategories.contains(category.rawValue) {
            deselectedCategories.remove(category.rawValue)
            selectAll(category: category)
        } else {
            deselectedCategories.insert(category.rawValue)
            deselectAll(category: category)
        }
        UserDefaults.standard.set(Array(deselectedCategories), forKey: "SP_Clean_DeselectedCategories")
        UserDefaults.standard.set(Array(deselectedPaths), forKey: "PG_Clean_DeselectedPaths")
    }

    public func isItemDeselected(item: CleanItem) -> Bool {
        if deselectedCategories.contains(item.category.rawValue) {
            return true
        }
        if deselectedPaths.contains(item.path.path) {
            return true
        }
        return false
    }

    public func toggleSelection(for id: UUID) {
        guard let item = scannedItems.first(where: { $0.id == id }), item.isSelectable else { return }
        let key = item.path.path
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
            deselectedPaths.insert(key)
        } else {
            selectedItemIDs.insert(id)
            deselectedPaths.remove(key)
        }
        UserDefaults.standard.set(Array(deselectedPaths), forKey: "PG_Clean_DeselectedPaths")
    }

    public func applySelectionPreset(_ preset: CleanSelectionPreset) {
        switch preset {
        case .recommended:
            deselectedPaths.removeAll()
            selectedItemIDs = Set(
                scannedItems
                    .filter { $0.isSelectable && $0.bucket == .suggested && !deselectedCategories.contains($0.category.rawValue) }
                    .map(\.id)
            )
        case .all:
            deselectedPaths.removeAll()
            selectedItemIDs = Set(scannedItems.filter(\.isSelectable).map(\.id))
        case .none:
            for item in selectableScannedItems {
                deselectedPaths.insert(item.path.path)
            }
            selectedItemIDs.removeAll()
        }
        UserDefaults.standard.set(Array(deselectedPaths), forKey: "PG_Clean_DeselectedPaths")
    }

    public func selectAll(category: CleanCategory? = nil) {
        if let category {
            let catItems = (itemsByCategory[category] ?? []).filter(\.isSelectable)
            for item in catItems {
                selectedItemIDs.insert(item.id)
                deselectedPaths.remove(item.path.path)
            }
        } else {
            applySelectionPreset(.all)
            return
        }
        UserDefaults.standard.set(Array(deselectedPaths), forKey: "PG_Clean_DeselectedPaths")
    }

    public func deselectAll(category: CleanCategory? = nil) {
        if let category {
            let catItems = (itemsByCategory[category] ?? []).filter(\.isSelectable)
            for item in catItems {
                selectedItemIDs.remove(item.id)
                deselectedPaths.insert(item.path.path)
            }
        } else {
            applySelectionPreset(.none)
            return
        }
        UserDefaults.standard.set(Array(deselectedPaths), forKey: "PG_Clean_DeselectedPaths")
    }

    /// 行内一键“清理保护”并写入 ~/.config/syspulse/whitelist
    public func protectItem(_ item: CleanItem) {
        guard let pattern = CleanProtectionStore.shared.addPath(item.path.path) else { return }
        selectedItemIDs.remove(item.id)
        if let idx = scannedItems.firstIndex(where: { $0.id == item.id }) {
            let old = scannedItems[idx]
            scannedItems[idx] = CleanItem(
                id: old.id,
                name: old.name,
                category: old.category,
                bucket: .excluded,
                path: old.path,
                sizeBytes: old.sizeBytes,
                detail: old.detail,
                isProtected: true,
                guardReason: "在清理保护名单中: \(pattern)",
                ownerBundleID: old.ownerBundleID,
                ownerAppName: old.ownerAppName,
                itemAgeDays: old.itemAgeDays,
                isInstalledInstaller: old.isInstalledInstaller,
                isCloudPlaceholder: old.isCloudPlaceholder,
                recommendedActionHint: old.recommendedActionHint
            )
        }
        undoProtectionNotice = CleanerUndoProtectionNotice(itemName: item.name, addedPattern: pattern)
    }

    public func undoLastProtection() {
        guard let notice = undoProtectionNotice else { return }
        CleanProtectionStore.shared.removePattern(notice.addedPattern)
        undoProtectionNotice = nil
        startScan()
    }

    public func cancelScan() {
        suppressAutoScanInSession = true
        currentTask?.cancel()
        currentTask = nil
        status = .idle
        currentScanPath = ""
        scanProgressValue = 0.0
        scanStageIndex = 0
        scanDiscoveredCount = 0
        scanDiscoveredBytes = 0
    }

    /// Trigger an automatic scan when entering the Cleaner tab if enabled, idle, and not cancelled this session.
    public func startAutoScanIfNeeded() {
        guard autoScanOnEnter, !suppressAutoScanInSession else { return }
        guard status == .idle else { return }
        startScan()
    }

    // MARK: - 扫描引擎

    public func startScan() {
        guard !isCleaning else { return }
        suppressAutoScanInSession = false
        lastExecutionSummary = nil
        undoProtectionNotice = nil
        currentTask?.cancel()
        status = .scanning(progress: 0.03, currentPath: "准备扫描系统残留与缓存目录…")
        currentScanPath = "准备扫描系统残留与缓存目录…"
        scanProgressValue = 0.03
        scanStageIndex = 1
        scanDiscoveredCount = 0
        scanDiscoveredBytes = 0
        scannedItems = []
        selectedItemIDs = []

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let matcher = CleanWhitelistMatcher.shared
            let now = Date()

            let runningApps = NSWorkspace.shared.runningApplications
            let runningBundles = Set(runningApps.compactMap(\.bundleIdentifier))
            let installedBundles = Self.discoverInstalledAppInfo()

            var discovered: [CleanItem] = []

            // 1. 用户缓存与通讯缓存 (User & Communication Caches: ~/Library/Caches)
            let s1Start = ContinuousClock.now
            let userCachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
            if let items = try? fm.contentsOfDirectory(at: userCachesURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                for (idx, sub) in items.enumerated() {
                    if Task.isCancelled { return }
                    let folderName = sub.lastPathComponent
                    if folderName.hasPrefix("com.apple.coresymbolicationd") || folderName.hasPrefix("com.apple.akd") {
                        continue
                    }

                    let progress = 0.02 + 0.115 * (Double(idx) / Double(max(1, items.count)))
                    let readableName = Self.humanReadableAppName(bundleID: folderName)
                    let liveBytes = discovered.filter(\.isSelectable).reduce(Int64(0)) { $0 + $1.sizeBytes }
                    await self?.updateScanStatus(progress: progress, step: 1, path: "扫描用户缓存: \(readableName)", foundCount: discovered.count, foundBytes: liveBytes)

                    let size = Self.calculateDirectorySize(url: sub)
                    guard size > 1024 * 1024 * 2 else { continue } // > 2MB

                    let isComm = Self.isCommunicationIdentifier(folderName)
                    let isBrowser = Self.isBrowserIdentifier(folderName)
                    let category: CleanCategory = isComm ? .communication : (isBrowser ? .webData : .userCaches)
                    let verdict = matcher.evaluate(url: sub)

                    if case .blocked(_, _) = verdict {
                        discovered.append(
                            CleanItem(
                                name: readableName + " 缓存",
                                category: category,
                                bucket: .excluded,
                                path: sub,
                                sizeBytes: size,
                                detail: "\(folderName) · 受清理安全规则保护跳过",
                                isProtected: true,
                                guardReason: verdict.detailText,
                                ownerBundleID: folderName,
                                ownerAppName: readableName
                            )
                        )
                        continue
                    }

                    let isUpdater = folderName.localizedCaseInsensitiveContains("sparkle") || folderName.localizedCaseInsensitiveContains("updater")
                    let finalCategory: CleanCategory = isUpdater ? .appLeftovers : category
                    let bucket: CleanReviewBucket = isComm ? .needsReview : .suggested
                    let detailText = isComm
                        ? "聊天软件媒体/图片缓存 · 清理后过期旧图无法恢复"
                        : "\(folderName) 产生的运行缓存与临时资源"

                    discovered.append(
                        CleanItem(
                            name: readableName + (isUpdater ? " 更新暂存" : " 缓存"),
                            category: finalCategory,
                            bucket: bucket,
                            path: sub,
                            sizeBytes: size,
                            detail: detailText,
                            ownerBundleID: folderName,
                            ownerAppName: readableName
                        )
                    )
                }
            }

            // 1.2 通讯软件精细分级缓存（区分安全日志/临时网页缓存 vs 聊天图片视频媒体缓存）
            let commTargets: [CleanTargetSpec] = [
                CleanTargetSpec(
                    title: "微信运行日志与调试堆栈",
                    category: .communication,
                    bucket: .suggested,
                    url: home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/com.tencent.xinWeChat/Logs", isDirectory: true),
                    detail: "微信客户端调试与崩溃日志文件，可安全清理且不影响聊天记录与图片",
                    bundleID: "com.tencent.xinWeChat",
                    appName: "微信",
                    minBytes: 1024 * 1024 * 2
                ),
                CleanTargetSpec(
                    title: "微信聊天图片与视频缓存",
                    category: .communication,
                    bucket: .needsReview,
                    url: home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Caches", isDirectory: true),
                    detail: "清理后旧图片和视频需重新下载，已过期的无法找回",
                    bundleID: "com.tencent.xinWeChat",
                    appName: "微信",
                    minBytes: 1024 * 1024 * 10
                ),
                CleanTargetSpec(
                    title: "钉钉运行日志与调试记录",
                    category: .communication,
                    bucket: .suggested,
                    url: home.appendingPathComponent("Library/Application Support/DingTalkMac/log", isDirectory: true),
                    detail: "钉钉客户端历史运行日志，清理不影响消息与本地文件",
                    bundleID: "com.alibaba.DingTalkMac",
                    appName: "钉钉",
                    minBytes: 1024 * 1024 * 2
                ),
                CleanTargetSpec(
                    title: "钉钉资源与媒体缓存",
                    category: .communication,
                    bucket: .needsReview,
                    url: home.appendingPathComponent("Library/Caches/DingTalk", isDirectory: true),
                    detail: "清理后旧图片和视频需重新下载，已过期的无法找回",
                    bundleID: "com.alibaba.DingTalkMac",
                    appName: "钉钉",
                    minBytes: 1024 * 1024 * 10
                )
            ]
            for spec in commTargets {
                if Task.isCancelled { return }
                await self?.updateScanStatus(progress: 0.128, step: 1, path: "扫描通讯分级缓存: \(spec.title)", items: discovered)
                if let item = Self.evaluateTargetSpec(spec, matcher: matcher) {
                    discovered.append(item)
                }
            }

            // 1.3 网盘缓存、创意设计渲染缓存与邮件下载副本
            await self?.updateScanStatus(progress: 0.138, step: 1, path: "扫描网盘与设计创意工具缓存…", items: discovered)
            let extendedUserSpecs = Self.cloudDesignAndMailTargetSpecs(home: home)
            for spec in extendedUserSpecs {
                if Task.isCancelled { return }
                if let item = Self.evaluateTargetSpec(spec, matcher: matcher) {
                    discovered.append(item)
                }
            }
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 1, to: 0.145, startedAt: s1Start, path: "用户与通讯缓存核验完成", items: discovered)

            // 2. 日志文件 (Log Files: ~/Library/Logs)
            let s2Start = ContinuousClock.now
            let logsURL = home.appendingPathComponent("Library/Logs", isDirectory: true)
            await self?.updateScanStatus(progress: 0.16, step: 2, path: "扫描日志文件: ~/Library/Logs", items: discovered)
            if let logSubs = try? fm.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                var totalLogsSize: Int64 = 0
                for sub in logSubs {
                    if Task.isCancelled { return }
                    if matcher.evaluate(url: sub).isAllowed {
                        totalLogsSize += Self.calculateDirectorySize(url: sub)
                    }
                }
                if totalLogsSize > 1024 * 512 {
                    discovered.append(
                        CleanItem(
                            name: "应用运行与系统历史日志",
                            category: .systemLogs,
                            bucket: .suggested,
                            path: logsURL,
                            sizeBytes: totalLogsSize,
                            detail: "应用调试输出及历史日志记录，可安全清理"
                        )
                    )
                }
            }
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 2, to: 0.270, startedAt: s2Start, path: "扫描日志文件: ~/Library/Logs", items: discovered)

            // 3. 网页临时数据 (Web Temporary Data)
            let s3Start = ContinuousClock.now
            let browserCachePaths: [(String, String, String, URL)] = [
                ("Safari 网页离线缓存", "Safari", "com.apple.Safari", home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Caches", isDirectory: true)),
                ("Google Chrome 网页缓存", "Google Chrome", "com.google.Chrome", home.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true)),
                ("Microsoft Edge 网页缓存", "Microsoft Edge", "com.microsoft.edgemac", home.appendingPathComponent("Library/Caches/Microsoft Edge", isDirectory: true)),
                ("Firefox 临时离线数据", "Firefox", "org.mozilla.firefox", home.appendingPathComponent("Library/Caches/Firefox", isDirectory: true)),
                ("Brave 网页缓存", "Brave Browser", "com.brave.Browser", home.appendingPathComponent("Library/Caches/BraveSoftware", isDirectory: true))
            ]
            await self?.updateScanStatus(progress: 0.285, step: 3, path: "检查浏览器网页临时缓存…", items: discovered)
            for (bIdx, (title, appName, bundleID, pathURL)) in browserCachePaths.enumerated() {
                if Task.isCancelled { return }
                guard fm.fileExists(atPath: pathURL.path) else { continue }
                let verdict = matcher.evaluate(url: pathURL)
                let p = 0.285 + 0.10 * (Double(bIdx) / Double(max(1, browserCachePaths.count)))
                await self?.updateScanStatus(progress: p, step: 3, path: "扫描网页临时数据: \(appName)", items: discovered)
                let sz = Self.calculateDirectorySize(url: pathURL)
                guard sz > 1024 * 1024 else { continue }
                discovered.append(
                    CleanItem(
                        name: title,
                        category: .webData,
                        bucket: verdict.isAllowed ? .suggested : .excluded,
                        path: pathURL,
                        sizeBytes: sz,
                        detail: "\(appName) 网页离线资源与网络请求中间缓存（保留登录状态与书签）",
                        isProtected: !verdict.isAllowed,
                        guardReason: verdict.detailText,
                        ownerBundleID: bundleID,
                        ownerAppName: appName
                    )
                )
            }
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 3, to: 0.395, startedAt: s3Start, path: "浏览器网页缓存核验完成", items: discovered)

            // 4. 崩溃诊断 (Crash Reports)
            let s4Start = ContinuousClock.now
            let diagURL = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
            await self?.updateScanStatus(progress: 0.41, step: 4, path: "扫描崩溃诊断转储报告…", items: discovered)
            if fm.fileExists(atPath: diagURL.path), matcher.evaluate(url: diagURL).isAllowed {
                let diagSize = Self.calculateDirectorySize(url: diagURL)
                if diagSize > 0 {
                    discovered.append(
                        CleanItem(
                            name: "应用崩溃诊断报告 (.ips / .crash)",
                            category: .crashReports,
                            bucket: .suggested,
                            path: diagURL,
                            sizeBytes: diagSize,
                            detail: "系统保存的历史崩溃转储与堆栈回溯分析文件"
                        )
                    )
                }
            }
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 4, to: 0.520, startedAt: s4Start, path: "崩溃诊断报告排查完成", items: discovered)

            // 5. 开发缓存 (Developer Caches: Xcode DerivedData 区分已删项目 vs 活跃项目、Simulators、包管理、过期 node_modules)
            let s5Start = ContinuousClock.now
            await self?.updateScanStatus(progress: 0.535, step: 5, path: "扫描 Xcode 与开发构建缓存…", items: discovered)
            let derivedDataURL = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
            if fm.fileExists(atPath: derivedDataURL.path), matcher.evaluate(url: derivedDataURL).isAllowed,
               let ddFolders = try? fm.contentsOfDirectory(at: derivedDataURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                var activeSize: Int64 = 0
                var deletedProjectsSize: Int64 = 0
                var deletedProjectItems: [(String, URL, Int64)] = []
                for sub in ddFolders {
                    if Task.isCancelled { return }
                    let sz = Self.calculateDirectorySize(url: sub)
                    guard sz > 1024 * 1024 else { continue }
                    let infoPlist = sub.appendingPathComponent("info.plist")
                    var workspaceMissing = false
                    if let data = try? Data(contentsOf: infoPlist),
                       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                       let workspacePath = plist["WorkspacePath"] as? String {
                        if !fm.fileExists(atPath: workspacePath) {
                            workspaceMissing = true
                        }
                    }
                    if workspaceMissing {
                        deletedProjectsSize += sz
                        deletedProjectItems.append((sub.lastPathComponent, sub, sz))
                    } else {
                        activeSize += sz
                    }
                }
                if !deletedProjectItems.isEmpty {
                    for (folderName, url, sz) in deletedProjectItems where sz > 1024 * 1024 * 5 {
                        discovered.append(
                            CleanItem(
                                name: "Xcode 已删除项目产物: \(folderName)",
                                category: .developerCache,
                                bucket: .suggested,
                                path: url,
                                sizeBytes: sz,
                                detail: "原工程目录已不在磁盘上，属于纯废弃构建索引与派生数据",
                                ownerBundleID: "com.apple.dt.Xcode",
                                ownerAppName: "Xcode"
                            )
                        )
                    }
                }
                if activeSize > 1024 * 1024 * 20 {
                    discovered.append(
                        CleanItem(
                            name: "Xcode DerivedData (活跃项目编译产物)",
                            category: .developerCache,
                            bucket: .suggested,
                            path: derivedDataURL,
                            sizeBytes: activeSize,
                            detail: "编译派生产物，清理后首次编译会重建",
                            ownerBundleID: "com.apple.dt.Xcode",
                            ownerAppName: "Xcode"
                        )
                    )
                }
            }

            let devPaths: [(String, String?, String?, URL, CleanReviewBucket, String)] = [
                ("iOS 模拟器运行时缓存", "com.apple.CoreSimulator.SimulatorTrampoline", "Xcode Simulator", home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true), .suggested, "iOS 模拟器 dyld 共享缓存"),
                ("Xcode 运行与增量安装包缓存", "com.apple.dt.Xcode", "Xcode", home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode", isDirectory: true), .suggested, "Xcode 组件增量下载包与临时缓存，清理后可按需重建"),
                ("Xcode iOS 设备调试符号 (DeviceSupport)", "com.apple.dt.Xcode", "Xcode", home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true), .needsReview, "真机调试符号文件，清理后连接旧系统真机将重新拷贝"),
                ("Xcode 历史归档包 (Archives)", "com.apple.dt.Xcode", "Xcode", home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true), .needsReview, "用于上架/回溯的打包归档与 dSYM 符号，请确认后再删"),
                ("SwiftPM 构建与包缓存", nil, nil, home.appendingPathComponent("Library/Caches/org.swift.swiftpm", isDirectory: true), .suggested, "Swift Package Manager 已下载包源码与清单缓存"),
                ("Homebrew 下载缓存", nil, nil, home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true), .suggested, "已下载的 brew 软件包压缩归档"),
                ("CocoaPods 仓库与缓存", nil, nil, home.appendingPathComponent(".cocoapods/cache", isDirectory: true), .suggested, "CocoaPods 本地缓存归档"),
                ("npm 依赖包缓存", nil, nil, home.appendingPathComponent(".npm/_cacache", isDirectory: true), .suggested, "Node.js npm 内容寻址缓存"),
                ("pnpm 全局存储缓存", nil, nil, home.appendingPathComponent("Library/pnpm/store", isDirectory: true), .needsReview, "pnpm 硬链接依赖存储池"),
                ("Gradle 构建中间件缓存", nil, nil, home.appendingPathComponent(".gradle/caches", isDirectory: true), .suggested, "Android / JVM 构建缓存"),
                ("Python pip 下载缓存", nil, nil, home.appendingPathComponent("Library/Caches/pip", isDirectory: true), .suggested, "pip wheel 软件包本地下载缓存"),
                ("Python uv 工具包缓存", nil, nil, home.appendingPathComponent(".cache/uv", isDirectory: true), .suggested, "uv 虚拟环境与依赖硬链接缓存"),
                ("Rust Cargo 索引与归档缓存", nil, nil, home.appendingPathComponent(".cargo/registry/cache", isDirectory: true), .suggested, "Rust crate 编译归档源码缓存")
            ]
            for (title, bundleID, appName, url, defaultBucket, desc) in devPaths {
                if Task.isCancelled { return }
                guard fm.fileExists(atPath: url.path) else { continue }
                let sz = Self.calculateDirectorySize(url: url)
                guard sz > 1024 * 1024 * 5 else { continue }
                let verdict = matcher.evaluate(url: url)
                discovered.append(
                    CleanItem(
                        name: title,
                        category: .developerCache,
                        bucket: verdict.isAllowed ? defaultBucket : .excluded,
                        path: url,
                        sizeBytes: sz,
                        detail: verdict.isAllowed ? desc : "受保护名单规则跳过",
                        isProtected: !verdict.isAllowed,
                        guardReason: verdict.detailText,
                        ownerBundleID: bundleID,
                        ownerAppName: appName
                    )
                )
            }

            // 5.2 长期未动项目里的 node_modules (>30天未改动)
            await self?.updateScanStatus(progress: 0.61, step: 5, path: "检查长期闲置项目的 node_modules…", items: discovered)
            let staleNodeModules = Self.discoverStaleNodeModules(home: home, now: now, matcher: matcher)
            discovered.append(contentsOf: staleNodeModules)
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 5, to: 0.645, startedAt: s5Start, path: "开发构建与依赖检查完成", items: discovered)

            // 6. 已卸载应用残留 & Saved State (~/Library/Application Support & Saved Application State)
            let s6Start = ContinuousClock.now
            await self?.updateScanStatus(progress: 0.66, step: 6, path: "扫描应用卸载残留与旧窗口状态…", items: discovered)
            let leftovers = Self.discoverAppLeftovers(
                home: home,
                installedNames: installedBundles.names,
                installedBundleIDs: installedBundles.bundleIDs,
                runningBundleIDs: runningBundles,
                matcher: matcher
            )
            discovered.append(contentsOf: leftovers)
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 6, to: 0.770, startedAt: s6Start, path: "应用卸载残留核验完成", items: discovered)

            // 7. 废纸篓与超期安装包残留 (Downloads + Desktop)
            let s7Start = ContinuousClock.now
            await self?.updateScanStatus(progress: 0.785, step: 7, path: "扫描系统与外置盘废纸篓…", items: discovered)
            let allTrashURLs = Self.discoverAllTrashLocations()
            var totalTrashSize: Int64 = 0
            var trashItemCount = 0

            for tURL in allTrashURLs {
                if Task.isCancelled { return }
                if matcher.evaluate(url: tURL).isAllowed {
                    let sz = Self.calculateDirectorySize(url: tURL)
                    totalTrashSize += sz
                    if let subs = try? fm.contentsOfDirectory(at: tURL, includingPropertiesForKeys: nil, options: []) {
                        trashItemCount += subs.count
                    }
                }
            }

            if totalTrashSize > 0 || trashItemCount > 0 {
                let primaryTrash = allTrashURLs.first ?? home.appendingPathComponent(".Trash", isDirectory: true)
                let displaySize = max(totalTrashSize, Int64(trashItemCount) * 1024 * 1024)
                let itemCountText = trashItemCount > 0 ? " (\(trashItemCount) 个项目)" : ""
                discovered.append(
                    CleanItem(
                        name: "废纸篓待清空文件 (系统与外置盘)",
                        category: .userTrash,
                        bucket: .needsReview,
                        path: primaryTrash,
                        sizeBytes: displaySize,
                        detail: "包含系统盘与外置挂载硬盘中等待永久清空的内容\(itemCountText)"
                    )
                )
            }

            // 下载 & 桌面目录安装包：结合“是否已安装”与“放置天数（>=14天）”精确分级
            let desktopURL = fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop", isDirectory: true)
            let installerSearchDirs: [(String, URL)] = [
                ("下载", home.appendingPathComponent("Downloads", isDirectory: true)),
                ("桌面", desktopURL)
            ]
            await self?.updateScanStatus(progress: 0.84, step: 7, path: "分析下载与桌面目录中的安装包…", items: discovered)
            for (dirLabel, dirURL) in installerSearchDirs {
                guard let files = try? fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for fileURL in files {
                    if Task.isCancelled { return }
                    let ext = fileURL.pathExtension.lowercased()
                    guard ext == "dmg" || ext == "pkg" || ext == "iso" else { continue }
                    let verdict = matcher.evaluate(url: fileURL)
                    guard verdict.isAllowed else { continue }

                    let isPlaceholder = CleanWhitelistMatcher.isICloudPlaceholder(url: fileURL)
                    let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey])
                    let size = isPlaceholder ? 0 : (vals?.fileSize.map { Int64($0) } ?? 0)
                    guard size > 1024 * 1024 * 10 || isPlaceholder else { continue }

                    let refDate = vals?.addedToDirectoryDate ?? vals?.contentModificationDate ?? now
                    let ageDays = max(0, Calendar.current.dateComponents([.day], from: refDate, to: now).day ?? 0)
                    let isInstalled = Self.looksInstalled(installerFileName: fileURL.deletingPathExtension().lastPathComponent, installedNames: installedBundles.names)

                    let bucket: CleanReviewBucket = isPlaceholder
                        ? .excluded
                        : ((ageDays >= 14 && isInstalled) ? .suggested : .needsReview)
                    var detailParts = ["位于「\(dirLabel)」目录 · 已存放 \(ageDays) 天"]
                    detailParts.append(isInstalled ? "对应软件已在「应用程序」中安装" : "未在「应用程序」中匹配到同名软件，请核对是否还需安装")
                    if isPlaceholder {
                        detailParts.append("iCloud 云端占位文件，自动跳过以防止触发下载或丢失")
                    }

                    discovered.append(
                        CleanItem(
                            name: "安装包: \(fileURL.lastPathComponent)",
                            category: .userTrash,
                            bucket: bucket,
                            path: fileURL,
                            sizeBytes: size,
                            detail: detailParts.joined(separator: " · "),
                            isProtected: isPlaceholder,
                            guardReason: isPlaceholder ? "iCloud 云端未下载占位文件，已跳过" : nil,
                            itemAgeDays: ageDays,
                            isInstalledInstaller: isInstalled,
                            isCloudPlaceholder: isPlaceholder
                        )
                    )
                }
            }
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 7, to: 0.895, startedAt: s7Start, path: "废纸篓与安装包排查完成", items: discovered)

            // 8. 仅手动管理项 (.manualOnly): iOS/iPad 备份、Parallels 虚拟机、Docker 磁盘映像、iCloud 云盘副本（完整扫描精确统计）
            let s8Start = ContinuousClock.now
            let manualCandidates = Self.manualManagementCandidates(home: home)
            await self?.updateScanStatus(progress: 0.905, step: 8, path: "核对手动大体积存储项…", items: discovered)
            for (mIdx, candidate) in manualCandidates.enumerated() {
                if Task.isCancelled { return }
                guard fm.fileExists(atPath: candidate.url.path) else { continue }
                let mProgress = 0.905 + 0.08 * (Double(mIdx) / Double(max(1, manualCandidates.count)))
                await self?.updateScanStatus(progress: mProgress, step: 8, path: "核对手动大体积项: \(candidate.title)", items: discovered)
                let sz = Self.calculateDirectorySize(url: candidate.url)
                if sz > 1024 * 1024 * 200 { // > 200 MB
                    discovered.append(
                        CleanItem(
                            name: candidate.title,
                            category: candidate.category,
                            bucket: .manualOnly,
                            path: candidate.url,
                            sizeBytes: sz,
                            detail: candidate.detail,
                            isProtected: true,
                            recommendedActionHint: candidate.hint
                        )
                    )
                }
            }
            if Task.isCancelled { return }
            await self?.paceScanStage(step: 8, to: 0.995, startedAt: s8Start, path: "正在整理扫描结果与保护规则…", items: discovered)
            discovered.sort { $0.sizeBytes > $1.sizeBytes }

            if Task.isCancelled { return }
            await self?.finishScan(items: discovered)
        }
    }

    private func paceScanStage(
        step: Int,
        to endProgress: Double,
        startedAt stageStart: ContinuousClock.Instant,
        targetStageDuration: Duration = .milliseconds(1280),
        path: String,
        items: [CleanItem]
    ) async {
        let startProgress = max(scanProgressValue, min(endProgress, Double(step - 1) * 0.125))
        let elapsed = stageStart.duration(to: ContinuousClock.now)
        let remaining = targetStageDuration - elapsed
        guard remaining > .zero else {
            updateScanStatus(progress: endProgress, step: step, path: path, items: items)
            return
        }

        let remainingMs = Double(remaining.components.seconds) * 1000.0
            + Double(remaining.components.attoseconds) / 1_000_000_000_000_000.0
        let ticks = max(1, Int((remainingMs / 45.0).rounded(.up)))
        let sliceMs = max(20, Int((remainingMs / Double(ticks)).rounded()))

        for tick in 1...ticks {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(sliceMs))
            if Task.isCancelled { return }
            let t = Double(tick) / Double(ticks)
            let eased = startProgress + (endProgress - startProgress) * t
            updateScanStatus(progress: eased, step: step, path: path, items: items)
        }
    }

    private func updateScanStatus(progress: Double, step: Int, path: String, foundCount: Int, foundBytes: Int64) {
        self.status = .scanning(progress: progress, currentPath: path)
        self.currentScanPath = path
        self.scanProgressValue = progress
        self.scanStageIndex = step
        self.scanDiscoveredCount = foundCount
        self.scanDiscoveredBytes = foundBytes
    }

    private func updateScanStatus(progress: Double, step: Int, path: String, items: [CleanItem]) {
        let bytes = items.filter(\.isSelectable).reduce(Int64(0)) { $0 + $1.sizeBytes }
        updateScanStatus(progress: progress, step: step, path: path, foundCount: items.count, foundBytes: bytes)
    }

    private func finishScan(items: [CleanItem]) {
        self.scannedItems = items
        let autoSelected = items.filter { item in
            item.isSelectable && item.bucket == .suggested && !self.isItemDeselected(item: item)
        }
        self.selectedItemIDs = Set(autoSelected.map(\.id))
        let total = items.filter(\.isSelectable).reduce(0) { $0 + $1.sizeBytes }
        self.scanProgressValue = 1.0
        self.scanStageIndex = 8
        self.scanDiscoveredCount = items.count
        self.scanDiscoveredBytes = total
        self.status = .completed(totalBytes: total, itemCount: items.count)
        self.currentScanPath = ""
    }

    // MARK: - Cleaning Execution Engine (运行中冲突检查 + 安全删除 + 结构化回执)

    /// 点击“立即清理”入口：先检测是否有正在运行的属主 App，若有则弹窗引导，否则直接清理。
    public func executeClean() {
        guard !selectedItemIDs.isEmpty else { return }
        let selectedItems = scannedItems.filter { selectedItemIDs.contains($0.id) && $0.isSelectable }
        if let readFailure = CleanProtectionStore.shared.readFailureReason() {
            let blockedEntries = selectedItems.map {
                CleanResultEntry(
                    name: $0.name,
                    path: $0.path,
                    sizeBytes: $0.sizeBytes,
                    disposition: .skippedWhitelist,
                    note: readFailure
                )
            }
            self.lastExecutionSummary = CleanExecutionSummary(
                freedBytes: 0,
                cleanedCount: 0,
                skippedCount: blockedEntries.count,
                failedCount: 0,
                entries: blockedEntries
            )
            self.showExecutionDetails = true
            self.status = .cleaned(freedBytes: 0, itemCount: 0)
            return
        }
        let runningApps = NSWorkspace.shared.runningApplications
        var conflictMap: [String: (appName: String, items: [String])] = [:]

        for item in selectedItems {
            guard let bundleID = item.ownerBundleID else { continue }
            if let running = runningApps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                let appName = item.ownerAppName ?? running.localizedName ?? bundleID
                var entry = conflictMap[bundleID] ?? (appName, [])
                entry.items.append(item.name)
                conflictMap[bundleID] = entry
            }
        }

        if !conflictMap.isEmpty {
            self.pendingRunningConflicts = conflictMap.map { key, val in
                CleanerRunningConflict(id: key, appName: val.appName, itemNames: val.items)
            }.sorted { $0.appName < $1.appName }
            self.isRunningConflictDialogPresented = true
            return
        }

        performExecuteClean(quitConflicts: false, skipRunningConflicts: false)
    }

    public func resolveRunningConflictsAndClean(quitApps: Bool) {
        self.isRunningConflictDialogPresented = false
        let bundleIDsToQuit = Set(pendingRunningConflicts.map(\.id))
        self.pendingRunningConflicts = []

        if quitApps {
            for app in NSWorkspace.shared.runningApplications {
                if let bid = app.bundleIdentifier, bundleIDsToQuit.contains(where: { $0.caseInsensitiveCompare(bid) == .orderedSame }) {
                    app.terminate()
                }
            }
            // 给目标 App 短暂保存与退出时间
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.performExecuteClean(quitConflicts: true, skipRunningConflicts: false)
            }
        } else {
            performExecuteClean(quitConflicts: false, skipRunningConflicts: true)
        }
    }

    private func performExecuteClean(quitConflicts: Bool, skipRunningConflicts: Bool) {
        let toClean = scannedItems.filter { selectedItemIDs.contains($0.id) && $0.isSelectable }
        guard !toClean.isEmpty else { return }

        currentTask?.cancel()
        status = .cleaning(progress: 0.05, currentItem: "准备安全清理…")

        let currentlyRunningBundles: Set<String> = skipRunningConflicts
            ? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            : []

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let matcher = CleanWhitelistMatcher.shared
            let mode = await self?.deleteMode ?? .moveToTrash

            var freed: Int64 = 0
            var count = 0
            var skippedCount = 0
            var failedCount = 0
            var entries: [CleanResultEntry] = []
            var succeededIDs: Set<UUID> = []

            let regularItems = toClean.filter { $0.category != .userTrash && $0.path.lastPathComponent != ".Trash" }
            let trashItems = toClean.filter { $0.category == .userTrash || $0.path.lastPathComponent == ".Trash" }
            let totalSteps = max(1, regularItems.count + (trashItems.isEmpty ? 0 : 1))
            var currentStep = 0

            for item in regularItems {
                if Task.isCancelled { return }
                currentStep += 1
                let pct = Double(currentStep) / Double(totalSteps)
                await self?.updateCleanProgress(progress: pct, name: "正在清理: \(item.name)")

                if !fm.fileExists(atPath: item.path.path) {
                    skippedCount += 1
                    entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .skippedMissing))
                    continue
                }

                if skipRunningConflicts, let ownerID = item.ownerBundleID,
                   currentlyRunningBundles.contains(where: { $0.caseInsensitiveCompare(ownerID) == .orderedSame }) {
                    skippedCount += 1
                    entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .skippedRunning, note: item.ownerAppName))
                    continue
                }

                let verdict = matcher.evaluate(url: item.path)
                if case .blocked(let reason, _) = verdict {
                    skippedCount += 1
                    let disp: CleanResultDisposition = (reason == .whitelisted) ? .skippedWhitelist : .skippedProtected
                    entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: disp, note: verdict.detailText))
                    continue
                }

                if Self.isCloudPlaceholderItem(url: item.path) {
                    skippedCount += 1
                    entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .skippedCloudPlaceholder))
                    continue
                }

                let ext = item.path.pathExtension.lowercased()
                let isSingleTargetFile = (ext == "dmg" || ext == "pkg" || ext == "iso") || !(Self.isDirectory(url: item.path))

                if isSingleTargetFile || item.category == .appLeftovers || item.path.lastPathComponent == "node_modules" {
                    do {
                        if mode == .moveToTrash {
                            try fm.trashItem(at: item.path, resultingItemURL: nil)
                            entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .movedToTrash))
                        } else {
                            try fm.removeItem(at: item.path)
                            entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .cleaned))
                        }
                        freed += item.sizeBytes
                        count += 1
                        succeededIDs.insert(item.id)
                    } catch {
                        failedCount += 1
                        let disp = Self.classifyDeleteError(error, url: item.path)
                        entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: disp, note: error.localizedDescription))
                    }
                } else {
                    if let subs = try? fm.contentsOfDirectory(at: item.path, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) {
                        var folderFreed: Int64 = 0
                        var removedSubCount = 0
                        var subHadFailure = false
                        var lastSubError: Error?

                        for sub in subs {
                            let subVerdict = matcher.evaluate(url: sub)
                            guard subVerdict.isAllowed else {
                                continue
                            }
                            if Self.isCloudPlaceholderItem(url: sub) {
                                continue
                            }
                            let isSymlink = (try? sub.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                            let subSize: Int64 = isSymlink ? 0 : Self.calculateItemOrDirectorySize(url: sub)
                            do {
                                try fm.removeItem(at: sub)
                                removedSubCount += 1
                                folderFreed += subSize
                            } catch {
                                subHadFailure = true
                                lastSubError = error
                            }
                        }

                        if removedSubCount > 0 {
                            let gained = min(item.sizeBytes, max(folderFreed, subHadFailure ? folderFreed : item.sizeBytes))
                            freed += gained
                            count += 1
                            succeededIDs.insert(item.id)
                            entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: gained, disposition: .cleaned))
                        } else if subHadFailure, let lastSubError {
                            failedCount += 1
                            let disp = Self.classifyDeleteError(lastSubError, url: item.path)
                            entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: disp, note: lastSubError.localizedDescription))
                        } else {
                            skippedCount += 1
                            entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .skippedProtected))
                        }
                    } else {
                        failedCount += 1
                        entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .skippedPermission))
                    }
                }
            }

            // 阶段二：废纸篓与独立安装包
            if !trashItems.isEmpty {
                if Task.isCancelled { return }
                currentStep += 1
                let pct = Double(currentStep) / Double(totalSteps)
                await self?.updateCleanProgress(progress: pct, name: "正在清理废纸篓与选定安装包…")

                let installerItems = trashItems.filter {
                    let ext = $0.path.pathExtension.lowercased()
                    return ext == "dmg" || ext == "pkg" || ext == "iso"
                }
                let actualTrashItems = trashItems.filter {
                    let ext = $0.path.pathExtension.lowercased()
                    return !(ext == "dmg" || ext == "pkg" || ext == "iso")
                }

                for inst in installerItems {
                    do {
                        if mode == .moveToTrash {
                            try fm.trashItem(at: inst.path, resultingItemURL: nil)
                            entries.append(CleanResultEntry(name: inst.name, path: inst.path, sizeBytes: inst.sizeBytes, disposition: .movedToTrash))
                        } else {
                            try fm.removeItem(at: inst.path)
                            entries.append(CleanResultEntry(name: inst.name, path: inst.path, sizeBytes: inst.sizeBytes, disposition: .cleaned))
                        }
                        freed += inst.sizeBytes
                        count += 1
                        succeededIDs.insert(inst.id)
                    } catch {
                        failedCount += 1
                        entries.append(CleanResultEntry(name: inst.name, path: inst.path, sizeBytes: inst.sizeBytes, disposition: Self.classifyDeleteError(error, url: inst.path), note: error.localizedDescription))
                    }
                }

                if !actualTrashItems.isEmpty {
                    let appleScriptSource = "tell application \"Finder\" to empty trash"
                    if let script = NSAppleScript(source: appleScriptSource) {
                        var err: NSDictionary?
                        script.executeAndReturnError(&err)
                    }

                    let allTrashes = Self.discoverAllTrashLocations()
                    for tURL in allTrashes {
                        if let subs = try? fm.contentsOfDirectory(at: tURL, includingPropertiesForKeys: nil, options: []) {
                            for sub in subs {
                                try? fm.removeItem(at: sub)
                            }
                        }
                    }

                    let trashSize = actualTrashItems.reduce(0) { $0 + $1.sizeBytes }
                    freed += trashSize
                    count += actualTrashItems.count
                    for item in actualTrashItems {
                        succeededIDs.insert(item.id)
                        entries.append(CleanResultEntry(name: item.name, path: item.path, sizeBytes: item.sizeBytes, disposition: .cleaned))
                    }

                    if let firstTrash = actualTrashItems.first?.path {
                        NSWorkspace.shared.noteFileSystemChanged(firstTrash.path)
                    }
                }
            }

            let summary = CleanExecutionSummary(
                freedBytes: freed,
                cleanedCount: count,
                skippedCount: skippedCount,
                failedCount: failedCount,
                entries: entries
            )
            await self?.finishClean(freed: freed, count: count, succeededIDs: succeededIDs, summary: summary)
        }
    }

    private func updateCleanProgress(progress: Double, name: String) {
        self.status = .cleaning(progress: progress, currentItem: name)
    }

    private func finishClean(freed: Int64, count: Int, succeededIDs: Set<UUID>, summary: CleanExecutionSummary) {
        self.lastFreedBytes = freed
        self.lastCleanDate = Date()
        UserDefaults.standard.set(Int(freed), forKey: "PG_Clean_LastFreedBytes")
        UserDefaults.standard.set(lastCleanDate, forKey: "PG_Clean_LastDate")

        self.lastExecutionSummary = summary
        self.status = .cleaned(freedBytes: freed, itemCount: count)
        self.scannedItems.removeAll { succeededIDs.contains($0.id) }
        self.selectedItemIDs.subtract(succeededIDs)
    }

    // MARK: - Discovery & Helper Utilities

    nonisolated private static func isDirectory(url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated private static func isCloudPlaceholderItem(url: URL) -> Bool {
        CleanWhitelistMatcher.isICloudPlaceholder(url: url)
    }

    nonisolated private static func classifyDeleteError(_ error: Error, url: URL) -> CleanResultDisposition {
        if let rv = try? url.resourceValues(forKeys: [.isUserImmutableKey, .isSystemImmutableKey]),
           rv.isUserImmutable == true || rv.isSystemImmutable == true {
            return .failedLocked
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let immutable = attrs[.immutable] as? Bool, immutable {
                return .failedLocked
            }
            if let ownerID = attrs[.ownerAccountID] as? NSNumber, ownerID.intValue == 0 {
                return .failedRootOwned
            }
        }
        let nsErr = error as NSError
        if (nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileWriteNoPermissionError)
            || (nsErr.domain == NSPOSIXErrorDomain && (nsErr.code == Int(EACCES) || nsErr.code == Int(EPERM))) {
            return .failedNotWritable
        }
        return .failedOther
    }

    nonisolated private static func isCommunicationIdentifier(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("wechat") || lower.contains("xinwechat")
            || lower.contains("tencent.qq") || lower.contains("dingtalk")
            || lower.contains("feishu") || lower.contains("lark")
            || lower.contains("telegram") || lower.contains("discord")
            || lower.contains("slack")
    }

    nonisolated private static func isBrowserIdentifier(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("safari") || lower.contains("chrome")
            || lower.contains("firefox") || lower.contains("edge")
            || lower.contains("brave") || lower.contains("arc")
    }

    nonisolated private static func discoverInstalledAppInfo() -> (names: [String], bundleIDs: Set<String>) {
        let fm = FileManager.default
        let appDirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var names: [String] = []
        var bundleIDs: Set<String> = []
        for dir in appDirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in items where item.pathExtension.lowercased() == "app" {
                let rawName = item.deletingPathExtension().lastPathComponent.lowercased()
                names.append(rawName)
                if let bundle = Bundle(url: item), let bid = bundle.bundleIdentifier {
                    bundleIDs.insert(bid.lowercased())
                }
            }
        }
        return (names, bundleIDs)
    }

    nonisolated private static func looksInstalled(installerFileName: String, installedNames: [String]) -> Bool {
        let normalized = installerFileName.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let tokens = normalized.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard let firstToken = tokens.first else { return false }
        return installedNames.contains { appName in
            appName == firstToken || appName.contains(firstToken) || firstToken.contains(appName)
        }
    }

    nonisolated private static func discoverStaleNodeModules(
        home: URL,
        now: Date,
        matcher: CleanWhitelistMatcher
    ) -> [CleanItem] {
        let fm = FileManager.default
        let searchRoots = ["Developer", "Projects", "Code", "Workspace", "work", "src"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
        var results: [CleanItem] = []

        func walk(dir: URL, depth: Int) {
            guard depth <= 3, results.count < 16 else { return }
            guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
            for sub in subs {
                let vals = try? sub.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .isSymbolicLinkKey])
                guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }
                if sub.lastPathComponent == "node_modules" {
                    let projectDir = sub.deletingLastPathComponent()
                    let projVals = try? projectDir.resourceValues(forKeys: [.contentModificationDateKey])
                    let lastMod = projVals?.contentModificationDate ?? vals?.contentModificationDate ?? now
                    let ageDays = max(0, Calendar.current.dateComponents([.day], from: lastMod, to: now).day ?? 0)
                    guard ageDays >= 30, matcher.evaluate(url: sub, allowInstallersOnlyInDesktopDownloads: false).isAllowed else { continue }
                    let size = calculateDirectorySize(url: sub)
                    if size > 1024 * 1024 * 30 { // > 30 MB
                        results.append(
                            CleanItem(
                                name: "闲置依赖: \(projectDir.lastPathComponent)/node_modules",
                                category: .developerCache,
                                bucket: .needsReview,
                                path: sub,
                                sizeBytes: size,
                                detail: "所属项目超过 \(ageDays) 天未修改 · 重新 npm/pnpm install 即可恢复",
                                itemAgeDays: ageDays
                            )
                        )
                    }
                } else if !sub.lastPathComponent.hasPrefix(".") && sub.lastPathComponent != "DerivedData" {
                    walk(dir: sub, depth: depth + 1)
                }
            }
        }

        for root in searchRoots where fm.fileExists(atPath: root.path) {
            walk(dir: root, depth: 0)
        }
        return results
    }

    nonisolated private static func discoverAppLeftovers(
        home: URL,
        installedNames: [String],
        installedBundleIDs: Set<String>,
        runningBundleIDs: Set<String>,
        matcher: CleanWhitelistMatcher
    ) -> [CleanItem] {
        let fm = FileManager.default
        let savedStateDir = home.appendingPathComponent("Library/Saved Application State", isDirectory: true)
        var results: [CleanItem] = []

        if let states = try? fm.contentsOfDirectory(at: savedStateDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for state in states where state.pathExtension == "savedState" {
                let bid = state.deletingPathExtension().lastPathComponent.lowercased()
                if bid.hasPrefix("com.apple.") || installedBundleIDs.contains(bid) || runningBundleIDs.contains(where: { $0.lowercased() == bid }) {
                    continue
                }
                let verdict = matcher.evaluate(url: state)
                guard verdict.isAllowed else { continue }
                let size = calculateDirectorySize(url: state)
                if size > 1024 * 256 {
                    results.append(
                        CleanItem(
                            name: "已卸载应用窗口状态: \(state.deletingPathExtension().lastPathComponent)",
                            category: .appLeftovers,
                            bucket: .needsReview,
                            path: state,
                            sizeBytes: size,
                            detail: "未在「应用程序」中找到对应 App · 可能是历史卸载遗留"
                        )
                    )
                }
            }
        }

        // 查找已卸载第三方 App 在 ~/Library/Application Support 留下的大目录（保守策略，绝不碰 Apple / 开发工具）
        let appSupportDir = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let conservativeKeepKeywords = ["apple", "icloud", "cloud", "sync", "system", "syspulse", "google", "microsoft", "adobe", "jetbrains", "cursor", "vscode", "code", "claude", "codex", "antigravity", "ollama", "docker", "1password", "bitwarden", "raycast", "alfred", "obsidian", "notion", "arc", "chrome", "firefox", "wechat", "tencent", "qq", "dingtalk", "feishu", "lark", "slack", "discord", "telegram", "steam", "mobilesync", "crashreporter", "knowledge"]
        if let supportFolders = try? fm.contentsOfDirectory(at: appSupportDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for sub in supportFolders {
                let raw = sub.lastPathComponent
                let lower = raw.lowercased()
                if conservativeKeepKeywords.contains(where: { lower.contains($0) }) { continue }
                if installedNames.contains(where: { lower.contains($0) || $0.contains(lower) }) { continue }
                if installedBundleIDs.contains(lower) { continue }
                let verdict = matcher.evaluate(url: sub)
                guard verdict.isAllowed else { continue }
                let size = calculateDirectorySize(url: sub)
                if size > 1024 * 1024 * 25 { // > 25 MB 才展示给用户复核
                    results.append(
                        CleanItem(
                            name: "疑似卸载残留: \(raw)",
                            category: .appLeftovers,
                            bucket: .needsReview,
                            path: sub,
                            sizeBytes: size,
                            detail: "未匹配到同名已安装 App · 若已不用或含旧配置，请确认后再清理"
                        )
                    )
                }
            }
        }

        // 查找浏览器/应用升级残留目录（例如 GoogleUpdater / EdgeUpdater / Keystone）
        let updaterSpecs: [CleanTargetSpec] = [
            CleanTargetSpec(
                title: "Google 软件更新缓存与暂存",
                category: .appLeftovers,
                bucket: .suggested,
                url: home.appendingPathComponent("Library/Caches/com.google.Keystone", isDirectory: true),
                detail: "Google 自动更新检查留下的临时下载安装包与缓存",
                bundleID: "com.google.Keystone",
                appName: "Google Updater",
                minBytes: 1024 * 1024
            ),
            CleanTargetSpec(
                title: "GoogleUpdater 安装器暂存",
                category: .appLeftovers,
                bucket: .needsReview,
                url: home.appendingPathComponent("Library/Application Support/Google/GoogleUpdater", isDirectory: true),
                detail: "浏览器自动更新程序解压暂存，若刚执行过更新可安全清理",
                bundleID: "com.google.GoogleUpdater",
                appName: "Google Updater",
                minBytes: 1024 * 1024 * 10
            ),
            CleanTargetSpec(
                title: "Microsoft Edge 更新暂存",
                category: .appLeftovers,
                bucket: .needsReview,
                url: home.appendingPathComponent("Library/Application Support/Microsoft/EdgeUpdater", isDirectory: true),
                detail: "Microsoft Edge 浏览器历史更新增量安装包暂存目录",
                bundleID: "com.microsoft.EdgeUpdater",
                appName: "Edge Updater",
                minBytes: 1024 * 1024 * 10
            )
        ]
        for spec in updaterSpecs {
            if let item = evaluateTargetSpec(spec, matcher: matcher) {
                results.append(item)
            }
        }
        return results
    }

    private struct CleanTargetSpec {
        let title: String
        let category: CleanCategory
        let bucket: CleanReviewBucket
        let url: URL
        let detail: String
        let bundleID: String?
        let appName: String?
        let minBytes: Int64
    }

    nonisolated private static func evaluateTargetSpec(_ spec: CleanTargetSpec, matcher: CleanWhitelistMatcher) -> CleanItem? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: spec.url.path) else { return nil }
        let sz = calculateDirectorySize(url: spec.url)
        guard sz >= spec.minBytes else { return nil }
        let verdict = matcher.evaluate(url: spec.url)
        return CleanItem(
            name: spec.title,
            category: spec.category,
            bucket: verdict.isAllowed ? spec.bucket : .excluded,
            path: spec.url,
            sizeBytes: sz,
            detail: verdict.isAllowed ? spec.detail : "受清理保护名单保护跳过",
            isProtected: !verdict.isAllowed,
            guardReason: verdict.detailText,
            ownerBundleID: spec.bundleID,
            ownerAppName: spec.appName ?? spec.bundleID.map { humanReadableAppName(bundleID: $0) }
        )
    }

    nonisolated private static func cloudDesignAndMailTargetSpecs(home: URL) -> [CleanTargetSpec] {
        [
            // 网盘纯缓存与运行日志（不触碰同步正本目录）
            CleanTargetSpec(title: "OneDrive 运行缓存与日志", category: .systemLogs, bucket: .suggested, url: home.appendingPathComponent("Library/Logs/OneDrive", isDirectory: true), detail: "OneDrive 客户端诊断日志，不影响云盘同步文件", bundleID: "com.microsoft.OneDrive", appName: "OneDrive", minBytes: 1024 * 1024 * 2),
            CleanTargetSpec(title: "Dropbox 运行日志", category: .systemLogs, bucket: .suggested, url: home.appendingPathComponent(".dropbox/logs", isDirectory: true), detail: "Dropbox 客户端运行日志，可安全清理", bundleID: "com.getdropbox.dropbox", appName: "Dropbox", minBytes: 1024 * 1024 * 2),
            CleanTargetSpec(title: "百度网盘客户端日志", category: .systemLogs, bucket: .suggested, url: home.appendingPathComponent("Library/Application Support/BaiduNetdisk-Mac/Logs", isDirectory: true), detail: "百度网盘历史日志与调试记录，不影响已下载与云端文件", bundleID: "com.baidu.BaiduNetdiskMac", appName: "百度网盘", minBytes: 1024 * 1024 * 2),
            CleanTargetSpec(title: "阿里云盘缩略图与网络缓存", category: .userCaches, bucket: .suggested, url: home.appendingPathComponent("Library/Caches/com.alicloud.smartdrive", isDirectory: true), detail: "阿里云盘缩略图与在线预览临时缓存", bundleID: "com.alicloud.smartdrive", appName: "阿里云盘", minBytes: 1024 * 1024 * 5),
            CleanTargetSpec(title: "夸克网盘预览与网页缓存", category: .userCaches, bucket: .suggested, url: home.appendingPathComponent("Library/Application Support/QuarkCloudDrive/Cache", isDirectory: true), detail: "夸克网盘界面及在线预览临时缓存", bundleID: "com.quark.QuarkCloudDrive", appName: "夸克网盘", minBytes: 1024 * 1024 * 5),

            // 创意设计软件渲染/媒体缓存
            CleanTargetSpec(title: "Figma 本地渲染缓存", category: .userCaches, bucket: .suggested, url: home.appendingPathComponent("Library/Application Support/Figma/Cache", isDirectory: true), detail: "Figma 离线字体、资源瓦片与渲染临时缓存，云端工程不受影响", bundleID: "com.figma.Desktop", appName: "Figma", minBytes: 1024 * 1024 * 5),
            CleanTargetSpec(title: "Adobe 通用媒体与渲染缓存", category: .userCaches, bucket: .suggested, url: home.appendingPathComponent("Library/Application Support/Adobe/Common/Media Cache Files", isDirectory: true), detail: "Premiere / After Effects 音视频峰值渲染缓存，重新打开工程可自动重建", bundleID: "com.adobe.PremierePro.24", appName: "Adobe Creative Cloud", minBytes: 1024 * 1024 * 20),
            CleanTargetSpec(title: "Adobe Media Cache 索引", category: .userCaches, bucket: .suggested, url: home.appendingPathComponent("Library/Application Support/Adobe/Common/Media Cache", isDirectory: true), detail: "Adobe 媒体缓存数据库与临时波形文件", bundleID: "com.adobe.AfterEffects", appName: "Adobe Media", minBytes: 1024 * 1024 * 10),
            CleanTargetSpec(title: "DaVinci Resolve 应用缓存", category: .userCaches, bucket: .suggested, url: home.appendingPathComponent("Library/Caches/com.blackmagic-design.DaVinciResolve", isDirectory: true), detail: "DaVinci Resolve 临时图形与界面缓存", bundleID: "com.blackmagic-design.DaVinciResolve", appName: "DaVinci Resolve", minBytes: 1024 * 1024 * 10),

            // Apple Mail 附件本地副本（需复核）
            CleanTargetSpec(title: "邮件 App 已预览附件本地副本", category: .userCaches, bucket: .needsReview, url: home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads", isDirectory: true), detail: "打开邮件附件时生成的本地临时副本，原始附件仍在邮件服务器或收件箱内", bundleID: "com.apple.mail", appName: "邮件", minBytes: 1024 * 1024 * 5)
        ]
    }

    nonisolated private static func manualManagementCandidates(home: URL) -> [(title: String, category: CleanCategory, url: URL, detail: String, hint: String)] {
        [
            (
                "iPhone / iPad 本地设备备份",
                .userTrash,
                home.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true),
                "可能包含重要的手机整机备份，SysPulse 不会自动清理",
                "请在访达侧边栏选设备 › 管理备份，或「系统设置 › 通用 › 储存空间 › iOS 文件」管理"
            ),
            (
                "Docker Desktop 虚拟磁盘镜像",
                .developerCache,
                home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms", isDirectory: true),
                "Docker 容器、镜像与卷共用空间，直接删文件会导致容器损坏",
                "建议在终端执行 docker system df 查看后再用 docker system prune 清理"
            ),
            (
                "Parallels 虚拟机镜像目录",
                .userTrash,
                home.appendingPathComponent("Parallels", isDirectory: true),
                "虚拟机磁盘包含完整系统数据，请按需在 Parallels 内回收空间",
                "关闭虚拟机后在 Parallels Control Center 执行「释放磁盘空间」"
            ),
            (
                "iCloud 云盘本地缓存副本",
                .userCaches,
                home.appendingPathComponent("Library/Mobile Documents", isDirectory: true),
                "同步盘内容由 Apple 云同步托管，本地删除会影响其他设备",
                "可在「Apple 账户 › iCloud › iCloud 云盘」开启优化 Mac 储存空间"
            )
        ]
    }

    nonisolated public static func calculateItemOrDirectorySize(url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            if values.isSymbolicLink == true {
                return 0
            }
            if values.isDirectory == true {
                return calculateDirectorySize(url: url)
            } else {
                return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return calculateDirectorySize(url: url)
    }

    nonisolated public static func calculateDirectorySize(url: URL, timeBudgetSeconds: TimeInterval? = nil) -> Int64 {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return 0
        }
        let fm = FileManager.default
        var totalSize: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }

        let deadline = timeBudgetSeconds.map { CFAbsoluteTimeGetCurrent() + $0 }
        var seenFiles = 0

        for case let fileURL as URL in enumerator {
            seenFiles += 1
            if seenFiles & 255 == 0 {
                if Task.isCancelled { return totalSize }
                if let deadline, CFAbsoluteTimeGetCurrent() >= deadline {
                    return totalSize
                }
            }
            if CleanWhitelistMatcher.isICloudPlaceholder(url: fileURL) {
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            totalSize += Int64(size)
        }
        return totalSize
    }

    nonisolated public static func humanReadableAppName(bundleID: String) -> String {
        let wellKnown: [String: String] = [
            "com.apple.Safari": "Safari",
            "com.google.Chrome": "Google Chrome",
            "com.microsoft.VSCode": "Visual Studio Code",
            "com.sublimetext.4": "Sublime Text",
            "com.tencent.xinWeChat": "微信",
            "com.tencent.qq": "QQ",
            "com.alibaba.DingTalkMac": "钉钉",
            "com.bytedance.feishu": "飞书",
            "com.netease.163music": "网易云音乐",
            "com.apple.dt.Xcode": "Xcode",
            "org.mozilla.firefox": "Firefox",
            "com.spotify.client": "Spotify",
            "com.apple.Music": "音乐",
            "com.figma.Desktop": "Figma",
            "com.bilibili.air": "哔哩哔哩",
            "com.baidu.BaiduNetdiskMac": "百度网盘"
        ]
        if let match = wellKnown[bundleID] {
            return match
        }
        if let catalogAppName = FolderNotesCatalog.shared.appDisplayName(forBundleID: bundleID) {
            return catalogAppName
        }
        let parts = bundleID.split(separator: ".")
        if let last = parts.last {
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return bundleID
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated public static func discoverAllTrashLocations() -> [URL] {
        let fm = FileManager.default
        var trashURLs: [URL] = []
        let uid = getuid()

        let homeTrash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        if fm.fileExists(atPath: homeTrash.path) {
            trashURLs.append(homeTrash)
        }

        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        if let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
            for vol in volumes {
                let candidate1 = vol.appendingPathComponent(".Trashes/\(uid)", isDirectory: true)
                let candidate2 = vol.appendingPathComponent(".Trashes", isDirectory: true)
                let candidate3 = vol.appendingPathComponent(".Trash/\(uid)", isDirectory: true)
                let candidate4 = vol.appendingPathComponent(".Trash", isDirectory: true)
                for c in [candidate1, candidate2, candidate3, candidate4] {
                    if fm.fileExists(atPath: c.path) && !trashURLs.contains(c) {
                        trashURLs.append(c)
                    }
                }
            }
        }

        return trashURLs
    }
}
