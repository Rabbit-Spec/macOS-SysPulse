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
    public var activeViewMode: AnalysisViewMode = .browser
    public var totalScannedFiles: Int = 0
    public var totalScannedBytes: Int64 = 0
    public var scanDuration: TimeInterval = 0
    public var searchQuery: String = ""
    public var lastActionMessage: String? = nil
    public var showingFDAGuidance: Bool = false

    // Internal concurrency control
    private var scanTask: Task<Void, Never>? = nil
    private nonisolated let cancellationBox = ScanCancellationBox()

    private nonisolated func setCancelled(_ cancelled: Bool) {
        cancellationBox.set(cancelled)
    }

    private nonisolated var isScanCancelled: Bool {
        cancellationBox.isCancelled
    }

    private init() {
        populateDefaultInsights()
    }

    // MARK: - Formatted Properties

    public var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalScannedBytes, countStyle: .file)
    }

    public var currentFolderChildren: [AnalysisNode] {
        guard let current = currentNode else { return [] }
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return current.children
        }
        let q = searchQuery.lowercased()
        return current.children.filter { $0.name.lowercased().contains(q) }
    }

    public var filteredLargeFiles: [AnalysisLargeFileItem] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return topLargeFiles
        }
        let q = searchQuery.lowercased()
        return topLargeFiles.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    // MARK: - Scan Actions

    public func startScan(location: AnalysisLocation? = nil) {
        if let location {
            self.selectedLocation = location
        }

        cancelScan()

        let targetURL = selectedLocation.url
        isScanning = true
        status = .scanning(scannedFiles: 0, scannedBytes: 0, currentPath: targetURL.path)
        rootNode = nil
        currentNode = nil
        breadcrumbStack = []
        topLargeFiles = []
        totalScannedFiles = 0
        totalScannedBytes = 0
        setCancelled(false)

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

        scanTask = Task.detached(priority: .userInitiated) { [weak self, cancellationBox, targetURL, rootDisplayName, hasFullDiskAccess, startTime, progressCallback] in
            var fileCount = 0
            var byteCount: Int64 = 0
            var largeFilesList: [AnalysisLargeFileItem] = []
            var lastUpdate = Date()

            // Build hierarchical tree off the MainActor
            let root = Self.scanDirectory(
                url: targetURL,
                rootPath: targetURL.path,
                rootDisplayName: rootDisplayName,
                fileCount: &fileCount,
                byteCount: &byteCount,
                largeFilesList: &largeFilesList,
                lastUpdate: &lastUpdate,
                hasFullDiskAccess: hasFullDiskAccess,
                isCancelled: { cancellationBox.isCancelled },
                onProgress: progressCallback
            )

            let duration = Date().timeIntervalSince(startTime)

            // Sort top large files descending and cap at 100
            largeFilesList.sort { $0.sizeBytes > $1.sizeBytes }
            let cappedLargeFiles = Array(largeFilesList.prefix(100))

            await MainActor.run {
                guard let self else { return }
                if self.isScanCancelled {
                    self.status = .cancelled
                    self.isScanning = false
                    return
                }

                self.rootNode = root
                self.currentNode = root
                if let root {
                    self.breadcrumbStack = [root]
                }
                self.topLargeFiles = cappedLargeFiles
                self.totalScannedFiles = fileCount
                self.totalScannedBytes = root?.sizeBytes ?? byteCount
                self.scanDuration = duration
                self.status = .completed(totalFiles: fileCount, totalBytes: self.totalScannedBytes, duration: duration)
                self.isScanning = false

                self.refreshHiddenInsights()
            }
        }
    }

    public func cancelScan() {
        setCancelled(true)
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            isScanning = false
            status = .cancelled
        }
    }

    // MARK: - Recursive Directory Tree Builder

    nonisolated private static let tccProtectedDirectoryNames: Set<String> = [
        "Safari", "Mail", "Messages", "Suggestions", "Calendars", "Reminders",
        "HomeKit", "IdentityServices", "PersonalizationPortrait", "AddressBook",
        "com.apple.TCC", "Photos Library.photoslibrary", "Photos Library"
    ]

    private nonisolated static func scanDirectory(
        url: URL,
        rootPath: String,
        rootDisplayName: String,
        fileCount: inout Int,
        byteCount: inout Int64,
        largeFilesList: inout [AnalysisLargeFileItem],
        lastUpdate: inout Date,
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
            .isSymbolicLinkKey
        ]

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

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
            isPackage: false
        )

        // Read direct directory contents
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            return node
        }

        var children: [AnalysisNode] = []
        var totalDirSize: Int64 = 0

        for itemURL in contents {
            if isCancelled() || Task.isCancelled { return nil }

            // 未开启完全磁盘访问权限时，严格跳过 macOS 隐私保护敏感目录，防止反复向用户弹出一堆系统授权请求
            let name = itemURL.lastPathComponent
            if !hasFullDiskAccess {
                if tccProtectedDirectoryNames.contains(name) {
                    continue
                }
                // 若处于个人主目录且未授权完全磁盘访问，跳过会触发系统单个授权弹窗的桌面/文稿/下载文件夹
                if url.path == NSHomeDirectory() && (name == "Desktop" || name == "Documents" || name == "Downloads") {
                    continue
                }
            }

            guard let values = try? itemURL.resourceValues(forKeys: resourceKeys) else { continue }

            // Skip symbolic links to avoid loops
            if values.isSymbolicLink == true { continue }

            let isPackage = values.isPackage == true
            let isDirectory = (values.isDirectory == true) && !isPackage

            if isPackage {
                // Treat packages (e.g., .app, .framework) as a single composite node
                let packageSize = calculatePackageSize(url: itemURL, isCancelled: isCancelled)
                let childNode = AnalysisNode(
                    url: itemURL,
                    sizeBytes: packageSize,
                    isDirectory: false,
                    isPackage: true,
                    childCount: 1,
                    parent: node
                )
                children.append(childNode)
                totalDirSize += packageSize
                fileCount += 1
                byteCount += packageSize

                if packageSize >= 50 * 1024 * 1024 { // >= 50MB
                    largeFilesList.append(AnalysisLargeFileItem(url: itemURL, sizeBytes: packageSize))
                }
            } else if isDirectory {
                if let subDirNode = scanDirectory(
                    url: itemURL,
                    rootPath: rootPath,
                    rootDisplayName: rootDisplayName,
                    fileCount: &fileCount,
                    byteCount: &byteCount,
                    largeFilesList: &largeFilesList,
                    lastUpdate: &lastUpdate,
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
                    childCount: 0,
                    parent: node
                )
                children.append(childNode)
                totalDirSize += size
                fileCount += 1
                byteCount += size

                if size >= 50 * 1024 * 1024 { // >= 50MB
                    largeFilesList.append(AnalysisLargeFileItem(url: itemURL, sizeBytes: size))
                }
            }

            // Periodic UI throttling update (every 120ms)
            let now = Date()
            if now.timeIntervalSince(lastUpdate) > 0.12 {
                lastUpdate = now
                onProgress(fileCount, byteCount, itemURL.path)
            }
        }

        // Sort children descending by size
        children.sort { $0.sizeBytes > $1.sizeBytes }
        node.children = children
        node.sizeBytes = totalDirSize
        node.childCount = children.count

        return node
    }

    private nonisolated static func calculatePackageSize(url: URL, isCancelled: () -> Bool) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if isCancelled() || Task.isCancelled { return total }
            if let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) {
                total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - 目录层级导航

    public func navigateTo(node: AnalysisNode) {
        guard node.isDirectory else {
            revealInFinder(url: node.url)
            return
        }
        searchQuery = ""
        currentNode = node
        breadcrumbStack.append(node)
    }

    public func navigateUp() {
        guard breadcrumbStack.count > 1 else { return }
        breadcrumbStack.removeLast()
        searchQuery = ""
        currentNode = breadcrumbStack.last
    }

    public func navigateToBreadcrumb(at index: Int) {
        guard index >= 0, index < breadcrumbStack.count else { return }
        breadcrumbStack = Array(breadcrumbStack.prefix(index + 1))
        searchQuery = ""
        currentNode = breadcrumbStack.last
    }

    // MARK: - File Actions

    public func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func moveToTrash(node: AnalysisNode) {
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.lastActionMessage = "无法移动到废纸篓：\(error.localizedDescription)"
                } else {
                    let freedSize = node.sizeBytes
                    self.lastActionMessage = "已移至废纸篓：\(node.name)"
                    // Remove from parent children
                    if let parent = node.parent {
                        parent.children.removeAll { $0.id == node.id }
                        parent.sizeBytes = max(0, parent.sizeBytes - freedSize)
                        parent.childCount = parent.children.count
                    }
                    // Remove from large files
                    self.topLargeFiles.removeAll { $0.url == node.url }
                    self.totalScannedBytes = max(0, self.totalScannedBytes - freedSize)
                }
            }
        }
    }

    public func moveToTrash(largeFile: AnalysisLargeFileItem) {
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
