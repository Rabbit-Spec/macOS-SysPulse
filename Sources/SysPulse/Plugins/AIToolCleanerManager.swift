import Foundation
import SwiftUI
import AppKit
import Observation

public enum AICleanBand: String, CaseIterable, Identifiable, Sendable {
    case safeCaches = "safeCaches"
    case reviewSessions = "reviewSessions"
    case toolsMaintenance = "toolsMaintenance"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .safeCaches: return "缓存与旧版本"
        case .reviewSessions: return "对话与 Worktree"
        case .toolsMaintenance: return "闲置工具与维护"
        }
    }

    public var subtitle: String {
        switch self {
        case .safeCaches: return "缓存可自动重建，旧版本与残留目录可安全释放"
        case .reviewSessions: return "对话历史按保留天数裁剪，Git Worktree 核验后再移除"
        case .toolsMaintenance: return "SQLite 数据库压缩、本地模型与长期闲置工具排查"
        }
    }

    public var accentColor: Color {
        switch self {
        case .safeCaches: return .green
        case .reviewSessions: return .orange
        case .toolsMaintenance: return .indigo
        }
    }
}

public enum AIRetentionPolicy: Int, CaseIterable, Identifiable, Sendable {
    case never = -1
    case days7 = 7
    case days14 = 14
    case days30 = 30
    case days90 = 90

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .never: return "暂不清理"
        case .days7: return "7 天之前"
        case .days14: return "14 天之前"
        case .days30: return "30 天之前"
        case .days90: return "90 天之前"
        }
    }
}

public enum AIItemKind: String, Sendable, Equatable {
    case cache
    case oldVersion
    case toolLeftover
    case sessionHistory
    case orphanedAsset
    case worktreeCleanable
    case worktreeKept
    case sqliteDatabase
    case localModel
    case idleTool
}

public struct AICleanItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let band: AICleanBand
    public let kind: AIItemKind
    public let toolName: String
    public let title: String
    public let detail: String
    public let paths: [URL]
    public let sizeBytes: Int64
    public let isProtected: Bool
    public let guardReason: String?
    public let ownerBundleID: String?
    public let ownerAppName: String?
    public let matchedCount: Int
    public let keepReasons: [String]
    public let cliHintCommand: String?
    public let isSelectable: Bool

    public init(
        id: UUID = UUID(),
        band: AICleanBand,
        kind: AIItemKind,
        toolName: String,
        title: String,
        detail: String,
        paths: [URL],
        sizeBytes: Int64,
        isProtected: Bool = false,
        guardReason: String? = nil,
        ownerBundleID: String? = nil,
        ownerAppName: String? = nil,
        matchedCount: Int = 1,
        keepReasons: [String] = [],
        cliHintCommand: String? = nil,
        isSelectable: Bool = true
    ) {
        self.id = id
        self.band = band
        self.kind = kind
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.paths = paths
        self.sizeBytes = sizeBytes
        self.isProtected = isProtected
        self.guardReason = guardReason
        self.ownerBundleID = ownerBundleID
        self.ownerAppName = ownerAppName
        self.matchedCount = matchedCount
        self.keepReasons = keepReasons
        self.cliHintCommand = cliHintCommand
        self.isSelectable = isSelectable && !isProtected
    }

    public var primaryPath: URL? { paths.first }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public struct AIRunningAppConflict: Identifiable, Sendable, Equatable {
    public let id: String // bundleID or appName
    public let appName: String
    public let bundleID: String?
}

@Observable
@MainActor
public final class AIToolCleanerManager {
    public static let shared = AIToolCleanerManager()

    public var isScanning: Bool = false
    public var isProcessing: Bool = false
    public var scanStatusText: String = "待机 · 点击「扫描 AI 数据」排查本地缓存与对话"
    public var items: [AICleanItem] = []
    public var selectedIDs: Set<UUID> = []
    public var activeBand: AICleanBand = .safeCaches
    public var retentionPolicy: AIRetentionPolicy = .days30 {
        didSet {
            if oldValue != retentionPolicy, !items.isEmpty || lastScanDate != nil {
                scanAITools()
            }
        }
    }

    public var detectedToolNames: [String] = []
    public var lastScanDate: Date? = nil
    public var lastSummaryText: String? = nil
    public var lastRecoveryInstructions: String? = nil
    public var undoProtectedPattern: (name: String, pattern: String)? = nil
    public var copiedHintToast: String? = nil

    public var pendingQuitConflicts: [AIRunningAppConflict] = []
    public var isQuitConflictModalPresented: Bool = false
    private var pendingActionType: PendingAIAction = .cleanSelected

    private enum PendingAIAction {
        case cleanSelected
        case vacuumDB(AICleanItem)
    }

    private var scanTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Computed Properties

    public func items(in band: AICleanBand) -> [AICleanItem] {
        items.filter { $0.band == band }
    }

    public func totalBytes(in band: AICleanBand) -> Int64 {
        items(in: band).filter(\.isSelectable).reduce(0) { $0 + $1.sizeBytes }
    }

    public var totalCleanableBytes: Int64 {
        items.filter(\.isSelectable).reduce(0) { $0 + $1.sizeBytes }
    }

