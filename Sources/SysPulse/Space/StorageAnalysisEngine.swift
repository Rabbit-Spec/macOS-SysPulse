import Foundation
import AppKit
import SwiftUI
import Observation

// MARK: - 磁盘空间分析引擎

private final class ScanCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool = false

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

@Observable
@MainActor
public final class StorageAnalysisEngine {
    public static let shared = StorageAnalysisEngine()

    // MARK: - Observable State

    public var selectedLocation: AnalysisLocation = .home
    public var status: StorageAnalysisStatus = .idle
    public var isScanning: Bool = false
    public var rootNode: AnalysisNode? = nil
    public var currentNode: AnalysisNode? = nil
    public var breadcrumbStack: [AnalysisNode] = []
    public var topLargeFiles: [AnalysisLargeFileItem] = []
    public var hiddenInsights: [HiddenSpaceInsight] = []
    public var ageBuckets: [AnalysisBucketMetric] = []
    public var sizeBuckets: [AnalysisBucketMetric] = []
    public var kindBuckets: [AnalysisBucketMetric] = []
    public var toolAdvisories: [AnalysisToolAdvisory] = []
    public var diskTelemetry: AnalysisDiskTelemetry = AnalysisDiskTelemetry()
    public var activeViewMode: AnalysisViewMode = .browser
    public var totalScannedFiles: Int = 0
    public var totalScannedBytes: Int64 = 0
    public var scanDuration: TimeInterval = 0
    public var searchQuery: String = ""
    public var showHiddenFilesInBrowser: Bool = true
    public var isMultiSelectMode: Bool = false
    public var selectedNodeIDs: Set<UUID> = []
    public var isTailExpanded: Bool = false
    public var lastActionMessage: String? = nil
    public var showingFDAGuidance: Bool = false
    public var pendingSizingCount: Int = 0
    public var protectedUnreadableCount: Int = 0

    // Internal concurrency control
    private var scanTask: Task<Void, Never>? = nil
    private var refinementTask: Task<Void, Never>? = nil
    private nonisolated let cancellationBox = ScanCancellationBox()

    private nonisolated func setCancelled(_ cancelled: Bool) {
        cancellationBox.set(cancelled)
    }

    private nonisolated var isScanCancelled: Bool {
        cancellationBox.isCancelled
    }

    private init() {
        populateDefaultInsights()
        FolderNotesCatalog.shared.preloadInBackground()
    }

    // MARK: - Formatted Properties

