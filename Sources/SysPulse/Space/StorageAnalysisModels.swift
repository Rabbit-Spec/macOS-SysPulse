import Foundation
import AppKit
import SwiftUI

// MARK: - Storage Analysis Location Options

public enum AnalysisLocation: Hashable, Identifiable, Sendable {
    case home
    case downloads
    case documents
    case desktop
    case developer
    case applications
    case custom(URL)

    public var id: String {
        switch self {
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

// MARK: - Analysis Tree Node

public final class AnalysisNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let path: String
    public var sizeBytes: Int64
    public let isDirectory: Bool
    public let isPackage: Bool
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
        childCount: Int = 0,
        children: [AnalysisNode] = [],
        parent: AnalysisNode? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.path = url.path
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.childCount = childCount
        self.children = children
        self.parent = parent
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
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

    public init(
        id: UUID = UUID(),
        url: URL,
        sizeBytes: Int64
    ) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.path = url.path
        self.sizeBytes = sizeBytes
        self.extensionName = url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased()
        self.parentDirectoryName = url.deletingLastPathComponent().lastPathComponent
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var icon: NSImage {
        AppIconLookupCache.shared.icon(forFilePath: path)
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
