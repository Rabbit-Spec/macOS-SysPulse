import Foundation
import AppKit
import SwiftUI
import Observation
import Darwin
import Quartz

// MARK: - 卷宗边界策略与硬链接去重

private struct VolumeBoundaryPolicy: Sendable {
    let allowedDeviceIDs: Set<Int32>
    let forbidExternalVolumesPrefix: Bool
    let isNetworkVolume: Bool

    static func forLocation(_ location: AnalysisLocation, targetPath: String) -> VolumeBoundaryPolicy {
        var devs: Set<Int32> = []
        if location.isBuiltInInternalLocation {
            var rootSt = Darwin.stat()
            if stat("/", &rootSt) == 0 {
                devs.insert(rootSt.st_dev)
            }
            var dataSt = Darwin.stat()
            if stat("/System/Volumes/Data", &dataSt) == 0 {
                devs.insert(dataSt.st_dev)
            }
            if !targetPath.hasPrefix("/Volumes/") && targetPath != "/Volumes" {
                var targetSt = Darwin.stat()
                if stat(targetPath, &targetSt) == 0 {
                    devs.insert(targetSt.st_dev)
                }
            }
            return VolumeBoundaryPolicy(
                allowedDeviceIDs: devs,
                forbidExternalVolumesPrefix: true,
                isNetworkVolume: false
            )
        } else {
            var targetSt = Darwin.stat()
            if stat(targetPath, &targetSt) == 0 {
                devs.insert(targetSt.st_dev)
            }
            let isNet: Bool = {
                if case .networkVolume = location { return true }
                var sfs = Darwin.statfs()
                guard statfs(targetPath, &sfs) == 0 else { return false }
                let fsType = withUnsafeBytes(of: sfs.f_fstypename) { rawPtr in
                    String(decoding: rawPtr.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
                }
                return ["smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp"].contains(fsType)
            }()
            let forbidExternal = !targetPath.hasPrefix("/Volumes/")
                && !targetPath.hasPrefix("/System/Volumes/Data/Volumes/")
            return VolumeBoundaryPolicy(
                allowedDeviceIDs: devs,
                forbidExternalVolumesPrefix: forbidExternal,
                isNetworkVolume: isNet
            )
        }
    }

    func allows(path: String, dev: Int32) -> Bool {
        if forbidExternalVolumesPrefix {
            if path == "/Volumes"
                || path.hasPrefix("/Volumes/")
                || path == "/Network"
                || path.hasPrefix("/Network/")
                || path.hasPrefix("/System/Volumes/Data/Volumes/") {
                return false
            }
        }
        if !allowedDeviceIDs.isEmpty && !allowedDeviceIDs.contains(dev) {
            return false
        }
        return true
    }
}

public struct HardlinkKey: Hashable, Sendable {
    public let dev: Int32
    public let ino: UInt64
}

public final class HardlinkTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<HardlinkKey> = []

    public init() {}

    /// 首次遇到该 inode 返回 true，重复硬链接返回 false（避免重复计算物理占用）。
    public func insertIfNew(dev: Int32, ino: UInt64) -> Bool {
        let key = HardlinkKey(dev: dev, ino: ino)
        lock.lock()
        let inserted = seen.insert(key).inserted
        lock.unlock()
        return inserted
    }
}

private final class OwnerAppResolverCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var missSet: Set<String> = []

    func resolveOwnerName(forPath dirPath: String, name dirName: String) -> String? {
        let parentPath = (dirPath as NSString).deletingLastPathComponent
        let parentName = (parentPath as NSString).lastPathComponent
        guard parentName == "Containers"
                || parentName == "Group Containers"
                || parentName == "Application Scripts"
                || parentName == "Caches" else {
            return nil
        }

        var candidateID = dirName
        guard !candidateID.isEmpty, candidateID.contains(".") else { return nil }
        if parentName == "Group Containers" {
            let parts = candidateID.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                if candidateID.hasPrefix("group.") {
                    candidateID = String(parts[1])
                } else if parts[0].count >= 8 {
                    candidateID = String(parts[1])
                }
            }
        }

        lock.lock()
        if let hit = cache[candidateID] {
            lock.unlock()
            return hit
        }
        if missSet.contains(candidateID) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        var resolved = FolderNotesCatalog.shared.appDisplayName(forBundleID: candidateID)
        if resolved == nil,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidateID) {
            if let info = FreshBundleInfo.read(at: appURL, requireBundleID: false) {
                resolved = info.displayName ?? info.bundleName
            }
            if resolved == nil || resolved?.isEmpty == true {
                resolved = appURL.deletingPathExtension().lastPathComponent
            }
        }

        lock.lock()
        if let resolved, !resolved.isEmpty {
            cache[candidateID] = resolved
        } else {
            missSet.insert(candidateID)
        }
        lock.unlock()
        return resolved
    }
}

private final class SharedScanProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Int = 0
    private var bytes: Int64 = 0
    private var lastUpdate: Date = .distantPast

    func advance(filesDelta: Int = 1, bytesDelta: Int64, path: String, onProgress: @Sendable (Int, Int64, String) -> Void) {
        lock.lock()
        files += filesDelta
        bytes += bytesDelta
        let now = Date()
        if now.timeIntervalSince(lastUpdate) > 0.12 {
            lastUpdate = now
            let f = files
            let b = bytes
            lock.unlock()
            onProgress(f, b, path)
        } else {
            lock.unlock()
        }
    }
}

