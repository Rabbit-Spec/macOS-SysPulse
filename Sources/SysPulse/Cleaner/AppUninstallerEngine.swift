import Foundation
import SwiftUI
import AppKit
import CoreServices
import Observation

@Observable
@MainActor
public final class AppUninstallerEngine {
    public static let shared = AppUninstallerEngine()

    public var status: UninstallerStatus = .idle
    public var scanProgress: Double = 0.0
    public var currentScanningApp: String = ""

    public var installedApps: [InstalledAppInfo] = [] {
        didSet {
            recomputeCategoryStats()
            recomputeFilteredDisplayItems()
        }
    }
    public var orphanedResidues: [OrphanedResidueItem] = [] {
        didSet {
            recomputeCategoryStats()
            recomputeFilteredDisplayItems()
        }
    }

    public var selectedCategory: AppCategoryFilter = .all {
        didSet {
            if oldValue != selectedCategory {
                recomputeFilteredDisplayItems()
            }
        }
    }
    public var selectedItemIDs: Set<UUID> = []
    public var expandedAppIDs: Set<UUID> = []

    public var selectedAppIDs: Set<UUID> = []
    public var selectedResidueIDs: Set<UUID> = []
    public var excludedComponentIDs: Set<UUID> = []
    public var commandLineTools: [CommandLineToolItem] = []
    public var selectedCliToolIDs: Set<UUID> = []
    public var ignoredOrphanPaths: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(ignoredOrphanPaths), forKey: "SP_Uninstaller_IgnoredOrphans")
        }
    }
    public var useHomebrewZapWhenAvailable: Bool = false
    public var hoveredCliToolID: UUID? = nil
    public var selectedTab: UninstallerSubTab = .installedApps

    public var searchQuery: String = "" {
        didSet {
            if oldValue != searchQuery {
                recomputeFilteredDisplayItems()
            }
        }
    }
    public var sortOption: AppSortOption = .sizeDesc {
        didSet {
            if oldValue != sortOption {
                recomputeFilteredDisplayItems()
            }
        }
    }
    public var sortOrder: ProcessSortOrder = .descending {
        didSet {
            if oldValue != sortOrder {
                recomputeFilteredDisplayItems()
            }
        }
    }

    public var deleteMode: UninstallerDeleteMode = .moveToTrash {
        didSet {
            UserDefaults.standard.set(deleteMode.rawValue, forKey: "SP_Uninstaller_DeleteMode")
        }
    }

    public var isOptionsPresented: Bool = false
    public var hoveredItemID: UUID? = nil

    public var lastUninstallDate: Date? = nil
    public var lastUninstalledBytes: Int64 = 0
    public var lastUninstalledCount: Int = 0
    public var statusMessage: String = ""

    private var currentScanTask: Task<Void, Never>? = nil

    public init() {
        let savedBytes = UserDefaults.standard.integer(forKey: "PG_Uninstaller_LastFreedBytes")
        if savedBytes > 0 {
            self.lastUninstalledBytes = Int64(savedBytes)
        }
        if let savedDate = UserDefaults.standard.object(forKey: "PG_Uninstaller_LastDate") as? Date {
            self.lastUninstallDate = savedDate
        }
        if let savedMode = UserDefaults.standard.string(forKey: "SP_Uninstaller_DeleteMode"),
           let mode = UninstallerDeleteMode(rawValue: savedMode) {
            self.deleteMode = mode
        }
        let ignored = UserDefaults.standard.stringArray(forKey: "SP_Uninstaller_IgnoredOrphans") ?? []
        self.ignoredOrphanPaths = Set(ignored)
    }

    // MARK: - State Checks

    public var isScanning: Bool {
        if case .scanning = status { return true }
        return false
    }

    public var isUninstalling: Bool {
        if case .uninstalling = status { return true }
        return false
    }

    // MARK: - Computed Totals & Formatted Strings

    public var totalAppsBytes: Int64 {
        installedApps.reduce(0) { $0 + $1.totalSizeBytes }
    }

    public var totalOrphanedBytes: Int64 {
        orphanedResidues.reduce(0) { $0 + $1.sizeBytes }
    }

    public var totalAllBytes: Int64 {
        totalAppsBytes + totalOrphanedBytes
    }

    public func removableBytes(for app: InstalledAppInfo) -> Int64 {
        app.components
            .filter { $0.isSafeToTrash && !excludedComponentIDs.contains($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    public var selectedBytes: Int64 {
        let appBytes = installedApps
            .filter { selectedItemIDs.contains($0.id) || selectedAppIDs.contains($0.id) }
            .reduce(0) { $0 + removableBytes(for: $1) }
        let resBytes = orphanedResidues
            .filter { selectedItemIDs.contains($0.id) || selectedResidueIDs.contains($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
        return appBytes + resBytes
    }

    public var selectedAppsBytes: Int64 {
        installedApps
            .filter { selectedItemIDs.contains($0.id) || selectedAppIDs.contains($0.id) }
            .reduce(0) { $0 + removableBytes(for: $1) }
    }

    public var selectedResiduesBytes: Int64 {
        orphanedResidues
            .filter { selectedItemIDs.contains($0.id) || selectedResidueIDs.contains($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    public var formattedSelectedBytes: String {
        formatBytes(selectedBytes)
    }

    public var formattedTotalAllBytes: String {
        formatBytes(totalAllBytes)
    }

    public var lastUninstallDescription: String {
        guard let date = lastUninstallDate else {
            return "还没卸载过"
        }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            return "今天 \(df.string(from: date)) 已卸载"
        } else {
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm"
            return "上次卸载于 \(df.string(from: date))"
        }
    }

    // MARK: - Category Stats (Cached in Single Pass)

    private var cachedCategoryCounts: [AppCategoryFilter: Int] = [:]
    private var cachedCategoryBytes: [AppCategoryFilter: Int64] = [:]
    public private(set) var cachedFilteredDisplayItems: [UninstallerRowItem] = []

    private func recomputeCategoryStats() {
        var userCount = 0
        var userBytes: Int64 = 0
        var unusedCount = 0
        var unusedBytes: Int64 = 0
        var sysCount = 0
        var sysBytes: Int64 = 0

        for app in installedApps {
            if app.isSystemApp {
                sysCount += 1
                sysBytes += app.totalSizeBytes
            } else {
                userCount += 1
                userBytes += app.totalSizeBytes
                if app.isUnused {
                    unusedCount += 1
                    unusedBytes += app.totalSizeBytes
                }
            }
        }

        let resCount = orphanedResidues.count
        let resBytes = orphanedResidues.reduce(0) { $0 + $1.sizeBytes }

        cachedCategoryCounts = [
            .all: installedApps.count + resCount,
            .user: userCount,
            .unused: unusedCount,
            .orphaned: resCount,
            .system: sysCount
        ]
        cachedCategoryBytes = [
            .all: userBytes + sysBytes + resBytes,
            .user: userBytes,
            .unused: unusedBytes,
            .orphaned: resBytes,
            .system: sysBytes
        ]
    }

    private func recomputeFilteredDisplayItems() {
        var baseItems: [UninstallerRowItem] = []
        switch selectedCategory {
        case .all:
            baseItems = installedApps.map { .app($0) } + orphanedResidues.map { .residue($0) }
        case .user:
            baseItems = installedApps.filter { !$0.isSystemApp }.map { .app($0) }
        case .unused:
            baseItems = installedApps.filter { $0.isUnused && !$0.isSystemApp }.map { .app($0) }
        case .orphaned:
            baseItems = orphanedResidues.map { .residue($0) }
        case .system:
            baseItems = installedApps.filter { $0.isSystemApp }.map { .app($0) }
        }

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            baseItems = baseItems.filter {
                $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
            }
        }

        let isAsc = (sortOrder == .ascending)
        switch sortOption {
        case .sizeDesc:
            baseItems.sort { isAsc ? $0.sizeBytes < $1.sizeBytes : $0.sizeBytes > $1.sizeBytes }
        case .nameAsc:
            baseItems.sort { isAsc ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .lastUsed:
            baseItems.sort { i1, i2 in
                let d1 = Self.itemLastUsedDate(i1)
                let d2 = Self.itemLastUsedDate(i2)
                return isAsc ? d1 < d2 : d1 > d2
            }
        case .installDate:
            baseItems.sort { i1, i2 in
                let d1 = Self.itemInstallDate(i1)
                let d2 = Self.itemInstallDate(i2)
                return isAsc ? d1 < d2 : d1 > d2
            }
        }

        cachedFilteredDisplayItems = baseItems
    }

    public func categoryCount(_ cat: AppCategoryFilter) -> Int {
        cachedCategoryCounts[cat] ?? 0
    }

    public func categoryBytes(_ cat: AppCategoryFilter) -> Int64 {
        cachedCategoryBytes[cat] ?? 0
    }

    // MARK: - Unified Row Items for Display

    public var filteredDisplayItems: [UninstallerRowItem] {
        cachedFilteredDisplayItems
    }

    private static func itemLastUsedDate(_ item: UninstallerRowItem) -> Date {
        switch item {
        case .app(let a): return a.lastUsedDate ?? Date.distantPast
        case .residue(let r): return r.lastModifiedDate ?? Date.distantPast
        }
    }

    private static func itemInstallDate(_ item: UninstallerRowItem) -> Date {
        switch item {
        case .app(let a): return a.installDate ?? Date.distantPast
        case .residue(let r): return r.lastModifiedDate ?? Date.distantPast
        }
    }

    public var filteredApps: [InstalledAppInfo] {
        var list = installedApps
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchQuery.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
            }
        }
        switch sortOption {
        case .sizeDesc:
            list.sort { $0.totalSizeBytes > $1.totalSizeBytes }
        case .nameAsc:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed:
            list.sort {
                ($0.lastUsedDate ?? Date.distantPast) > ($1.lastUsedDate ?? Date.distantPast)
            }
        case .installDate:
            list.sort {
                ($0.installDate ?? Date.distantPast) > ($1.installDate ?? Date.distantPast)
            }
        }
        return list
    }

    // MARK: - Sorting Controls

    public func toggleSort(option: AppSortOption) {
        if sortOption == option {
            sortOrder = (sortOrder == .ascending) ? .descending : .ascending
        } else {
            sortOption = option
            sortOrder = (option == .nameAsc) ? .ascending : .descending
        }
    }

    // MARK: - Selection Controls

    public func isItemSelected(_ id: UUID) -> Bool {
        selectedItemIDs.contains(id) || selectedAppIDs.contains(id) || selectedResidueIDs.contains(id)
    }

    public func toggleSelection(for id: UUID) {
        if selectedItemIDs.contains(id) || selectedAppIDs.contains(id) || selectedResidueIDs.contains(id) {
            selectedItemIDs.remove(id)
            selectedAppIDs.remove(id)
            selectedResidueIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
            selectedAppIDs.insert(id)
            selectedResidueIDs.insert(id)
        }
    }

    public func selectAll() {
        let selectableIDs = filteredDisplayItems.filter { !$0.isSystemApp }.map(\.id)
        selectedItemIDs.formUnion(selectableIDs)
        selectedAppIDs.formUnion(selectableIDs)
        selectedResidueIDs.formUnion(selectableIDs)
    }

    public func deselectAll() {
        let currentIDs = Set(filteredDisplayItems.map(\.id))
        selectedItemIDs.subtract(currentIDs)
        selectedAppIDs.subtract(currentIDs)
        selectedResidueIDs.subtract(currentIDs)
    }

    public func toggleAppSelection(_ id: UUID) {
        toggleSelection(for: id)
    }

    public func selectAllApps() {
        let userAppIDs = filteredApps.filter { !$0.isSystemApp }.map(\.id)
        selectedAppIDs.formUnion(userAppIDs)
        selectedItemIDs.formUnion(userAppIDs)
    }

    public func deselectAllApps() {
        selectedAppIDs.removeAll()
        selectedItemIDs.removeAll()
    }

    public func toggleResidueSelection(_ id: UUID) {
        toggleSelection(for: id)
    }

    public func selectAllResidues() {
        let rIDs = Set(orphanedResidues.map(\.id))
        selectedResidueIDs = rIDs
        selectedItemIDs.formUnion(rIDs)
    }

    public func deselectAllResidues() {
        selectedResidueIDs.removeAll()
        selectedItemIDs.subtract(Set(orphanedResidues.map(\.id)))
    }

    public func toggleAppExpanded(_ id: UUID) {
        if expandedAppIDs.contains(id) {
            expandedAppIDs.remove(id)
        } else {
            expandedAppIDs.insert(id)
        }
    }

    public func isComponentIncluded(_ component: AppSpaceComponent) -> Bool {
        !excludedComponentIDs.contains(component.id)
    }

    public func toggleComponentIncluded(_ component: AppSpaceComponent) {
        guard component.type != .appBundle else { return }
        if excludedComponentIDs.contains(component.id) {
            excludedComponentIDs.remove(component.id)
        } else {
            excludedComponentIDs.insert(component.id)
        }
    }

    public var filteredCommandLineTools: [CommandLineToolItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = q.isEmpty ? commandLineTools : commandLineTools.filter {
            $0.name.lowercased().contains(q)
                || $0.displayTitle.lowercased().contains(q)
                || $0.source.rawValue.lowercased().contains(q)
        }
        return base.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public var visibleOrphanedResidues: [OrphanedResidueItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = orphanedResidues.filter { !ignoredOrphanPaths.contains($0.path.path) }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.originalAppName.lowercased().contains(q)
                || $0.bundleID.lowercased().contains(q)
                || $0.path.path.lowercased().contains(q)
        }
    }

    public func muteOrphanedResidue(_ residue: OrphanedResidueItem) {
        ignoredOrphanPaths.insert(residue.path.path)
        selectedItemIDs.remove(residue.id)
        selectedResidueIDs.remove(residue.id)
        recomputeCategoryStats()
        recomputeFilteredDisplayItems()
    }

    public func clearIgnoredOrphans() {
        ignoredOrphanPaths.removeAll()
        startScan()
    }

    // MARK: - Scanning Pipeline

    public func startScan() {
        currentScanTask?.cancel()
        status = .scanning(progress: 0.05, currentApp: "正在检索已安装应用…")
        scanProgress = 0.05
        currentScanningApp = "正在检索已安装应用…"
        installedApps = []
        orphanedResidues = []
        commandLineTools = []
        selectedItemIDs.removeAll()
        selectedAppIDs.removeAll()
        selectedResidueIDs.removeAll()
        excludedComponentIDs.removeAll()

        let currentIgnored = self.ignoredOrphanPaths
        StartupItemManager.shared.startScan()

        currentScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser

            // 0. Discover Homebrew Caskroom mapping
            let caskMapping = Self.discoverHomebrewCasks(fm: fm)

            // 1. Gather all application URLs
            var appURLs: [URL] = []
            let searchDirs = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true)
            ]

            for dir in searchDirs {
                if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for item in items {
                        if item.pathExtension == "app" {
                            appURLs.append(item)
                        } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            if let subItems = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                                for sub in subItems where sub.pathExtension == "app" {
                                    appURLs.append(sub)
                                }
                            }
                        }
                    }
                }
            }

            var scannedAppList: [InstalledAppInfo] = []
            var knownBundleIDs = Set<String>()
            var knownAppNames = Set<String>()

            if let selfBid = Bundle.main.bundleIdentifier {
                knownBundleIDs.insert(selfBid.lowercased())
            }
            knownAppNames.insert(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent.lowercased())

            let running = NSWorkspace.shared.runningApplications
            var runningMap: [String: pid_t] = [:]
            for r in running {
                if let bid = r.bundleIdentifier {
                    runningMap[bid] = r.processIdentifier
                    knownBundleIDs.insert(bid.lowercased())
                }
                if let locName = r.localizedName, !locName.isEmpty {
                    knownAppNames.insert(locName.lowercased())
                }
                if let rURL = r.bundleURL {
                    knownAppNames.insert(rURL.deletingPathExtension().lastPathComponent.lowercased())
                }
            }

            let systemAppDirs = [
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
                URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
            ]
            for sysDir in systemAppDirs {
                if let items = try? fm.contentsOfDirectory(at: sysDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for item in items where item.pathExtension == "app" {
                        knownAppNames.insert(item.deletingPathExtension().lastPathComponent.lowercased())
                        if let b = Bundle(url: item), let bid = b.bundleIdentifier {
                            knownBundleIDs.insert(bid.lowercased())
                        }
                    }
                }
            }

            // Cache user & system LaunchAgents/Daemons & Receipts for fast per-app correlation
            let groupContainersDir = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
            let groupContainerEntries = (try? fm.contentsOfDirectory(at: groupContainersDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let receiptsDir = URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true)
            let receiptEntries = (try? fm.contentsOfDirectory(at: receiptsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

            let totalApps = max(1, appURLs.count)
            for (idx, appURL) in appURLs.enumerated() {
                if Task.isCancelled { return }
                let appName = appURL.deletingPathExtension().lastPathComponent
                let progress = 0.05 + 0.58 * (Double(idx) / Double(totalApps))
                await self?.updateScanProgress(progress: progress, appName: "分析空间: \(appName)")

                guard let bundle = Bundle(url: appURL) else { continue }
                let bid = bundle.bundleIdentifier ?? "com.unknown.\(appName.lowercased())"
                knownBundleIDs.insert(bid.lowercased())
                knownAppNames.insert(appName.lowercased())

                let infoDict = bundle.infoDictionary ?? [:]
                let displayName = (infoDict["CFBundleDisplayName"] as? String)
                    ?? (infoDict["CFBundleName"] as? String)
                    ?? appName
                knownAppNames.insert(displayName.lowercased())

                Self.collectEmbeddedSubBundleIdentifiers(
                    in: appURL,
                    fm: fm,
                    bundleIDs: &knownBundleIDs,
                    appNames: &knownAppNames
                )
                let version = (infoDict["CFBundleShortVersionString"] as? String)
                    ?? (infoDict["CFBundleVersion"] as? String)
                    ?? "1.0"

                let isSys = appURL.path.hasPrefix("/System/") || bid.hasPrefix("com.apple.")
                let isRun = runningMap[bid] != nil
                let runPid = runningMap[bid]
                let resValues = try? appURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let installDate = resValues?.creationDate
                let lastUsed = Self.queryLastUsedDate(url: appURL) ?? resValues?.contentModificationDate

                var components: [AppSpaceComponent] = []
                var seenPaths = Set<String>()

                func appendComponent(
                    type: AppSpaceComponentType,
                    url: URL,
                    isDir: Bool = true,
                    minBytes: Int64 = 0,
                    isSafeToTrash: Bool = true,
                    confidence: AppResidueConfidence = .auto,
                    evidence: String
                ) {
                    guard !seenPaths.contains(url.path), fm.fileExists(atPath: url.path) else { return }
                    let sz = isDir
                        ? Self.calculateDirectorySize(url: url)
                        : ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 4096)
                    guard sz >= minBytes else { return }
                    seenPaths.insert(url.path)
                    components.append(
                        AppSpaceComponent(
                            type: type,
                            path: url,
                            sizeBytes: sz,
                            isSafeToTrash: isSafeToTrash,
                            confidence: confidence,
                            evidenceLabel: evidence
                        )
                    )
                }

                // 1. App Bundle
                appendComponent(type: .appBundle, url: appURL, isSafeToTrash: !isSys, confidence: .auto, evidence: "应用本体路径")
                // 2. Containers & Application Scripts
                appendComponent(type: .containers, url: home.appendingPathComponent("Library/Containers/\(bid)", isDirectory: true), minBytes: 1024 * 8, evidence: "Bundle ID 精确匹配")
                appendComponent(type: .applicationScripts, url: home.appendingPathComponent("Library/Application Scripts/\(bid)", isDirectory: true), minBytes: 1024, evidence: "脚本容器匹配")
                // 3. Group Containers (exact BID suffix match -> .auto)
                let bidLower = bid.lowercased()
                for gc in groupContainerEntries {
                    let gcNameLower = gc.lastPathComponent.lowercased()
                    if gcNameLower.contains(bidLower) {
                        appendComponent(type: .groupContainers, url: gc, minBytes: 1024 * 8, confidence: .review, evidence: "共享群组容器（建议复核）")
                    }
                }
                // 4. Application Support
                appendComponent(type: .appSupport, url: home.appendingPathComponent("Library/Application Support/\(bid)", isDirectory: true), minBytes: 1024 * 8, evidence: "Bundle ID 精确匹配")
                appendComponent(type: .appSupport, url: home.appendingPathComponent("Library/Application Support/\(appName)", isDirectory: true), minBytes: 1024 * 8, confidence: .auto, evidence: "应用名称精确匹配")
                // 5. Caches, HTTPStorages, WebKit
                appendComponent(type: .caches, url: home.appendingPathComponent("Library/Caches/\(bid)", isDirectory: true), minBytes: 1024 * 8, evidence: "Bundle ID 缓存匹配")
                appendComponent(type: .httpStorages, url: home.appendingPathComponent("Library/HTTPStorages/\(bid)", isDirectory: true), minBytes: 1024, evidence: "网络存储目录")
                appendComponent(type: .httpStorages, url: home.appendingPathComponent("Library/HTTPStorages/\(bid).binarycookies"), isDir: false, evidence: "BinaryCookies 凭证")
                appendComponent(type: .webKit, url: home.appendingPathComponent("Library/WebKit/\(bid)", isDirectory: true), minBytes: 1024, evidence: "WebKit 沙盒数据")
                // 6. Preferences & SyncedPreferences
                appendComponent(type: .preferences, url: home.appendingPathComponent("Library/Preferences/\(bid).plist"), isDir: false, evidence: "偏好设置文件")
                appendComponent(type: .syncedPreferences, url: home.appendingPathComponent("Library/SyncedPreferences/\(bid).plist"), isDir: false, evidence: "云同步偏好")
                // 7. Saved Application State
                appendComponent(type: .savedState, url: home.appendingPathComponent("Library/Saved Application State/\(bid).savedState", isDirectory: true), evidence: "窗口恢复状态")
                // 8. LaunchAgents & Logs
                appendComponent(type: .launchAgents, url: home.appendingPathComponent("Library/LaunchAgents/\(bid).plist"), isDir: false, evidence: "用户自启代理")
                appendComponent(type: .logs, url: home.appendingPathComponent("Library/Logs/\(appName)", isDirectory: true), minBytes: 1024 * 8, evidence: "应用运行日志")
                appendComponent(type: .logs, url: home.appendingPathComponent("Library/Logs/\(bid)", isDirectory: true), minBytes: 1024 * 8, evidence: "Bundle ID 日志")
                // 9. Privileged Helper / Global Daemons (.review)
                let helperURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(bid)")
                appendComponent(type: .helperTools, url: helperURL, isDir: false, isSafeToTrash: false, confidence: .review, evidence: "特权助手（需谨慎移除）")
                let daemonURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(bid).plist")
                appendComponent(type: .launchDaemons, url: daemonURL, isDir: false, isSafeToTrash: false, confidence: .review, evidence: "系统守护进程")
                // 10. Installer Receipts
                for rec in receiptEntries where rec.lastPathComponent.lowercased().hasPrefix(bidLower) {
                    appendComponent(type: .receipts, url: rec, isDir: false, isSafeToTrash: false, confidence: .review, evidence: "系统安装票据")
                }

                let caskMatch = caskMapping[appName.lowercased()] ?? caskMapping[displayName.lowercased()]
                let hasLogin = fm.fileExists(atPath: appURL.appendingPathComponent("Contents/Library/LoginItems").path)
                    || components.contains(where: { $0.type == .launchAgents || $0.type == .launchDaemons })

                scannedAppList.append(
                    InstalledAppInfo(
                        name: displayName,
                        bundleID: bid,
                        bundleURL: appURL,
                        version: version,
                        lastUsedDate: lastUsed,
                        installDate: installDate,
                        isRunning: isRun,
                        runningPID: runPid,
                        isSystemApp: isSys,
                        caskMatch: caskMatch,
                        hasLaunchRegistrations: hasLogin,
                        components: components
                    )
                )
            }

            // 3. Scan for Orphaned Residues
            await self?.updateScanProgress(progress: 0.72, appName: "正在排查无主沙盒、HTTP 存储与残留…")
            let discoveredOrphans = Self.detectOrphanedResidues(
                home: home,
                fm: fm,
                installedBundleIDs: knownBundleIDs,
                installedAppNames: knownAppNames,
                ignoredPaths: currentIgnored
            )

            // 4. Scan Command Line Tools (Cellar / ~/.local/bin / npm / pipx)
            await self?.updateScanProgress(progress: 0.88, appName: "正在盘点本机命令行工具与 CLI 体积…")
            let cliTools = Self.scanCommandLineTools(home: home, fm: fm)

            await self?.finishScan(apps: scannedAppList, orphans: discoveredOrphans, cliTools: cliTools)
        }
    }

    public func cancelScan() {
        currentScanTask?.cancel()
        currentScanTask = nil
        self.scanProgress = 0.0
        self.currentScanningApp = ""
        self.status = .idle
    }

    private func updateScanProgress(progress: Double, appName: String) {
        self.status = .scanning(progress: progress, currentApp: appName)
        self.scanProgress = progress
        self.currentScanningApp = appName
    }

    private func finishScan(apps: [InstalledAppInfo], orphans: [OrphanedResidueItem], cliTools: [CommandLineToolItem]) {
        self.installedApps = apps
        self.orphanedResidues = orphans
        self.commandLineTools = cliTools
        var defaultExcluded = Set<UUID>()
        for app in apps {
            for comp in app.components where comp.confidence == .review {
                defaultExcluded.insert(comp.id)
            }
        }
        self.excludedComponentIDs = defaultExcluded
        self.scanProgress = 1.0
        self.currentScanningApp = ""
        self.status = .completed
        self.statusMessage = "扫描就绪：检测到 \(apps.count) 款应用，\(cliTools.count) 项 CLI 工具，发现 \(orphans.count) 项无主残留"
    }

    // MARK: - Homebrew Caskroom & Command Line Tools Discovery

    nonisolated private static func discoverHomebrewCasks(fm: FileManager) -> [String: HomebrewCaskMatch] {
        var map: [String: HomebrewCaskMatch] = [:]
        for rootPath in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let tokens = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for tokenURL in tokens {
                let token = tokenURL.lastPathComponent
                guard let versions = try? fm.contentsOfDirectory(at: tokenURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                      let verURL = versions.first(where: { !$0.lastPathComponent.hasPrefix(".") }) else {
                    continue
                }
                let ver = verURL.lastPathComponent
                let match = HomebrewCaskMatch(token: token, caskroomPath: tokenURL, installedVersion: ver)
                map[token.lowercased()] = match
                map[token.replacingOccurrences(of: "-", with: " ").lowercased()] = match
                if let subItems = try? fm.contentsOfDirectory(at: verURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for item in subItems where item.pathExtension == "app" {
                        map[item.deletingPathExtension().lastPathComponent.lowercased()] = match
                    }
                }
            }
        }
        return map
    }

    nonisolated private static func scanCommandLineTools(home: URL, fm: FileManager) -> [CommandLineToolItem] {
        var items: [CommandLineToolItem] = []
        var seenNames = Set<String>()

        // Snapshot running process executable basenames
        let psOut = runSimpleCommand("/bin/ps", args: ["-axo", "comm"]).lowercased()
        let runningComms = Set(psOut.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent })

        // 1. Homebrew Cellar (/opt/homebrew/Cellar & /usr/local/Cellar)
        for cellarPath in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            let cellarURL = URL(fileURLWithPath: cellarPath, isDirectory: true)
            guard let formulas = try? fm.contentsOfDirectory(at: cellarURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for fURL in formulas {
                let name = fURL.lastPathComponent
                let versions = (try? fm.contentsOfDirectory(at: fURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let ver = versions.last(where: { !$0.lastPathComponent.hasPrefix(".") })?.lastPathComponent ?? "latest"
                let sz = calculateDirectorySize(url: fURL)
                let binDir = versions.last?.appendingPathComponent("bin")
                seenNames.insert(name.lowercased())
                items.append(
                    CommandLineToolItem(
                        name: name,
                        displayTitle: name,
                        source: .homebrewFormula,
                        installURL: fURL,
                        binaryURL: binDir,
                        version: ver,
                        sizeBytes: sz,
                        isRunning: runningComms.contains(name.lowercased()),
                        formulaName: name
                    )
                )
            }
        }

        // 2. Standalone CLI tools in ~/.local/bin & /usr/local/bin (skipping symlinks into Cellar)
        let localBinDirs: [(URL, CommandLineToolSource)] = [
            (home.appendingPathComponent(".local/bin", isDirectory: true), .userLocalBin),
            (URL(fileURLWithPath: "/usr/local/bin", isDirectory: true), .systemLocalBin)
        ]
        for (dir, source) in localBinDirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for entry in entries {
                let name = entry.lastPathComponent
                guard !seenNames.contains(name.lowercased()) else { continue }
                let resolved = entry.resolvingSymlinksInPath()
                if resolved.path.contains("/Cellar/") { continue }
                let sz: Int64 = {
                    if let attrs = try? fm.attributesOfItem(atPath: resolved.path),
                       let s = attrs[.size] as? Int64 {
                        return s
                    }
                    return 0
                }()
                guard sz > 0 else { continue }
                seenNames.insert(name.lowercased())
                items.append(
                    CommandLineToolItem(
                        name: name,
                        displayTitle: name,
                        source: source,
                        installURL: entry,
                        binaryURL: resolved,
                        version: "独立二进制",
                        sizeBytes: sz,
                        isRunning: runningComms.contains(name.lowercased()),
                        formulaName: nil
                    )
                )
            }
        }

        // 3. pipx / uv virtual environments
        let envRoots: [(URL, CommandLineToolSource)] = [
            (home.appendingPathComponent(".local/pipx/venvs", isDirectory: true), .uvOrPipx),
            (home.appendingPathComponent(".local/share/uv/tools", isDirectory: true), .uvOrPipx)
        ]
        for (root, source) in envRoots {
            guard let pkgs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for pkg in pkgs {
                let name = pkg.lastPathComponent
                let sz = calculateDirectorySize(url: pkg)
                items.append(
                    CommandLineToolItem(
                        name: name,
                        displayTitle: name,
                        source: source,
                        installURL: pkg,
                        binaryURL: pkg.appendingPathComponent("bin/\(name)"),
                        version: "独立虚拟环境",
                        sizeBytes: sz,
                        isRunning: runningComms.contains(name.lowercased()),
                        formulaName: nil
                    )
                )
            }
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    nonisolated private static func runSimpleCommand(_ path: String, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Orphaned Residue Detection Engine

    nonisolated private static func collectEmbeddedSubBundleIdentifiers(
        in appURL: URL,
        fm: FileManager,
        bundleIDs: inout Set<String>,
        appNames: inout Set<String>
    ) {
        let subDirs = [
            appURL.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true),
            appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true),
            appURL.appendingPathComponent("Contents/XPCServices", isDirectory: true),
            appURL.appendingPathComponent("Contents/Helpers", isDirectory: true),
            appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        ]
        let validExtensions: Set<String> = ["app", "appex", "xpc", "bundle", "plugin"]

        for dir in subDirs where fm.fileExists(atPath: dir.path) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in items where validExtensions.contains(item.pathExtension.lowercased()) {
                appNames.insert(item.deletingPathExtension().lastPathComponent.lowercased())
                if let subBundle = Bundle(url: item) {
                    if let subBid = subBundle.bundleIdentifier {
                        bundleIDs.insert(subBid.lowercased())
                    }
                    if let name = subBundle.infoDictionary?["CFBundleDisplayName"] as? String {
                        appNames.insert(name.lowercased())
                    }
                    if let name = subBundle.infoDictionary?["CFBundleName"] as? String {
                        appNames.insert(name.lowercased())
                    }
                }
            }
        }
    }

    nonisolated private static func isProtectedOrSystemResidue(name: String, path: String) -> Bool {
        // 1. Honor SysPulse unified CleanProtectionStore whitelist (e.g. CloudKit*, Cursor, WeChat, Surge, etc.)
        if CleanProtectionStore.shared.isProtected(path: path) {
            return true
        }

        let lower = name.lowercased()

        // 2. Apple / macOS bundle prefixes
        let protectedPrefixes = [
            "com.apple.", "group.com.apple.", "system.", "mobile.", "apple.", "darwin.",
            "clouddocs", "addressbook", "callhistory", "mail", "safari", "calendars",
            "reminders", "notes", "photos", "findmy", "messages", "shortcuts",
            "sentry", "crashpad", "bugsnag"
        ]
        if protectedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        // 3. Exact macOS system frameworks, cloud sync services, and shared runtime SDK folders
        let protectedExactNames: Set<String> = [
            "apple", "cloudkit", "clouddocs", "cloudphotos", "icloud",
            "geoservices", "passkit", "familycircle", "gamekit",
            "sirientitycache", "siritts", "animoji", "addressbook",
            "callhistorydb", "callhistorytransactions", "facetime", "music",
            "fileprovider", "mobilesync", "crashreporter", "differentialprivacy",
            "intelligenceflow", "knowledge", "categories", "caches",
            "sharedfilelist", "syncservices", "coredata", "icdd", "ubiquity",
            "spotlight", "dictionaryservices", "fontcollections", "keychains",
            "webkit", "amsdatamigratortool", "avatarkit", "homekit",
            "mediaservices", "protectedcloudstorage", "contextstoreagent",
            "replayd", "akd", "gamed", "biometrickit", "triald", "biome",
            "duetexpertd", "coreduet", "proapps", "motion", "installation",
            "syspulse",
            // Shared crash/telemetry SDKs & developer runtimes
            "sentrycrash", "chrome_crashpad_handler", "cctclearcutlogger",
            "phtphenotype", "gippseudonymousid", "homebrew", "pip", "uv",
            "yarn", "pnpm", "npm", "node-gyp", "ms-playwright", "huggingface",
            "torch", "pypoetry", "tealdeer", "typescript", "go-build", "swiftpm",
            // Multi-app vendor root folders
            "google", "microsoft", "adobe", "steam", "jetbrains", "bytedance",
            "mozilla", "oracle", "atlassian", "autodesk", "blackmagic design",
            "parallels software", "epic", "unity", "valve", "vmware", "docker",
            "anthropic", "openai"
        ]
        return protectedExactNames.contains(lower)
    }

    nonisolated private static func normalizedCandidateIdentifiers(for rawName: String) -> [String] {
        var candidates: [String] = []
        let lower = rawName.lowercased()
        candidates.append(lower)

        // Strip Team ID prefix like "2BUA8C4S2C.com.1password.browser-helper"
        if let firstDot = lower.firstIndex(of: ".") {
            let prefix = String(lower[..<firstDot])
            let suffix = String(lower[lower.index(after: firstDot)...])
            if prefix.count == 10, prefix.allSatisfy({ $0.isLetter || $0.isNumber }), !suffix.isEmpty {
                candidates.append(suffix)
            }
        }

        // Strip "group." container prefix
        for base in candidates where base.hasPrefix("group.") {
            candidates.append(String(base.dropFirst("group.".count)))
        }

        // Strip crash SDK prefixes such as "bugsnag-shared-com.nssurge.surge-mac"
        for prefix in ["bugsnag-shared-", "sentry-"] where lower.hasPrefix(prefix) {
            candidates.append(String(lower.dropFirst(prefix.count)))
        }

        return candidates
    }

    nonisolated private static func isOwnedByInstalledApp(
        rawName: String,
        installedBundleIDs: Set<String>,
        installedAppNames: Set<String>
    ) -> Bool {
        let candidates = normalizedCandidateIdentifiers(for: rawName)

        for candidate in candidates {
            if installedBundleIDs.contains(candidate) || installedAppNames.contains(candidate) {
                return true
            }

            // Sub-helper or daemon identifiers such as "<installedBid>.helper" / ".server" / "-mac"
            for bid in installedBundleIDs where bid.count >= 5 {
                if candidate.hasPrefix(bid + ".") || candidate.hasPrefix(bid + "-") || candidate.hasPrefix(bid + "_") {
                    return true
                }
            }

            // Folder name prefixed by an installed app's name (e.g. "DaVinci Resolve Welcome", "Microsoft Edge Beta")
            for appName in installedAppNames where appName.count >= 4 {
                if candidate == appName
                    || candidate.hasPrefix(appName + " ")
                    || candidate.hasPrefix(appName + "-")
                    || candidate.hasPrefix(appName + ".")
                    || candidate.hasPrefix(appName + "installer") {
                    return true
                }
            }
        }

        // Check if bundled FolderNotes.json maps this bundle ID to a currently installed app display name
        if let resolvedDisplayName = FolderNotesCatalog.shared.appDisplayName(forBundleID: rawName)?.lowercased(),
           installedAppNames.contains(resolvedDisplayName) {
            return true
        }

        return false
    }

    nonisolated private static func detectOrphanedResidues(
        home: URL,
        fm: FileManager,
        installedBundleIDs: Set<String>,
        installedAppNames: Set<String>,
        ignoredPaths: Set<String>
    ) -> [OrphanedResidueItem] {
        var orphans: [OrphanedResidueItem] = []

        func shouldSkipOrphanCandidate(name: String, url: URL) -> Bool {
            if ignoredPaths.contains(url.path) {
                return true
            }
            if isProtectedOrSystemResidue(name: name, path: url.path) {
                return true
            }
            if isOwnedByInstalledApp(
                rawName: name,
                installedBundleIDs: installedBundleIDs,
                installedAppNames: installedAppNames
            ) {
                return true
            }
            return false
        }

        let directoryTargets: [(relPath: String, type: AppSpaceComponentType, minBytes: Int64, stripExt: Bool, confidence: AppResidueConfidence, evidence: String)] = [
            ("Library/Containers", .containers, 1024 * 1024, false, .auto, "未匹配到宿主沙盒应用"),
            ("Library/Group Containers", .groupContainers, 1024 * 1024, false, .review, "孤儿共享群组容器（建议复核）"),
            ("Library/Application Scripts", .applicationScripts, 64 * 1024, false, .auto, "孤儿应用脚本容器"),
            ("Library/Application Support", .appSupport, 1024 * 1024 * 2, false, .auto, "未匹配到宿主支持目录"),
            ("Library/Saved Application State", .savedState, 64 * 1024, true, .auto, "残留窗口状态目录"),
            ("Library/Caches", .caches, 1024 * 1024 * 5, false, .auto, "未匹配到宿主运行缓存"),
            ("Library/HTTPStorages", .httpStorages, 1024 * 128, false, .auto, "孤儿 HTTP 网络存储"),
            ("Library/WebKit", .webKit, 1024 * 256, false, .auto, "孤儿 WebKit 缓存容器")
        ]

        for target in directoryTargets {
            let rootURL = home.appendingPathComponent(target.relPath, isDirectory: true)
            guard let subItems = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for sub in subItems {
                let rawID = target.stripExt ? sub.deletingPathExtension().lastPathComponent : sub.lastPathComponent
                if shouldSkipOrphanCandidate(name: rawID, url: sub) { continue }
                let size = calculateDirectorySize(url: sub)
                if size > target.minBytes {
                    let readable = humanReadableResidueName(identifier: rawID)
                    orphans.append(
                        OrphanedResidueItem(
                            originalAppName: readable,
                            bundleID: rawID,
                            componentType: target.type,
                            path: sub,
                            sizeBytes: size,
                            lastModifiedDate: (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                            confidence: target.confidence,
                            evidenceLabel: target.evidence
                        )
                    )
                }
            }
        }

        // Target E: LaunchAgents (~/Library/LaunchAgents)
        let launchAgentsURL = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        if let subItems = try? fm.contentsOfDirectory(at: launchAgentsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for sub in subItems where sub.pathExtension == "plist" {
                let name = sub.deletingPathExtension().lastPathComponent
                if shouldSkipOrphanCandidate(name: name, url: sub) { continue }

                let sz = (try? fm.attributesOfItem(atPath: sub.path)[.size] as? Int64) ?? 2048
                let readable = humanReadableResidueName(identifier: name)
                orphans.append(
                    OrphanedResidueItem(
                        originalAppName: readable,
                        bundleID: name,
                        componentType: .launchAgents,
                        path: sub,
                        sizeBytes: sz,
                        lastModifiedDate: (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                        confidence: .auto,
                        evidenceLabel: "孤儿用户自启代理 Plist"
                    )
                )
            }
        }

        return orphans
    }

    // MARK: - Safe Uninstallation Execution

    public func executeUninstall() {
        guard !isUninstalling && !isScanning else { return }
        let activeSelectedIDs = selectedItemIDs.union(selectedAppIDs).union(selectedResidueIDs)
        guard !activeSelectedIDs.isEmpty else { return }

        let protection = CleanProtectionStore.shared
        if let readFailure = protection.readFailureReason() {
            statusMessage = readFailure
            return
        }

        let appsToUninstall = installedApps.filter { activeSelectedIDs.contains($0.id) && !$0.isSystemApp }
        let residuesToClean = orphanedResidues.filter { activeSelectedIDs.contains($0.id) }
        guard !appsToUninstall.isEmpty || !residuesToClean.isEmpty else { return }

        status = .uninstalling(progress: 0.1, currentApp: "正在准备安全卸载…")

        // Graceful app termination stays on MainActor (fast IPC call)
        let runningBundleIDs = appsToUninstall.filter(\.isRunning).map(\.bundleID)
        for app in appsToUninstall {
            if app.isRunning, let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == app.bundleID }) {
                running.terminate()
            }
        }

        // Snapshot safe URLs to remove so the background task only operates on Sendable values
        let excludedIDs = self.excludedComponentIDs
        let zapWithBrew = self.useHomebrewZapWhenAvailable
        let appPayloads: [(id: UUID, name: String, bundleID: String, bundleURL: URL, caskToken: String?, agentPlists: [URL], targets: [(url: URL, sizeBytes: Int64)])] = appsToUninstall.map { app in
            let safeTargets = app.components
                .filter { $0.isSafeToTrash && !excludedIDs.contains($0.id) && !protection.isProtected(path: $0.path.path) }
                .map { ($0.path, $0.sizeBytes) }
            let agentURLs = app.components
                .filter { $0.type == .launchAgents || $0.type == .launchDaemons }
                .map(\.path)
            return (app.id, app.name, app.bundleID, app.bundleURL, app.caskMatch?.token, agentURLs, safeTargets)
        }
        let residuePayloads: [(id: UUID, name: String, url: URL, sizeBytes: Int64)] = residuesToClean
            .filter { !protection.isProtected(path: $0.path.path) }
            .map { ($0.id, $0.originalAppName, $0.path, $0.sizeBytes) }
        let currentDeleteMode = self.deleteMode

        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var freedTotal: Int64 = 0
            var removedIDs: Set<UUID> = []
            var totalCount = 0

            // Wait up to 3s for terminating processes to exit before removing bundles
            if !runningBundleIDs.isEmpty {
                for _ in 0..<15 {
                    let anyStillRunning = await MainActor.run {
                        NSWorkspace.shared.runningApplications.contains {
                            guard let bid = $0.bundleIdentifier else { return false }
                            return runningBundleIDs.contains(bid) && !$0.isTerminated
                        }
                    }
                    if !anyStillRunning { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await MainActor.run {
                    for bid in runningBundleIDs {
                        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bid && !app.isTerminated {
                            app.forceTerminate()
                        }
                    }
                }
            }

            var privilegedTargets: [(url: URL, sizeBytes: Int64, residueID: UUID?)] = []

            // 1. Process Apps off-main thread so multi-GB bundles never freeze the UI
            for (idx, app) in appPayloads.enumerated() {
                let progress = 0.1 + 0.55 * (Double(idx) / Double(max(1, appPayloads.count)))
                let appName = app.name
                await MainActor.run {
                    self?.status = .uninstalling(progress: progress, currentApp: "正在卸载 \(appName)…")
                }

                StartupItemManager.bootoutMatchingServices(labels: [app.bundleID], plistURLs: app.agentPlists)

                var preExistingTargets: Set<String> = []
                for target in app.targets where fm.fileExists(atPath: target.url.path) {
                    preExistingTargets.insert(target.url.path)
                }

                if zapWithBrew, currentDeleteMode == .permanent, let token = app.caskToken {
                    let brewBin = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
                    if FileManager.default.isExecutableFile(atPath: brewBin) {
                        _ = Self.runSimpleCommand(brewBin, args: ["uninstall", "--cask", "--zap", token])
                        for target in app.targets where preExistingTargets.contains(target.url.path) && !fm.fileExists(atPath: target.url.path) {
                            freedTotal += target.sizeBytes
                        }
                    }
                }

                for target in app.targets {
                    if fm.fileExists(atPath: target.url.path) {
                        do {
                            if currentDeleteMode == .moveToTrash {
                                try fm.trashItem(at: target.url, resultingItemURL: nil)
                            } else {
                                try fm.removeItem(at: target.url)
                            }
                            if !fm.fileExists(atPath: target.url.path) {
                                freedTotal += target.sizeBytes
                            }
                        } catch {
                            privilegedTargets.append((target.url, target.sizeBytes, nil))
                        }
                    }
                }
            }

            // 2. Process Residues
            for (idx, residue) in residuePayloads.enumerated() {
                let progress = 0.65 + 0.2 * (Double(idx) / Double(max(1, residuePayloads.count)))
                let resName = residue.name
                await MainActor.run {
                    self?.status = .uninstalling(progress: progress, currentApp: "正在清理残留 \(resName)…")
                }

                if fm.fileExists(atPath: residue.url.path) {
                    if residue.url.pathExtension == "plist" && residue.url.path.contains("/LaunchAgents/") {
                        StartupItemManager.bootoutMatchingServices(labels: [residue.url.deletingPathExtension().lastPathComponent], plistURLs: [residue.url])
                    }
                    do {
                        if currentDeleteMode == .moveToTrash {
                            try fm.trashItem(at: residue.url, resultingItemURL: nil)
                        } else {
                            try fm.removeItem(at: residue.url)
                        }
                        if !fm.fileExists(atPath: residue.url.path) {
                            freedTotal += residue.sizeBytes
                            removedIDs.insert(residue.id)
                            totalCount += 1
                        }
                    } catch {
                        privilegedTargets.append((residue.url, residue.sizeBytes, residue.id))
                    }
                }
            }

            // 3. Single batch administrator authorization fallback for /Applications or protected targets
            if !privilegedTargets.isEmpty {
                await MainActor.run {
                    self?.status = .uninstalling(progress: 0.88, currentApp: "正在请求管理员权限以移除受保护应用组件…")
                }
                Self.runPrivilegedBatchRemove(urls: privilegedTargets.map(\.url), mode: currentDeleteMode)

                for item in privilegedTargets {
                    if !fm.fileExists(atPath: item.url.path) {
                        freedTotal += item.sizeBytes
                        if let resID = item.residueID {
                            removedIDs.insert(resID)
                            totalCount += 1
                        }
                    }
                }
            }

            // Verify app bundle removal before counting an app as uninstalled
            for app in appPayloads {
                if !fm.fileExists(atPath: app.bundleURL.path) {
                    removedIDs.insert(app.id)
                    totalCount += 1
                }
            }

            let finalFreed = freedTotal
            let finalCount = totalCount
            let finalRemovedIDs = removedIDs

            await MainActor.run {
                guard let self else { return }
                if finalCount == 0 && finalFreed == 0 {
                    self.status = .completed
                    self.statusMessage = "卸载未完成：目标应用受系统权限保护，请授予管理员权限后重试。"
                    return
                }

                self.lastUninstalledBytes = finalFreed
                self.lastUninstallDate = Date()
                self.lastUninstalledCount = finalCount
                UserDefaults.standard.set(finalFreed, forKey: "PG_Uninstaller_LastFreedBytes")
                UserDefaults.standard.set(Date(), forKey: "PG_Uninstaller_LastDate")

                self.installedApps.removeAll { finalRemovedIDs.contains($0.id) }
                self.orphanedResidues.removeAll { finalRemovedIDs.contains($0.id) }
                self.selectedItemIDs.subtract(finalRemovedIDs)
                self.selectedAppIDs.subtract(finalRemovedIDs)
                self.selectedResidueIDs.subtract(finalRemovedIDs)

                self.status = .finished(freedBytes: finalFreed, count: finalCount)

                // Trigger disk monitor refresh
                SystemResourceMonitor.shared.refreshNow()
            }
        }
    }

    public func uninstallSelectedApps() {
        executeUninstall()
    }

    public func cleanSelectedOrphanedResidues() {
        executeUninstall()
    }

    /// 仅清理应用关联数据（保留 .app 应用本体），适合重置异常配置或瘦身大体积沙盒。
    public func clearDataOnly(for app: InstalledAppInfo) {
        guard !isUninstalling && !isScanning && !app.isSystemApp else { return }
        let protection = CleanProtectionStore.shared
        if let readFailure = protection.readFailureReason() {
            statusMessage = readFailure
            return
        }
        if app.isRunning, let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == app.bundleID }) {
            running.terminate()
        }
        let excluded = self.excludedComponentIDs
        let dataTargets = app.components
            .filter { $0.type != .appBundle && $0.isSafeToTrash && !excluded.contains($0.id) && !protection.isProtected(path: $0.path.path) }
            .map { ($0.path, $0.sizeBytes) }
        guard !dataTargets.isEmpty else {
            statusMessage = "\(app.name) 暂无可安全清理的数据目录"
            return
        }
        let currentMode = self.deleteMode
        let bundleID = app.bundleID
        let agentURLs = app.components.filter { $0.type == .launchAgents }.map(\.path)
        status = .uninstalling(progress: 0.25, currentApp: "正在清理 \(app.name) 数据并保留应用本体…")

        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var freed: Int64 = 0
            StartupItemManager.bootoutMatchingServices(labels: [bundleID], plistURLs: agentURLs)
            for target in dataTargets where fm.fileExists(atPath: target.0.path) {
                do {
                    if currentMode == .moveToTrash {
                        try fm.trashItem(at: target.0, resultingItemURL: nil)
                    } else {
                        try fm.removeItem(at: target.0)
                    }
                    freed += target.1
                } catch {}
            }
            let totalFreed = freed
            await MainActor.run {
                guard let self else { return }
                self.statusMessage = "已清理 \(app.name) 数据 \(self.formatBytes(totalFreed))，应用本体已保留"
                self.startScan()
            }
        }
    }

    public func uninstallCommandLineTool(_ tool: CommandLineToolItem) {
        guard !isUninstalling else { return }
        let mode = self.deleteMode
        statusMessage = "正在卸载命令行工具 \(tool.name)…"

        Task.detached(priority: .userInitiated) { [weak self] in
            var errorMsg: String? = nil
            if tool.source == .homebrewFormula, let formula = tool.formulaName {
                let brewBin = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
                let out = Self.runSimpleCommand(brewBin, args: ["uninstall", formula])
                if FileManager.default.fileExists(atPath: tool.installURL.path) {
                    errorMsg = out.isEmpty ? "Homebrew 卸载未移除（可能存在依赖此公式的软件）" : String(out.prefix(120))
                }
            } else {
                do {
                    if mode == .moveToTrash {
                        try FileManager.default.trashItem(at: tool.installURL, resultingItemURL: nil)
                    } else {
                        try FileManager.default.removeItem(at: tool.installURL)
                    }
                } catch {
                    errorMsg = error.localizedDescription
                }
            }

            await MainActor.run {
                guard let self else { return }
                if let errorMsg {
                    self.statusMessage = "CLI 卸载受阻：\(errorMsg)"
                } else {
                    self.commandLineTools.removeAll { $0.id == tool.id }
                    self.statusMessage = "已卸载 \(tool.name)，释放 \(tool.formattedSize)"
                }
            }
        }
    }

    // MARK: - Utilities

    nonisolated private static func calculateDirectorySize(url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return 0
        }
        while let fileURL = enumerator.nextObject() as? URL {
            if let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let sz = values.fileAllocatedSize ?? values.fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    nonisolated private static func queryLastUsedDate(url: URL) -> Date? {
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            if let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
                return date
            }
        }
        return nil
    }

    nonisolated private static func humanReadableResidueName(identifier: String) -> String {
        let lower = identifier.lowercased()
        if lower.contains("xcode") { return "Xcode 开发套件" }
        if lower.contains("wechat") || lower.contains("xinwechat") { return "微信" }
        if lower.contains("chrome") { return "Google Chrome" }
        if lower.contains("slack") { return "Slack" }
        if lower.contains("vscode") || lower.contains("code") { return "Visual Studio Code" }
        if lower.contains("neteasemusic") || lower.contains("cloudmusic") { return "网易云音乐" }
        if lower.contains("telegram") { return "Telegram" }
        if lower.contains("dingtalk") { return "钉钉" }
        if lower.contains("feishu") || lower.contains("lark") { return "飞书" }
        if lower.contains("qq") { return "QQ" }
        if lower.contains("raycast") { return "Raycast" }

        let components = identifier.split(separator: ".")
        if let last = components.last, last.count > 2 {
            return String(last).capitalized
        }
        return identifier
    }

    nonisolated private static func runPrivilegedBatchRemove(urls: [URL], mode: UninstallerDeleteMode) {
        guard !urls.isEmpty else { return }
        func shSingleQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let userTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        var scriptLines = ["#!/bin/bash", "TRASH_DIR=\(shSingleQuote(userTrash))", "mkdir -p \"$TRASH_DIR\" 2>/dev/null || true"]

        for url in urls {
            let p = shSingleQuote(url.path)
            let base = shSingleQuote(url.lastPathComponent)
            scriptLines.append("/usr/bin/chflags -R nouchg \(p) 2>/dev/null || true")
            if mode == .moveToTrash {
                scriptLines.append("""
                if [ -e \(p) ]; then
                  ITEM_NAME=\(base)
                  DEST="$TRASH_DIR/$ITEM_NAME"
                  if [ -e "$DEST" ]; then
                    DEST="$TRASH_DIR/${ITEM_NAME}.$(/bin/date +%Y%m%d%H%M%S)"
                  fi
                  /bin/mv \(p) "$DEST" 2>/dev/null || true
                fi
                """)
            } else {
                scriptLines.append("/bin/rm -rf \(p) 2>/dev/null || true")
            }
        }

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syspulse-uninstall-\(UUID().uuidString).sh")
        let content = scriptLines.joined(separator: "\n")
        do {
            try content.write(to: scriptURL, atomically: true, encoding: .utf8)
            _ = runSimpleCommand("/bin/chmod", args: ["700", scriptURL.path])
        } catch {
            return
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let shellCmd = "/bin/bash " + shSingleQuote(scriptURL.path)
        let escapedForAppleScript = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"
        _ = runSimpleCommand("/usr/bin/osascript", args: ["-e", appleScript])
    }

    public func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 {
            return "0 B"
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
