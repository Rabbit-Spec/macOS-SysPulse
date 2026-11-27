import Foundation
import AppKit
import SwiftUI

public enum AppSpaceComponentType: String, CaseIterable, Identifiable, Sendable {
    case appBundle = "应用本体"
    case containers = "沙盒容器"
    case groupContainers = "共享群组"
    case applicationScripts = "应用脚本"
    case appSupport = "应用支持数据"
    case caches = "运行缓存"
    case httpStorages = "网络存储"
    case webKit = "网页容器"
    case preferences = "偏好设置"
    case syncedPreferences = "同步偏好"
    case savedState = "窗口状态"
    case launchAgents = "自启代理"
    case launchDaemons = "守护进程"
    case helperTools = "后台服务组件"
    case systemPlugins = "系统扩展"
    case receipts = "安装票据"
    case logs = "运行日志"
    case homebrewCask = "Cask 源"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .appBundle: return "app.badge.fill"
        case .containers: return "cube.box.fill"
        case .groupContainers: return "shippingbox.fill"
        case .applicationScripts: return "scroll.fill"
        case .appSupport: return "folder.fill.badge.gearshape"
        case .caches: return "archivebox.fill"
        case .httpStorages: return "network"
        case .webKit: return "safari.fill"
        case .preferences: return "slider.horizontal.2.square"
        case .syncedPreferences: return "icloud.fill"
        case .savedState: return "macwindow.on.rectangle"
        case .launchAgents: return "bolt.horizontal.fill"
        case .launchDaemons: return "server.rack"
        case .helperTools: return "wrench.and.screwdriver.fill"
        case .systemPlugins: return "puzzlepiece.extension.fill"
        case .receipts: return "doc.plaintext.fill"
        case .logs: return "doc.text.magnifyingglass"
        case .homebrewCask: return "shippingbox.circle.fill"
        }
    }
}

public enum AppResidueConfidence: String, Sendable {
    case auto = "高置信"
    case review = "建议复核"
}

public struct AppSpaceComponent: Identifiable, Sendable {
    public let id: UUID
    public let type: AppSpaceComponentType
    public let path: URL
    public let sizeBytes: Int64
    public let isSafeToTrash: Bool
    public let confidence: AppResidueConfidence
    public let evidenceLabel: String

    public init(
        id: UUID = UUID(),
        type: AppSpaceComponentType,
        path: URL,
        sizeBytes: Int64,
        isSafeToTrash: Bool = true,
        confidence: AppResidueConfidence = .auto,
        evidenceLabel: String = ""
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.sizeBytes = sizeBytes
        self.isSafeToTrash = isSafeToTrash
        self.confidence = confidence
        self.evidenceLabel = evidenceLabel
    }

    public var formattedSize: String {
        formatBytes(sizeBytes)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
        } else if b >= 1024 * 1024 {
            return String(format: "%.1f MB", b / (1024 * 1024))
        } else if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        } else {
            return "\(bytes) B"
        }
    }
}

public struct HomebrewCaskMatch: Sendable {
    public let token: String
    public let caskroomPath: URL
    public let installedVersion: String

    public init(token: String, caskroomPath: URL, installedVersion: String) {
        self.token = token
        self.caskroomPath = caskroomPath
        self.installedVersion = installedVersion
    }
}

