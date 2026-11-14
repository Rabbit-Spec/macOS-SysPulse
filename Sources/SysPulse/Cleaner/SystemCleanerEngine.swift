import Foundation
import SwiftUI
import AppKit
import Observation

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
    public var deleteMode: CleanDeleteMode = .moveToTrash {
        didSet {
            UserDefaults.standard.set(deleteMode.rawValue, forKey: "SP_Cleaner_DeleteMode")
        }
    }

    private var currentTask: Task<Void, Never>? = nil

    public init() {
        let savedFreed = UserDefaults.standard.integer(forKey: "PG_Clean_LastFreedBytes")
        if savedFreed > 0 {
            self.lastFreedBytes = Int64(savedFreed)
        }
        if let savedDate = UserDefaults.standard.object(forKey: "PG_Clean_LastDate") as? Date {
            self.lastCleanDate = savedDate
        }
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

    public var totalScannedBytes: Int64 {
        scannedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var selectedBytes: Int64 {
        scannedItems.filter { selectedItemIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var itemsByCategory: [CleanCategory: [CleanItem]] {
        Dictionary(grouping: scannedItems, by: { $0.category })
    }

    public func categoryBytes(_ cat: CleanCategory) -> Int64 {
        (itemsByCategory[cat] ?? []).reduce(0) { $0 + $1.sizeBytes }
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
        scannedItems.filter { !isItemDeselected(item: $0) && selectedItemIDs.contains($0.id) }
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

    // MARK: - Selection Actions

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
        guard let item = scannedItems.first(where: { $0.id == id }) else { return }
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

    public func selectAll(category: CleanCategory? = nil) {
        if let category {
            let catItems = itemsByCategory[category] ?? []
            for item in catItems {
                selectedItemIDs.insert(item.id)
                deselectedPaths.remove(item.path.path)
            }
        } else {
            selectedItemIDs = Set(scannedItems.map(\.id))
            deselectedPaths.removeAll()
        }
        UserDefaults.standard.set(Array(deselectedPaths), forKey: "PG_Clean_DeselectedPaths")
    }

    public func deselectAll(category: CleanCategory? = nil) {
        if let category {
            let catItems = itemsByCategory[category] ?? []
            for item in catItems {
                selectedItemIDs.remove(item.id)
                deselectedPaths.insert(item.path.path)
            }
        } else {
            for item in scannedItems {
                deselectedPaths.insert(item.path.path)
            }
            selectedItemIDs.removeAll()
        }
        UserDefaults.standard.set(Array(deselectedPaths), forKey: "PG_Clean_DeselectedPaths")
    }

    public func cancelScan() {
        currentTask?.cancel()
        currentTask = nil
        status = .idle
        currentScanPath = ""
    }

    // MARK: - 扫描引擎

    public func startScan() {
        currentTask?.cancel()
        status = .scanning(progress: 0.05, currentPath: "正在排查系统残留…")
        currentScanPath = "正在排查系统残留…"
        scannedItems = []
        selectedItemIDs = []

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let matcher = CleanWhitelistMatcher.shared

            let runningApps = NSWorkspace.shared.runningApplications
            let runningBundles = Set(runningApps.compactMap(\.bundleIdentifier))

            var discovered: [CleanItem] = []

            // 1. 用户缓存 (User Caches: ~/Library/Caches)
            let userCachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
            if let items = try? fm.contentsOfDirectory(at: userCachesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for (idx, sub) in items.enumerated() {
                    if Task.isCancelled { return }
                    let folderName = sub.lastPathComponent
                    if folderName.hasPrefix("com.apple.coresymbolicationd") || folderName.hasPrefix("com.apple.akd") {
                        continue
                    }
                    guard matcher.isSafeToClean(url: sub) else { continue }

                    let progress = 0.05 + 0.25 * (Double(idx) / Double(max(1, items.count)))
                    let readableName = Self.humanReadableAppName(bundleID: folderName)

                    await self?.updateScanStatus(progress: progress, path: "扫描用户缓存: \(readableName)")

                    let size = Self.calculateDirectorySize(url: sub)
                    if size > 1024 * 1024 * 2 { // > 2MB
                        let isLocked = matcher.isActivelyLockedByRunningApp(url: sub, runningBundleIDs: runningBundles)
                        discovered.append(
                            CleanItem(
                                name: readableName + " 缓存",
                                category: .userCaches,
                                bucket: .suggested,
                                path: sub,
                                sizeBytes: size,
                                detail: "\(folderName) 产生的运行缓存与临时资源",
                                isProtected: isLocked
                            )
                        )
                    }
                }
            }

            // 2. 日志文件 (Log Files: ~/Library/Logs & /Library/Logs)
            let logsURL = home.appendingPathComponent("Library/Logs", isDirectory: true)
            if let logSubs = try? fm.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                await self?.updateScanStatus(progress: 0.35, path: "扫描日志文件: ~/Library/Logs")
                var totalLogsSize: Int64 = 0
                for sub in logSubs {
                    guard matcher.isSafeToClean(url: sub) else { continue }
                    totalLogsSize += Self.calculateDirectorySize(url: sub)
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

            // 3. 网页临时数据 (Web Temporary Data: Safari / Chrome / Edge / Firefox)
            let browserCachePaths: [(String, String, URL)] = [
                ("Safari 网页离线缓存", "Safari", home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Caches", isDirectory: true)),
                ("Google Chrome 网页缓存", "Chrome", home.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true)),
                ("Microsoft Edge 网页缓存", "Edge", home.appendingPathComponent("Library/Caches/Microsoft Edge", isDirectory: true)),
                ("Firefox 临时离线数据", "Firefox", home.appendingPathComponent("Library/Caches/Firefox", isDirectory: true))
            ]
            for (title, appName, pathURL) in browserCachePaths {
                if Task.isCancelled { return }
                if fm.fileExists(atPath: pathURL.path), matcher.isSafeToClean(url: pathURL) {
                    await self?.updateScanStatus(progress: 0.48, path: "扫描网页临时数据: \(appName)")
                    let sz = Self.calculateDirectorySize(url: pathURL)
                    if sz > 1024 * 1024 {
                        discovered.append(
                            CleanItem(
                                name: title,
                                category: .webData,
                                bucket: .suggested,
                                path: pathURL,
                                sizeBytes: sz,
                                detail: "\(appName) 网页离线资源与网络请求中间缓存"
                            )
                        )
                    }
                }
            }

            // 4. 崩溃诊断 (Crash Reports & Diagnostics: DiagnosticReports / CrashReporter)
            let diagURL = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
            if fm.fileExists(atPath: diagURL.path), matcher.isSafeToClean(url: diagURL) {
                await self?.updateScanStatus(progress: 0.58, path: "扫描崩溃诊断转储报告…")
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

            // 5. 开发缓存 (Developer Caches: Xcode DerivedData, Simulators, CocoaPods, npm, etc.)
            let devPaths: [(String, URL, CleanReviewBucket)] = [
                ("Xcode DerivedData (编译派生产物)", home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true), .suggested),
                ("iOS 模拟器运行时缓存", home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true), .suggested),
                ("Xcode 历史归档包 (Archives)", home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true), .needsReview),
                ("CocoaPods 仓库与缓存", home.appendingPathComponent(".cocoapods/cache", isDirectory: true), .suggested),
                ("npm 依赖包缓存", home.appendingPathComponent(".npm/_cacache", isDirectory: true), .suggested),
                ("Gradle 构建中间件缓存", home.appendingPathComponent(".gradle/caches", isDirectory: true), .suggested)
            ]
            for (title, url, bucket) in devPaths {
                if Task.isCancelled { return }
                if fm.fileExists(atPath: url.path), matcher.isSafeToClean(url: url) {
                    await self?.updateScanStatus(progress: 0.72, path: "扫描开发构建缓存: \(url.lastPathComponent)")
                    let sz = Self.calculateDirectorySize(url: url)
                    if sz > 1024 * 1024 * 2 {
                        discovered.append(
                            CleanItem(
                                name: title,
                                category: .developerCache,
                                bucket: bucket,
                                path: url,
                                sizeBytes: sz,
                                detail: "编译产物派生数据 · 随时可重新生成"
                            )
                        )
                    }
                }
            }

            // 6. 废纸篓与安装包残留 (User Trash: ~/.Trash & 外置盘 /.Trashes & ~/Downloads/*.dmg, *.pkg)
            await self?.updateScanStatus(progress: 0.85, path: "扫描系统与外置盘废纸篓…")
            let allTrashURLs = Self.discoverAllTrashLocations()
            var totalTrashSize: Int64 = 0
            var trashItemCount = 0

            for tURL in allTrashURLs {
                if matcher.isSafeToClean(url: tURL) {
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

            let downloadsURL = home.appendingPathComponent("Downloads", isDirectory: true)
            if let downloadFiles = try? fm.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                await self?.updateScanStatus(progress: 0.92, path: "扫描下载目录中的安装包残留…")
                for fileURL in downloadFiles {
                    guard matcher.isSafeToClean(url: fileURL) else { continue }
                    let ext = fileURL.pathExtension.lowercased()
                    if ext == "dmg" || ext == "pkg" || ext == "iso" {
                        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                        if size > 1024 * 1024 * 10 { // > 10MB
                            discovered.append(
                                CleanItem(
                                    name: "安装镜像残留: " + fileURL.lastPathComponent,
                                    category: .userTrash,
                                    bucket: .suggested,
                                    path: fileURL,
                                    sizeBytes: size,
                                    detail: "下载目录中已不再需要的安装包介质"
                                )
                            )
                        }
                    }
                }
            }

            // Sort largest to smallest
            discovered.sort { $0.sizeBytes > $1.sizeBytes }

            if Task.isCancelled { return }
            await self?.finishScan(items: discovered)
        }
    }

    private func updateScanStatus(progress: Double, path: String) {
        self.status = .scanning(progress: progress, currentPath: path)
        self.currentScanPath = path
    }

    private func finishScan(items: [CleanItem]) {
        self.scannedItems = items
        // Auto-select suggested non-protected items, excluding user-deselected ones
        let autoSelected = items.filter { item in
            !item.isProtected && item.bucket == .suggested && !self.isItemDeselected(item: item)
        }
        self.selectedItemIDs = Set(autoSelected.map(\.id))
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        self.status = .completed(totalBytes: total, itemCount: items.count)
        self.currentScanPath = ""
    }

    // MARK: - Cleaning Execution Engine (Move to Trash / Permanent Delete)

    public func executeClean() {
        guard !selectedItemIDs.isEmpty else { return }
        let toClean = scannedItems.filter { selectedItemIDs.contains($0.id) }

        status = .cleaning(progress: 0.05, currentItem: "准备安全清理…")

        currentTask?.cancel()
        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let matcher = CleanWhitelistMatcher.shared
            let mode = await self?.deleteMode ?? .moveToTrash
            var freed: Int64 = 0
            var count = 0

            // 分离普通清理项与废纸篓收尾项
            let regularItems = toClean.filter { $0.category != .userTrash && $0.path.lastPathComponent != ".Trash" }
            let trashItems = toClean.filter { $0.category == .userTrash || $0.path.lastPathComponent == ".Trash" }

            let totalSteps = max(1, regularItems.count + (trashItems.isEmpty ? 0 : 1))
            var currentStep = 0

            // 阶段一：清理常规临时垃圾与残留
            for item in regularItems {
                if Task.isCancelled { return }
                guard matcher.isSafeToClean(url: item.path) else { continue }

                currentStep += 1
                let pct = Double(currentStep) / Double(totalSteps)
                await self?.updateCleanProgress(progress: pct, name: "正在清理: \(item.name)")

                if item.path.pathExtension.lowercased() == "dmg" || item.path.pathExtension.lowercased() == "pkg" || item.path.pathExtension.lowercased() == "iso" {
                    // 安装包残留：遵循用户选择的安全模式（移到废纸篓留后悔药 vs 物理直接删除）
                    if mode == .moveToTrash {
                        if (try? fm.trashItem(at: item.path, resultingItemURL: nil)) != nil {
                            freed += item.sizeBytes
                            count += 1
                        }
                    } else {
                        if (try? fm.removeItem(at: item.path)) != nil {
                            freed += item.sizeBytes
                            count += 1
                        }
                    }
                } else {
                    // 系统与应用缓存、运行日志、Xcode/Homebrew/npm 开发产物：纯临时衍生垃圾，直接安全物理释放，绝不污染倒灌废纸篓
                    if let subs = try? fm.contentsOfDirectory(at: item.path, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) {
                        var folderFreed: Int64 = 0
                        var allRemoved = !subs.isEmpty
                        for sub in subs {
                            guard matcher.isSafeToClean(url: sub) else {
                                allRemoved = false
                                continue
                            }
                            let isSymlink = (try? sub.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                            // 符号链接仅删除链接本身，严禁通过链接计算或递归目标目录
                            let subSize: Int64 = isSymlink ? 0 : Self.calculateItemOrDirectorySize(url: sub)
                            if (try? fm.removeItem(at: sub)) != nil {
                                count += 1
                                folderFreed += subSize
                            } else {
                                allRemoved = false
                            }
                        }
                        if allRemoved {
                            freed += item.sizeBytes
                        } else {
                            freed += min(item.sizeBytes, folderFreed)
                        }
                    }
                }
            }

            // 阶段二：用户明确勾选废纸篓时的压轴清空（最后一步统一执行）
            if !trashItems.isEmpty {
                if Task.isCancelled { return }
                currentStep += 1
                let pct = Double(currentStep) / Double(totalSteps)
                await self?.updateCleanProgress(progress: pct, name: "正在清空系统与外置盘废纸篓…")

                // 1. 原生委托 macOS Finder 清空所有卷的废纸篓（内置盘 + 外置盘）
                let appleScriptSource = "tell application \"Finder\" to empty trash"
                if let script = NSAppleScript(source: appleScriptSource) {
                    var err: NSDictionary?
                    script.executeAndReturnError(&err)
                }

                // 2. 双保险：遍历所有已知的 Trash 目录尝试清理子项
                let allTrashes = Self.discoverAllTrashLocations()
                var directRemovedCount = 0
                for tURL in allTrashes {
                    if let subs = try? fm.contentsOfDirectory(at: tURL, includingPropertiesForKeys: nil, options: []) {
                        for sub in subs {
                            if (try? fm.removeItem(at: sub)) != nil {
                                directRemovedCount += 1
                            }
                        }
                    }
                }

                let trashSize = trashItems.reduce(0) { $0 + $1.sizeBytes }
                freed += trashSize
                count += max(1, directRemovedCount)

                // 通知访达系统文件状态已变更，立即刷新废纸篓图标为“空”
                if let firstTrash = trashItems.first?.path {
                    NSWorkspace.shared.noteFileSystemChanged(firstTrash.path)
                }
            }

            await self?.finishClean(freed: freed, count: count)
        }
    }

    private func updateCleanProgress(progress: Double, name: String) {
        self.status = .cleaning(progress: progress, currentItem: name)
    }

    private func finishClean(freed: Int64, count: Int) {
        self.lastFreedBytes = freed
        self.lastCleanDate = Date()
        UserDefaults.standard.set(Int(freed), forKey: "PG_Clean_LastFreedBytes")
        UserDefaults.standard.set(lastCleanDate, forKey: "PG_Clean_LastDate")

        self.status = .cleaned(freedBytes: freed, itemCount: count)
        // Refresh scanned items by removing cleaned items
        self.scannedItems.removeAll { self.selectedItemIDs.contains($0.id) }
        self.selectedItemIDs.removeAll()
    }

    // MARK: - Utilities

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

    nonisolated public static func calculateDirectorySize(url: URL) -> Int64 {
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

        for case let fileURL as URL in enumerator {
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
            "com.netease.163music": "网易云音乐",
            "com.apple.dt.Xcode": "Xcode",
            "org.mozilla.firefox": "Firefox",
            "com.spotify.client": "Spotify",
            "com.apple.Music": "音乐",
            "com.figma.Desktop": "Figma",
            "com.bilibili.air": "哔哩哔哩",
            "com.baidu.BaiduNetdiskMac": "百度网盘",
            "com.tw93.MoleApp": "Mole",
            "com.cleer.app": "Cleer"
        ]
        if let match = wellKnown[bundleID] {
            return match
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

        // 1. 系统主盘用户废纸篓
        let homeTrash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        if fm.fileExists(atPath: homeTrash.path) {
            trashURLs.append(homeTrash)
        }

        // 2. 所有挂载卷宗（外置硬盘、移动硬盘、分区卷）废纸篓
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
