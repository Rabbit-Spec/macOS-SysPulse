import Foundation
import SwiftUI

// MARK: - 清理残留分类

public enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches = "userCaches"         // 用户缓存
    case systemLogs = "systemLogs"         // 日志文件
    case webData = "webData"               // 网页临时数据
    case crashReports = "crashReports"     // 崩溃诊断
    case developerCache = "developerCache" // 开发缓存
    case userTrash = "userTrash"           // 废纸篓

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .userCaches: return "用户缓存"
        case .systemLogs: return "日志文件"
        case .webData: return "网页临时数据"
        case .crashReports: return "崩溃诊断"
        case .developerCache: return "开发缓存"
        case .userTrash: return "废纸篓"
        }
    }

    public var detailDescription: String {
        switch self {
        case .userCaches: return "应用运行产生的临时缓存，用到时会自动重建"
        case .systemLogs: return "系统运行历史日志与诊断记录，不影响正常使用"
        case .webData: return "Safari、Chrome 等浏览器网页离线缓存与临时数据"
        case .crashReports: return "应用与系统历史崩溃转储与诊断日志 (.ips / .crash)"
        case .developerCache: return "Xcode DerivedData、编译索引、模拟器与包管理缓存"
        case .userTrash: return "用户废纸篓待清空文件及下载目录中残留的安装包"
        }
    }

    public var iconName: String {
        switch self {
        case .userCaches: return "laptopcomputer"
        case .systemLogs: return "doc.text.fill"
        case .webData: return "globe"
        case .crashReports: return "exclamationmark.triangle.fill"
        case .developerCache: return "hammer.fill"
        case .userTrash: return "trash.fill"
        }
    }

    public var themeColor: Color {
        switch self {
        case .userCaches: return Color.cyan
        case .systemLogs: return Color.orange
        case .webData: return Color.blue
        case .crashReports: return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .developerCache: return Color.mint
        case .userTrash: return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }
}

// MARK: - Review Bucket (复核分桶: 建议清理 / 需要复核 / 白名单保护)

public enum CleanReviewBucket: String, Sendable, CaseIterable, Identifiable {
    case suggested = "suggested"     // 建议清理 (默认勾选)
    case needsReview = "needsReview" // 需要复核 (默认不选)
    case excluded = "excluded"       // 白名单保护跳过

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .suggested: return "建议清理"
        case .needsReview: return "需要复核"
        case .excluded: return "白名单保护"
        }
    }
}

// MARK: - Deletion Mode (清理方式)

public enum CleanDeleteMode: String, CaseIterable, Identifiable, Sendable {
    case moveToTrash = "moveToTrash"
    case permanent = "permanent"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .moveToTrash: return "移到废纸篓 (推荐)"
        case .permanent: return "直接永久删除"
        }
    }

    public var subtitle: String {
        switch self {
        case .moveToTrash: return "清理后可在访达废纸篓中随时找回或恢复"
        case .permanent: return "彻底删除并立即腾出空间，删除后无法恢复"
        }
    }
}

// MARK: - Clean Item

public struct CleanItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let category: CleanCategory
    public let bucket: CleanReviewBucket
    public let path: URL
    public let sizeBytes: Int64
    public let detail: String
    public let isProtected: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        category: CleanCategory,
        bucket: CleanReviewBucket = .suggested,
        path: URL,
        sizeBytes: Int64,
        detail: String,
        isProtected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.bucket = bucket
        self.path = path
        self.sizeBytes = sizeBytes
        self.detail = detail
        self.isProtected = isProtected
    }

    public var formattedSize: String {
        let bytes = Double(sizeBytes)
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", bytes / (1024 * 1024 * 1024))
        } else if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", bytes / 1024)
        } else {
            return "\(sizeBytes) B"
        }
    }
}

// MARK: - Scan Status & Sorting

public enum CleanScanStatus: Equatable, Sendable {
    case idle
    case scanning(progress: Double, currentPath: String)
    case completed(totalBytes: Int64, itemCount: Int)
    case cleaning(progress: Double, currentItem: String)
    case cleaned(freedBytes: Int64, itemCount: Int)
}

public enum CleanerSortField: String, Sendable {
    case name
    case category
    case size
}