public struct InstalledAppInfo: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let bundleID: String
    public let bundleURL: URL
    public let version: String
    public let lastUsedDate: Date?
    public let installDate: Date?
    public let isRunning: Bool
    public let runningPID: pid_t?
    public let isSystemApp: Bool
    public let caskMatch: HomebrewCaskMatch?
    public let hasLaunchRegistrations: Bool
    public let uninstallWarnings: [String]
    public let components: [AppSpaceComponent]
    public let totalSizeBytes: Int64
    public let binarySizeBytes: Int64
    public let dataSizeBytes: Int64

    public init(
        id: UUID = UUID(),
        name: String,
        bundleID: String,
        bundleURL: URL,
        version: String,
        lastUsedDate: Date? = nil,
        installDate: Date? = nil,
        isRunning: Bool = false,
        runningPID: pid_t? = nil,
        isSystemApp: Bool = false,
        caskMatch: HomebrewCaskMatch? = nil,
        hasLaunchRegistrations: Bool = false,
        uninstallWarnings: [String] = [],
        components: [AppSpaceComponent] = []
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.version = version
        self.lastUsedDate = lastUsedDate
        self.installDate = installDate
        self.isRunning = isRunning
        self.runningPID = runningPID
        self.isSystemApp = isSystemApp
        self.caskMatch = caskMatch
        self.hasLaunchRegistrations = hasLaunchRegistrations
        self.uninstallWarnings = uninstallWarnings
        self.components = components

        let total = components.reduce(0) { $0 + $1.sizeBytes }
        self.totalSizeBytes = total

        let bin = components.first(where: { $0.type == .appBundle })?.sizeBytes ?? 0
        self.binarySizeBytes = bin
        self.dataSizeBytes = max(0, total - bin)
    }

    public var formattedTotalSize: String { formatBytes(totalSizeBytes) }
    public var formattedBinarySize: String { formatBytes(binarySizeBytes) }
    public var formattedDataSize: String { formatBytes(dataSizeBytes) }

    public var isUnused: Bool {
        guard let d = lastUsedDate else { return true }
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return days >= 30
    }

    public var daysSinceLastUsed: Int {
        guard let d = lastUsedDate else { return 9999 }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
    }

    public var formattedLastUsed: String {
        guard let d = lastUsedDate else { return "长期未使用" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
        if days == 0 { return "今天有活动" }
        else if days == 1 { return "昨天有活动" }
        else if days < 7 { return "\(days) 天前有活动" }
        else if days < 30 { return "\(days / 7) 周前有活动" }
        else if days < 365 { return "\(days / 30) 个月前有活动" }
        else { return "1 年以上未活动" }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
        } else if b >= 1024 * 1024 {
            return String(format: "%.1f MB", b / (1024 * 1024))
        } else if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        } else {
            return "\(bytes) B"
        }
    }
}

public struct OrphanedResidueItem: Identifiable, Sendable {
    public let id: UUID
    public let originalAppName: String
    public let bundleID: String
    public let componentType: AppSpaceComponentType
    public let path: URL
    public let sizeBytes: Int64
    public let lastModifiedDate: Date?
    public let confidence: AppResidueConfidence
    public let evidenceLabel: String

    public init(
        id: UUID = UUID(),
        originalAppName: String,
        bundleID: String,
        componentType: AppSpaceComponentType,
        path: URL,
        sizeBytes: Int64,
        lastModifiedDate: Date? = nil,
        confidence: AppResidueConfidence = .auto,
        evidenceLabel: String = "未匹配到宿主应用"
    ) {
        self.id = id
        self.originalAppName = originalAppName
        self.bundleID = bundleID
        self.componentType = componentType
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastModifiedDate = lastModifiedDate
        self.confidence = confidence
        self.evidenceLabel = evidenceLabel
    }

    public var formattedSize: String {
        let b = Double(sizeBytes)
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
        } else if b >= 1024 * 1024 {
            return String(format: "%.1f MB", b / (1024 * 1024))
        } else if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        } else {
            return "\(sizeBytes) B"
        }
    }
}

// MARK: - 命令行工具卸载项

public enum CommandLineToolSource: String, CaseIterable, Identifiable, Sendable {
    case homebrewFormula = "Homebrew"
    case userLocalBin = "用户目录 Bin"
    case systemLocalBin = "系统 Local Bin"
    case npmGlobal = "npm 全局"
    case uvOrPipx = "pipx / uv"
    case cargoBin = "Rust Cargo"
    case bunOrDeno = "Bun / Deno"
    case nodeVersionManager = "Node/Py 运行时"

    public var id: String { rawValue }
}

