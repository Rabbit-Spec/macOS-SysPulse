import Foundation
import AppKit
import SwiftUI
import Darwin

// MARK: - Storage Analysis Location Options

public enum AnalysisLocation: Hashable, Identifiable, Sendable {
    case entireDisk
    case home
    case downloads
    case documents
    case desktop
    case developer
    case applications
    case externalVolume(url: URL, name: String)
    case networkVolume(url: URL, name: String)
    case custom(URL)

    public var id: String {
        switch self {
        case .entireDisk: return "entire_disk"
        case .home: return "home"
        case .downloads: return "downloads"
        case .documents: return "documents"
        case .desktop: return "desktop"
        case .developer: return "developer"
        case .applications: return "applications"
        case .externalVolume(let url, _): return "extvol-\(url.standardizedFileURL.path)"
        case .networkVolume(let url, _): return "netvol-\(url.standardizedFileURL.path)"
        case .custom(let url): return "custom-\(url.standardizedFileURL.path)"
        }
    }

    public var displayName: String {
        switch self {
        case .entireDisk: return "全盘概览 (/)"
        case .home: return "个人主目录"
        case .downloads: return "下载文件夹"
        case .documents: return "文稿文件夹"
        case .desktop: return "桌面"
        case .developer: return "开发目录 (Developer)"
        case .applications: return "应用程序 (/Applications)"
        case .externalVolume(_, let name): return name
        case .networkVolume(_, let name): return name
        case .custom(let url): return url.lastPathComponent
        }
    }

    public var iconName: String {
        switch self {
        case .entireDisk: return "internaldrive.fill"
        case .home: return "house.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .documents: return "doc.text.fill"
        case .desktop: return "macwindow.on.rectangle"
        case .developer: return "hammer.fill"
        case .applications: return "app.badge.fill"
        case .externalVolume: return "externaldrive.fill"
        case .networkVolume: return "externaldrive.connected.to.line.below.fill"
        case .custom: return "folder.fill"
        }
    }

    /// 内置本机位置（扫描时严格限制在本机内置系统/数据卷内，严禁跨卷进入外置硬盘或 SMB NAS）
    public var isBuiltInInternalLocation: Bool {
        switch self {
        case .entireDisk, .home, .downloads, .documents, .desktop, .developer, .applications:
            return true
        case .externalVolume, .networkVolume, .custom:
            return false
        }
    }

    public var url: URL {
        let fileManager = FileManager.default
        switch self {
        case .entireDisk:
            return URL(fileURLWithPath: "/")
        case .home:
            return fileManager.homeDirectoryForCurrentUser
        case .downloads:
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        case .documents:
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        case .desktop:
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        case .developer:
            let dev = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
            return fileManager.fileExists(atPath: dev.path) ? dev : fileManager.homeDirectoryForCurrentUser
        case .applications:
            return URL(fileURLWithPath: "/Applications")
        case .externalVolume(let url, _), .networkVolume(let url, _):
            return url
        case .custom(let url):
            return url
        }
    }
}

// MARK: - Mounted External & SMB/NAS Volume Discovery

public struct MountedVolumeItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isNetwork: Bool
    public let capacitySummary: String

    public init(id: String, url: URL, name: String, isNetwork: Bool, capacitySummary: String) {
        self.id = id
        self.url = url
        self.name = name
        self.isNetwork = isNetwork
        self.capacitySummary = capacitySummary
    }
}

