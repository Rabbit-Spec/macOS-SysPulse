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

    public var installedApps: [InstalledAppInfo] = []
    public var orphanedResidues: [OrphanedResidueItem] = []

    public var selectedCategory: AppCategoryFilter = .all
    public var selectedItemIDs: Set<UUID> = []
    public var expandedAppIDs: Set<UUID> = []

    // Backward compatibility with previous properties
    public var selectedAppIDs: Set<UUID> = []
    public var selectedResidueIDs: Set<UUID> = []
    public var selectedTab: UninstallerSubTab = .installedApps

    public var searchQuery: String = ""
    public var sortOption: AppSortOption = .sizeDesc
    public var sortOrder: ProcessSortOrder = .descending

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

    public var selectedBytes: Int64 {
        let appBytes = installedApps
            .filter { selectedItemIDs.contains($0.id) || selectedAppIDs.contains($0.id) }
            .reduce(0) { $0 + $1.totalSizeBytes }
        let resBytes = orphanedResidues
            .filter { selectedItemIDs.contains($0.id) || selectedResidueIDs.contains($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
        return appBytes + resBytes
    }

    public var selectedAppsBytes: Int64 {
        installedApps
            .filter { selectedItemIDs.contains($0.id) || selectedAppIDs.contains($0.id) }
            .reduce(0) { $0 + $1.totalSizeBytes }
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

    // MARK: - Category Stats

    public func categoryCount(_ cat: AppCategoryFilter) -> Int {
        switch cat {
        case .all:
            return installedApps.count + orphanedResidues.count
        case .user:
            return installedApps.filter { !$0.isSystemApp }.count
        case .unused:
            return installedApps.filter { $0.isUnused && !$0.isSystemApp }.count
        case .orphaned:
            return orphanedResidues.count
        case .system:
            return installedApps.filter { $0.isSystemApp }.count
        }
    }

    public func categoryBytes(_ cat: AppCategoryFilter) -> Int64 {
        switch cat {
        case .all:
            return installedApps.reduce(0) { $0 + $1.totalSizeBytes } + orphanedResidues.reduce(0) { $0 + $1.sizeBytes }
        case .user:
            return installedApps.filter { !$0.isSystemApp }.reduce(0) { $0 + $1.totalSizeBytes }
        case .unused:
            return installedApps.filter { $0.isUnused && !$0.isSystemApp }.reduce(0) { $0 + $1.totalSizeBytes }
        case .orphaned:
            return orphanedResidues.reduce(0) { $0 + $1.sizeBytes }
        case .system:
            return installedApps.filter { $0.isSystemApp }.reduce(0) { $0 + $1.totalSizeBytes }
        }
    }

    // MARK: - Unified Row Items for Display

    public var filteredDisplayItems: [UninstallerRowItem] {
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

        return baseItems
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

    // Backward compatibility for filteredApps
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

    // MARK: - Scanning Pipeline

    public func startScan() {
        currentScanTask?.cancel()
        status = .scanning(progress: 0.05, currentApp: "正在检索已安装应用…")
        scanProgress = 0.05
        currentScanningApp = "正在检索已安装应用…"
        installedApps = []
        orphanedResidues = []
        selectedItemIDs.removeAll()
        selectedAppIDs.removeAll()
        selectedResidueIDs.removeAll()

        currentScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser

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

            // Gather running applications
            let running = NSWorkspace.shared.runningApplications
            var runningMap: [String: pid_t] = [:]
            for r in running {
                if let bid = r.bundleIdentifier {
                    runningMap[bid] = r.processIdentifier
                }
            }

            var scannedAppList: [InstalledAppInfo] = []
            var knownBundleIDs = Set<String>()

            // 2. Scan each application and its associated footprint components
            let totalApps = max(1, appURLs.count)
            for (idx, appURL) in appURLs.enumerated() {
                if Task.isCancelled { return }
                let appName = appURL.deletingPathExtension().lastPathComponent
                let progress = 0.05 + 0.65 * (Double(idx) / Double(totalApps))
                await self?.updateScanProgress(progress: progress, appName: "分析空间: \(appName)")

                guard let bundle = Bundle(url: appURL) else { continue }
                let bid = bundle.bundleIdentifier ?? "com.unknown.\(appName.lowercased())"
                knownBundleIDs.insert(bid)

                let infoDict = bundle.infoDictionary ?? [:]
                let displayName = (infoDict["CFBundleDisplayName"] as? String)
                    ?? (infoDict["CFBundleName"] as? String)
                    ?? appName
                let version = (infoDict["CFBundleShortVersionString"] as? String)
                    ?? (infoDict["CFBundleVersion"] as? String)
                    ?? "1.0"

                let isSys = appURL.path.hasPrefix("/System/") || bid.hasPrefix("com.apple.")
                let isRun = runningMap[bid] != nil
                let runPid = runningMap[bid]

                // Resource dates
                let resValues = try? appURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let installDate = resValues?.creationDate

                // Query Spotlight last used date
                let lastUsed = Self.queryLastUsedDate(url: appURL) ?? resValues?.contentModificationDate

                // Calculate footprint components
                var components: [AppSpaceComponent] = []

                // Component 1: App Bundle
                let bundleSize = Self.calculateDirectorySize(url: appURL)
                components.append(
                    AppSpaceComponent(
                        type: .appBundle,
                        path: appURL,
                        sizeBytes: bundleSize,
                        isSafeToTrash: !isSys
                    )
                )

                // Component 2: Containers (~/Library/Containers/<BundleID>)
                let containerURL = home.appendingPathComponent("Library/Containers/\(bid)", isDirectory: true)
                if fm.fileExists(atPath: containerURL.path) {
                    let sz = Self.calculateDirectorySize(url: containerURL)
                    if sz > 1024 * 16 {
                        components.append(
                            AppSpaceComponent(
                                type: .containers,
                                path: containerURL,
                                sizeBytes: sz
                            )
                        )
                    }
                }

                // Component 3: Application Support (~/Library/Application Support/<bid or name>)
                let appSupportBID = home.appendingPathComponent("Library/Application Support/\(bid)", isDirectory: true)
                if fm.fileExists(atPath: appSupportBID.path) {
                    let sz = Self.calculateDirectorySize(url: appSupportBID)
                    if sz > 1024 * 16 {
                        components.append(
                            AppSpaceComponent(
                                type: .appSupport,
                                path: appSupportBID,
                                sizeBytes: sz
                            )
                        )
                    }
                }
                let appSupportName = home.appendingPathComponent("Library/Application Support/\(appName)", isDirectory: true)
                if appSupportName.path != appSupportBID.path && fm.fileExists(atPath: appSupportName.path) {
                    let sz = Self.calculateDirectorySize(url: appSupportName)
                    if sz > 1024 * 16 {
                        components.append(
                            AppSpaceComponent(
                                type: .appSupport,
                                path: appSupportName,
                                sizeBytes: sz
                            )
                        )
                    }
                }

                // Component 4: Caches (~/Library/Caches/<bid>)
                let cacheURL = home.appendingPathComponent("Library/Caches/\(bid)", isDirectory: true)
                if fm.fileExists(atPath: cacheURL.path) {
                    let sz = Self.calculateDirectorySize(url: cacheURL)
                    if sz > 1024 * 16 {
                        components.append(
                            AppSpaceComponent(
                                type: .caches,
                                path: cacheURL,
                                sizeBytes: sz
                            )
                        )
                    }
                }

                // Component 5: Preferences (~/Library/Preferences/<bid>.plist)
                let prefURL = home.appendingPathComponent("Library/Preferences/\(bid).plist")
                if fm.fileExists(atPath: prefURL.path) {
                    let sz = (try? fm.attributesOfItem(atPath: prefURL.path)[.size] as? Int64) ?? 4096
                    components.append(
                        AppSpaceComponent(
                            type: .preferences,
                            path: prefURL,
                            sizeBytes: sz
                        )
                    )
                }

                // Component 6: Saved Application State (~/Library/Saved Application State/<bid>.savedState)
                let savedURL = home.appendingPathComponent("Library/Saved Application State/\(bid).savedState", isDirectory: true)
                if fm.fileExists(atPath: savedURL.path) {
                    let sz = Self.calculateDirectorySize(url: savedURL)
                    components.append(
                        AppSpaceComponent(
                            type: .savedState,
                            path: savedURL,
                            sizeBytes: sz
                        )
                    )
                }

                // Component 7: LaunchAgents (~/Library/LaunchAgents/<bid>.plist)
                let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(bid).plist")
                if fm.fileExists(atPath: agentURL.path) {
                    let sz = (try? fm.attributesOfItem(atPath: agentURL.path)[.size] as? Int64) ?? 2048
                    components.append(
                        AppSpaceComponent(
                            type: .launchAgents,
                            path: agentURL,
                            sizeBytes: sz
                        )
                    )
                }

                // Component 8: Logs (~/Library/Logs/<appName>)
                let logURL = home.appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
                if fm.fileExists(atPath: logURL.path) {
                    let sz = Self.calculateDirectorySize(url: logURL)
                    if sz > 1024 * 16 {
                        components.append(
                            AppSpaceComponent(
                                type: .logs,
                                path: logURL,
                                sizeBytes: sz
                            )
                        )
                    }
                }

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
                        components: components
                    )
                )
            }

            // 3. Scan for Orphaned Residues (无主残留)
            await self?.updateScanProgress(progress: 0.75, appName: "正在检查已卸载软件残留…")
            let discoveredOrphans = Self.detectOrphanedResidues(
                home: home,
                fm: fm,
                installedBundleIDs: knownBundleIDs,
                installedAppNames: Set(scannedAppList.map { $0.name.lowercased() })
            )

            await self?.finishScan(apps: scannedAppList, orphans: discoveredOrphans)
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

    private func finishScan(apps: [InstalledAppInfo], orphans: [OrphanedResidueItem]) {
        self.installedApps = apps
        self.orphanedResidues = orphans
        self.scanProgress = 1.0
        self.currentScanningApp = ""
        self.status = .completed
        self.statusMessage = "扫描就绪：检测到 \(apps.count) 款应用，发现 \(orphans.count) 项无主残留"
    }

    // MARK: - Orphaned Residue Detection Engine

    nonisolated private static func detectOrphanedResidues(
        home: URL,
        fm: FileManager,
        installedBundleIDs: Set<String>,
        installedAppNames: Set<String>
    ) -> [OrphanedResidueItem] {
        var orphans: [OrphanedResidueItem] = []

        let protectedApplePrefixes = [
            "com.apple.", "system.", "mobile.", "clouddocs", "addressbook",
            "callhistory", "mail", "safari", "calendars", "reminders",
            "notes", "photos", "findmy", "messages", "shortcuts"
        ]

        // Target A: Containers (~/Library/Containers)
        let containersURL = home.appendingPathComponent("Library/Containers", isDirectory: true)
        if let subItems = try? fm.contentsOfDirectory(at: containersURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for sub in subItems {
                let name = sub.lastPathComponent
                let lower = name.lowercased()
                if protectedApplePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }

                if !installedBundleIDs.contains(name) {
                    let size = calculateDirectorySize(url: sub)
                    if size > 1024 * 1024 * 1 { // > 1MB
                        let readable = humanReadableResidueName(identifier: name)
                        orphans.append(
                            OrphanedResidueItem(
                                originalAppName: readable,
                                bundleID: name,
                                componentType: .containers,
                                path: sub,
                                sizeBytes: size,
                                lastModifiedDate: (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            )
                        )
                    }
                }
            }
        }

        // Target B: Application Support (~/Library/Application Support)
        let appSupportURL = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        if let subItems = try? fm.contentsOfDirectory(at: appSupportURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for sub in subItems {
                let name = sub.lastPathComponent
                let lower = name.lowercased()
                if protectedApplePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
                if lower == "google" || lower == "microsoft" || lower == "adobe" || lower == "steam" { continue }

                let matchesInstalled = installedBundleIDs.contains(name) || installedAppNames.contains(lower)
                if !matchesInstalled {
                    let size = calculateDirectorySize(url: sub)
                    if size > 1024 * 1024 * 2 { // > 2MB
                        let readable = humanReadableResidueName(identifier: name)
                        orphans.append(
                            OrphanedResidueItem(
                                originalAppName: readable,
                                bundleID: name,
                                componentType: .appSupport,
                                path: sub,
                                sizeBytes: size,
                                lastModifiedDate: (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            )
                        )
                    }
                }
            }
        }

        // Target C: Saved Application State (~/Library/Saved Application State)
        let savedStateURL = home.appendingPathComponent("Library/Saved Application State", isDirectory: true)
        if let subItems = try? fm.contentsOfDirectory(at: savedStateURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for sub in subItems {
                let name = sub.deletingPathExtension().lastPathComponent
                let lower = name.lowercased()
                if protectedApplePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }

                if !installedBundleIDs.contains(name) {
                    let size = calculateDirectorySize(url: sub)
                    if size > 1024 * 64 { // > 64KB
                        let readable = humanReadableResidueName(identifier: name)
                        orphans.append(
                            OrphanedResidueItem(
                                originalAppName: readable,
                                bundleID: name,
                                componentType: .savedState,
                                path: sub,
                                sizeBytes: size,
                                lastModifiedDate: (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            )
                        )
                    }
                }
            }
        }

        // Target D: Caches (~/Library/Caches)
        let cachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
        if let subItems = try? fm.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for sub in subItems {
                let name = sub.lastPathComponent
                let lower = name.lowercased()
                if protectedApplePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }

                if !installedBundleIDs.contains(name) {
                    let size = calculateDirectorySize(url: sub)
                    if size > 1024 * 1024 * 5 { // > 5MB
                        let readable = humanReadableResidueName(identifier: name)
                        orphans.append(
                            OrphanedResidueItem(
                                originalAppName: readable,
                                bundleID: name,
                                componentType: .caches,
                                path: sub,
                                sizeBytes: size,
                                lastModifiedDate: (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            )
                        )
                    }
                }
            }
        }

        // Target E: LaunchAgents (~/Library/LaunchAgents)
        let launchAgentsURL = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        if let subItems = try? fm.contentsOfDirectory(at: launchAgentsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for sub in subItems where sub.pathExtension == "plist" {
                let name = sub.deletingPathExtension().lastPathComponent
                let lower = name.lowercased()
                if protectedApplePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }

                if !installedBundleIDs.contains(name) {
                    let sz = (try? fm.attributesOfItem(atPath: sub.path)[.size] as? Int64) ?? 2048
                    let readable = humanReadableResidueName(identifier: name)
                    orphans.append(
                        OrphanedResidueItem(
                            originalAppName: readable,
                            bundleID: name,
                            componentType: .launchAgents,
                            path: sub,
                            sizeBytes: sz,
                            lastModifiedDate: (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        )
                    )
                }
            }
        }

        return orphans
    }

    // MARK: - Safe Uninstallation Execution

    public func executeUninstall() {
        let activeSelectedIDs = selectedItemIDs.union(selectedAppIDs).union(selectedResidueIDs)
        guard !activeSelectedIDs.isEmpty else { return }

        let appsToUninstall = installedApps.filter { activeSelectedIDs.contains($0.id) && !$0.isSystemApp }
        let residuesToClean = orphanedResidues.filter { activeSelectedIDs.contains($0.id) }
        guard !appsToUninstall.isEmpty || !residuesToClean.isEmpty else { return }

        status = .uninstalling(progress: 0.1, currentApp: "正在准备安全卸载…")

        let fm = FileManager.default
        var freedTotal: Int64 = 0
        var totalCount = 0

        // 1. Process Apps
        for (idx, app) in appsToUninstall.enumerated() {
            let progress = 0.1 + 0.6 * (Double(idx) / Double(max(1, appsToUninstall.count)))
            status = .uninstalling(progress: progress, currentApp: "正在卸载 \(app.name)…")

            // If app is running, terminate gracefully
            if app.isRunning, let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == app.bundleID }) {
                running.terminate()
            }

            // Remove components
            for comp in app.components where comp.isSafeToTrash {
                if CleanProtectionStore.shared.isProtected(path: comp.path.path) {
                    continue
                }
                if fm.fileExists(atPath: comp.path.path) {
                    do {
                        if deleteMode == .moveToTrash {
                            try fm.trashItem(at: comp.path, resultingItemURL: nil)
                        } else {
                            try fm.removeItem(at: comp.path)
                        }
                        freedTotal += comp.sizeBytes
                    } catch {
                        print("SysPulse Uninstaller: Failed to remove \(comp.path): \(error)")
                    }
                }
            }
            totalCount += 1
        }

        // 2. Process Residues
        for (idx, residue) in residuesToClean.enumerated() {
            let progress = 0.7 + 0.3 * (Double(idx) / Double(max(1, residuesToClean.count)))
            status = .uninstalling(progress: progress, currentApp: "正在清理残留 \(residue.originalAppName)…")

            if CleanProtectionStore.shared.isProtected(path: residue.path.path) {
                continue
            }
            if fm.fileExists(atPath: residue.path.path) {
                do {
                    if deleteMode == .moveToTrash {
                        try fm.trashItem(at: residue.path, resultingItemURL: nil)
                    } else {
                        try fm.removeItem(at: residue.path)
                    }
                    freedTotal += residue.sizeBytes
                    totalCount += 1
                } catch {
                    print("SysPulse Uninstaller: Failed to remove residue \(residue.path): \(error)")
                }
            }
        }

        // Update local state
        self.lastUninstalledBytes = freedTotal
        self.lastUninstallDate = Date()
        self.lastUninstalledCount = totalCount
        UserDefaults.standard.set(freedTotal, forKey: "PG_Uninstaller_LastFreedBytes")
        UserDefaults.standard.set(Date(), forKey: "PG_Uninstaller_LastDate")

        self.installedApps.removeAll { activeSelectedIDs.contains($0.id) }
        self.orphanedResidues.removeAll { activeSelectedIDs.contains($0.id) }
        self.selectedItemIDs.removeAll()
        self.selectedAppIDs.removeAll()
        self.selectedResidueIDs.removeAll()

        self.status = .finished(freedBytes: freedTotal, count: totalCount)

        // Trigger disk monitor refresh
        SystemResourceMonitor.shared.refreshNow()

        // Log Power Event
        PowerSourceEngine.shared.appendEvent(
            PowerEvent(
                type: .selfTest,
                details: "应用安全卸载：成功卸载并清理 \(totalCount) 款应用及残留，释放 \(formatBytes(freedTotal)) 磁盘空间"
            )
        )
    }

    public func uninstallSelectedApps() {
        executeUninstall()
    }

    public func cleanSelectedOrphanedResidues() {
        executeUninstall()
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

    public func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
