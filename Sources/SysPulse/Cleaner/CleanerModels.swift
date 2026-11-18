import Foundation
import SwiftUI

// MARK: - 清理残留分类

public enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches = "userCaches"         // 用户缓存
    case systemLogs = "systemLogs"         // 日志文件
    case webData = "webData"               // 网页临时数据
    case crashReports = "crashReports"     // 崩溃诊断
    case developerCache = "developerCache" // 开发缓存
    case communication = "communication"   // 通讯工具媒体缓存
    case appLeftovers = "appLeftovers"     // 卸载残留与更新器
    case userTrash = "userTrash"           // 废纸篓与安装包

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .userCaches: return "用户缓存"
        case .systemLogs: return "日志文件"
        case .webData: return "网页临时数据"
        case .crashReports: return "崩溃诊断"
        case .developerCache: return "开发缓存"
        case .communication: return "通讯缓存"
        case .appLeftovers: return "残留与更新"
        case .userTrash: return "废纸篓"
        }
    }

    public var detailDescription: String {
        switch self {
        case .userCaches: return "应用运行产生的临时缓存，用到时会自动重建"
        case .systemLogs: return "系统运行历史日志与诊断记录，不影响正常使用"
        case .webData: return "Safari、Chrome 等浏览器网页离线缓存与临时数据"
        case .crashReports: return "应用与系统历史崩溃转储与诊断日志 (.ips / .crash)"
        case .developerCache: return "Xcode 派生数据、已删项目产物、模拟器与依赖包缓存"
        case .communication: return "聊天软件图片/视频缓存，清理后旧媒体需重新下载，已过期的无法找回"
        case .appLeftovers: return "已删除应用的配置/容器残留及 Sparkle 更新下载残留"
        case .userTrash: return "用户废纸篓待清空文件及下载/桌面目录超期安装包"
        }
    }

    public var iconName: String {
        switch self {
        case .userCaches: return "laptopcomputer"
        case .systemLogs: return "doc.text.fill"
        case .webData: return "globe"
        case .crashReports: return "exclamationmark.triangle.fill"
        case .developerCache: return "hammer.fill"
        case .communication: return "message.fill"
        case .appLeftovers: return "shippingbox.fill"
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
        case .communication: return Color.green
        case .appLeftovers: return Color.indigo
        case .userTrash: return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }
}

// MARK: - Review Bucket (复核分桶: 建议清理 / 需要复核 / 手动管理 / 保护拦截)

public enum CleanReviewBucket: String, Sendable, CaseIterable, Identifiable {
    case suggested = "suggested"     // 建议清理 (默认勾选)
    case needsReview = "needsReview" // 需要复核 (默认不选)
    case manualOnly = "manualOnly"   // 仅手动管理 (虚拟机/iOS备份/iCloud大副本等只读展示)
    case excluded = "excluded"       // 白名单/策略保护拦截跳过

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .suggested: return "建议清理"
        case .needsReview: return "需要复核"
        case .manualOnly: return "手动管理"
        case .excluded: return "保护拦截"
        }
    }
}

// MARK: - Selection Presets

public enum CleanSelectionPreset: String, Sendable, CaseIterable, Identifiable {
    case recommended = "推荐"
    case all = "全选"
    case none = "全不选"

    public var id: String { rawValue }
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
    public let guardReason: String?
    public let ownerBundleID: String?
    public let ownerAppName: String?
    public let itemAgeDays: Int?
    public let isInstalledInstaller: Bool?
    public let isCloudPlaceholder: Bool
    public let recommendedActionHint: String?

    public init(
        id: UUID = UUID(),
        name: String,
        category: CleanCategory,
        bucket: CleanReviewBucket = .suggested,
        path: URL,
        sizeBytes: Int64,
        detail: String,
        isProtected: Bool = false,
        guardReason: String? = nil,
        ownerBundleID: String? = nil,
        ownerAppName: String? = nil,
        itemAgeDays: Int? = nil,
        isInstalledInstaller: Bool? = nil,
        isCloudPlaceholder: Bool = false,
        recommendedActionHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.bucket = bucket
        self.path = path
        self.sizeBytes = sizeBytes
        self.detail = detail
        self.isProtected = isProtected || bucket == .excluded
        self.guardReason = guardReason
        self.ownerBundleID = ownerBundleID
        self.ownerAppName = ownerAppName
        self.itemAgeDays = itemAgeDays
        self.isInstalledInstaller = isInstalledInstaller
        self.isCloudPlaceholder = isCloudPlaceholder
        self.recommendedActionHint = recommendedActionHint
    }

    public var isSelectable: Bool {
        !isProtected && bucket != .excluded && bucket != .manualOnly
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - Execution Result Summary (结构化清理回执)

public enum CleanResultDisposition: String, Sendable, CaseIterable, Identifiable {
    case movedToTrash
    case cleaned
    case skippedWhitelist
    case skippedProtected
    case skippedRunning
    case skippedCloudPlaceholder
    case skippedMissing
    case skippedPermission
    case failedLocked
    case failedNotWritable
    case failedRootOwned
    case failedOther

    public var id: String { rawValue }

    public var groupTitle: String {
        switch self {
        case .movedToTrash: return "已移到废纸篓"
        case .cleaned: return "已清理"
        case .skippedWhitelist: return "跳过：白名单"
        case .skippedProtected: return "跳过：保护路径"
        case .skippedRunning: return "跳过：运行中"
        case .skippedCloudPlaceholder: return "跳过：iCloud 云端占位"
        case .skippedMissing: return "跳过：已不存在"
        case .skippedPermission: return "跳过：权限不足"
        case .failedLocked: return "失败：文件已锁定"
        case .failedNotWritable: return "失败：当前账户无法写入"
        case .failedRootOwned: return "失败：归 root 所有"
        case .failedOther: return "失败：请在访达中处理"
        }
    }

    public var isSuccess: Bool {
        self == .movedToTrash || self == .cleaned
    }

    public var isSkipped: Bool {
        switch self {
        case .skippedWhitelist, .skippedProtected, .skippedRunning, .skippedCloudPlaceholder, .skippedMissing, .skippedPermission:
            return true
        default:
            return false
        }
    }
}

public struct CleanResultEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let path: URL
    public let sizeBytes: Int64
    public let disposition: CleanResultDisposition
    public let note: String?

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        sizeBytes: Int64,
        disposition: CleanResultDisposition,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.disposition = disposition
        self.note = note
    }
}

public struct CleanExecutionSummary: Sendable, Equatable {
    public let completedAt: Date
    public let freedBytes: Int64
    public let cleanedCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let entries: [CleanResultEntry]

    public init(
        completedAt: Date = Date(),
        freedBytes: Int64,
        cleanedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        entries: [CleanResultEntry]
    ) {
        self.completedAt = completedAt
        self.freedBytes = freedBytes
        self.cleanedCount = cleanedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.entries = entries
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