@MainActor
private final class SpaceQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = SpaceQuickLookController()
    var previewURL: URL?

    func preview(url: URL) {
        self.previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let previewURL else { return nil }
        return previewURL as NSURL
    }
}

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
    public var hoveredTreemapNodeID: UUID? = nil
    public var lastSnapshotDate: Date? = nil
    public var isShowingCachedSnapshot: Bool = false
    public var mountedExternalVolumes: [MountedVolumeItem] = []
    public var mountedNetworkVolumes: [MountedVolumeItem] = []

    // Internal concurrency control
    private var scanTask: Task<Void, Never>? = nil
    private var refinementTask: Task<Void, Never>? = nil
    private nonisolated let cancellationBox = ScanCancellationBox()
    private var quickLookPreviewURL: URL? = nil
    private var activeVolumePolicy: VolumeBoundaryPolicy? = nil
    private var hydratingNodeIDs: Set<UUID> = []
    private var mountObservers: [NSObjectProtocol] = []

    private nonisolated func setCancelled(_ cancelled: Bool) {
        cancellationBox.set(cancelled)
    }

    private nonisolated var isScanCancelled: Bool {
        cancellationBox.isCancelled
    }

    private init() {
        populateDefaultInsights()
        let nc = NSWorkspace.shared.notificationCenter
        let mountObs = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMountedVolumes()
            }
        }
        let unmountObs = nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMountedVolumes()
            }
        }
        mountObservers = [mountObs, unmountObs]
    }

    public func refreshMountedVolumes() {
        Task.detached(priority: .utility) { [weak self] in
            let discovered = MountedVolumeDiscovery.discover()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.mountedExternalVolumes = discovered.external
                self.mountedNetworkVolumes = discovered.network
            }
        }
    }

    public func releaseInMemoryTreeIfIdle() {
        guard !isScanning && pendingSizingCount == 0 else { return }
        refinementTask?.cancel()
        refinementTask = nil
        rootNode = nil
        currentNode = nil
        breadcrumbStack = []
        topLargeFiles = []
        selectedNodeIDs.removeAll()
    }

    public func previewWithQuickLook(url: URL) {
        quickLookPreviewURL = url
        SpaceQuickLookController.shared.preview(url: url)
    }

    nonisolated private static func snapshotFileURL(for locationID: String) -> URL {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSup.appendingPathComponent("SysPulse/SpaceSnapshots", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeID = locationID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent("snapshot_\(safeID).json")
    }

    public func loadCachedSnapshotIfAvailable(for location: AnalysisLocation? = nil) {
        let loc = location ?? selectedLocation
        guard rootNode == nil && !isScanning else { return }
        let fileURL = Self.snapshotFileURL(for: loc.id)
        guard let data = try? Data(contentsOf: fileURL),
              let dto = try? JSONDecoder().decode(AnalysisSnapshotDTO.self, from: data),
              dto.sizeBuckets.count >= 4 else {
            return
        }
        let rebuiltRoot = dto.rootNode.toNode(parent: nil)
        self.activeVolumePolicy = VolumeBoundaryPolicy.forLocation(loc, targetPath: loc.url.path)
        self.rootNode = rebuiltRoot
        self.currentNode = rebuiltRoot
        self.breadcrumbStack = [rebuiltRoot]
        self.topLargeFiles = dto.topLargeFiles.map { $0.toItem() }
        self.ageBuckets = dto.ageBuckets.map { AnalysisBucketMetric(id: $0.id, label: $0.label, bytes: $0.bytes, count: $0.count, tintName: $0.tintName) }
        self.sizeBuckets = dto.sizeBuckets.map { AnalysisBucketMetric(id: $0.id, label: $0.label, bytes: $0.bytes, count: $0.count, tintName: $0.tintName) }
        self.kindBuckets = dto.kindBuckets.map { AnalysisBucketMetric(id: $0.id, label: $0.label, bytes: $0.bytes, count: $0.count, tintName: $0.tintName) }
        let initialUsed = (dto.volumeTotalBytes > 0 && dto.volumeImportantAvailableBytes > 0)
            ? max(0, dto.volumeTotalBytes - dto.volumeImportantAvailableBytes)
            : dto.volumeUsedBytes
        self.diskTelemetry = AnalysisDiskTelemetry(
            volumeTotalBytes: dto.volumeTotalBytes,
            volumeAvailableBytes: dto.volumeAvailableBytes,
            volumeImportantAvailableBytes: dto.volumeImportantAvailableBytes,
            volumePurgeableBytes: dto.volumePurgeableBytes,
            volumeUsedBytes: initialUsed
        )
        self.totalScannedFiles = dto.totalScannedFiles
        self.totalScannedBytes = dto.totalScannedBytes
        self.scanDuration = dto.scanDuration
        self.lastSnapshotDate = Date(timeIntervalSince1970: dto.savedTimestamp)
        self.isShowingCachedSnapshot = true
        self.status = .completed(totalFiles: dto.totalScannedFiles, totalBytes: dto.totalScannedBytes, duration: dto.scanDuration)
        self.refreshHiddenInsights(for: loc)
    }

    nonisolated private static func saveSnapshot(
        locationID: String,
        root: AnalysisNode,
        totalFiles: Int,
        totalBytes: Int64,
        duration: TimeInterval,
        topLargeFiles: [AnalysisLargeFileItem],
        ageBuckets: [AnalysisBucketMetric],
        sizeBuckets: [AnalysisBucketMetric],
        kindBuckets: [AnalysisBucketMetric],
        telemetry: AnalysisDiskTelemetry
    ) {
        let dto = AnalysisSnapshotDTO(
            locationID: locationID,
            savedTimestamp: Date().timeIntervalSince1970,
            totalScannedFiles: totalFiles,
            totalScannedBytes: totalBytes,
            scanDuration: duration,
            rootNode: AnalysisNodeSnapshotDTO.from(node: root, maxDepth: 3),
            topLargeFiles: topLargeFiles.prefix(80).map { AnalysisLargeFileSnapshotDTO.from(item: $0) },
            ageBuckets: ageBuckets.map { AnalysisBucketMetricSnapshotDTO(id: $0.id, label: $0.label, bytes: $0.bytes, count: $0.count, tintName: $0.tintName) },
            sizeBuckets: sizeBuckets.map { AnalysisBucketMetricSnapshotDTO(id: $0.id, label: $0.label, bytes: $0.bytes, count: $0.count, tintName: $0.tintName) },
            kindBuckets: kindBuckets.map { AnalysisBucketMetricSnapshotDTO(id: $0.id, label: $0.label, bytes: $0.bytes, count: $0.count, tintName: $0.tintName) },
            volumeTotalBytes: telemetry.volumeTotalBytes,
            volumeAvailableBytes: telemetry.volumeAvailableBytes,
            volumeImportantAvailableBytes: telemetry.volumeImportantAvailableBytes,
            volumePurgeableBytes: telemetry.volumePurgeableBytes,
            volumeUsedBytes: telemetry.volumeUsedBytes
        )
        let url = snapshotFileURL(for: locationID)
        if let data = try? JSONEncoder().encode(dto) {
            try? data.write(to: url, options: .atomic)
        }
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
        var huge2gBytes: Int64 = 0
        var huge2gCount: Int = 0
        var largeTierBytes: Int64 = 0
        var largeTierCount: Int = 0
        var mediumTierBytes: Int64 = 0
        var mediumTierCount: Int = 0
        var smallTierBytes: Int64 = 0
        var smallTierCount: Int = 0
        var kindTotals: [AnalysisFileKind: (bytes: Int64, count: Int)] = [:]
        var pendingSizingNodes: [AnalysisNode] = []
        var protectedUnreadableCount: Int = 0

        mutating func recordFile(filePath: String, name: String, size: Int64, isPackage: Bool, modDate: Date?, accessDate: Date?, now: Date) {
            fileCount += 1
            byteCount += size

            if size >= 2 * 1024 * 1024 * 1024 {
                huge2gBytes += size; huge2gCount += 1
            } else if size >= 1024 * 1024 * 1024 {
                largeTierBytes += size; largeTierCount += 1
            } else if size >= 100 * 1024 * 1024 {
                mediumTierBytes += size; mediumTierCount += 1
            } else {
                smallTierBytes += size; smallTierCount += 1
            }

            if size >= 50 * 1024 * 1024 {
                largeFiles.append(
                    AnalysisLargeFileItem(
                        filePath: filePath,
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

            let kind = AnalysisFileKind.classify(path: filePath, name: name, isPackage: isPackage)
            let prev = kindTotals[kind] ?? (0, 0)
            kindTotals[kind] = (prev.bytes + size, prev.count + 1)
        }

        mutating func merge(_ other: ScanAccumulator) {
            fileCount += other.fileCount
            byteCount += other.byteCount
            largeFiles.append(contentsOf: other.largeFiles)
            recentBytes += other.recentBytes
            recentCount += other.recentCount
            mid6mBytes += other.mid6mBytes
            mid6mCount += other.mid6mCount
            old1yBytes += other.old1yBytes
            old1yCount += other.old1yCount
            stale1yPlusBytes += other.stale1yPlusBytes
            stale1yPlusCount += other.stale1yPlusCount
            huge2gBytes += other.huge2gBytes
            huge2gCount += other.huge2gCount
            largeTierBytes += other.largeTierBytes
            largeTierCount += other.largeTierCount
            mediumTierBytes += other.mediumTierBytes
            mediumTierCount += other.mediumTierCount
            smallTierBytes += other.smallTierBytes
            smallTierCount += other.smallTierCount
            for (kind, entry) in other.kindTotals {
                let prev = kindTotals[kind] ?? (0, 0)
                kindTotals[kind] = (prev.bytes + entry.bytes, prev.count + entry.count)
            }
            pendingSizingNodes.append(contentsOf: other.pendingSizingNodes)
            protectedUnreadableCount += other.protectedUnreadableCount
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
                AnalysisBucketMetric(id: "ge2g", label: "≥ 2 GB", bytes: huge2gBytes, count: huge2gCount, tintName: "purple"),
                AnalysisBucketMetric(id: "1g_2g", label: "1 GB – 2 GB", bytes: largeTierBytes, count: largeTierCount, tintName: "indigo"),
                AnalysisBucketMetric(id: "100m_1g", label: "100 MB – 1 GB", bytes: mediumTierBytes, count: mediumTierCount, tintName: "blue"),
                AnalysisBucketMetric(id: "lt100m", label: "< 100 MB", bytes: smallTierBytes, count: smallTierCount, tintName: "teal")
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

        let locationSnapshot = selectedLocation
        let locationID = locationSnapshot.id
        let isEntireDisk = (locationSnapshot == .entireDisk)
        let isBuiltInInternal = locationSnapshot.isBuiltInInternalLocation
        let targetURL = locationSnapshot.url
        let policy = VolumeBoundaryPolicy.forLocation(locationSnapshot, targetPath: targetURL.path)
        self.activeVolumePolicy = policy
        isScanning = true
        isTailExpanded = false
        isShowingCachedSnapshot = false
        selectedNodeIDs.removeAll()
        status = .scanning(scannedFiles: 0, scannedBytes: 0, currentPath: targetURL.path)
        rootNode = nil
        currentNode = nil
        breadcrumbStack = []
        topLargeFiles = []
        ageBuckets = []
        sizeBuckets = []
        kindBuckets = []
        toolAdvisories = []
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
        let rootDisplayName = locationSnapshot.displayName
        let cancellationBox = self.cancellationBox
        let progressCallback: @Sendable (Int, Int64, String) -> Void = { [weak self] currentFiles, currentBytes, currentPath in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.status = .scanning(scannedFiles: currentFiles, scannedBytes: currentBytes, currentPath: currentPath)
            }
        }

        scanTask = Task.detached(priority: .userInitiated) { [weak self, cancellationBox, locationSnapshot, locationID, targetURL, rootDisplayName, hasFullDiskAccess, isEntireDisk, isBuiltInInternal, policy, startTime, baselineKey, prevBytes, prevDate, progressCallback] in
            let scanNow = Date()
            let hardlinkTracker = HardlinkTracker()
            let ownerResolver = OwnerAppResolverCache()
            let progressTracker = SharedScanProgressTracker()

            var (root, acc) = await Self.scanRootConcurrently(
                rootPath: targetURL.path,
                rootDisplayName: rootDisplayName,
                isEntireDiskRoot: isEntireDisk,
                policy: policy,
                now: scanNow,
                hasFullDiskAccess: hasFullDiskAccess,
                hardlinkTracker: hardlinkTracker,
                ownerResolver: ownerResolver,
                progressTracker: progressTracker,
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
            let systemUsed = max(0, totalCap - importantAvail)
            let delta = prevBytes.map { totalRootBytes - $0 }
            let telemetry = AnalysisDiskTelemetry(
                volumeTotalBytes: totalCap,
                volumeAvailableBytes: normalAvail,
                volumeImportantAvailableBytes: importantAvail,
                volumePurgeableBytes: purgeable,
                volumeUsedBytes: systemUsed,
                scanDeltaBytes: delta,
                previousScanDate: prevDate
            )

            let advisories = isBuiltInInternal ? Self.collectEnvironmentAdvisories(policy: policy) : []

            let pendingNodes = acc.pendingSizingNodes
            let protectedCount = acc.protectedUnreadableCount

            if let root, !cancellationBox.isCancelled {
                Self.saveSnapshot(
                    locationID: locationID,
                    root: root,
                    totalFiles: acc.fileCount,
                    totalBytes: totalRootBytes,
                    duration: duration,
                    topLargeFiles: cappedLargeFiles,
                    ageBuckets: builtAgeBuckets,
                    sizeBuckets: builtSizeBuckets,
                    kindBuckets: builtKindBuckets,
                    telemetry: telemetry
                )
            }

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
                self.lastSnapshotDate = Date()
                self.isShowingCachedSnapshot = false
                self.status = .completed(totalFiles: acc.fileCount, totalBytes: self.totalScannedBytes, duration: duration)
                self.isScanning = false

                self.refreshHiddenInsights(for: locationSnapshot)
                if !pendingNodes.isEmpty {
                    self.scheduleBackgroundSizingRefinement(for: pendingNodes, policy: policy)
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

    private func scheduleBackgroundSizingRefinement(for nodes: [AnalysisNode], policy: VolumeBoundaryPolicy) {
        refinementTask?.cancel()
        let cancellationBox = self.cancellationBox
        let targetPaths = nodes.map { ($0.id, $0.path, $0.sizeBytes) }
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        refinementTask = Task.detached(priority: .utility) { [weak self, targetPaths, nodeMap, policy, cancellationBox] in
            for entry in targetPaths {
                if cancellationBox.isCancelled || Task.isCancelled { return }
                let result = Self.calculatePackageSize(
                    path: entry.1,
                    policy: policy,
                    timeBudgetSeconds: nil,
                    hardlinkTracker: HardlinkTracker()
                ) {
                    cancellationBox.isCancelled
                }
                if cancellationBox.isCancelled || Task.isCancelled { return }
                let delta = result.bytes - entry.2
                await MainActor.run { [weak self] in
                    guard let self, let node = nodeMap[entry.0] else { return }
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

    nonisolated private static let knownPackageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "prefpane",
        "qlgenerator", "mdimporter", "xpc", "fcpbundle", "photoslibrary",
        "aplibrary", "theater", "imovielibrary", "logicx", "band",
        "xcodeproj", "xcworkspace", "playground", "xcarchive", "dsym",
        "mlpackage", "mlmodelc", "utm", "pvm", "vmwarevm", "sparsebundle",
        "rtfd", "scriv"
    ]

    nonisolated private static func dateFromTimespec(_ ts: Darwin.timespec) -> Date? {
        guard ts.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000.0)
    }

    nonisolated private static func isDirectoryPackage(path: String, name: String) -> Bool {
        if name.hasPrefix(".") || !name.contains(".") {
            return false
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if knownPackageExtensions.contains(ext) {
            return true
        }
        return autoreleasepool {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        }
    }

    nonisolated private static func allocatedSizeFromStat(
        _ st: Darwin.stat,
        name: String,
        policy: VolumeBoundaryPolicy,
        hardlinkTracker: HardlinkTracker
    ) -> (bytes: Int64, isCloudPlaceholder: Bool) {
        let isDataless = (Int32(st.st_flags) & SF_DATALESS) != 0
        if isDataless || (name.hasPrefix(".") && name.lowercased().hasSuffix(".icloud")) {
            return (0, true)
        }
        if st.st_nlink > 1, !hardlinkTracker.insertIfNew(dev: Int32(st.st_dev), ino: UInt64(st.st_ino)) {
            return (0, false)
        }
        let allocated = Int64(st.st_blocks) * 512
        if allocated > 0 {
            return (allocated, false)
        }
        if policy.isNetworkVolume && st.st_size > 0 {
            return (Int64(st.st_size), false)
        }
        return (0, false)
    }

    public nonisolated static func physicalAllocatedSize(
        for itemURL: URL,
        values: URLResourceValues?,
        hardlinkTracker: HardlinkTracker
    ) -> (bytes: Int64, isCloudPlaceholder: Bool) {
        var st = Darwin.stat()
        if Darwin.lstat(itemURL.path, &st) == 0 {
            let isDataless = (Int32(st.st_flags) & SF_DATALESS) != 0
            if isDataless || CleanWhitelistMatcher.isICloudPlaceholder(url: itemURL) {
                return (0, true)
            }
            if st.st_nlink > 1, !hardlinkTracker.insertIfNew(dev: Int32(st.st_dev), ino: UInt64(st.st_ino)) {
                return (0, false)
            }
            let allocated = Int64(values?.fileAllocatedSize ?? Int(st.st_blocks) * 512)
            if allocated > 0 {
                return (allocated, false)
            }
            let rawSize = Int64(values?.fileSize ?? Int(st.st_size))
            return (rawSize > 0 && st.st_blocks == 0 ? 0 : rawSize, false)
        }
        if CleanWhitelistMatcher.isICloudPlaceholder(url: itemURL) {
            return (0, true)
        }
        return (Int64(values?.fileAllocatedSize ?? values?.fileSize ?? 0), false)
    }

    private nonisolated static func scanRootConcurrently(
        rootPath: String,
        rootDisplayName: String,
        isEntireDiskRoot: Bool,
        policy: VolumeBoundaryPolicy,
        now: Date,
        hasFullDiskAccess: Bool,
        hardlinkTracker: HardlinkTracker,
        ownerResolver: OwnerAppResolverCache,
        progressTracker: SharedScanProgressTracker,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Int, Int64, String) -> Void
    ) async -> (AnalysisNode?, ScanAccumulator) {
        var rootAcc = ScanAccumulator()
        if isCancelled() || Task.isCancelled { return (nil, rootAcc) }

        var rootSt = Darwin.stat()
        guard stat(rootPath, &rootSt) == 0 else { return (nil, rootAcc) }
        let rootIsDir = (rootSt.st_mode & S_IFMT) == S_IFDIR
        let rootMod = dateFromTimespec(rootSt.st_mtimespec)
        let rootAccess = dateFromTimespec(rootSt.st_atimespec)
        let rootName = (rootPath as NSString).lastPathComponent

        let node = AnalysisNode(
            filePath: rootPath,
            name: rootDisplayName,
            isDirectory: rootIsDir,
            isPackage: false,
            isHiddenFolder: false,
            ownerAppName: ownerResolver.resolveOwnerName(forPath: rootPath, name: rootName),
            modificationDate: rootMod,
            lastAccessDate: rootAccess
        )

        var children: [AnalysisNode] = []
        var totalDirSize: Int64 = 0
        var subDirTargets: [(path: String, name: String, displayOverride: String?)] = []
        var readFailed = false

        autoreleasepool {
            let fileManager = FileManager.default
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: rootPath)
                let homePath = NSHomeDirectory()
                let isHomeRoot = (rootPath == homePath)
                let isSlashRoot = (isEntireDiskRoot && rootPath == "/")

                for name in contents {
                    if isCancelled() || Task.isCancelled { return }
                    if ignoredSystemHiddenNames.contains(name) { continue }
                    if isSlashRoot && entireDiskRootSkips.contains(name) { continue }

                    let childPath = (rootPath == "/") ? "/\(name)" : "\(rootPath)/\(name)"

                    if policy.forbidExternalVolumesPrefix && !hasFullDiskAccess {
                        let isProtectedByName = tccProtectedDirectoryNames.contains(name)
                            || (isHomeRoot && (name == "Desktop" || name == "Documents" || name == "Downloads"))
                        if isProtectedByName {
                            let protectedNode = AnalysisNode(
                                filePath: childPath,
                                name: name,
                                sizeBytes: 0,
                                isDirectory: true,
                                isPackage: false,
                                isHiddenFolder: name.hasPrefix("."),
                                isProtectedOrUnreadable: true,
                                parent: node
                            )
                            children.append(protectedNode)
                            rootAcc.protectedUnreadableCount += 1
                            continue
                        }
                    }

                    var st = Darwin.stat()
                    guard Darwin.lstat(childPath, &st) == 0 else { continue }
                    let fileType = st.st_mode & S_IFMT
                    if fileType == S_IFLNK { continue }
                    if !policy.allows(path: childPath, dev: Int32(st.st_dev)) { continue }

                    let modDate = dateFromTimespec(st.st_mtimespec)
                    let accessDate = dateFromTimespec(st.st_atimespec)

                    if fileType == S_IFDIR {
                        if isDirectoryPackage(path: childPath, name: name) {
                            let packageScan = calculatePackageSize(
                                path: childPath,
                                policy: policy,
                                timeBudgetSeconds: 0.25,
                                hardlinkTracker: hardlinkTracker,
                                isCancelled: isCancelled
                            )
                            let childNode = AnalysisNode(
                                filePath: childPath,
                                name: name,
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
                                rootAcc.pendingSizingNodes.append(childNode)
                            }
                            children.append(childNode)
                            totalDirSize += packageScan.bytes
                            rootAcc.recordFile(filePath: childPath, name: name, size: packageScan.bytes, isPackage: true, modDate: modDate, accessDate: accessDate, now: now)
                            progressTracker.advance(bytesDelta: packageScan.bytes, path: childPath, onProgress: onProgress)
                        } else {
                            subDirTargets.append((childPath, name, nil))
                        }
                    } else if fileType == S_IFREG {
                        let sized = allocatedSizeFromStat(st, name: name, policy: policy, hardlinkTracker: hardlinkTracker)
                        let childNode = AnalysisNode(
                            filePath: childPath,
                            name: name,
                            sizeBytes: sized.bytes,
                            isDirectory: false,
                            isPackage: false,
                            isHiddenFolder: false,
                            isCloudPlaceholder: sized.isCloudPlaceholder,
                            modificationDate: modDate,
                            lastAccessDate: accessDate,
                            childCount: 0,
                            parent: node
                        )
                        children.append(childNode)
                        totalDirSize += sized.bytes
                        rootAcc.recordFile(filePath: childPath, name: name, size: sized.bytes, isPackage: false, modDate: modDate, accessDate: accessDate, now: now)
                        progressTracker.advance(bytesDelta: sized.bytes, path: childPath, onProgress: onProgress)
                    }
                }

                if isSlashRoot && !isCancelled() && !Task.isCancelled {
                    var tmpSt = Darwin.stat()
                    let tmpPath = "/private/tmp"
                    if Darwin.lstat(tmpPath, &tmpSt) == 0,
                       (tmpSt.st_mode & S_IFMT) == S_IFDIR,
                       policy.allows(path: tmpPath, dev: Int32(tmpSt.st_dev)) {
                        subDirTargets.append((tmpPath, "tmp", "临时文件夹 (tmp)"))
                    }
                }
            } catch {
                readFailed = true
            }
        }

        if isCancelled() || Task.isCancelled { return (nil, rootAcc) }
        if readFailed {
            node.isProtectedOrUnreadable = true
            rootAcc.protectedUnreadableCount += 1
            return (node, rootAcc)
        }

        var workerResults: [(AnalysisNode, ScanAccumulator)] = []
        await withTaskGroup(of: (AnalysisNode?, ScanAccumulator).self) { group in
            var nextIdx = 0
            let initialBatch = min(6, subDirTargets.count)
            while nextIdx < initialBatch {
                let target = subDirTargets[nextIdx]
                nextIdx += 1
                group.addTask {
                    var workerAcc = ScanAccumulator()
                    let subNode = scanDirectory(
                        dirPath: target.path,
                        rootPath: rootPath,
                        rootDisplayName: rootDisplayName,
                        isEntireDiskRoot: false,
                        depth: 1,
                        displayNameOverride: target.displayOverride,
                        policy: policy,
                        now: now,
                        acc: &workerAcc,
                        hasFullDiskAccess: hasFullDiskAccess,
                        hardlinkTracker: hardlinkTracker,
                        ownerResolver: ownerResolver,
                        progressTracker: progressTracker,
                        isCancelled: isCancelled,
                        onProgress: onProgress
                    )
                    return (subNode, workerAcc)
                }
            }

            for await (subNode, workerAcc) in group {
                if let subNode {
                    workerResults.append((subNode, workerAcc))
                }
                if nextIdx < subDirTargets.count && !isCancelled() && !Task.isCancelled {
                    let target = subDirTargets[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        var workerAcc = ScanAccumulator()
                        let nextNode = scanDirectory(
                            dirPath: target.path,
                            rootPath: rootPath,
                            rootDisplayName: rootDisplayName,
                            isEntireDiskRoot: false,
                            depth: 1,
                            displayNameOverride: target.displayOverride,
                            policy: policy,
                            now: now,
                            acc: &workerAcc,
                            hasFullDiskAccess: hasFullDiskAccess,
                            hardlinkTracker: hardlinkTracker,
                            ownerResolver: ownerResolver,
                            progressTracker: progressTracker,
                            isCancelled: isCancelled,
                            onProgress: onProgress
                        )
                        return (nextNode, workerAcc)
                    }
                }
            }
        }

        for (subNode, workerAcc) in workerResults {
            subNode.parent = node
            children.append(subNode)
            totalDirSize += subNode.sizeBytes
            rootAcc.merge(workerAcc)
        }

        children.sort { $0.sizeBytes > $1.sizeBytes }
        node.children = children
        node.sizeBytes = totalDirSize
        node.childCount = children.count
        return (node, rootAcc)
    }

    private nonisolated static func scanDirectory(
        dirPath: String,
        rootPath: String,
        rootDisplayName: String,
        isEntireDiskRoot: Bool,
        depth: Int = 0,
        displayNameOverride: String? = nil,
        policy: VolumeBoundaryPolicy,
        now: Date,
        acc: inout ScanAccumulator,
        hasFullDiskAccess: Bool,
        hardlinkTracker: HardlinkTracker = HardlinkTracker(),
        ownerResolver: OwnerAppResolverCache = OwnerAppResolverCache(),
        progressTracker: SharedScanProgressTracker? = nil,
        isCancelled: () -> Bool,
        onProgress: @Sendable (Int, Int64, String) -> Void
    ) -> AnalysisNode? {
        if isCancelled() || Task.isCancelled { return nil }

        var dirSt = Darwin.stat()
        guard Darwin.lstat(dirPath, &dirSt) == 0 else { return nil }
        let dirType = dirSt.st_mode & S_IFMT
        if dirType == S_IFLNK || dirType != S_IFDIR { return nil }
        if !policy.allows(path: dirPath, dev: Int32(dirSt.st_dev)) { return nil }

        let lastComponent = (dirPath as NSString).lastPathComponent
        let nodeName: String
        if let displayNameOverride, !displayNameOverride.isEmpty {
            nodeName = displayNameOverride
        } else if dirPath == rootPath {
            nodeName = rootDisplayName
        } else {
            nodeName = lastComponent.isEmpty ? dirPath : lastComponent
        }

        let node = AnalysisNode(
            filePath: dirPath,
            name: nodeName,
            isDirectory: true,
            isPackage: false,
            isHiddenFolder: dirPath != rootPath && lastComponent.hasPrefix("."),
            ownerAppName: ownerResolver.resolveOwnerName(forPath: dirPath, name: lastComponent),
            modificationDate: dateFromTimespec(dirSt.st_mtimespec),
            lastAccessDate: dateFromTimespec(dirSt.st_atimespec)
        )

        var children: [AnalysisNode] = []
        var totalDirSize: Int64 = 0
        var subDirTargets: [(path: String, name: String)] = []
        var readFailed = false

        autoreleasepool {
            let fileManager = FileManager.default
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: dirPath)
                let homePath = NSHomeDirectory()
                let isHomeRoot = (dirPath == homePath)
                let isSlashRoot = (isEntireDiskRoot && dirPath == "/")

                for name in contents {
                    if isCancelled() || Task.isCancelled { return }
                    if ignoredSystemHiddenNames.contains(name) { continue }
                    if isSlashRoot && entireDiskRootSkips.contains(name) { continue }

                    let childPath = (dirPath == "/") ? "/\(name)" : "\(dirPath)/\(name)"

                    if policy.forbidExternalVolumesPrefix && !hasFullDiskAccess {
                        let isProtectedByName = tccProtectedDirectoryNames.contains(name)
                            || (isHomeRoot && (name == "Desktop" || name == "Documents" || name == "Downloads"))
                        if isProtectedByName {
                            let protectedNode = AnalysisNode(
                                filePath: childPath,
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

                    var st = Darwin.stat()
                    guard Darwin.lstat(childPath, &st) == 0 else { continue }
                    let fileType = st.st_mode & S_IFMT
                    if fileType == S_IFLNK { continue }
                    if !policy.allows(path: childPath, dev: Int32(st.st_dev)) { continue }

                    let modDate = dateFromTimespec(st.st_mtimespec)
                    let accessDate = dateFromTimespec(st.st_atimespec)

                    if fileType == S_IFDIR {
                        if isDirectoryPackage(path: childPath, name: name) {
                            let packageScan = calculatePackageSize(
                                path: childPath,
                                policy: policy,
                                timeBudgetSeconds: 0.25,
                                hardlinkTracker: hardlinkTracker,
                                isCancelled: isCancelled
                            )
                            let childNode = AnalysisNode(
                                filePath: childPath,
                                name: name,
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
                            acc.recordFile(filePath: childPath, name: name, size: packageScan.bytes, isPackage: true, modDate: modDate, accessDate: accessDate, now: now)
                            progressTracker?.advance(bytesDelta: packageScan.bytes, path: childPath, onProgress: onProgress)
                        } else {
                            subDirTargets.append((childPath, name))
                        }
                    } else if fileType == S_IFREG {
                        let sized = allocatedSizeFromStat(st, name: name, policy: policy, hardlinkTracker: hardlinkTracker)
                        let childNode = AnalysisNode(
                            filePath: childPath,
                            name: name,
                            sizeBytes: sized.bytes,
                            isDirectory: false,
                            isPackage: false,
                            isHiddenFolder: false,
                            isCloudPlaceholder: sized.isCloudPlaceholder,
                            modificationDate: modDate,
                            lastAccessDate: accessDate,
                            childCount: 0,
                            parent: node
                        )
                        children.append(childNode)
                        totalDirSize += sized.bytes
                        acc.recordFile(filePath: childPath, name: name, size: sized.bytes, isPackage: false, modDate: modDate, accessDate: accessDate, now: now)
                        progressTracker?.advance(bytesDelta: sized.bytes, path: childPath, onProgress: onProgress)
                    }

                    if progressTracker == nil {
                        let curNow = Date()
                        if curNow.timeIntervalSince(acc.lastProgressUpdate) > 0.12 {
                            acc.lastProgressUpdate = curNow
                            onProgress(acc.fileCount, acc.byteCount, childPath)
                        }
                    }
                }
            } catch {
                readFailed = true
            }
        }

        if isCancelled() || Task.isCancelled { return nil }
        if readFailed {
            node.isProtectedOrUnreadable = true
            acc.protectedUnreadableCount += 1
            return node
        }

        for sub in subDirTargets {
            if isCancelled() || Task.isCancelled { return nil }
            if let subDirNode = scanDirectory(
                dirPath: sub.path,
                rootPath: rootPath,
                rootDisplayName: rootDisplayName,
                isEntireDiskRoot: false,
                depth: depth + 1,
                policy: policy,
                now: now,
                acc: &acc,
                hasFullDiskAccess: hasFullDiskAccess,
                hardlinkTracker: hardlinkTracker,
                ownerResolver: ownerResolver,
                progressTracker: progressTracker,
                isCancelled: isCancelled,
                onProgress: onProgress
            ) {
                subDirNode.parent = node
                children.append(subDirNode)
                totalDirSize += subDirNode.sizeBytes
            }
        }

        // 全盘扫描时显式纳入 /private/tmp（/tmp 为符号链接且整盘默认跳过 /private，单独扫描便于发现临时大文件）
        if isEntireDiskRoot && dirPath == "/" && !isCancelled() && !Task.isCancelled {
            let tmpPath = "/private/tmp"
            var tmpSt = Darwin.stat()
            if Darwin.lstat(tmpPath, &tmpSt) == 0,
               (tmpSt.st_mode & S_IFMT) == S_IFDIR,
               policy.allows(path: tmpPath, dev: Int32(tmpSt.st_dev)),
               let tmpNode = scanDirectory(
                   dirPath: tmpPath,
                   rootPath: rootPath,
                   rootDisplayName: rootDisplayName,
                   isEntireDiskRoot: false,
                   depth: depth + 1,
                   displayNameOverride: "临时文件夹 (tmp)",
                   policy: policy,
                   now: now,
                   acc: &acc,
                   hasFullDiskAccess: hasFullDiskAccess,
                   hardlinkTracker: hardlinkTracker,
                   ownerResolver: ownerResolver,
                   progressTracker: progressTracker,
                   isCancelled: isCancelled,
                   onProgress: onProgress
               ) {
                tmpNode.parent = node
                children.append(tmpNode)
                totalDirSize += tmpNode.sizeBytes
            }
        }

        let actualCount = children.count
        children.sort { $0.sizeBytes > $1.sizeBytes }
        // 深层大目录在保证总量与统计 100% 精确的前提下裁剪海量零碎小叶节点；进入目录时按需即时补齐
        if depth >= 2 && actualCount > 60 {
            var kept: [AnalysisNode] = []
            kept.reserveCapacity(min(actualCount, 80))
            for (idx, child) in children.enumerated() {
                if idx < 60
                    || child.isProtectedOrUnreadable
                    || child.sizeBytes >= 1_048_576
                    || (child.isDirectory && child.sizeBytes >= 262_144) {
                    kept.append(child)
                }
            }
            if kept.count < actualCount {
                node.children = kept
                node.hasPrunedChildren = true
            } else {
                node.children = children
            }
        } else {
            node.children = children
        }
        node.sizeBytes = totalDirSize
        node.childCount = actualCount

        return node
    }

    private nonisolated static func calculatePackageSize(
        path: String,
        policy: VolumeBoundaryPolicy,
        timeBudgetSeconds: TimeInterval? = nil,
        hardlinkTracker: HardlinkTracker = HardlinkTracker(),
        isCancelled: () -> Bool
    ) -> (bytes: Int64, didTruncate: Bool) {
        let deadline = timeBudgetSeconds.map { CFAbsoluteTimeGetCurrent() + $0 }
        let fileManager = FileManager.default
        var stack: [String] = [path]
        var total: Int64 = 0
        var seen = 0

        while let currentDir = stack.popLast() {
            if isCancelled() || Task.isCancelled { return (total, true) }
            if let deadline, CFAbsoluteTimeGetCurrent() >= deadline {
                return (total, true)
            }

            var truncated = false
            autoreleasepool {
                guard let names = try? fileManager.contentsOfDirectory(atPath: currentDir) else { return }
                for name in names {
                    seen += 1
                    if seen & 255 == 0 {
                        if isCancelled() || Task.isCancelled {
                            truncated = true
                            return
                        }
                        if let deadline, CFAbsoluteTimeGetCurrent() >= deadline {
                            truncated = true
                            return
                        }
                    }

                    let itemPath = (currentDir == "/") ? "/\(name)" : "\(currentDir)/\(name)"
                    var st = Darwin.stat()
                    guard Darwin.lstat(itemPath, &st) == 0 else { continue }
                    let fileType = st.st_mode & S_IFMT
                    // 关键防护：软件包（如 .fcpbundle 媒体库）内部常见指向外置盘或 NAS 的符号链接，必须严格忽略
                    if fileType == S_IFLNK { continue }
                    if !policy.allows(path: itemPath, dev: Int32(st.st_dev)) { continue }

                    if fileType == S_IFDIR {
                        stack.append(itemPath)
                    } else if fileType == S_IFREG {
                        total += allocatedSizeFromStat(
                            st,
                            name: name,
                            policy: policy,
                            hardlinkTracker: hardlinkTracker
                        ).bytes
                    }
                }
            }
            if truncated {
                return (total, true)
            }
        }
        return (total, false)
    }

    private nonisolated static func scanMissingDirectChildren(
        dirPath: String,
        existingNames: Set<String>,
        isEntireDiskRoot: Bool,
        policy: VolumeBoundaryPolicy,
        hasFullDiskAccess: Bool
    ) -> [AnalysisNode] {
        var added: [AnalysisNode] = []
        let fileManager = FileManager.default
        let hardlinkTracker = HardlinkTracker()
        let ownerResolver = OwnerAppResolverCache()
        let now = Date()

        autoreleasepool {
            guard let names = try? fileManager.contentsOfDirectory(atPath: dirPath) else { return }
            let homePath = NSHomeDirectory()
            let isHomeRoot = (dirPath == homePath)
            let isSlashRoot = (isEntireDiskRoot && dirPath == "/")

            for name in names {
                if existingNames.contains(name) { continue }
                if ignoredSystemHiddenNames.contains(name) { continue }
                if isSlashRoot && entireDiskRootSkips.contains(name) { continue }

                let childPath = (dirPath == "/") ? "/\(name)" : "\(dirPath)/\(name)"
                if policy.forbidExternalVolumesPrefix && !hasFullDiskAccess {
                    let isProtectedByName = tccProtectedDirectoryNames.contains(name)
                        || (isHomeRoot && (name == "Desktop" || name == "Documents" || name == "Downloads"))
                    if isProtectedByName {
                        added.append(
                            AnalysisNode(
                                filePath: childPath,
                                name: name,
                                sizeBytes: 0,
                                isDirectory: true,
                                isPackage: false,
                                isHiddenFolder: name.hasPrefix("."),
                                isProtectedOrUnreadable: true
                            )
                        )
                        continue
                    }
                }

                var st = Darwin.stat()
                guard Darwin.lstat(childPath, &st) == 0 else { continue }
                let fileType = st.st_mode & S_IFMT
                if fileType == S_IFLNK { continue }
                if !policy.allows(path: childPath, dev: Int32(st.st_dev)) { continue }

                let modDate = dateFromTimespec(st.st_mtimespec)
                let accessDate = dateFromTimespec(st.st_atimespec)

                if fileType == S_IFDIR {
                    if isDirectoryPackage(path: childPath, name: name) {
                        let pkg = calculatePackageSize(
                            path: childPath,
                            policy: policy,
                            timeBudgetSeconds: 0.25,
                            hardlinkTracker: hardlinkTracker,
                            isCancelled: { false }
                        )
                        added.append(
                            AnalysisNode(
                                filePath: childPath,
                                name: name,
                                sizeBytes: pkg.bytes,
                                isDirectory: false,
                                isPackage: true,
                                isHiddenFolder: false,
                                isSizingPending: pkg.didTruncate,
                                modificationDate: modDate,
                                lastAccessDate: accessDate,
                                childCount: 1
                            )
                        )
                    } else {
                        var subAcc = ScanAccumulator()
                        if let subNode = scanDirectory(
                            dirPath: childPath,
                            rootPath: dirPath,
                            rootDisplayName: name,
                            isEntireDiskRoot: false,
                            depth: 2,
                            policy: policy,
                            now: now,
                            acc: &subAcc,
                            hasFullDiskAccess: hasFullDiskAccess,
                            hardlinkTracker: hardlinkTracker,
                            ownerResolver: ownerResolver,
                            isCancelled: { false },
                            onProgress: { _, _, _ in }
                        ) {
                            added.append(subNode)
                        }
                    }
                } else if fileType == S_IFREG {
                    let sized = allocatedSizeFromStat(st, name: name, policy: policy, hardlinkTracker: hardlinkTracker)
                    added.append(
                        AnalysisNode(
                            filePath: childPath,
                            name: name,
                            sizeBytes: sized.bytes,
                            isDirectory: false,
                            isPackage: false,
                            isHiddenFolder: false,
                            isCloudPlaceholder: sized.isCloudPlaceholder,
                            modificationDate: modDate,
                            lastAccessDate: accessDate,
                            childCount: 0
                        )
                    )
                }
            }
        }

        return added
    }

    // MARK: - 目录层级导航

    private func hydratePrunedDirectoryIfNeeded(_ targetNode: AnalysisNode) {
        let needsHydration = targetNode.hasPrunedChildren
            || (targetNode.isDirectory && !targetNode.isProtectedOrUnreadable && targetNode.children.isEmpty && targetNode.childCount > 0)
        guard needsHydration, !isScanning, !hydratingNodeIDs.contains(targetNode.id) else { return }
        hydratingNodeIDs.insert(targetNode.id)

        let dirPath = targetNode.path
        let existingNames = Set(targetNode.children.map(\.name))
        let location = selectedLocation
        let policy = activeVolumePolicy ?? VolumeBoundaryPolicy.forLocation(location, targetPath: location.url.path)
        let isEntireDiskRoot = (dirPath == "/" && location == .entireDisk)
        let hasFullDiskAccess = SystemPermissionManager.shared.fullDiskAccessStatus == .authorized

        Task.detached(priority: .userInitiated) { [weak self, dirPath, existingNames, isEntireDiskRoot, policy, hasFullDiskAccess] in
            let hydrated = Self.scanMissingDirectChildren(
                dirPath: dirPath,
                existingNames: existingNames,
                isEntireDiskRoot: isEntireDiskRoot,
                policy: policy,
                hasFullDiskAccess: hasFullDiskAccess
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hydratingNodeIDs.remove(targetNode.id)
                guard self.rootNode != nil else { return }
                if !hydrated.isEmpty {
                    for child in hydrated {
                        child.parent = targetNode
                    }
                    var merged = targetNode.children
                    merged.append(contentsOf: hydrated)
                    merged.sort { $0.sizeBytes > $1.sizeBytes }
                    targetNode.children = merged
                    targetNode.childCount = merged.count
                }
                targetNode.hasPrunedChildren = false
            }
        }
    }

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
        hydratePrunedDirectoryIfNeeded(node)
    }

    public func navigateUp() {
        guard breadcrumbStack.count > 1 else { return }
        breadcrumbStack.removeLast()
        searchQuery = ""
        isTailExpanded = false
        selectedNodeIDs.removeAll()
        currentNode = breadcrumbStack.last
        if let target = currentNode {
            hydratePrunedDirectoryIfNeeded(target)
        }
    }

    public func navigateToBreadcrumb(at index: Int) {
        guard index >= 0, index < breadcrumbStack.count else { return }
        breadcrumbStack = Array(breadcrumbStack.prefix(index + 1))
        searchQuery = ""
        isTailExpanded = false
        selectedNodeIDs.removeAll()
        currentNode = breadcrumbStack.last
        if let target = currentNode {
            hydratePrunedDirectoryIfNeeded(target)
        }
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
        let targetPath = targetNode.path
        let displayName = targetNode.name
        let location = selectedLocation
        let policy = activeVolumePolicy ?? VolumeBoundaryPolicy.forLocation(location, targetPath: location.url.path)
        let hasFullDiskAccess = SystemPermissionManager.shared.fullDiskAccessStatus == .authorized
        lastActionMessage = "正在刷新 \(displayName)…"

        Task.detached(priority: .userInitiated) { [weak self, targetPath, displayName, policy, hasFullDiskAccess] in
            var acc = ScanAccumulator()
            let now = Date()
            let refreshed = Self.scanDirectory(
                dirPath: targetPath,
                rootPath: targetPath,
                rootDisplayName: displayName,
                isEntireDiskRoot: (targetPath == "/"),
                depth: 0,
                policy: policy,
                now: now,
                acc: &acc,
                hasFullDiskAccess: hasFullDiskAccess,
                isCancelled: { false },
                onProgress: { _, _, _ in }
            )

            await MainActor.run { [weak self] in
                guard let self, let refreshed else { return }
                let previousBytes = targetNode.sizeBytes
                let delta = refreshed.sizeBytes - previousBytes
                for oldChild in targetNode.children {
                    oldChild.detachPreservingPath()
                }
                for child in refreshed.children {
                    child.parent = targetNode
                }
                targetNode.children = refreshed.children
                targetNode.sizeBytes = refreshed.sizeBytes
                targetNode.childCount = refreshed.childCount
                targetNode.hasPrunedChildren = refreshed.hasPrunedChildren

                // 用差值沿父链向上传播，确保深层被裁剪的祖先目录总容量也保持 100% 精确
                var walker = targetNode.parent
                while let p = walker {
                    p.sizeBytes = max(0, p.sizeBytes + delta)
                    p.children.sort { $0.sizeBytes > $1.sizeBytes }
                    walker = p.parent
                }
                self.totalScannedBytes = self.rootNode?.sizeBytes ?? self.totalScannedBytes

                let prefix = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
                self.topLargeFiles.removeAll { $0.path == targetPath || $0.path.hasPrefix(prefix) }
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
            let url = node.url
            if guardBlockMessage(for: url) != nil {
                blockedCount += 1
            } else {
                allowedURLs.append(url)
                allowedNodes.append(node)
            }
        }

        guard !allowedURLs.isEmpty else {
            lastActionMessage = "所选项目均受系统或清理白名单保护，已跳过"
            return
        }

        let immutableURLs = allowedURLs
        let immutableRemovedIDs = Set(allowedNodes.map(\.id))
        let immutableRemovedPaths = Set(allowedURLs.map(\.path))
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
                for child in current.children where immutableRemovedIDs.contains(child.id) {
                    child.detachPreservingPath()
                }
                current.children.removeAll { immutableRemovedIDs.contains($0.id) }
                current.sizeBytes = max(0, current.sizeBytes - immutableFreedTotal)
                current.childCount = max(current.children.count, current.childCount - immutableAllowedCount)
                var walker = current.parent
                while let p = walker {
                    p.sizeBytes = max(0, p.sizeBytes - immutableFreedTotal)
                    walker = p.parent
                }
                self.topLargeFiles.removeAll { immutableRemovedPaths.contains($0.path) }
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
        let targetURL = node.url
        let targetPath = targetURL.path
        if let blockMsg = guardBlockMessage(for: targetURL) {
            lastActionMessage = blockMsg
            return
        }
        NSWorkspace.shared.recycle([targetURL]) { [weak self] _, error in
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
                        node.detachPreservingPath()
                        parent.sizeBytes = max(0, parent.sizeBytes - freedSize)
                        parent.childCount = max(parent.children.count, parent.childCount - 1)
                        var walker = parent.parent
                        while let p = walker {
                            p.sizeBytes = max(0, p.sizeBytes - freedSize)
                            walker = p.parent
                        }
                    }
                    self.topLargeFiles.removeAll { $0.path == targetPath }
                    self.totalScannedBytes = max(0, self.totalScannedBytes - freedSize)
                }
            }
        }
    }

    public func moveToTrash(largeFile: AnalysisLargeFileItem) {
        let targetURL = largeFile.url
        let targetPath = targetURL.path
        if let blockMsg = guardBlockMessage(for: targetURL) {
            lastActionMessage = blockMsg
            return
        }
        NSWorkspace.shared.recycle([targetURL]) { [weak self] _, error in
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
                        self.removeNodeFromTree(root: root, targetPath: targetPath, freedSize: freedSize)
                    }
                }
            }
        }
    }

    private nonisolated static func collectEnvironmentAdvisories(policy: VolumeBoundaryPolicy) -> [AnalysisToolAdvisory] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        func quickDirSize(_ url: URL) -> Int64 {
            var st = Darwin.stat()
            guard Darwin.lstat(url.path, &st) == 0 else { return 0 }
            guard (st.st_mode & S_IFMT) == S_IFDIR, policy.allows(path: url.path, dev: Int32(st.st_dev)) else {
                return 0
            }
            return calculatePackageSize(
                path: url.path,
                policy: policy,
                timeBudgetSeconds: 0.4,
                hardlinkTracker: HardlinkTracker(),
                isCancelled: { false }
            ).bytes
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

    private func removeNodeFromTree(root: AnalysisNode, targetPath: String, freedSize: Int64) {
        if let idx = root.children.firstIndex(where: { $0.path == targetPath }) {
            let removed = root.children.remove(at: idx)
            removed.detachPreservingPath()
            root.sizeBytes = max(0, root.sizeBytes - freedSize)
            root.childCount = max(root.children.count, root.childCount - 1)
            return
        }
        for child in root.children where child.isDirectory {
            removeNodeFromTree(root: child, targetPath: targetPath, freedSize: freedSize)
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
                iconName: "icloud.and.arrow.down.fill"
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

    public func refreshHiddenInsights(for location: AnalysisLocation = .home) {
        let targetURL = location.url
        let isInternal = location.isBuiltInInternalLocation
        // Query system purgeable space (CacheDelete) and APFS snapshots off the MainActor
        Task.detached(priority: .utility) { [weak self, targetURL, isInternal] in
            var purgeableStr: String? = isInternal ? nil : "0 B"
            var liveTotal: Int64 = 0
            var liveNormalAvail: Int64 = 0
            var liveImportantAvail: Int64 = 0
            var livePurgeable: Int64 = 0
            var liveUsed: Int64 = 0
            let volQueryURL = FileManager.default.fileExists(atPath: targetURL.path) ? targetURL : URL(fileURLWithPath: "/")
            if let values = try? volQueryURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
                liveTotal = Int64(values.volumeTotalCapacity ?? 0)
                liveNormalAvail = Int64(values.volumeAvailableCapacity ?? 0)
                liveImportantAvail = values.volumeAvailableCapacityForImportantUsage ?? Int64(liveNormalAvail)
                livePurgeable = max(0, liveImportantAvail - liveNormalAvail)
                liveUsed = max(0, liveTotal - liveImportantAvail)
                if livePurgeable > 0 {
                    purgeableStr = ByteCountFormatter.string(fromByteCount: livePurgeable, countStyle: .file)
                }
            }

            var snapshotText: String? = isInternal ? nil : "外置/网络卷不适用"
            if isInternal {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
                process.arguments = ["listlocalsnapshots", "/"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

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
            }

            let finalPurgeable = purgeableStr
            let finalSnapshot = snapshotText
            let finalTotal = liveTotal
            let finalNormalAvail = liveNormalAvail
            let finalImportantAvail = liveImportantAvail
            let finalPurgeableBytes = livePurgeable
            let finalUsed = liveUsed
            let expectedStdPath = targetURL.standardizedFileURL.path
            await MainActor.run { [weak self] in
                guard let self else { return }
                if finalTotal > 0 && self.selectedLocation.url.standardizedFileURL.path == expectedStdPath {
                    let prevDelta = self.diskTelemetry.scanDeltaBytes
                    let prevDate = self.diskTelemetry.previousScanDate
                    self.diskTelemetry = AnalysisDiskTelemetry(
                        volumeTotalBytes: finalTotal,
                        volumeAvailableBytes: finalNormalAvail,
                        volumeImportantAvailableBytes: finalImportantAvail,
                        volumePurgeableBytes: finalPurgeableBytes,
                        volumeUsedBytes: finalUsed,
                        scanDeltaBytes: prevDelta,
                        previousScanDate: prevDate
                    )
                }
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

    /// 自检卷宗隔离边界与软件包内符号链接跳过逻辑，确保个人主目录/本机位置绝不误扫外置盘与 NAS
    public nonisolated static func runVolumeIsolationSelfTest() -> Bool {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sp_vol_isolation_\(UUID().uuidString)", isDirectory: true)
        let mockHome = base.appendingPathComponent("Home", isDirectory: true)
        let mockExternal = base.appendingPathComponent("ExternalNAS", isDirectory: true)
        let mockPkg = mockHome.appendingPathComponent("Library.fcpbundle", isDirectory: true)

        do {
            try fm.createDirectory(at: mockHome, withIntermediateDirectories: true)
            try fm.createDirectory(at: mockExternal, withIntermediateDirectories: true)
            try fm.createDirectory(at: mockPkg, withIntermediateDirectories: true)

            let localData = Data(repeating: 0xCD, count: 32 * 1024)
            try localData.write(to: mockHome.appendingPathComponent("real.bin"))

            let pkgData = Data(repeating: 0xEF, count: 16 * 1024)
            try pkgData.write(to: mockPkg.appendingPathComponent("Info.plist"))

            let externalData = Data(repeating: 0xAB, count: 512 * 1024)
            try externalData.write(to: mockExternal.appendingPathComponent("movie.mov"))

            try fm.createSymbolicLink(
                at: mockPkg.appendingPathComponent("Original Media"),
                withDestinationURL: mockExternal
            )
            try fm.createSymbolicLink(
                at: mockHome.appendingPathComponent("NASMount"),
                withDestinationURL: mockExternal
            )
        } catch {
            try? fm.removeItem(at: base)
            return false
        }
        defer { try? fm.removeItem(at: base) }

        var homeSt = Darwin.stat()
        guard stat(mockHome.path, &homeSt) == 0 else { return false }
        let homeDev = Int32(homeSt.st_dev)

        let policy = VolumeBoundaryPolicy(
            allowedDeviceIDs: [homeDev],
            forbidExternalVolumesPrefix: true,
            isNetworkVolume: false
        )

        var acc = ScanAccumulator()
        let root = scanDirectory(
            dirPath: mockHome.path,
            rootPath: mockHome.path,
            rootDisplayName: "HomeTest",
            isEntireDiskRoot: false,
            depth: 0,
            policy: policy,
            now: Date(),
            acc: &acc,
            hasFullDiskAccess: true,
            isCancelled: { false },
            onProgress: { _, _, _ in }
        )

        guard let root else { return false }
        guard acc.fileCount == 2 else { return false }
        guard root.sizeBytes > 0 && root.sizeBytes < 200_000 else { return false }
        guard !root.children.contains(where: { $0.name == "NASMount" }) else { return false }
        guard !policy.allows(path: "/Volumes/巨无霸/test.mov", dev: homeDev) else { return false }
        guard !policy.allows(path: "/System/Volumes/Data/Volumes/NAS/a.mov", dev: homeDev) else { return false }
        guard !policy.allows(path: "/Users/test/file.dat", dev: homeDev &+ 99) else { return false }

        let extPolicy = VolumeBoundaryPolicy(
            allowedDeviceIDs: [homeDev],
            forbidExternalVolumesPrefix: false,
            isNetworkVolume: true
        )
        guard extPolicy.allows(path: "/Volumes/NAS/a.mov", dev: homeDev) else { return false }
        guard !extPolicy.allows(path: "/Volumes/Other/b.mov", dev: homeDev &+ 1) else { return false }
        return true
    }
}