public enum MountedVolumeDiscovery {
    private static func cStringFromTuple<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { rawPtr in
            let slice = rawPtr.prefix(while: { $0 != 0 })
            return String(decoding: slice, as: UTF8.self)
        }
    }

    /// 枚举当前挂载的外置磁盘与 SMB/NAS 网络卷宗（排除系统内部 APFS 卷与隐藏系统卷）
    public static func discover() -> (external: [MountedVolumeItem], network: [MountedVolumeItem]) {
        var internalDevs: Set<Int32> = []
        var rootSt = Darwin.stat()
        if stat("/", &rootSt) == 0 {
            internalDevs.insert(rootSt.st_dev)
        }
        var dataSt = Darwin.stat()
        if stat("/System/Volumes/Data", &dataSt) == 0 {
            internalDevs.insert(dataSt.st_dev)
        }

        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey,
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return ([], [])
        }

        let networkFSTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp"]
        var external: [MountedVolumeItem] = []
        var network: [MountedVolumeItem] = []
        var seenPaths: Set<String> = []

        for volURL in volumeURLs {
            let stdPath = volURL.standardizedFileURL.path
            guard !stdPath.isEmpty, stdPath != "/", !seenPaths.contains(stdPath) else { continue }
            if stdPath.hasPrefix("/System/")
                || stdPath.hasPrefix("/private/")
                || stdPath.hasPrefix("/Library/")
                || stdPath.hasPrefix("/dev")
                || stdPath.contains("com.apple.TimeMachine") {
                continue
            }

            var sfs = Darwin.statfs()
            guard statfs(stdPath, &sfs) == 0 else { continue }
            if (Int32(sfs.f_flags) & MNT_DONTBROWSE) != 0 { continue }

            let mountOn = cStringFromTuple(sfs.f_mntonname)
            guard mountOn == stdPath || mountOn == volURL.path else { continue }

            let fsType = cStringFromTuple(sfs.f_fstypename).lowercased()
            if fsType == "devfs" || fsType == "autofs" { continue }

            var volSt = Darwin.stat()
            guard Darwin.lstat(stdPath, &volSt) == 0 else { continue }

            let vals = try? volURL.resourceValues(forKeys: Set(keys))
            let isNetwork = (vals?.volumeIsLocal == false) || networkFSTypes.contains(fsType)

            if !isNetwork && internalDevs.contains(volSt.st_dev) {
                continue
            }

            seenPaths.insert(stdPath)
            let name = vals?.volumeLocalizedName ?? vals?.volumeName ?? volURL.lastPathComponent
            let totalBytes = Int64(vals?.volumeTotalCapacity ?? 0)
            let availBytes = Int64(vals?.volumeAvailableCapacity ?? 0)
            let usedBytes = max(0, totalBytes - availBytes)

            let summary: String
            if totalBytes > 0 {
                let usedStr = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
                let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                summary = "已用 \(usedStr) / \(totalStr)"
            } else {
                summary = isNetwork ? "网络共享存储" : "外置存储卷"
            }

            let item = MountedVolumeItem(
                id: stdPath,
                url: volURL,
                name: name.isEmpty ? volURL.lastPathComponent : name,
                isNetwork: isNetwork,
                capacitySummary: summary
            )
            if isNetwork {
                network.append(item)
            } else {
                external.append(item)
            }
        }

        external.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        network.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (external, network)
    }
}

// MARK: - Analysis View Mode

public enum AnalysisViewMode: String, CaseIterable, Identifiable, Sendable {
    case browser = "层级目录"
    case treemap = "空间地图"
    case largeFiles = "最大文件"
    case insights = "系统空间"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .browser: return "folder.badge.gearshape"
        case .treemap: return "square.grid.3x2.fill"
        case .largeFiles: return "chart.bar.xaxis"
        case .insights: return "sparkles.rectangle.stack"
        }
    }
}

// MARK: - Analysis Status

public enum StorageAnalysisStatus: Equatable, Sendable {
    case idle
    case scanning(scannedFiles: Int, scannedBytes: Int64, currentPath: String)
    case completed(totalFiles: Int, totalBytes: Int64, duration: TimeInterval)
    case cancelled
}

// MARK: - File Kind Classification

public enum AnalysisFileKind: String, CaseIterable, Identifiable, Sendable {
    case aiModel = "AI 模型与权重"
    case developer = "开发构建与依赖"
    case video = "视频媒体"
    case diskImage = "磁盘映像/虚拟机"
    case archive = "压缩归档包"
    case application = "应用程序与包"
    case audio = "音频文件"
    case image = "图像与设计稿"
    case document = "文档与数据"
    case other = "其他文件"

    public var id: String { rawValue }

    public var tintName: String {
        switch self {
        case .aiModel: return "mint"
        case .developer: return "indigo"
        case .video: return "orange"
        case .diskImage: return "purple"
        case .archive: return "blue"
        case .application: return "cyan"
        case .audio: return "pink"
        case .image: return "teal"
        case .document: return "gray"
        case .other: return "gray"
        }
    }

    public static func classify(url: URL, isPackage: Bool = false) -> AnalysisFileKind {
        classify(path: url.path, name: url.lastPathComponent, isPackage: isPackage)
    }

