import Foundation
import AppKit
import SwiftUI

// MARK: - Storage Analysis Location Options

public enum AnalysisLocation: Hashable, Identifiable, Sendable {
    case entireDisk
    case home
    case downloads
    case documents
    case desktop
    case developer
    case applications
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
        case .custom(let url): return "custom-\(url.path)"
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
        case .custom: return "folder.fill"
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
        case .custom(let url):
            return url
        }
    }
}

// MARK: - Analysis View Mode

public enum AnalysisViewMode: String, CaseIterable, Identifiable, Sendable {
    case browser = "层级目录"
    case largeFiles = "最大文件"
    case insights = "系统空间"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .browser: return "folder.badge.gearshape"
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
        if isPackage || url.pathExtension.lowercased() == "app" {
            return .application
        }
        let pathLower = url.path.lowercased()
        let ext = url.pathExtension.lowercased()

        if ["gguf", "safetensors", "onnx", "mlmodel", "ckpt", "pt", "pth", "bin"].contains(ext),
           pathLower.contains("ollama") || pathLower.contains("lmstudio") || pathLower.contains("huggingface") || pathLower.contains("models") || ext == "gguf" || ext == "safetensors" {
            return .aiModel
        }
        if pathLower.contains("/.ollama/models") || pathLower.contains("/.lmstudio/models") {
            return .aiModel
        }
        if ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "qcow2", "ova", "ipsw", "utm"].contains(ext) {
            return .diskImage
        }
        if ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "pkg", "xip"].contains(ext) {
            return .archive
        }
        if ["mp4", "mov", "mkv", "avi", "m4v", "webm", "prores", "ts", "flv", "braw"].contains(ext) {
            return .video
        }
        if ["wav", "flac", "mp3", "m4a", "aac", "aiff", "ogg"].contains(ext) {
            return .audio
        }
        if ["png", "jpg", "jpeg", "heic", "raw", "cr3", "nef", "arw", "psd", "ai", "fig", "sketch", "tiff", "exr", "webp"].contains(ext) {
            return .image
        }
        if ["o", "a", "dylib", "swiftmodule", "d", "map", "node", "pyc", "class", "jar", "wasm", "pdb", "ipa", "apk", "aab"].contains(ext) ||
            pathLower.contains("/deriveddata/") || pathLower.contains("/node_modules/") || pathLower.contains("/target/") || pathLower.contains("/.cargo/") {
            return .developer
        }
        if ["pdf", "sqlite", "db", "jsonl", "csv", "parquet", "xlsx", "docx", "pptx", "pages", "key"].contains(ext) {
            return .document
        }
        return .other
    }
}

// MARK: - Analysis Tree Node

public final class AnalysisNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let path: String
    public var sizeBytes: Int64
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHiddenFolder: Bool
    public var isProtectedOrUnreadable: Bool
    public var isSizingPending: Bool
    public let modificationDate: Date?
    public let lastAccessDate: Date?
    public var childCount: Int
    public var children: [AnalysisNode]
    public weak var parent: AnalysisNode?

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        sizeBytes: Int64 = 0,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isHiddenFolder: Bool? = nil,
        isProtectedOrUnreadable: Bool = false,
        isSizingPending: Bool = false,
        modificationDate: Date? = nil,
        lastAccessDate: Date? = nil,
        childCount: Int = 0,
        children: [AnalysisNode] = [],
        parent: AnalysisNode? = nil
    ) {
        self.id = id
        self.url = url
        let resolvedName = name ?? url.lastPathComponent
        self.name = resolvedName
        self.path = url.path
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHiddenFolder = isHiddenFolder ?? (isDirectory && url.lastPathComponent.hasPrefix("."))
        self.isProtectedOrUnreadable = isProtectedOrUnreadable
        self.isSizingPending = isSizingPending
        self.modificationDate = modificationDate
        self.lastAccessDate = lastAccessDate
        self.childCount = childCount
        self.children = children
        self.parent = parent
    }

    public var isUnusedOverYear: Bool {
        let refDate = lastAccessDate ?? modificationDate
        guard let refDate else { return false }
        return Date().timeIntervalSince(refDate) >= 365 * 24 * 3600
    }

    public var formattedSize: String {
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
        url.pathExtension.uppercased()
    }
}

// MARK: - Analysis Top Large File Item

public struct AnalysisLargeFileItem: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
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
        url: URL,
        sizeBytes: Int64,
        isPackage: Bool = false,
        modificationDate: Date? = nil,
        lastAccessDate: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.path = url.path
        self.sizeBytes = sizeBytes
        self.extensionName = isPackage ? "APP" : (url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased())
        self.parentDirectoryName = url.deletingLastPathComponent().lastPathComponent
        self.fileKind = AnalysisFileKind.classify(url: url, isPackage: isPackage)
        self.modificationDate = modificationDate
        self.lastAccessDate = lastAccessDate
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