    public var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalScannedBytes, countStyle: .file)
    }

    public var currentFolderChildren: [AnalysisNode] {
        guard let current = currentNode else { return [] }
        let base: [AnalysisNode]
        if showHiddenFilesInBrowser {
            base = current.children
        } else {
            base = current.children.filter { !$0.name.hasPrefix(".") }
        }
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return base
        }
        let q = searchQuery.lowercased()
        return base.filter { $0.name.lowercased().contains(q) }
    }

    public var hiddenEntriesCountInCurrentFolder: Int {
        guard let current = currentNode else { return 0 }
        return current.children.filter { $0.name.hasPrefix(".") }.count
    }

    public var hiddenEntriesBytesInCurrentFolder: Int64 {
        guard let current = currentNode else { return 0 }
        return current.children.filter { $0.name.hasPrefix(".") }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var selectedNodesBytes: Int64 {
        guard let current = currentNode else { return 0 }
        return current.children.filter { selectedNodeIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var filteredLargeFiles: [AnalysisLargeFileItem] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return topLargeFiles
        }
        let q = searchQuery.lowercased()
        return topLargeFiles.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    public func toggleNodeSelection(_ node: AnalysisNode) {
        if selectedNodeIDs.contains(node.id) {
            selectedNodeIDs.remove(node.id)
        } else {
            selectedNodeIDs.insert(node.id)
        }
    }

    public func clearNodeSelection() {
        selectedNodeIDs.removeAll()
    }

    public func selectUnusedOverYearInCurrentFolder() {
        for child in currentFolderChildren where child.isUnusedOverYear {
            selectedNodeIDs.insert(child.id)
        }
    }

    // MARK: - Scan Actions

    private struct ScanAccumulator {
        var fileCount: Int = 0
        var byteCount: Int64 = 0
        var largeFiles: [AnalysisLargeFileItem] = []
        var lastProgressUpdate: Date = Date()
        var recentBytes: Int64 = 0
        var recentCount: Int = 0
        var mid6mBytes: Int64 = 0
        var mid6mCount: Int = 0
        var old1yBytes: Int64 = 0
        var old1yCount: Int = 0
        var stale1yPlusBytes: Int64 = 0
        var stale1yPlusCount: Int = 0
        var largeTierBytes: Int64 = 0
        var largeTierCount: Int = 0
        var mediumTierBytes: Int64 = 0
        var mediumTierCount: Int = 0
        var smallTierBytes: Int64 = 0
        var smallTierCount: Int = 0
        var kindTotals: [AnalysisFileKind: (bytes: Int64, count: Int)] = [:]
        var pendingSizingNodes: [AnalysisNode] = []
        var protectedUnreadableCount: Int = 0

        mutating func recordFile(url: URL, size: Int64, isPackage: Bool, modDate: Date?, accessDate: Date?, now: Date) {
            fileCount += 1
            byteCount += size

            if size >= 1024 * 1024 * 1024 {
                largeTierBytes += size; largeTierCount += 1
            } else if size >= 100 * 1024 * 1024 {
                mediumTierBytes += size; mediumTierCount += 1
            } else {
                smallTierBytes += size; smallTierCount += 1
            }

            if size >= 50 * 1024 * 1024 {
                largeFiles.append(
                    AnalysisLargeFileItem(
                        url: url,
                        sizeBytes: size,
                        isPackage: isPackage,
                        modificationDate: modDate,
                        lastAccessDate: accessDate
                    )
                )
            }

            if let refDate = accessDate ?? modDate {
                let days = now.timeIntervalSince(refDate) / 86400.0
                if days <= 30 {
                    recentBytes += size; recentCount += 1
                } else if days <= 180 {
                    mid6mBytes += size; mid6mCount += 1
                } else if days <= 365 {
                    old1yBytes += size; old1yCount += 1
                } else {
                    stale1yPlusBytes += size; stale1yPlusCount += 1
                }
            } else {
                mid6mBytes += size; mid6mCount += 1
            }

            let kind = AnalysisFileKind.classify(url: url, isPackage: isPackage)
            let prev = kindTotals[kind] ?? (0, 0)
            kindTotals[kind] = (prev.bytes + size, prev.count + 1)
        }

        func buildAgeBuckets() -> [AnalysisBucketMetric] {
            [
                AnalysisBucketMetric(id: "recent", label: "30 天内活跃", bytes: recentBytes, count: recentCount, tintName: "green"),
                AnalysisBucketMetric(id: "mid6m", label: "1–6 个月", bytes: mid6mBytes, count: mid6mCount, tintName: "blue"),
                AnalysisBucketMetric(id: "old1y", label: "6–12 个月", bytes: old1yBytes, count: old1yCount, tintName: "orange"),
                AnalysisBucketMetric(id: "stale1y", label: "1 年以上未动", bytes: stale1yPlusBytes, count: stale1yPlusCount, tintName: "red")
            ]
        }

        func buildSizeBuckets() -> [AnalysisBucketMetric] {
            [
                AnalysisBucketMetric(id: "gt1g", label: "≥ 1 GB 超大项", bytes: largeTierBytes, count: largeTierCount, tintName: "purple"),
                AnalysisBucketMetric(id: "100m_1g", label: "100 MB – 1 GB", bytes: mediumTierBytes, count: mediumTierCount, tintName: "blue"),
                AnalysisBucketMetric(id: "lt100m", label: "< 100 MB 常规文件", bytes: smallTierBytes, count: smallTierCount, tintName: "teal")
            ]
        }

        func buildKindBuckets() -> [AnalysisBucketMetric] {
            AnalysisFileKind.allCases.compactMap { kind in
                guard let entry = kindTotals[kind], entry.bytes > 0 else { return nil }
                return AnalysisBucketMetric(
                    id: kind.rawValue,
                    label: kind.rawValue,
                    bytes: entry.bytes,
                    count: entry.count,
                    tintName: kind.tintName
                )
            }
            .sorted { $0.bytes > $1.bytes }
        }
    }

    public func startScan(location: AnalysisLocation? = nil) {
        if let location {
            self.selectedLocation = location
        }

        cancelScan()

        let locationID = selectedLocation.id
        let isEntireDisk = (selectedLocation == .entireDisk)
        let targetURL = selectedLocation.url
        isScanning = true
        isTailExpanded = false
        selectedNodeIDs.removeAll()
        status = .scanning(scannedFiles: 0, scannedBytes: 0, currentPath: targetURL.path)
        rootNode = nil
        currentNode = nil
        breadcrumbStack = []
        topLargeFiles = []
        ageBuckets = []
        sizeBuckets = []
        kindBuckets = []
        totalScannedFiles = 0
        totalScannedBytes = 0
        pendingSizingCount = 0
        protectedUnreadableCount = 0
        setCancelled(false)

        let baselineKey = "SP_SpaceBaseline_\(locationID)"
        let prevDict = UserDefaults.standard.dictionary(forKey: baselineKey)
        let prevBytes = (prevDict?["bytes"] as? NSNumber)?.int64Value
        let prevTimestamp = (prevDict?["timestamp"] as? NSNumber)?.doubleValue
        let prevDate = prevTimestamp.map { Date(timeIntervalSince1970: $0) }

        let startTime = Date()
        let hasFullDiskAccess = SystemPermissionManager.shared.fullDiskAccessStatus == .authorized
        let rootDisplayName = selectedLocation.displayName
        let cancellationBox = self.cancellationBox
        let progressCallback: @Sendable (Int, Int64, String) -> Void = { [weak self] currentFiles, currentBytes, currentPath in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.status = .scanning(scannedFiles: currentFiles, scannedBytes: currentBytes, currentPath: currentPath)
            }
        }

        scanTask = Task.detached(priority: .userInitiated) { [weak self, cancellationBox, targetURL, rootDisplayName, hasFullDiskAccess, isEntireDisk, startTime, baselineKey, prevBytes, prevDate, progressCallback] in
            var acc = ScanAccumulator()
            let scanNow = Date()

            let root = Self.scanDirectory(
                url: targetURL,
                rootPath: targetURL.path,
                rootDisplayName: rootDisplayName,
                isEntireDiskRoot: isEntireDisk,
                now: scanNow,
                acc: &acc,
                hasFullDiskAccess: hasFullDiskAccess,
                isCancelled: { cancellationBox.isCancelled },
                onProgress: progressCallback
            )

            let duration = Date().timeIntervalSince(startTime)
            acc.largeFiles.sort { $0.sizeBytes > $1.sizeBytes }
            let cappedLargeFiles = Array(acc.largeFiles.prefix(100))
            let totalRootBytes = root?.sizeBytes ?? acc.byteCount
            let builtAgeBuckets = acc.buildAgeBuckets()
            let builtSizeBuckets = acc.buildSizeBuckets()
            let builtKindBuckets = acc.buildKindBuckets()

            // Query volume metrics
            let volURL = FileManager.default.fileExists(atPath: targetURL.path) ? targetURL : URL(fileURLWithPath: "/")
            var totalCap: Int64 = 0
            var normalAvail: Int64 = 0
            var importantAvail: Int64 = 0
            if let v = try? volURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                totalCap = Int64(v.volumeTotalCapacity ?? 0)
                normalAvail = Int64(v.volumeAvailableCapacity ?? 0)
                importantAvail = v.volumeAvailableCapacityForImportantUsage ?? Int64(normalAvail)
            }
            let purgeable = max(0, importantAvail - normalAvail)
            let physicalUsed = max(0, totalCap - normalAvail)
            let delta = prevBytes.map { totalRootBytes - $0 }
            let telemetry = AnalysisDiskTelemetry(
                volumeTotalBytes: totalCap,
                volumeAvailableBytes: normalAvail,
                volumeImportantAvailableBytes: importantAvail,
                volumePurgeableBytes: purgeable,
                volumeUsedBytes: physicalUsed,
                scanDeltaBytes: delta,
                previousScanDate: prevDate
            )

            let advisories = Self.collectEnvironmentAdvisories()

            let pendingNodes = acc.pendingSizingNodes
            let protectedCount = acc.protectedUnreadableCount

            await MainActor.run {
                guard let self else { return }
                if self.isScanCancelled {
                    self.status = .cancelled
                    self.isScanning = false
                    return
                }

                UserDefaults.standard.set(
                    ["bytes": NSNumber(value: totalRootBytes), "timestamp": NSNumber(value: Date().timeIntervalSince1970)],
                    forKey: baselineKey
                )

                self.rootNode = root
                self.currentNode = root
                if let root {
                    self.breadcrumbStack = [root]
                }
                self.topLargeFiles = cappedLargeFiles
                self.ageBuckets = builtAgeBuckets
                self.sizeBuckets = builtSizeBuckets
                self.kindBuckets = builtKindBuckets
                self.diskTelemetry = telemetry
                self.toolAdvisories = advisories
                self.totalScannedFiles = acc.fileCount
                self.totalScannedBytes = totalRootBytes
                self.protectedUnreadableCount = protectedCount
                self.pendingSizingCount = pendingNodes.count
                self.scanDuration = duration
                self.status = .completed(totalFiles: acc.fileCount, totalBytes: self.totalScannedBytes, duration: duration)
                self.isScanning = false

                self.refreshHiddenInsights()
                if !pendingNodes.isEmpty {
                    self.scheduleBackgroundSizingRefinement(for: pendingNodes)
                }
            }
        }
    }

    public func cancelScan() {
        setCancelled(true)
        scanTask?.cancel()
        scanTask = nil
        refinementTask?.cancel()
        refinementTask = nil
        pendingSizingCount = 0
        if isScanning {
            isScanning = false
            status = .cancelled
        }
    }

    private func scheduleBackgroundSizingRefinement(for nodes: [AnalysisNode]) {
        refinementTask?.cancel()
        let cancellationBox = self.cancellationBox
        refinementTask = Task.detached(priority: .utility) { [weak self, nodes, cancellationBox] in
            for node in nodes {
                if cancellationBox.isCancelled || Task.isCancelled { return }
                let previousBytes = node.sizeBytes
                let result = Self.calculatePackageSize(url: node.url, timeBudgetSeconds: nil) {
                    cancellationBox.isCancelled
                }
                if cancellationBox.isCancelled || Task.isCancelled { return }
                let delta = result.bytes - previousBytes
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    node.sizeBytes = result.bytes
                    node.isSizingPending = false
                    var walker = node.parent
                    while let p = walker {
                        p.sizeBytes = max(0, p.sizeBytes + delta)
                        p.children.sort { $0.sizeBytes > $1.sizeBytes }
                        walker = p.parent
                    }
                    if delta != 0 {
                        self.totalScannedBytes = max(0, self.totalScannedBytes + delta)
                    }
                    self.pendingSizingCount = max(0, self.pendingSizingCount - 1)
                }
            }
        }
    }

    // MARK: - Recursive Directory Tree Builder

    nonisolated private static let tccProtectedDirectoryNames: Set<String> = [
        "Safari", "Mail", "Messages", "Suggestions", "Calendars", "Reminders",
        "HomeKit", "IdentityServices", "PersonalizationPortrait", "AddressBook",
        "com.apple.TCC", "Photos Library.photoslibrary", "Photos Library"
    ]

    nonisolated private static let ignoredSystemHiddenNames: Set<String> = [
        ".DS_Store", ".Trash", ".Trashes", ".Spotlight-V100", ".DocumentRevisions-V100",
        ".fseventsd", ".TemporaryItems", ".MobileBackups", ".localized",
        ".CFUserTextEncoding", ".VolumeIcon.icns", ".vol", ".file",
        ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware"
    ]

    nonisolated private static let entireDiskRootSkips: Set<String> = [
        "System", "private", "dev", "Volumes", "Network", "cores",
        "home", "net", "bin", "sbin", "usr", "etc", "var", "tmp"
    ]

    private nonisolated static func scanDirectory(
        url: URL,
        rootPath: String,
        rootDisplayName: String,
        isEntireDiskRoot: Bool,
        now: Date,
        acc: inout ScanAccumulator,
        hasFullDiskAccess: Bool,
        isCancelled: () -> Bool,
        onProgress: @Sendable (Int, Int64, String) -> Void
    ) -> AnalysisNode? {
        if isCancelled() || Task.isCancelled { return nil }

        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .contentAccessDateKey
        ]

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        let selfVals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])

        let nodeName: String
        if url.path == rootPath {
            nodeName = rootDisplayName
        } else {
            nodeName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }

        let node = AnalysisNode(
            url: url,
            name: nodeName,
            isDirectory: isDir.boolValue,
            isPackage: false,
            isHiddenFolder: url.path != rootPath && url.lastPathComponent.hasPrefix("."),
            modificationDate: selfVals?.contentModificationDate,
            lastAccessDate: selfVals?.contentAccessDate
        )

        // Include user dotfiles (e.g. .ollama, .cache, .claude) and filter only macOS system metadata entries
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        } catch {
            node.isProtectedOrUnreadable = true
            acc.protectedUnreadableCount += 1
            return node
        }

        var children: [AnalysisNode] = []
        var totalDirSize: Int64 = 0

        for itemURL in contents {
            if isCancelled() || Task.isCancelled { return nil }

            let name = itemURL.lastPathComponent
            if ignoredSystemHiddenNames.contains(name) {
                continue
            }
            if isEntireDiskRoot && url.path == "/" && entireDiskRootSkips.contains(name) {
                continue
            }

            if !hasFullDiskAccess {
                let isProtectedByName = tccProtectedDirectoryNames.contains(name)
                    || (url.path == NSHomeDirectory() && (name == "Desktop" || name == "Documents" || name == "Downloads"))
                if isProtectedByName {
                    let protectedNode = AnalysisNode(
                        url: itemURL,
                        name: name,
                        sizeBytes: 0,
                        isDirectory: true,
                        isPackage: false,
                        isHiddenFolder: name.hasPrefix("."),
                        isProtectedOrUnreadable: true,
                        parent: node
                    )
                    children.append(protectedNode)
                    acc.protectedUnreadableCount += 1
                    continue
                }
            }

            guard let values = try? itemURL.resourceValues(forKeys: resourceKeys) else { continue }

            // Skip symbolic links & firmlink loops
            if values.isSymbolicLink == true { continue }

            let isPackage = values.isPackage == true
            let isDirectory = (values.isDirectory == true) && !isPackage
            let modDate = values.contentModificationDate
            let accessDate = values.contentAccessDate

            if isPackage {
                let packageScan = calculatePackageSize(url: itemURL, timeBudgetSeconds: 0.25, isCancelled: isCancelled)
                let childNode = AnalysisNode(
                    url: itemURL,
                    sizeBytes: packageScan.bytes,
                    isDirectory: false,
                    isPackage: true,
                    isHiddenFolder: false,
                    isSizingPending: packageScan.didTruncate,
                    modificationDate: modDate,
                    lastAccessDate: accessDate,
                    childCount: 1,
                    parent: node
                )
                if packageScan.didTruncate {
                    acc.pendingSizingNodes.append(childNode)
                }
                children.append(childNode)
                totalDirSize += packageScan.bytes
                acc.recordFile(url: itemURL, size: packageScan.bytes, isPackage: true, modDate: modDate, accessDate: accessDate, now: now)
            } else if isDirectory {
                if let subDirNode = scanDirectory(
                    url: itemURL,
                    rootPath: rootPath,
                    rootDisplayName: rootDisplayName,
                    isEntireDiskRoot: false,
                    now: now,
                    acc: &acc,
                    hasFullDiskAccess: hasFullDiskAccess,
                    isCancelled: isCancelled,
                    onProgress: onProgress
                ) {
                    subDirNode.parent = node
                    children.append(subDirNode)
                    totalDirSize += subDirNode.sizeBytes
                }
            } else {
                let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                let childNode = AnalysisNode(
                    url: itemURL,
                    sizeBytes: size,
                    isDirectory: false,
                    isPackage: false,
                    isHiddenFolder: false,
                    modificationDate: modDate,
                    lastAccessDate: accessDate,
                    childCount: 0,
                    parent: node
                )
                children.append(childNode)
                totalDirSize += size
                acc.recordFile(url: itemURL, size: size, isPackage: false, modDate: modDate, accessDate: accessDate, now: now)
            }

            let curNow = Date()
            if curNow.timeIntervalSince(acc.lastProgressUpdate) > 0.12 {
                acc.lastProgressUpdate = curNow
                onProgress(acc.fileCount, acc.byteCount, itemURL.path)
            }
        }

        children.sort { $0.sizeBytes > $1.sizeBytes }
        node.children = children
        node.sizeBytes = totalDirSize
        node.childCount = children.count

        return node
    }

    private nonisolated static func calculatePackageSize(
        url: URL,
        timeBudgetSeconds: TimeInterval? = nil,
        isCancelled: () -> Bool
    ) -> (bytes: Int64, didTruncate: Bool) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey],
            options: []
        ) else { return (0, false) }

        let deadline = timeBudgetSeconds.map { CFAbsoluteTimeGetCurrent() + $0 }
        var total: Int64 = 0
        var seen = 0
        for case let fileURL as URL in enumerator {
            seen += 1
            if seen & 255 == 0 {
                if isCancelled() || Task.isCancelled { return (total, true) }
                if let deadline, CFAbsoluteTimeGetCurrent() >= deadline {
                    return (total, true)
                }
            }
            if let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) {
                total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return (total, false)
    }

    // MARK: - 目录层级导航

    public func navigateTo(node: AnalysisNode) {
        guard node.isDirectory else {
            revealInFinder(url: node.url)
            return
        }
        searchQuery = ""
        isTailExpanded = false
        selectedNodeIDs.removeAll()
        currentNode = node
        breadcrumbStack.append(node)
    }

    public func navigateUp() {
        guard breadcrumbStack.count > 1 else { return }
        breadcrumbStack.removeLast()
        searchQuery = ""
        isTailExpanded = false
        selectedNodeIDs.removeAll()
        currentNode = breadcrumbStack.last
    }

    public func navigateToBreadcrumb(at index: Int) {
        guard index >= 0, index < breadcrumbStack.count else { return }
        breadcrumbStack = Array(breadcrumbStack.prefix(index + 1))
        searchQuery = ""
        isTailExpanded = false
        selectedNodeIDs.removeAll()
        currentNode = breadcrumbStack.last
    }

    // MARK: - File Actions & Node Refresh

    public func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openItem(url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        lastActionMessage = "已复制路径：\(path)"
    }

    private func guardBlockMessage(for url: URL) -> String? {
        let stdPath = url.standardizedFileURL.path
        let protectedRoots: Set<String> = [
            "/", NSHomeDirectory(), "/Users", "/Applications", "/Library", "/opt"
        ]
        if protectedRoots.contains(stdPath) {
            return "已受保护规则拦截：不能将顶层系统或个人主目录移到废纸篓"
        }
        let verdict = CleanWhitelistMatcher.shared.evaluate(url: url)
        guard case .blocked(let reason, _) = verdict else { return nil }
        switch reason {
        case .criticalSystemPath, .protectedAppData, .whitelisted, .symlinkedPath, .protectedSymlinkTarget, .controlChars, .traversal, .notAbsolute, .emptyPath:
            return "已受保护规则拦截：\(reason.localizedReason)"
        case .userDataPath, .outsideAllowedZones:
            return nil
        }
    }

    public func folderPurposeHint(for node: AnalysisNode) -> String? {
        guard node.isDirectory else { return nil }
        if let catalogNote = FolderNotesCatalog.shared.note(forPath: node.path, isDirectory: true) {
            return catalogNote
        }
        let name = node.name
        let path = node.path
        if name == "DerivedData" || path.hasSuffix("/Library/Developer/Xcode/DerivedData") {
            return "Xcode 编译缓存"
        }
        if name == "CoreSimulator" || path.hasSuffix("/Library/Developer/CoreSimulator") {
            return "iOS 模拟器镜像"
        }
        if name == "Archives" && path.contains("/Xcode/") {
            return "Xcode 打包归档"
        }
        if name == "node_modules" {
            return "Node.js 项目依赖"
        }
        if name == "Mobile Documents" || path.contains("CloudDocs") {
            return "iCloud 云端同步"
        }
        if name == "Containers" || name == "Group Containers" {
            return "沙盒应用容器数据"
        }
        if name == "Application Support" {
            return "应用配置与支持数据"
        }
        if name == "Caches" || name == ".cache" {
            return "可重建本地缓存"
        }
        if name == "Logs" {
            return "诊断与运行日志"
        }
        if [".ollama", ".lmstudio", ".claude", ".codex", ".cursor", ".gemini", ".copilot"].contains(name) {
            return "AI 工具本地工作区"
        }
        if name == "Developer" {
            return "开发工具与编译产物"
        }
        return nil
    }

    public func refreshNode(_ targetNode: AnalysisNode) {
        guard !isScanning else { return }
        let targetURL = targetNode.url
        let displayName = targetNode.name
        let hasFullDiskAccess = SystemPermissionManager.shared.fullDiskAccessStatus == .authorized
        lastActionMessage = "正在刷新 \(displayName)…"

        Task.detached(priority: .userInitiated) { [weak self] in
            var acc = ScanAccumulator()
            let now = Date()
            let refreshed = Self.scanDirectory(
                url: targetURL,
                rootPath: targetURL.path,
                rootDisplayName: displayName,
                isEntireDiskRoot: (targetURL.path == "/"),
                now: now,
                acc: &acc,
                hasFullDiskAccess: hasFullDiskAccess,
                isCancelled: { false },
                onProgress: { _, _, _ in }
            )

            await MainActor.run { [weak self] in
                guard let self, let refreshed else { return }
                for child in refreshed.children {
                    child.parent = targetNode
                }
                targetNode.children = refreshed.children
                targetNode.sizeBytes = refreshed.sizeBytes
                targetNode.childCount = refreshed.children.count

                // Propagate size changes up parent chain
                var walker = targetNode.parent
                while let p = walker {
                    p.sizeBytes = p.children.reduce(0) { $0 + $1.sizeBytes }
                    p.children.sort { $0.sizeBytes > $1.sizeBytes }
                    walker = p.parent
                }
                self.totalScannedBytes = self.rootNode?.sizeBytes ?? self.totalScannedBytes

                let prefix = targetURL.path.hasSuffix("/") ? targetURL.path : targetURL.path + "/"
                self.topLargeFiles.removeAll { $0.path == targetURL.path || $0.path.hasPrefix(prefix) }
                self.topLargeFiles.append(contentsOf: acc.largeFiles)
                self.topLargeFiles.sort { $0.sizeBytes > $1.sizeBytes }
                if self.topLargeFiles.count > 100 {
                    self.topLargeFiles = Array(self.topLargeFiles.prefix(100))
                }
                self.lastActionMessage = "已刷新 \(displayName)（\(targetNode.formattedSize)）"
            }
        }
    }

    public func moveSelectedNodesToTrash() {
        guard let current = currentNode else { return }
        let targets = current.children.filter { selectedNodeIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        var blockedCount = 0
        var allowedURLs: [URL] = []
        var allowedNodes: [AnalysisNode] = []

        for node in targets {
            if guardBlockMessage(for: node.url) != nil {
                blockedCount += 1
            } else {
                allowedURLs.append(node.url)
                allowedNodes.append(node)
            }
        }

        guard !allowedURLs.isEmpty else {
            lastActionMessage = "所选项目均受系统或清理白名单保护，已跳过"
            return
        }

        let immutableURLs = allowedURLs
        let immutableRemovedIDs = Set(allowedNodes.map(\.id))
        let immutableRemovedURLs = Set(allowedURLs)
        let immutableFreedTotal = allowedNodes.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let immutableAllowedCount = allowedNodes.count
        let immutableBlockedCount = blockedCount

        NSWorkspace.shared.recycle(immutableURLs) { [weak self] _, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.lastActionMessage = "批量移至废纸篓失败：\(error.localizedDescription)"
                    return
                }
                current.children.removeAll { immutableRemovedIDs.contains($0.id) }
                current.sizeBytes = max(0, current.sizeBytes - immutableFreedTotal)
                current.childCount = current.children.count
                var walker = current.parent
                while let p = walker {
                    p.sizeBytes = max(0, p.sizeBytes - immutableFreedTotal)
                    walker = p.parent
                }
                self.topLargeFiles.removeAll { immutableRemovedURLs.contains($0.url) }
                self.totalScannedBytes = max(0, self.totalScannedBytes - immutableFreedTotal)
                self.selectedNodeIDs.subtract(immutableRemovedIDs)
                let formatted = ByteCountFormatter.string(fromByteCount: immutableFreedTotal, countStyle: .file)
                if immutableBlockedCount > 0 {
                    self.lastActionMessage = "已移至废纸篓 \(immutableAllowedCount) 项（释放 \(formatted)），另有 \(immutableBlockedCount) 项受保护跳过"
                } else {
                    self.lastActionMessage = "已批量移至废纸篓 \(immutableAllowedCount) 项（共 \(formatted)）"
                }
            }
        }
    }

    public func moveToTrash(node: AnalysisNode) {
        if let blockMsg = guardBlockMessage(for: node.url) {
            lastActionMessage = blockMsg
            return
        }
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.lastActionMessage = "无法移动到废纸篓：\(error.localizedDescription)"
                } else {
                    let freedSize = node.sizeBytes
                    self.lastActionMessage = "已移至废纸篓：\(node.name)"
                    self.selectedNodeIDs.remove(node.id)
                    if let parent = node.parent {
                        parent.children.removeAll { $0.id == node.id }
                        parent.sizeBytes = max(0, parent.sizeBytes - freedSize)
                        parent.childCount = parent.children.count
                        var walker = parent.parent
                        while let p = walker {
                            p.sizeBytes = max(0, p.sizeBytes - freedSize)
                            walker = p.parent
                        }
                    }
                    self.topLargeFiles.removeAll { $0.url == node.url }
                    self.totalScannedBytes = max(0, self.totalScannedBytes - freedSize)
                }
            }
        }
    }

    public func moveToTrash(largeFile: AnalysisLargeFileItem) {
        if let blockMsg = guardBlockMessage(for: largeFile.url) {
            lastActionMessage = blockMsg
            return
        }
        NSWorkspace.shared.recycle([largeFile.url]) { [weak self] _, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.lastActionMessage = "无法移动到废纸篓：\(error.localizedDescription)"
                } else {
                    let freedSize = largeFile.sizeBytes
                    self.lastActionMessage = "已移至废纸篓：\(largeFile.name)"
                    self.topLargeFiles.removeAll { $0.id == largeFile.id }
                    self.totalScannedBytes = max(0, self.totalScannedBytes - freedSize)
                    if let root = self.rootNode {
                        self.removeNodeFromTree(root: root, targetURL: largeFile.url, freedSize: freedSize)
                    }
                }
            }
        }
    }

    private nonisolated static func collectEnvironmentAdvisories() -> [AnalysisToolAdvisory] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        func quickDirSize(_ url: URL) -> Int64 {
            guard fm.fileExists(atPath: url.path) else { return 0 }
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) else { return 0 }
            var total: Int64 = 0
            for case let f as URL in enumerator {
                if let v = try? f.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) {
                    total += Int64(v.fileAllocatedSize ?? v.fileSize ?? 0)
                }
            }
            return total
        }

        var advisories: [AnalysisToolAdvisory] = []

        let dockerURL = home.appendingPathComponent("Library/Containers/com.docker.docker")
        let dockerSize = quickDirSize(dockerURL)
        if dockerSize >= 200 * 1024 * 1024 {
            advisories.append(AnalysisToolAdvisory(
                id: "docker",
                toolName: "Docker 镜像与虚拟磁盘",
                badge: "CLI 建议",
                sizeBytes: dockerSize,
                summary: "Docker Desktop 虚拟镜像内部空间需通过 CLI 回收才能真正释放。",
                cliCommand: "docker system prune -a",
                targetURL: dockerURL,
                iconName: "shippingbox.fill"
            ))
        }

        let simURL = home.appendingPathComponent("Library/Developer/CoreSimulator")
        let simSize = quickDirSize(simURL)
        if simSize >= 200 * 1024 * 1024 {
            advisories.append(AnalysisToolAdvisory(
                id: "coresim",
                toolName: "Xcode CoreSimulator 模拟器",
                badge: "开发占空",
                sizeBytes: simSize,
                summary: "不可用的旧版本 iOS/watchOS 模拟器运行镜像可用 xcrun 安全清除。",
                cliCommand: "xcrun simctl delete unavailable",
                targetURL: simURL,
                iconName: "iphone.gen3"
            ))
        }

        let ollamaURL = home.appendingPathComponent(".ollama/models")
        let ollamaSize = quickDirSize(ollamaURL)
        if ollamaSize >= 200 * 1024 * 1024 {
            advisories.append(AnalysisToolAdvisory(
                id: "ollama",
                toolName: "Ollama 本地大模型权重",
                badge: "模型权重",
                sizeBytes: ollamaSize,
                summary: "切勿直接删 blobs 散列文件，请通过 ollama rm 等官方命令安全移除。",
                cliCommand: "ollama list && ollama rm <model>",
                targetURL: ollamaURL,
                iconName: "brain.head.profile"
            ))
        }

        let brewURL = home.appendingPathComponent("Library/Caches/Homebrew")
        let brewSize = quickDirSize(brewURL)
        if brewSize >= 100 * 1024 * 1024 {
            advisories.append(AnalysisToolAdvisory(
                id: "homebrew",
                toolName: "Homebrew 下载归档缓存",
                badge: "包管理器",
                sizeBytes: brewSize,
                summary: "Homebrew 保留的历史源码压缩包与旧版本 Bottle 缓存。",
                cliCommand: "brew cleanup -s --prune=all",
                targetURL: brewURL,
                iconName: "mug.fill"
            ))
        }

        return advisories
    }

    private func removeNodeFromTree(root: AnalysisNode, targetURL: URL, freedSize: Int64) {
        if let idx = root.children.firstIndex(where: { $0.url == targetURL }) {
            root.children.remove(at: idx)
            root.sizeBytes = max(0, root.sizeBytes - freedSize)
            root.childCount = root.children.count
            return
        }
        for child in root.children where child.isDirectory {
            removeNodeFromTree(root: child, targetURL: targetURL, freedSize: freedSize)
        }
    }

    // MARK: - 系统隐藏空间统计

    public func populateDefaultInsights() {
        hiddenInsights = [
            HiddenSpaceInsight(
                id: "purgeable",
                title: "可清除空间 (Purgeable Space)",
                badge: "系统自动管理",
                badgeColorName: "blue",
                summary: "macOS 系统为临时缓存、本地快照与可重建资源标记的预留空间。",
                detailedExplanation: "这部分空间在磁盘紧张时会自动被 macOS 抹除以腾出可用容量。访达显示的可用空间通常已包含了这部分，因此与各目录物理总和产生差异属于正常现象。",
                iconName: "externaldrive.badge.icloud"
            ),
            HiddenSpaceInsight(
                id: "apfs_snapshots",
                title: "APFS 本地快照 (Local Snapshots)",
                badge: "Time Machine",
                badgeColorName: "purple",
                summary: "系统更新或时间机器备份在本地创建的 APFS 只读时间点冻结镜像。",
                detailedExplanation: "即使你删除了上百 GB 的大文件，如果快照引用了这些数据块，物理空间依然不会被真正释放，直到旧快照被自动或手动清理。",
                iconName: "clock.arrow.circlepath"
            ),
            HiddenSpaceInsight(
                id: "apfs_clones",
                title: "硬链接与 APFS 写时复制克隆",
                badge: "零物理重复",
                badgeColorName: "green",
                summary: "APFS 卷宗内复制的文件共享相同的底层磁盘数据块，不占用双倍空间。",
                detailedExplanation: "在同一个 APFS 容器中复制 10GB 的文件，实际只消耗几 KB 的元数据索引。因此把各文件体积简单相加往往会大于实际占用的物理磁盘容量。",
                iconName: "link"
            ),
            HiddenSpaceInsight(
                id: "icloud_placeholders",
                title: "iCloud 云端占位文件",
                badge: "按需下载",
                badgeColorName: "cyan",
                summary: "开启优化 Mac 存储空间后，云端文件在本地仅占用极少元数据。",
                detailedExplanation: "显示有几十 GB 的文稿，在磁盘上可能只有几 MB 快捷占位。只有双击打开时才会从 Apple 云端拉取真实内容。",
                iconName: "icloud.and.tour"
            ),
            HiddenSpaceInsight(
                id: "permissions",
                title: "系统保护与权限受限目录",
                badge: "SIP 安全保护",
                badgeColorName: "orange",
                summary: "部分高权限系统容器、TCC 隐私目录受保护，常规扫描将自动安全略过。",
                detailedExplanation: "为了保障 macOS 系统完整性 (SIP) 与用户隐私安全，SysPulse 始终遵循沙盒安全规范，绝不侵入受保护的系统级专有空间。",
                iconName: "lock.shield.fill"
            )
        ]
    }

    public func refreshHiddenInsights() {
        // Query system purgeable space (CacheDelete) and APFS snapshots off the MainActor
        Task.detached(priority: .utility) { [weak self] in
            let fileManager = FileManager.default
            let homeURL = fileManager.homeDirectoryForCurrentUser
            var purgeableStr: String? = nil
            if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
                let important = values.volumeAvailableCapacityForImportantUsage ?? 0
                let normal = Int64(values.volumeAvailableCapacity ?? 0)
                let purgeable = max(0, important - normal)
                if purgeable > 0 {
                    purgeableStr = ByteCountFormatter.string(fromByteCount: purgeable, countStyle: .file)
                }
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            process.arguments = ["listlocalsnapshots", "/"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            var snapshotText: String? = nil
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                try? pipe.fileHandleForReading.close()
                process.waitUntilExit()
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: .newlines).filter { $0.contains("com.apple.TimeMachine") }
                    let count = lines.count
                    snapshotText = count > 0 ? "\(count) 个本地快照" : "未检测到积压快照"
                }
            } catch {
                // Ignore silent failure
            }

            let finalPurgeable = purgeableStr
            let finalSnapshot = snapshotText
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let formatted = finalPurgeable,
                   let idx = self.hiddenInsights.firstIndex(where: { $0.id == "purgeable" }) {
                    self.hiddenInsights[idx].detectedSize = formatted
                }
                if let finalSnapshot,
                   let idx = self.hiddenInsights.firstIndex(where: { $0.id == "apfs_snapshots" }) {
                    self.hiddenInsights[idx].detectedSize = finalSnapshot
                }
            }
        }
    }
}