    public static func classify(path: String, name: String, isPackage: Bool = false) -> AnalysisFileKind {
        let pathLower = path.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()

        // 1. 先匹配特定大类包类型（避免 .mlpackage / .dSYM / .utm / .photoslibrary 等被笼统归入应用包或“其他”）
        let aiModelExts: Set<String> = [
            "gguf", "ggml", "safetensors", "onnx", "mlmodel", "mlpackage", "mlmodelc",
            "mlx", "ckpt", "pt", "pth", "keras", "h5", "tflite", "llamafile", "npz", "ort", "engine"
        ]
        if aiModelExts.contains(ext) {
            return .aiModel
        }
        if pathLower.contains("/.ollama/models") || pathLower.contains("/.lmstudio/models") {
            return .aiModel
        }
        if (ext == "bin" || ext == "model" || ext == "weights"),
           (pathLower.contains("ollama") || pathLower.contains("lmstudio") || pathLower.contains("huggingface")
            || pathLower.contains("/models/") || pathLower.contains("/checkpoints/")) {
            return .aiModel
        }

        // 2. 磁盘映像与虚拟机镜像（必须在 RAW 照片前区分虚拟盘 .raw）
        let diskImageExts: Set<String> = [
            "dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "qcow2",
            "ova", "ovf", "ipsw", "utm", "pvm", "vmwarevm", "vhd", "vhdx", "vdi"
        ]
        if diskImageExts.contains(ext) || (ext == "raw" && (pathLower.contains("docker") || pathLower.contains("/vm") || pathLower.contains("orbstack") || pathLower.contains("qemu"))) {
            return .diskImage
        }

        // 3. 开发构建产物与编译器中间文件
        let devExts: Set<String> = [
            "o", "a", "dylib", "so", "rlib", "rmeta", "swiftmodule", "swiftdoc", "swiftinterface",
            "d", "map", "node", "pyc", "pyo", "class", "jar", "war", "wasm", "pdb", "ipa", "apk", "aab",
            "dsym", "xcarchive", "bc", "pch", "profraw", "profdata", "tsbuildinfo",
            "xcodeproj", "xcworkspace", "playground", "realm", "avro", "ndjson", "trace", "dump"
        ]
        let devPathFragments = [
            "/deriveddata/", "/node_modules/", "/target/", "/.cargo/",
            "/.build/", "/.next/", "/.nuxt/", "/.turbo/", "/dist/",
            "/build/", "/.gradle/", "/.venv/", "/__pycache__/", "/pods/"
        ]
        if devExts.contains(ext) || devPathFragments.contains(where: { pathLower.contains($0) }) {
            return .developer
        }

        // 4. 相机 RAW 照片、现代图像格式与设计源文件
        let imageExts: Set<String> = [
            "png", "jpg", "jpeg", "heic", "heif", "avif", "gif", "bmp", "webp", "svg",
            "tiff", "tif", "psd", "psb", "ai", "fig", "sketch", "exr", "hdr", "icns", "ico",
            "photoslibrary",
            // 相机无损 RAW 格式
            "raw", "cr2", "cr3", "dng", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
            "rw2", "pef", "srw", "x3f", "3fr", "iiq", "fff", "erf", "mrw", "dcr", "kdc",
            "mos", "gpr", "rwl"
        ]
        if imageExts.contains(ext) {
            return .image
        }

        // 5. 应用程序与通用 Bundle
        if isPackage || ext == "app" || ext == "appex" || ext == "framework" || ext == "kext" || ext == "prefpane" {
            return .application
        }

        // 6. 归档包 / 视频 / 音频 / 文档
        if ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "pkg", "xip"].contains(ext) {
            return .archive
        }
        if ["mp4", "mov", "mkv", "avi", "m4v", "webm", "prores", "ts", "flv", "braw", "r3d", "mxf", "vob", "mpg", "mpeg", "3gp"].contains(ext) {
            return .video
        }
        if ["wav", "flac", "mp3", "m4a", "aac", "aiff", "ogg", "alac", "opus", "wma", "mid", "midi"].contains(ext) {
            return .audio
        }
        if ["pdf", "sqlite", "db", "jsonl", "csv", "parquet", "xlsx", "docx", "pptx", "pages", "key", "numbers", "epub", "mobi", "duckdb", "md", "txt", "rtf", "json", "xml", "yaml", "yml"].contains(ext) {
            return .document
        }
        return .other
    }
}

// MARK: - Analysis Tree Node