    public var selectedBytes: Int64 {
        items.filter { selectedIDs.contains($0.id) && $0.isSelectable }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var protectedItemsCount: Int {
        items.filter(\.isProtected).count
    }

    // MARK: - Selection & Whitelist Protection

    public func toggleSelection(for item: AICleanItem) {
        guard item.isSelectable else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    public func selectAllSafeCaches() {
        for item in items(in: .safeCaches) where item.isSelectable {
            selectedIDs.insert(item.id)
        }
    }

    public func clearSelection(in band: AICleanBand? = nil) {
        if let band {
            let ids = Set(items(in: band).map(\.id))
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.removeAll()
        }
    }

    /// 共享同一 CleanProtectionStore 白名单：插件行内一键「清理保护」
    public func protectItem(_ item: AICleanItem) {
        guard let url = item.primaryPath,
              let pattern = CleanProtectionStore.shared.addPath(url.path) else { return }
        selectedIDs.remove(item.id)
        undoProtectedPattern = (item.title, pattern)
        scanAITools()
    }

    public func undoLastProtection() {
        guard let info = undoProtectedPattern else { return }
        CleanProtectionStore.shared.removePattern(info.pattern)
        undoProtectedPattern = nil
        scanAITools()
    }

    // MARK: - Scan Engine

    public func scanAITools() {
        guard FeatureToggleManager.shared.enablePluginAIToolCleaner else { return }
        guard !isProcessing else { return }

        scanTask?.cancel()
        isScanning = true
        lastSummaryText = nil
        scanStatusText = "正在扫描缓存、旧版本、对话与 Worktree…"

        let retentionDays = retentionPolicy.rawValue

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let matcher = CleanWhitelistMatcher.shared
            let now = Date()

            var foundTools = Set<String>()
            var collected: [AICleanItem] = []

            // 1. Band 1 — Safe Caches, Old Versions & Leftovers
            await self?.updateScanStatus("正在扫描 AI 工具缓存与旧版本…")
            let cacheSpecs: [(tool: String, title: String, bundleID: String?, appName: String?, relPaths: [String])] = [
                ("Claude", "Claude Desktop 缓存与 Web 资源", "com.anthropic.claudefordesktop", "Claude", [
                    "Library/Application Support/Claude/Cache",
                    "Library/Application Support/Claude/Code Cache",
                    "Library/Application Support/Claude/GPUCache",
                    "Library/Application Support/Claude/DawnGraphiteCache",
                    "Library/Application Support/Claude/DawnWebGPUCache",
                    "Library/Application Support/Claude/blob_storage",
                    "Library/Caches/com.anthropic.claudefordesktop",
                    "Library/Caches/claude-cli-nodejs",
                    ".cache/claude",
                    ".claude/debug",
                    ".claude/shell-snapshots"
                ]),
                ("Codex", "Codex Desktop 缓存与运行时临时文件", "com.openai.codex", "Codex", [
                    "Library/Application Support/Codex/Cache",
                    "Library/Application Support/Codex/Code Cache",
                    "Library/Application Support/Codex/GPUCache",
                    "Library/Application Support/Codex/DawnGraphiteCache",
                    "Library/Application Support/Codex/DawnWebGPUCache",
                    "Library/Application Support/Codex/blob_storage",
                    "Library/Caches/Codex",
                    ".cache/codex-runtimes",
                    ".codex/log",
                    ".codex/crash_reports"
                ]),
                ("ChatGPT", "ChatGPT Desktop 网页与 GPU 缓存", "com.openai.chat", "ChatGPT", [
                    "Library/Application Support/com.openai.chat/Cache",
                    "Library/Application Support/com.openai.chat/Code Cache",
                    "Library/Application Support/com.openai.chat/GPUCache",
                    "Library/Caches/ChatGPTHelper",
                    "Library/Caches/com.openai.chat"
                ]),
                ("Cursor", "Cursor 编辑器渲染与日志缓存（保护登录态与设置）", "com.todesktop.230313mzl4w4u92", "Cursor", [
                    "Library/Application Support/Cursor/Cache",
                    "Library/Application Support/Cursor/CachedData",
                    "Library/Application Support/Cursor/GPUCache",
                    "Library/Application Support/Cursor/Code Cache",
                    "Library/Application Support/Cursor/logs",
                    ".cache/cursor-agent",
                    ".cursor/agent-transcripts"
                ]),
                ("Antigravity", "Antigravity / Antigravity IDE 缓存与临时上下文", "com.google.antigravity", "Antigravity", [
                    "Library/Application Support/Antigravity/Cache",
                    "Library/Application Support/Antigravity/Code Cache",
                    "Library/Application Support/Antigravity/GPUCache",
                    "Library/Application Support/Antigravity/DawnGraphiteCache",
                    "Library/Application Support/Antigravity/DawnWebGPUCache",
                    "Library/Application Support/Antigravity/blob_storage",
                    "Library/Application Support/Antigravity IDE/Cache",
                    "Library/Application Support/Antigravity IDE/Code Cache",
                    "Library/Application Support/Antigravity IDE/GPUCache",
                    "Library/Application Support/Antigravity IDE/DawnGraphiteCache",
                    "Library/Application Support/Antigravity IDE/DawnWebGPUCache",
                    "Library/Application Support/Antigravity IDE/blob_storage",
                    ".gemini/tmp"
                ]),
                ("OpenCode", "OpenCode 运行日志与缓存", nil, "OpenCode", [
                    ".cache/opencode",
                    ".local/share/opencode/log",
                    ".local/share/opencode/snapshot"
                ]),
                ("Copilot", "GitHub Copilot 项目索引与 CLI 缓存", nil, "GitHub Copilot", [
                    ".cache/copilot",
                    ".cache/github-copilot"
                ]),
                ("LM Studio", "LM Studio 运行缓存", "ai.elementlabs.lmstudio", "LM Studio", [
                    "Library/Caches/com.lmstudio.lmstudio",
                    ".cache/vmlx-engine"
                ]),
                ("Comfy Desktop", "Comfy Desktop 运行缓存", nil, "Comfy Desktop", [
                    "Library/Application Support/Comfy Desktop/Cache",
                    "Library/Application Support/Comfy Desktop/GPUCache"
                ])
            ]

            for spec in cacheSpecs {
                if Task.isCancelled { return }
                var existingAllowed: [URL] = []
                var allowedBytes: Int64 = 0
                var blockedPaths: [URL] = []
                var blockedBytes: Int64 = 0
                var firstBlockReason: String?

                for rel in spec.relPaths {
                    let url = home.appendingPathComponent(rel)
                    guard fm.fileExists(atPath: url.path) else { continue }
                    foundTools.insert(spec.tool)
                    let sz = SystemCleanerEngine.calculateItemOrDirectorySize(url: url)
                    guard sz > 1024 * 128 else { continue }
                    let verdict = matcher.evaluateForAIToolCleanup(url: url)
                    if verdict.isAllowed {
                        existingAllowed.append(url)
                        allowedBytes += sz
                    } else {
                        blockedPaths.append(url)
                        blockedBytes += sz
                        if firstBlockReason == nil {
                            firstBlockReason = verdict.detailText
                        }
                    }
                }

                if allowedBytes > 1024 * 512 { // > 512 KB
                    collected.append(
                        AICleanItem(
                            band: .safeCaches,
                            kind: .cache,
                            toolName: spec.tool,
                            title: spec.title,
                            detail: "包含 \(existingAllowed.count) 处可自动重建缓存目录（保留对话、配置与本地模型）",
                            paths: existingAllowed,
                            sizeBytes: allowedBytes,
                            ownerBundleID: spec.bundleID,
                            ownerAppName: spec.appName,
                            matchedCount: existingAllowed.count
                        )
                    )
                }
                if blockedBytes > 1024 * 512, let firstReason = firstBlockReason {
                    collected.append(
                        AICleanItem(
                            band: .safeCaches,
                            kind: .cache,
                            toolName: spec.tool,
                            title: "\(spec.title)（受白名单保护）",
                            detail: firstReason,
                            paths: blockedPaths,
                            sizeBytes: blockedBytes,
                            isProtected: true,
                            guardReason: firstReason,
                            matchedCount: blockedPaths.count,
                            isSelectable: false
                        )
                    )
                }
            }

            // Old versions of standalone Codex / CLI packages
            let codexVersionsDir = home.appendingPathComponent(".codex/packages/standalone/versions", isDirectory: true)
            if fm.fileExists(atPath: codexVersionsDir.path),
               let versions = try? fm.contentsOfDirectory(at: codexVersionsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
               versions.count > 1 {
                foundTools.insert("Codex")
                let sorted = versions.sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
                let oldDirs = Array(sorted.dropFirst())
                let oldBytes = oldDirs.reduce(Int64(0)) { $0 + SystemCleanerEngine.calculateDirectorySize(url: $1) }
                if oldBytes > 1024 * 1024 {
                    let verdict = matcher.evaluateForAIToolCleanup(url: codexVersionsDir)
                    collected.append(
                        AICleanItem(
                            band: .safeCaches,
                            kind: .oldVersion,
                            toolName: "Codex",
                            title: "Codex CLI 旧版本二进制 (\(oldDirs.count) 个)",
                            detail: "已保留最新当前版本，旧版本可直接清理",
                            paths: oldDirs,
                            sizeBytes: oldBytes,
                            isProtected: !verdict.isAllowed,
                            guardReason: verdict.detailText,
                            matchedCount: oldDirs.count
                        )
                    )
                }
            }

            // Uninstalled leftover AI tool folders
            let leftoverCandidates: [(tool: String, appPaths: [String], dirRel: String)] = [
                ("Kiro", ["/Applications/Kiro.app"], ".kiro"),
                ("Trae", ["/Applications/Trae.app", "/Applications/Trae CN.app"], ".trae"),
                ("Trae CN", ["/Applications/Trae CN.app"], ".trae-cn"),
                ("Windsurf", ["/Applications/Windsurf.app"], ".codeium/windsurf")
            ]
            for cand in leftoverCandidates {
                let isAppInstalled = cand.appPaths.contains { fm.fileExists(atPath: $0) }
                let dirURL = home.appendingPathComponent(cand.dirRel, isDirectory: true)
                if !isAppInstalled, fm.fileExists(atPath: dirURL.path) {
                    let sz = SystemCleanerEngine.calculateDirectorySize(url: dirURL)
                    if sz > 1024 * 1024 * 5 {
                        let verdict = matcher.evaluateForAIToolCleanup(url: dirURL)
                        collected.append(
                            AICleanItem(
                                band: .safeCaches,
                                kind: .toolLeftover,
                                toolName: cand.tool,
                                title: "\(cand.tool) 遗留配置目录 (~/\(cand.dirRel))",
                                detail: "未检测到对应的 \(cand.tool) 应用，属于卸载或停用残留",
                                paths: [dirURL],
                                sizeBytes: sz,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText
                            )
                        )
                    }
                }
            }

            // 2. Band 2 — Sessions (by Retention Days) & Git Worktrees
            await self?.updateScanStatus("正在按保留策略扫描对话记录…")
            let cutoffDate: Date? = retentionDays > 0
                ? Calendar.current.date(byAdding: .day, value: -retentionDays, to: now)
                : nil

            // 2.1 Claude Code sessions (~/.claude/projects)
            let claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
            if fm.fileExists(atPath: claudeProjects.path) {
                foundTools.insert("Claude Code")
                if let projectDirs = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    var expiredFiles: [URL] = []
                    var expiredBytes: Int64 = 0
                    var orphanFiles: [URL] = []
                    var orphanBytes: Int64 = 0
                    var topProjectName = ""
                    var topProjectCount = 0

                    for projDir in projectDirs {
                        guard let sessionFiles = try? fm.contentsOfDirectory(at: projDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                        let projRawName = projDir.lastPathComponent
                        var projExpired = 0

                        // Claude Code encodes folder paths as `-Users-name-...`
                        let decodedPath = "/" + projRawName.dropFirst().replacingOccurrences(of: "-", with: "/")
                        let isOrphan = projRawName.hasPrefix("-") && !fm.fileExists(atPath: decodedPath)

                        for f in sessionFiles where f.pathExtension == "jsonl" || f.pathExtension == "json" {
                            let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                            let fSize = vals?.fileSize.map(Int64.init) ?? 0
                            let fDate = vals?.contentModificationDate ?? now

                            if isOrphan {
                                orphanFiles.append(f)
                                orphanBytes += fSize
                            } else if let cutoffDate, fDate < cutoffDate {
                                expiredFiles.append(f)
                                expiredBytes += fSize
                                projExpired += 1
                            }
                        }

                        if projExpired > topProjectCount {
                            topProjectCount = projExpired
                            topProjectName = projDir.lastPathComponent
                        }
                    }

                    let verdict = matcher.evaluateForAIToolCleanup(url: claudeProjects)
                    if !expiredFiles.isEmpty {
                        collected.append(
                            AICleanItem(
                                band: .reviewSessions,
                                kind: .sessionHistory,
                                toolName: "Claude Code",
                                title: "Claude Code 聊天记录（\(expiredFiles.count) 个对话超过 \(retentionDays) 天）",
                                detail: topProjectName.isEmpty ? "已按保留天数筛选，移入废纸篓可随时找回" : "主要来自 \(topProjectName) · 清理前将导出恢复指引",
                                paths: expiredFiles,
                                sizeBytes: expiredBytes,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText,
                                matchedCount: expiredFiles.count
                            )
                        )
                    }
                    if !orphanFiles.isEmpty && orphanBytes > 1024 * 512 {
                        collected.append(
                            AICleanItem(
                                band: .reviewSessions,
                                kind: .orphanedAsset,
                                toolName: "Claude Code",
                                title: "找不到项目目录的 Claude 对话（\(orphanFiles.count) 个）",
                                detail: "对应工程文件夹已从磁盘删除或移动，请复核后再清理",
                                paths: orphanFiles,
                                sizeBytes: orphanBytes,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText,
                                matchedCount: orphanFiles.count
                            )
                        )
                    }
                }
            }

            // 2.2 Codex sessions & orphaned visualizations (~/.codex/sessions, archived_sessions, visualizations)
            let codexSessionsDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
            let codexArchivedDir = home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
            let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
            if fm.fileExists(atPath: codexRoot.path) {
                foundTools.insert("Codex")
                if let cutoffDate {
                    let collectedSessions = Self.collectOldFiles(in: [codexSessionsDir, codexArchivedDir], olderThan: cutoffDate)
                    let oldSessions = collectedSessions.urls
                    let oldBytes = collectedSessions.bytes
                    if !oldSessions.isEmpty {
                        let verdict = matcher.evaluateForAIToolCleanup(url: codexSessionsDir)
                        collected.append(
                            AICleanItem(
                                band: .reviewSessions,
                                kind: .sessionHistory,
                                toolName: "Codex",
                                title: "Codex 聊天记录（\(oldSessions.count) 个超过 \(retentionDays) 天）",
                                detail: "清理后无法在 Codex 中继续历史会话，建议开启废纸篓或恢复副本",
                                paths: oldSessions,
                                sizeBytes: oldBytes,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText,
                                ownerBundleID: "com.openai.codex",
                                ownerAppName: "Codex",
                                matchedCount: oldSessions.count
                            )
                        )
                    }
                }

                let vizDir = home.appendingPathComponent(".codex/visualizations", isDirectory: true)
                if fm.fileExists(atPath: vizDir.path) {
                    let sz = SystemCleanerEngine.calculateDirectorySize(url: vizDir)
                    if sz > 1024 * 512 {
                        let verdict = matcher.evaluateForAIToolCleanup(url: vizDir)
                        collected.append(
                            AICleanItem(
                                band: .reviewSessions,
                                kind: .orphanedAsset,
                                toolName: "Codex",
                                title: "Codex 生成图像与可视化暂存",
                                detail: "位于 ~/.codex/visualizations · 确认不再需要对应图表后可清理",
                                paths: [vizDir],
                                sizeBytes: sz,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText
                            )
                        )
                    }
                }
            }

            // 2.3 Antigravity & Antigravity IDE conversations & brain artifacts
            let antigravityVariantRoots: [(relPath: String, label: String)] = [
                (".gemini/antigravity", "Antigravity"),
                (".gemini/antigravity-ide", "Antigravity IDE")
            ]
            for variant in antigravityVariantRoots {
                let antigravityDir = home.appendingPathComponent(variant.relPath, isDirectory: true)
                guard fm.fileExists(atPath: antigravityDir.path) else { continue }
                foundTools.insert("Antigravity")
                let convDir = antigravityDir.appendingPathComponent("conversations", isDirectory: true)
                let brainDir = antigravityDir.appendingPathComponent("brain", isDirectory: true)
                if let cutoffDate {
                    var expiredDirs: [URL] = []
                    var expiredBytes: Int64 = 0
                    for targetRoot in [convDir, brainDir] where fm.fileExists(atPath: targetRoot.path) {
                        if let subs = try? fm.contentsOfDirectory(at: targetRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                            for sub in subs {
                                let mdate = (try? sub.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                                if mdate < cutoffDate {
                                    expiredDirs.append(sub)
                                    expiredBytes += SystemCleanerEngine.calculateItemOrDirectorySize(url: sub)
                                }
                            }
                        }
                    }
                    if !expiredDirs.isEmpty && expiredBytes > 1024 * 1024 {
                        let verdict = matcher.evaluateForAIToolCleanup(url: antigravityDir)
                        collected.append(
                            AICleanItem(
                                band: .reviewSessions,
                                kind: .sessionHistory,
                                toolName: "Antigravity",
                                title: "\(variant.label) 历史对话与 Brain Artifacts（\(expiredDirs.count) 项超过 \(retentionDays) 天）",
                                detail: "包含超期未活跃的任务上下文与截图产出，移至废纸篓前可预览",
                                paths: expiredDirs,
                                sizeBytes: expiredBytes,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText,
                                matchedCount: expiredDirs.count
                            )
                        )
                    }
                }
            }

            // Surface ~/.gemini/antigravity-backup safely as read-only advisory archive (never auto-cleaned)
            let antigravityBackupDir = home.appendingPathComponent(".gemini/antigravity-backup", isDirectory: true)
            if fm.fileExists(atPath: antigravityBackupDir.path) {
                foundTools.insert("Antigravity")
                let backupBytes = SystemCleanerEngine.calculateDirectorySize(url: antigravityBackupDir)
                if backupBytes > 1024 * 1024 * 10 {
                    collected.append(
                        AICleanItem(
                            band: .toolsMaintenance,
                            kind: .localModel,
                            toolName: "Antigravity",
                            title: "Antigravity 本地备份归档 (.gemini/antigravity-backup)",
                            detail: "仅展示占用以便排查磁盘去向，已开启只读保护，如需清理请右键在访达中手动核对",
                            paths: [antigravityBackupDir],
                            sizeBytes: backupBytes,
                            isProtected: true,
                            guardReason: "安全保护归档 · 禁止自动删除",
                            isSelectable: false
                        )
                    )
                }
            }

            // 2.4 Git Worktree Inspector
            await self?.updateScanStatus("正在核对 Git Worktree 提交与工作区状态…")
            let worktreeItems = Self.inspectAIWorktrees(home: home, now: now, matcher: matcher)
            if !worktreeItems.isEmpty {
                foundTools.insert("Git Worktrees")
                collected.append(contentsOf: worktreeItems)
            }

            // 3. Band 3 — Tools Maintenance (SQLite VACUUM & Local Models)
            await self?.updateScanStatus("正在扫描数据库空间与本地大模型权重…")
            let sqliteTargets: [(tool: String, appName: String?, bundleID: String?, relPath: String)] = [
                ("Copilot", nil, nil, ".copilot/session-store.db"),
                ("OpenCode", "OpenCode", nil, ".local/share/opencode/opencode.db"),
                ("Cursor", "Cursor", "com.todesktop.230313mzl4w4u92", "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            ]
            for spec in sqliteTargets {
                let dbURL = home.appendingPathComponent(spec.relPath)
                guard fm.fileExists(atPath: dbURL.path) else { continue }
                foundTools.insert(spec.tool)
                let dbSize = SystemCleanerEngine.calculateItemOrDirectorySize(url: dbURL)
                let walSize = SystemCleanerEngine.calculateItemOrDirectorySize(url: URL(fileURLWithPath: dbURL.path + "-wal"))
                let totalDB = dbSize + walSize
                if totalDB > 1024 * 1024 * 10 { // > 10 MB
                    collected.append(
                        AICleanItem(
                            band: .toolsMaintenance,
                            kind: .sqliteDatabase,
                            toolName: spec.tool,
                            title: "压缩 \(spec.tool) SQLite 数据库",
                            detail: "不删除任何对话，仅执行 SQLite VACUUM 释放空闲页（操作前需先退出 \(spec.appName ?? spec.tool)）",
                            paths: [dbURL],
                            sizeBytes: totalDB,
                            ownerBundleID: spec.bundleID,
                            ownerAppName: spec.appName ?? spec.tool,
                            isSelectable: false
                        )
                    )
                }
            }

            // Local Ollama & LM Studio Models
            let ollamaModels = Self.inspectOllamaModels(home: home, matcher: matcher)
            if !ollamaModels.isEmpty {
                foundTools.insert("Ollama")
                collected.append(contentsOf: ollamaModels)
            }

            let lmStudioModelsDir = home.appendingPathComponent(".lmstudio/models", isDirectory: true)
            if fm.fileExists(atPath: lmStudioModelsDir.path) {
                foundTools.insert("LM Studio")
                let sz = SystemCleanerEngine.calculateDirectorySize(url: lmStudioModelsDir)
                if sz > 1024 * 1024 * 100 {
                    let verdict = matcher.evaluateForAIToolCleanup(url: lmStudioModelsDir)
                    collected.append(
                        AICleanItem(
                            band: .toolsMaintenance,
                            kind: .localModel,
                            toolName: "LM Studio",
                            title: "LM Studio 本地模型仓库",
                            detail: verdict.isAllowed ? "包含 GGUF / MLX 权重文件，建议按需确认清理" : (verdict.detailText ?? "受保护"),
                            paths: [lmStudioModelsDir],
                            sizeBytes: sz,
                            isProtected: !verdict.isAllowed,
                            guardReason: verdict.detailText
                        )
                    )
                }
            }

            collected.sort {
                if $0.band != $1.band { return $0.band.rawValue < $1.band.rawValue }
                return $0.sizeBytes > $1.sizeBytes
            }

            let toolList = Array(foundTools).sorted()
            await self?.finishScan(items: collected, tools: toolList)
        }
    }

    private func updateScanStatus(_ text: String) {
        self.scanStatusText = text
    }

    private func finishScan(items: [AICleanItem], tools: [String]) {
        self.items = items
        self.detectedToolNames = tools
        self.lastScanDate = Date()
        self.isScanning = false
        self.scanStatusText = items.isEmpty
            ? "未发现需要维护的 AI 工具垃圾或过期对话"
            : "已扫描 \(tools.count) 个 AI 工具 · 发现可安全释放与待复核项目"

        // 默认只自动选中 Band 1 (安全缓存与旧版本) 中未被保护的项
        self.selectedIDs = Set(
            items.filter { $0.band == .safeCaches && $0.isSelectable }.map(\.id)
        )
    }

    // MARK: - Cleaning, Recovery Backup & SQLite VACUUM

    public func executeSelectedClean() {
        if let readFailure = CleanProtectionStore.shared.readFailureReason() {
            lastSummaryText = readFailure
            return
        }
        let targets = items.filter { selectedIDs.contains($0.id) && $0.isSelectable }
        guard !targets.isEmpty else { return }

        if let conflicts = findRunningConflicts(for: targets), !conflicts.isEmpty {
            self.pendingQuitConflicts = conflicts
            self.pendingActionType = .cleanSelected
            self.isQuitConflictModalPresented = true
            return
        }

        performClean(targets: targets)
    }

    public func compactDatabase(_ item: AICleanItem) {
        guard item.kind == .sqliteDatabase else { return }
        if let conflicts = findRunningConflicts(for: [item]), !conflicts.isEmpty {
            self.pendingQuitConflicts = conflicts
            self.pendingActionType = .vacuumDB(item)
            self.isQuitConflictModalPresented = true
            return
        }
        performVacuum(item: item)
    }

    public func resolveQuitConflict(quitApps: Bool) {
        self.isQuitConflictModalPresented = false
        let conflicts = pendingQuitConflicts
        pendingQuitConflicts = []

        if quitApps {
            for c in conflicts {
                for app in NSWorkspace.shared.runningApplications {
                    let matchBundle = c.bundleID != nil && app.bundleIdentifier?.caseInsensitiveCompare(c.bundleID!) == .orderedSame
                    let matchName = app.localizedName?.localizedCaseInsensitiveContains(c.appName) == true
                    if matchBundle || matchName {
                        app.terminate()
                    }
                }
            }
        }

        let action = pendingActionType
        Task { @MainActor [weak self] in
            if quitApps {
                try? await Task.sleep(for: .milliseconds(750))
            }
            switch action {
            case .cleanSelected:
                let targets = self?.items.filter { (self?.selectedIDs.contains($0.id) ?? false) && $0.isSelectable } ?? []
                if quitApps {
                    self?.performClean(targets: targets)
                }
            case .vacuumDB(let dbItem):
                if quitApps {
                    self?.performVacuum(item: dbItem)
                }
            }
        }
    }

    private func findRunningConflicts(for targets: [AICleanItem]) -> [AIRunningAppConflict]? {
        let running = NSWorkspace.shared.runningApplications
        var map: [String: AIRunningAppConflict] = [:]

        for item in targets {
            guard let appName = item.ownerAppName else { continue }
            let bundleID = item.ownerBundleID
            let matched = running.contains { app in
                if let bundleID, let rbid = app.bundleIdentifier, rbid.caseInsensitiveCompare(bundleID) == .orderedSame {
                    return true
                }
                return app.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }
            if matched {
                map[bundleID ?? appName] = AIRunningAppConflict(id: bundleID ?? appName, appName: appName, bundleID: bundleID)
            }
        }
        return map.isEmpty ? nil : Array(map.values)
    }

    private func performClean(targets: [AICleanItem]) {
        guard !targets.isEmpty else { return }
        isProcessing = true
        lastSummaryText = nil
        lastRecoveryInstructions = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let matcher = CleanWhitelistMatcher.shared
            var freed: Int64 = 0
            var processedCount = 0
            var hadSessionRecovery = false
            var recoveryDirPath: String?

            // 如果包含对话历史，提前创建恢复副本目录（放在废纸篓外独立备份或通过 trashItem 可找回）
            let hasSessions = targets.contains { $0.kind == .sessionHistory || $0.kind == .orphanedAsset }
            var recoveryDir: URL?
            if hasSessions {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd-HHmmss"
                let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("SysPulse/Recovery/AITools/\(df.string(from: Date()))", isDirectory: true)
                try? fm.createDirectory(at: base, withIntermediateDirectories: true)
                recoveryDir = base
                recoveryDirPath = base.path
            }

            for item in targets {
                if item.kind == .worktreeCleanable {
                    for wtURL in item.paths {
                        guard matcher.evaluateForAIToolCleanup(url: wtURL).isAllowed else { continue }
                        let sz = SystemCleanerEngine.calculateDirectorySize(url: wtURL)
                        if Self.removeGitWorktree(at: wtURL) {
                            freed += max(sz, item.sizeBytes / Int64(max(1, item.paths.count)))
                            processedCount += 1
                        }
                    }
                    continue
                }

                for url in item.paths {
                    guard matcher.evaluateForAIToolCleanup(url: url).isAllowed else { continue }
                    guard fm.fileExists(atPath: url.path) else { continue }
                    let sz = SystemCleanerEngine.calculateItemOrDirectorySize(url: url)

                    // 会话类额外留存恢复副本
                    if hasSessions && (item.kind == .sessionHistory || item.kind == .orphanedAsset), let recoveryDir {
                        let backupDest = recoveryDir.appendingPathComponent("\(item.toolName)-\(url.lastPathComponent)")
                        if (try? fm.copyItem(at: url, to: backupDest)) != nil {
                            hadSessionRecovery = true
                        }
                    }

                    // Band 2 对话统一进废纸篓留双保险；Band 1 缓存优先移入废纸篓或直接移除
                    do {
                        if item.band == .reviewSessions || item.kind == .localModel || item.kind == .toolLeftover {
                            try fm.trashItem(at: url, resultingItemURL: nil)
                        } else {
                            try fm.removeItem(at: url)
                        }
                        freed += sz
                        processedCount += 1
                    } catch {
                        // Ignore individual locked file errors
                    }
                }
            }

            let finalFreed = freed
            let finalCount = processedCount
            let recoveryTip = (hadSessionRecovery && recoveryDirPath != nil)
                ? "对话恢复副本已保存至：\(recoveryDirPath!)（同时对应文件已移到废纸篓，清倒前均可随时还原）。"
                : nil

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                let formatted = ByteCountFormatter.string(fromByteCount: finalFreed, countStyle: .file)
                self.lastSummaryText = "本次维护完成：已处理 \(finalCount) 个项目，释放 \(formatted)"
                self.lastRecoveryInstructions = recoveryTip
                self.scanAITools()
            }
        }
    }

    private func performVacuum(item: AICleanItem) {
        guard let dbURL = item.primaryPath else { return }
        isProcessing = true
        let initialSize = item.sizeBytes

        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let backupURL = URL(fileURLWithPath: dbURL.path + ".syspulse-vacuum-bak")
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: dbURL, to: backupURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [dbURL.path, "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"]
            let errPipe = Pipe()
            process.standardError = errPipe

            var succeeded = false
            do {
                try process.run()
                process.waitUntilExit()
                succeeded = (process.terminationStatus == 0)
            } catch {
                succeeded = false
            }

            if !succeeded {
                if fm.fileExists(atPath: backupURL.path) {
                    try? fm.removeItem(at: dbURL)
                    try? fm.moveItem(at: backupURL, to: dbURL)
                }
            } else {
                try? fm.removeItem(at: backupURL)
            }

            let afterSize = SystemCleanerEngine.calculateItemOrDirectorySize(url: dbURL)
                + SystemCleanerEngine.calculateItemOrDirectorySize(url: URL(fileURLWithPath: dbURL.path + "-wal"))
            let saved = max(0, initialSize - afterSize)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                if succeeded {
                    let savedStr = ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)
                    self.lastSummaryText = "\(item.toolName) 数据库已压缩完成，回收空闲页 \(savedStr)"
                } else {
                    self.lastSummaryText = "\(item.toolName) 数据库正在被占用或受锁，已安全回滚未做更改"
                }
                self.scanAITools()
            }
        }
    }