public struct CommandLineToolItem: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let displayTitle: String
    public let source: CommandLineToolSource
    public let installURL: URL
    public let binaryURL: URL?
    public let version: String
    public let sizeBytes: Int64
    public let isRunning: Bool
    public let formulaName: String?
    public let dependentFormulaCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        displayTitle: String,
        source: CommandLineToolSource,
        installURL: URL,
        binaryURL: URL?,
        version: String,
        sizeBytes: Int64,
        isRunning: Bool = false,
        formulaName: String? = nil,
        dependentFormulaCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.displayTitle = displayTitle
        self.source = source
        self.installURL = installURL
        self.binaryURL = binaryURL
        self.version = version
        self.sizeBytes = sizeBytes
        self.isRunning = isRunning
        self.formulaName = formulaName
        self.dependentFormulaCount = dependentFormulaCount
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum AppSortOption: String, CaseIterable, Identifiable, Sendable {
    case sizeDesc = "占用体积 ↓"
    case nameAsc = "应用名称 A-Z"
    case lastUsed = "最近使用"
    case installDate = "安装时间"

    public var id: String { rawValue }
}

public enum UninstallerSubTab: String, CaseIterable, Identifiable, Sendable {
    case installedApps = "应用管理"
    case commandLineTools = "命令行工具"
    case orphanedResidues = "无主残留"
    case startupItems = "启动项管理"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .installedApps: return "square.stack.3d.up.fill"
        case .commandLineTools: return "terminal.fill"
        case .orphanedResidues: return "trash.slash.fill"
        case .startupItems: return "bolt.badge.checkmark.fill"
        }
    }
}

// MARK: - 应用分类筛选器

public enum AppCategoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部应用"
    case user = "第三方应用"
    case unused = "长期未使用"
    case system = "系统应用"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    public var iconName: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .user: return "app.badge.fill"
        case .unused: return "clock.arrow.circlepath"
        case .system: return "lock.shield.fill"
        }
    }

    public var themeColor: Color {
        switch self {
        case .all: return Color.cyan
        case .user: return Color(red: 0.25, green: 0.65, blue: 0.95)
        case .unused: return Color.orange
        case .system: return Color(red: 0.70, green: 0.45, blue: 0.95)
        }
    }
}

public enum UninstallerDeleteMode: String, CaseIterable, Identifiable, Sendable {
    case moveToTrash = "移到废纸篓 (推荐)"
    case permanent = "直接永久删除"

    public var id: String { rawValue }
    public var title: String { rawValue }
    public var subtitle: String {
        switch self {
        case .moveToTrash:
            return "卸载后所有组件均移入访达废纸篓，可随时放回原处或找回。"
        case .permanent:
            return "直接物理清除所有文件，立即释放存储空间，不可撤回。"
        }
    }
}

public enum UninstallerStatus: Sendable, Equatable {
    case idle
    case scanning(progress: Double, currentApp: String)
    case completed
    case uninstalling(progress: Double, currentApp: String)
    case finished(freedBytes: Int64, count: Int)
}

public enum UninstallerRowItem: Identifiable, Sendable {
    case app(InstalledAppInfo)
    case residue(OrphanedResidueItem)

    public var id: UUID {
        switch self {
        case .app(let a): return a.id
        case .residue(let r): return r.id
        }
    }

    public var name: String {
        switch self {
        case .app(let a): return a.name
        case .residue(let r): return r.originalAppName
        }
    }

    public var bundleID: String {
        switch self {
        case .app(let a): return a.bundleID
        case .residue(let r): return r.bundleID
        }
    }

    public var sizeBytes: Int64 {
        switch self {
        case .app(let a): return a.totalSizeBytes
        case .residue(let r): return r.sizeBytes
        }
    }

    public var formattedSize: String {
        switch self {
        case .app(let a): return a.formattedTotalSize
        case .residue(let r): return r.formattedSize
        }
    }

    public var isSystemApp: Bool {
        switch self {
        case .app(let a): return a.isSystemApp
        case .residue: return false
        }
    }
}