public final class AnalysisNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let name: String
    private var explicitPath: String?
    public var sizeBytes: Int64
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHiddenFolder: Bool
    public var isProtectedOrUnreadable: Bool
    public var isSizingPending: Bool
    public var isCloudPlaceholder: Bool
    public var hasPrunedChildren: Bool
    public var ownerAppName: String?
    public let modificationDate: Date?
    public let lastAccessDate: Date?
    public var childCount: Int
    public var children: [AnalysisNode]
    public weak var parent: AnalysisNode? {
        didSet {
            guard let p = parent, let exp = explicitPath else { return }
            let pPath = p.path
            let expected = (pPath == "/") ? "/\(name)" : "\(pPath)/\(name)"
            if exp == expected {
                explicitPath = nil
            }
        }
    }

    /// 从文件路径轻量初始化（不持有 URL 与 CoreServices _FileCache；常规子节点路径由 parent 链推算，内存占用近零）
    public init(
        id: UUID = UUID(),
        filePath: String,
        name: String? = nil,
        sizeBytes: Int64 = 0,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isHiddenFolder: Bool? = nil,
        isProtectedOrUnreadable: Bool = false,
        isSizingPending: Bool = false,
        isCloudPlaceholder: Bool = false,
        hasPrunedChildren: Bool = false,
        ownerAppName: String? = nil,
        modificationDate: Date? = nil,
        lastAccessDate: Date? = nil,
        childCount: Int = 0,
        children: [AnalysisNode] = [],
        parent: AnalysisNode? = nil
    ) {
        self.id = id
        let fileName = (filePath as NSString).lastPathComponent
        let resolvedName = name ?? (fileName.isEmpty ? filePath : fileName)
        self.name = resolvedName
        if let parent {
            let pPath = parent.path
            let expected = (pPath == "/") ? "/\(resolvedName)" : "\(pPath)/\(resolvedName)"
            self.explicitPath = (filePath == expected) ? nil : filePath
        } else {
            self.explicitPath = filePath
        }
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHiddenFolder = isHiddenFolder ?? (isDirectory && fileName.hasPrefix("."))
        self.isProtectedOrUnreadable = isProtectedOrUnreadable
        self.isSizingPending = isSizingPending
        self.isCloudPlaceholder = isCloudPlaceholder
        self.hasPrunedChildren = hasPrunedChildren
        self.ownerAppName = ownerAppName
        self.modificationDate = modificationDate
        self.lastAccessDate = lastAccessDate
        self.childCount = childCount
        self.children = children
        self.parent = parent
    }

    public convenience init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        sizeBytes: Int64 = 0,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isHiddenFolder: Bool? = nil,
        isProtectedOrUnreadable: Bool = false,
        isSizingPending: Bool = false,
        isCloudPlaceholder: Bool = false,
        hasPrunedChildren: Bool = false,
        ownerAppName: String? = nil,
        modificationDate: Date? = nil,
        lastAccessDate: Date? = nil,
        childCount: Int = 0,
        children: [AnalysisNode] = [],
        parent: AnalysisNode? = nil
    ) {
        self.init(
            id: id,
            filePath: url.path,
            name: name,
            sizeBytes: sizeBytes,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHiddenFolder: isHiddenFolder,
            isProtectedOrUnreadable: isProtectedOrUnreadable,
            isSizingPending: isSizingPending,
            isCloudPlaceholder: isCloudPlaceholder,
            hasPrunedChildren: hasPrunedChildren,
            ownerAppName: ownerAppName,
            modificationDate: modificationDate,
            lastAccessDate: lastAccessDate,
            childCount: childCount,
            children: children,
            parent: parent
        )
    }

    public var path: String {
        if let explicitPath { return explicitPath }
        if let parent {
            let pPath = parent.path
            return (pPath == "/") ? "/\(name)" : "\(pPath)/\(name)"
        }
        return name
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    public func detachPreservingPath() {
        explicitPath = path
        parent = nil
    }

    public var isUnusedOverYear: Bool {
        let refDate = lastAccessDate ?? modificationDate
        guard let refDate else { return false }
        return Date().timeIntervalSince(refDate) >= 365 * 24 * 3600
    }

    public var formattedSize: String {
        if isCloudPlaceholder && sizeBytes == 0 {
            return "云端未下载"
        }
        if isProtectedOrUnreadable && sizeBytes == 0 {
            return "受保护"
        }
        let base = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return isSizingPending ? "\(base)+" : base
    }

    public var icon: NSImage {
        AppIconLookupCache.shared.icon(forFilePath: path)
    }

    public var extensionName: String {
        (name as NSString).pathExtension.uppercased()
    }
}