    // MARK: - Worktree & Ollama Inspectors

    nonisolated private static func inspectAIWorktrees(
        home: URL,
        now: Date,
        matcher: CleanWhitelistMatcher
    ) -> [AICleanItem] {
        let fm = FileManager.default
        let roots = [
            home.appendingPathComponent(".claude/worktrees", isDirectory: true),
            home.appendingPathComponent(".codex/worktrees", isDirectory: true)
        ]

        var cleanableURLs: [URL] = []
        var cleanableBytes: Int64 = 0
        var keptResults: [AICleanItem] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for wtURL in children {
                let isDir = (try? wtURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { continue }
                let size = SystemCleanerEngine.calculateDirectorySize(url: wtURL)
                guard size > 1024 * 64 else { continue }

                var reasons: [String] = []
                let gitDirMarker = wtURL.appendingPathComponent(".git")
                let mdate = (try? wtURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(mdate) < 24 * 3600 {
                    reasons.append("24 小时内有活动")
                }

                if fm.fileExists(atPath: gitDirMarker.path) {
                    if let gitDirRaw = runGit(in: wtURL, args: ["rev-parse", "--git-dir"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !gitDirRaw.isEmpty {
                        let gitDirURL = gitDirRaw.hasPrefix("/")
                            ? URL(fileURLWithPath: gitDirRaw, isDirectory: true)
                            : wtURL.appendingPathComponent(gitDirRaw, isDirectory: true)
                        if fm.fileExists(atPath: gitDirURL.appendingPathComponent("index.lock").path) {
                            reasons.append("存在 .git/index.lock 活跃锁")
                        }
                    }

                    if let statusOut = runGit(in: wtURL, args: ["status", "--porcelain"]) {
                        if !statusOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            reasons.append("有未提交的改动或新文件")
                        }
                    } else {
                        reasons.append("无法确认 Git 状态")
                    }

                    if let subOut = runGit(in: wtURL, args: ["submodule", "status"]),
                       !subOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reasons.append("含有已初始化的子模块")
                    }

                    let mainBranch = ["main", "master"].first { branch in
                        runGit(in: wtURL, args: ["rev-parse", "--verify", "--quiet", branch]) != nil
                    }
                    if let mainBranch {
                        let isMerged = runGit(in: wtURL, args: ["merge-base", "--is-ancestor", "HEAD", mainBranch]) != nil
                        if !isMerged {
                            reasons.append("改动尚未合并到 \(mainBranch)")
                        }
                    } else if let unpushedOut = runGit(in: wtURL, args: ["log", "HEAD", "--not", "--remotes", "--oneline"]),
                              !unpushedOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reasons.append("有仅保存在此目录的本地提交")
                    }
                } else {
                    reasons.append("无法确认 Git 状态")
                }

                let verdict = matcher.evaluateForAIToolCleanup(url: wtURL)
                if reasons.isEmpty && verdict.isAllowed {
                    cleanableURLs.append(wtURL)
                    cleanableBytes += size
                } else {
                    keptResults.append(
                        AICleanItem(
                            band: .reviewSessions,
                            kind: .worktreeKept,
                            toolName: "Git Worktree",
                            title: "已保留 worktree: \(wtURL.lastPathComponent)",
                            detail: wtURL.path,
                            paths: [wtURL],
                            sizeBytes: size,
                            isProtected: true,
                            guardReason: reasons.isEmpty ? verdict.detailText : reasons.joined(separator: " · "),
                            keepReasons: reasons,
                            isSelectable: false
                        )
                    )
                }
            }
        }

        var items: [AICleanItem] = []
        if !cleanableURLs.isEmpty {
            items.append(
                AICleanItem(
                    band: .reviewSessions,
                    kind: .worktreeCleanable,
                    toolName: "Git Worktree",
                    title: "已完成的 AI Worktree（\(cleanableURLs.count) 个）",
                    detail: "改动均已合并到主分支且工作区干净（无 index.lock）· 仅移除工作目录，Git 分支与提交记录保留",
                    paths: cleanableURLs,
                    sizeBytes: cleanableBytes,
                    matchedCount: cleanableURLs.count
                )
            )
        }
        items.append(contentsOf: keptResults)
        return items
    }

    nonisolated private static func inspectOllamaModels(
        home: URL,
        matcher: CleanWhitelistMatcher
    ) -> [AICleanItem] {
        let fm = FileManager.default
        let ollamaModels = home.appendingPathComponent(".ollama/models", isDirectory: true)
        guard fm.fileExists(atPath: ollamaModels.path) else { return [] }

        let totalBytes = SystemCleanerEngine.calculateDirectorySize(url: ollamaModels)
        guard totalBytes > 1024 * 1024 * 50 else { return [] }

        // Parse manifest model tags
        var modelNames: [String] = []
        let manifestsDir = ollamaModels.appendingPathComponent("manifests/registry.ollama.ai/library", isDirectory: true)
        if let libs = try? fm.contentsOfDirectory(at: manifestsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for lib in libs {
                if let tags = try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for tag in tags {
                        modelNames.append("\(lib.lastPathComponent):\(tag.lastPathComponent)")
                    }
                }
            }
        }

        let verdict = matcher.evaluateForAIToolCleanup(url: ollamaModels)
        let previewModels = modelNames.isEmpty ? "Ollama 模型权重" : modelNames.prefix(4).joined(separator: ", ") + (modelNames.count > 4 ? " 等 \(modelNames.count) 个模型" : "")

        return [
            AICleanItem(
                band: .toolsMaintenance,
                kind: .localModel,
                toolName: "Ollama",
                title: "Ollama 本地模型（\(previewModels)）",
                detail: verdict.isAllowed
                    ? "可使用 ollama rm <模型> 精确删除，或移到废纸篓（之后可用 ollama pull 重下）"
                    : "默认受 ~/.config/syspulse/whitelist 保护，建议用 ollama list / ollama rm 管理",
                paths: [ollamaModels],
                sizeBytes: totalBytes,
                isProtected: !verdict.isAllowed,
                guardReason: verdict.detailText,
                cliHintCommand: "ollama list && ollama rm <model>"
            )
        ]
    }

    nonisolated private static func collectOldFiles(in directories: [URL], olderThan cutoffDate: Date) -> (urls: [URL], bytes: Int64) {
        let fm = FileManager.default
        var urls: [URL] = []
        var total: Int64 = 0
        for dir in directories where fm.fileExists(atPath: dir.path) {
            guard let enumr = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumr {
                let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard vals?.isRegularFile == true else { continue }
                if let mdate = vals?.contentModificationDate, mdate < cutoffDate {
                    urls.append(fileURL)
                    total += Int64(vals?.fileSize ?? 0)
                }
            }
        }
        return (urls, total)
    }

    nonisolated private static func runGit(in directory: URL, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", directory.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    nonisolated private static func removeGitWorktree(at url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", url.path, "worktree", "remove", "--force", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 && !FileManager.default.fileExists(atPath: url.path) {
                return true
            }
        }
        return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }
}