// MARK: - Analysis Top Large File Item

public struct AnalysisLargeFileItem: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let sizeBytes: Int64
    public let extensionName: String
    public let parentDirectoryName: String
    public let fileKind: AnalysisFileKind
    public let modificationDate: Date?
    public let lastAccessDate: Date?

    public init(
        id: UUID = UUID(),
        filePath: String,
        sizeBytes: Int64,
        isPackage: Bool = false,
        modificationDate: Date? = nil,
        lastAccessDate: Date? = nil
    ) {
        self.id = id
        let nsPath = filePath as NSString
        let fileName = nsPath.lastPathComponent
        let ext = nsPath.pathExtension
        self.name = fileName
        self.path = filePath
        self.sizeBytes = sizeBytes
        self.extensionName = isPackage ? "APP" : (ext.isEmpty ? "文件" : ext.uppercased())
        self.parentDirectoryName = (nsPath.deletingLastPathComponent as NSString).lastPathComponent
        self.fileKind = AnalysisFileKind.classify(path: filePath, name: fileName, isPackage: isPackage)
        self.modificationDate = modificationDate
        self.lastAccessDate = lastAccessDate
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        sizeBytes: Int64,
        isPackage: Bool = false,
        modificationDate: Date? = nil,
        lastAccessDate: Date? = nil
    ) {
        self.init(
            id: id,
            filePath: url.path,
            sizeBytes: sizeBytes,
            isPackage: isPackage,
            modificationDate: modificationDate,
            lastAccessDate: lastAccessDate
        )
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var isUnusedOverYear: Bool {
        let refDate = lastAccessDate ?? modificationDate
        guard let refDate else { return false }
        return Date().timeIntervalSince(refDate) >= 365 * 24 * 3600
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var icon: NSImage {
        AppIconLookupCache.shared.icon(forFilePath: path)
    }
}

// MARK: - Telemetry, Age/Kind Breakdown & CLI Advisories

public struct AnalysisBucketMetric: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let bytes: Int64
    public let count: Int
    public let tintName: String

    public init(id: String, label: String, bytes: Int64, count: Int, tintName: String) {
        self.id = id
        self.label = label
        self.bytes = bytes
        self.count = count
        self.tintName = tintName
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public struct AnalysisDiskTelemetry: Sendable, Equatable {
    public let volumeTotalBytes: Int64
    public let volumeAvailableBytes: Int64
    public let volumeImportantAvailableBytes: Int64
    public let volumePurgeableBytes: Int64
    public let volumeUsedBytes: Int64
    public let scanDeltaBytes: Int64?
    public let previousScanDate: Date?

    public init(
        volumeTotalBytes: Int64 = 0,
        volumeAvailableBytes: Int64 = 0,
        volumeImportantAvailableBytes: Int64 = 0,
        volumePurgeableBytes: Int64 = 0,
        volumeUsedBytes: Int64 = 0,
        scanDeltaBytes: Int64? = nil,
        previousScanDate: Date? = nil
    ) {
        self.volumeTotalBytes = volumeTotalBytes
        self.volumeAvailableBytes = volumeAvailableBytes
        self.volumeImportantAvailableBytes = volumeImportantAvailableBytes
        self.volumePurgeableBytes = volumePurgeableBytes
        self.volumeUsedBytes = volumeUsedBytes
        self.scanDeltaBytes = scanDeltaBytes
        self.previousScanDate = previousScanDate
    }
}

public struct AnalysisToolAdvisory: Identifiable, Sendable {
    public let id: String
    public let toolName: String
    public let badge: String
    public let sizeBytes: Int64
    public let summary: String
    public let cliCommand: String
    public let targetURL: URL
    public let iconName: String

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - Hidden Space Insights Model

public struct HiddenSpaceInsight: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let badge: String
    public let badgeColorName: String
    public let summary: String
    public let detailedExplanation: String
    public let iconName: String
    public var detectedSize: String?

    public init(
        id: String,
        title: String,
        badge: String,
        badgeColorName: String,
        summary: String,
        detailedExplanation: String,
        iconName: String,
        detectedSize: String? = nil
    ) {
        self.id = id
        self.title = title
        self.badge = badge
        self.badgeColorName = badgeColorName
        self.summary = summary
        self.detailedExplanation = detailedExplanation
        self.iconName = iconName
        self.detectedSize = detectedSize
    }
}

// MARK: - Snapshot Quick-Open Cache DTOs

public struct AnalysisNodeSnapshotDTO: Codable, Sendable {
    public let path: String
    public let name: String
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHiddenFolder: Bool
    public let isProtectedOrUnreadable: Bool
    public let isCloudPlaceholder: Bool
    public let ownerAppName: String?
    public let modificationTimestamp: TimeInterval?
    public let lastAccessTimestamp: TimeInterval?
    public let childCount: Int
    public let children: [AnalysisNodeSnapshotDTO]

    public static func from(node: AnalysisNode, maxDepth: Int) -> AnalysisNodeSnapshotDTO {
        let childDTOs: [AnalysisNodeSnapshotDTO] = maxDepth > 0
            ? node.children.prefix(250).map { from(node: $0, maxDepth: maxDepth - 1) }
            : []
        return AnalysisNodeSnapshotDTO(
            path: node.path,
            name: node.name,
            sizeBytes: node.sizeBytes,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isHiddenFolder: node.isHiddenFolder,
            isProtectedOrUnreadable: node.isProtectedOrUnreadable,
            isCloudPlaceholder: node.isCloudPlaceholder,
            ownerAppName: node.ownerAppName,
            modificationTimestamp: node.modificationDate?.timeIntervalSince1970,
            lastAccessTimestamp: node.lastAccessDate?.timeIntervalSince1970,
            childCount: node.childCount,
            children: childDTOs
        )
    }

    public func toNode(parent: AnalysisNode? = nil) -> AnalysisNode {
        let node = AnalysisNode(
            filePath: path,
            name: name,
            sizeBytes: sizeBytes,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHiddenFolder: isHiddenFolder,
            isProtectedOrUnreadable: isProtectedOrUnreadable,
            isSizingPending: false,
            isCloudPlaceholder: isCloudPlaceholder,
            ownerAppName: ownerAppName,
            modificationDate: modificationTimestamp.map { Date(timeIntervalSince1970: $0) },
            lastAccessDate: lastAccessTimestamp.map { Date(timeIntervalSince1970: $0) },
            childCount: childCount,
            children: [],
            parent: parent
        )
        let restoredChildren = children.map { $0.toNode(parent: node) }
        node.children = restoredChildren
        if isDirectory && !isProtectedOrUnreadable && restoredChildren.count < childCount {
            node.hasPrunedChildren = true
        }
        return node
    }
}

public struct AnalysisLargeFileSnapshotDTO: Codable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let isPackage: Bool
    public let modificationTimestamp: TimeInterval?
    public let lastAccessTimestamp: TimeInterval?

    public static func from(item: AnalysisLargeFileItem) -> AnalysisLargeFileSnapshotDTO {
        AnalysisLargeFileSnapshotDTO(
            path: item.path,
            sizeBytes: item.sizeBytes,
            isPackage: item.extensionName == "APP",
            modificationTimestamp: item.modificationDate?.timeIntervalSince1970,
            lastAccessTimestamp: item.lastAccessDate?.timeIntervalSince1970
        )
    }

    public func toItem() -> AnalysisLargeFileItem {
        AnalysisLargeFileItem(
            filePath: path,
            sizeBytes: sizeBytes,
            isPackage: isPackage,
            modificationDate: modificationTimestamp.map { Date(timeIntervalSince1970: $0) },
            lastAccessDate: lastAccessTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

public struct AnalysisBucketMetricSnapshotDTO: Codable, Sendable {
    public let id: String
    public let label: String
    public let bytes: Int64
    public let count: Int
    public let tintName: String
}

public struct AnalysisSnapshotDTO: Codable, Sendable {
    public let locationID: String
    public let savedTimestamp: TimeInterval
    public let totalScannedFiles: Int
    public let totalScannedBytes: Int64
    public let scanDuration: TimeInterval
    public let rootNode: AnalysisNodeSnapshotDTO
    public let topLargeFiles: [AnalysisLargeFileSnapshotDTO]
    public let ageBuckets: [AnalysisBucketMetricSnapshotDTO]
    public let sizeBuckets: [AnalysisBucketMetricSnapshotDTO]
    public let kindBuckets: [AnalysisBucketMetricSnapshotDTO]
    public let volumeTotalBytes: Int64
    public let volumeAvailableBytes: Int64
    public let volumeImportantAvailableBytes: Int64
    public let volumePurgeableBytes: Int64
    public let volumeUsedBytes: Int64
}
