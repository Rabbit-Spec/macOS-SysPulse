import Foundation
import SwiftUI
import AppKit
import CoreServices
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
    case staleHooksAndMCP
    case duplicateSessions
    case codexProjectFolder
    case worktreeCleanable
    case worktreeKept
    case sqliteDatabase
    case localModel
    case idleTool
}

public struct StaleHookMCPRef: Sendable, Equatable {
    public let sectionKey: String
    public let entryIdentifier: String
    public let missingTargetPath: String

    public init(sectionKey: String, entryIdentifier: String, missingTargetPath: String) {
        self.sectionKey = sectionKey
        self.entryIdentifier = entryIdentifier
        self.missingTargetPath = missingTargetPath
    }
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
    public let defaultChecked: Bool
    public let staleConfigRefs: [StaleHookMCPRef]
    public let ollamaModelTag: String?

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
        isSelectable: Bool = true,
        defaultChecked: Bool = true,
        staleConfigRefs: [StaleHookMCPRef] = [],
        ollamaModelTag: String? = nil
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
        self.defaultChecked = defaultChecked
        self.staleConfigRefs = staleConfigRefs
        self.ollamaModelTag = ollamaModelTag
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
    public var retentionTierPreviews: [Int: (count: Int, bytes: Int64)] = [:]

    public func retentionPickerLabel(for policy: AIRetentionPolicy) -> String {
        guard policy != .never,
              let preview = retentionTierPreviews[policy.rawValue],
              preview.count > 0 else {
            return policy.title
        }
        let sz = ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file)
        return "\(policy.title) (\(preview.count) · \(sz))"
    }

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

    public var selectedCount: Int {
        items.filter { selectedIDs.contains($0.id) && $0.isSelectable }.count
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
        selectAll(in: .safeCaches)
    }

    public func selectAll(in band: AICleanBand) {
        for item in items(in: band) where Self.isEligibleForSelectAll(item) {
            selectedIDs.insert(item.id)
        }
    }

    public func areDefaultItemsAllSelected(in band: AICleanBand) -> Bool {
        let eligible = items(in: band).filter { Self.isEligibleForSelectAll($0) }
        guard !eligible.isEmpty else { return false }
        return eligible.allSatisfy { selectedIDs.contains($0.id) }
    }

    nonisolated public static func isEligibleForSelectAll(_ item: AICleanItem) -> Bool {
        guard item.isSelectable && item.defaultChecked else { return false }
        return !item.paths.contains { isPathInTrash($0.path) }
    }

    nonisolated public static func isPathInTrash(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return components.contains { component in
            component == ".Trash" || component == ".Trashes" || component == ".trash" || component == "Trash"
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
                ("Comfy Desktop", "Comfy Desktop 运行与下载缓存", nil, "Comfy Desktop", [
                    "Library/Application Support/Comfy Desktop/Cache",
                    "Library/Application Support/Comfy Desktop/GPUCache",
                    "Library/Application Support/Comfy Desktop/download-cache"
                ]),
                ("Windsurf", "Windsurf 编辑器渲染与日志缓存", "com.exafunction.windsurf", "Windsurf", [
                    "Library/Application Support/Windsurf/Cache",
                    "Library/Application Support/Windsurf/CachedData",
                    "Library/Application Support/Windsurf/GPUCache",
                    "Library/Application Support/Windsurf/Code Cache",
                    "Library/Application Support/Windsurf/logs"
                ]),
                ("Zed", "Zed 编辑器 AI / Node 运行缓存", "dev.zed.Zed", "Zed", [
                    "Library/Application Support/Zed/node/cache"
                ]),
                ("iFlow", "iFlow CLI 临时运行文件", nil, "iFlow", [
                    ".iflow/tmp"
                ]),
                ("QwenWork", "千问办公桌面端缓存", "cn.qwenwork.desktop.mac", "QwenWork", [
                    ".qwenworkcn/cache/dws-releases",
                    "Library/Application Support/QwenWorkCN/Cache",
                    "Library/Application Support/QwenWorkCN/Code Cache",
                    "Library/Application Support/QwenWorkCN/GPUCache",
                    "Library/Caches/cn.qwenwork.desktop.mac"
                ]),
                ("DoubaoWork", "豆包工作桌面端缓存", "com.bytedance.doubaowork", "DoubaoWork", [
                    "Library/Application Support/DoubaoWork/gecko_cache",
                    "Library/Application Support/DoubaoWork/sandbox_runtime/downloads",
                    "Library/Caches/DoubaoWork"
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
                    guard !Self.isPathInTrash(url.path) else { continue }
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

            if fm.fileExists(atPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
                || fm.fileExists(atPath: home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path) {
                foundTools.insert("Codex")
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
            var listedClaudeSessionURLs: Set<URL> = []
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
                        guard !Self.isPathInTrash(projDir.path) else { continue }
                        guard let sessionFiles = try? fm.contentsOfDirectory(at: projDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                        let projRawName = projDir.lastPathComponent
                        var projExpired = 0

                        // Claude Code encodes folder paths as `-Users-name-...`
                        let decodedPath = "/" + projRawName.dropFirst().replacingOccurrences(of: "-", with: "/")
                        let isOrphan = projRawName.hasPrefix("-") && !fm.fileExists(atPath: decodedPath)

                        for f in sessionFiles where f.pathExtension == "jsonl" || f.pathExtension == "json" {
                            guard !Self.isPathInTrash(f.path) else { continue }
                            let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                            let fSize = vals?.fileSize.map(Int64.init) ?? 0
                            let fDate = vals?.contentModificationDate ?? now

                            if isOrphan {
                                orphanFiles.append(f)
                                orphanBytes += fSize
                                listedClaudeSessionURLs.insert(f.standardizedFileURL)
                            } else if let cutoffDate, fDate < cutoffDate {
                                expiredFiles.append(f)
                                expiredBytes += fSize
                                projExpired += 1
                                listedClaudeSessionURLs.insert(f.standardizedFileURL)
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

                let vizDirs = [
                    home.appendingPathComponent(".codex/visualizations", isDirectory: true),
                    home.appendingPathComponent(".codex/generated_images", isDirectory: true)
                ]
                let activeCodexSessionIDs = Self.collectCodexActiveSessionIDs(dirs: [codexSessionsDir, codexArchivedDir])
                var orphanVizFiles: [URL] = []
                var orphanVizBytes: Int64 = 0
                for vDir in vizDirs where fm.fileExists(atPath: vDir.path) {
                    let orphan = Self.collectOrphanCodexAssets(in: vDir, activeSessionIDs: activeCodexSessionIDs)
                    orphanVizFiles.append(contentsOf: orphan.urls)
                    orphanVizBytes += orphan.bytes
                }
                if !orphanVizFiles.isEmpty && orphanVizBytes > 1024 * 128 {
                    let verdict = matcher.evaluateForAIToolCleanup(url: codexRoot.appendingPathComponent("visualizations"))
                    collected.append(
                        AICleanItem(
                            band: .reviewSessions,
                            kind: .orphanedAsset,
                            toolName: "Codex",
                            title: "Codex 孤立生成图与可视化附件（\(orphanVizFiles.count) 个）",
                            detail: "仅列出所属会话已删除的孤立配图（活跃会话配图已自动保护）",
                            paths: orphanVizFiles,
                            sizeBytes: orphanVizBytes,
                            isProtected: !verdict.isAllowed,
                            guardReason: verdict.detailText,
                            ownerBundleID: "com.openai.codex",
                            ownerAppName: "Codex",
                            matchedCount: orphanVizFiles.count
                        )
                    )
                }
            }

            // 2.2c 新一代 AI CLI 与 Agent 会话历史（Kimi / Goose / Amp / Factory / Grok / Hermes / OpenClaw / Pi）
            let modernSessionTools: [(tool: String, relDirs: [String])] = [
                ("Kimi CLI", [".kimi/sessions", ".kimi-code/sessions"]),
                ("Goose", [".local/share/goose/sessions"]),
                ("Amp", [".local/share/amp/threads"]),
                ("Factory", [".factory/sessions"]),
                ("Grok CLI", [".grok/sessions"]),
                ("Hermes", [".hermes/sessions"]),
                ("OpenClaw", [".openclaw/sessions"]),
                ("Pi Agent", [".pi/agent/sessions"])
            ]
            for spec in modernSessionTools {
                if Task.isCancelled { return }
                let existingDirs = spec.relDirs.map { home.appendingPathComponent($0, isDirectory: true) }.filter { fm.fileExists(atPath: $0.path) }
                guard !existingDirs.isEmpty else { continue }
                foundTools.insert(spec.tool)
                if let cutoffDate {
                    let oldSessions = Self.collectOldFiles(in: existingDirs, olderThan: cutoffDate)
                    if !oldSessions.urls.isEmpty && oldSessions.bytes > 1024 * 32 {
                        let verdict = matcher.evaluateForAIToolCleanup(url: existingDirs[0])
                        collected.append(
                            AICleanItem(
                                band: .reviewSessions,
                                kind: .sessionHistory,
                                toolName: spec.tool,
                                title: "\(spec.tool) 聊天记录（\(oldSessions.urls.count) 个超过 \(retentionDays) 天）",
                                detail: "超期会话记录，清理前将备份恢复副本并移入废纸篓",
                                paths: oldSessions.urls,
                                sizeBytes: oldSessions.bytes,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText,
                                matchedCount: oldSessions.urls.count
                            )
                        )
                    }
                }
            }

            // 2.2b DeepSeek Harness sessions (~/.dsh/sessions, archived_sessions, *.jsonl)
            let dshRoot = home.appendingPathComponent(".dsh", isDirectory: true)
            if fm.fileExists(atPath: dshRoot.path) {
                foundTools.insert("DeepSeek Harness")
                if let cutoffDate {
                    let dshDirs = [
                        dshRoot.appendingPathComponent("sessions", isDirectory: true),
                        dshRoot.appendingPathComponent("archived_sessions", isDirectory: true)
                    ]
                    var dshCollected = Self.collectOldFiles(in: dshDirs, olderThan: cutoffDate)
                    if let rootEntries = try? fm.contentsOfDirectory(
                        at: dshRoot,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for f in rootEntries where f.pathExtension.lowercased() == "jsonl" {
                            guard !Self.isPathInTrash(f.path) else { continue }
                            let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                            guard vals?.isRegularFile == true else { continue }
                            if let mdate = vals?.contentModificationDate, mdate < cutoffDate {
                                dshCollected.urls.append(f)
                                dshCollected.bytes += Int64(vals?.fileSize ?? 0)
                            }
                        }
                    }
                    if !dshCollected.urls.isEmpty {
                        let verdict = matcher.evaluateForAIToolCleanup(url: dshRoot)
                        collected.append(
                            AICleanItem(
                                band: .reviewSessions,
                                kind: .sessionHistory,
                                toolName: "DeepSeek Harness",
                                title: "DeepSeek Harness 聊天记录（\(dshCollected.urls.count) 个超过 \(retentionDays) 天）",
                                detail: "来自 ~/.dsh 会话与归档记录 · 清理时移入废纸篓并保留恢复副本",
                                paths: dshCollected.urls,
                                sizeBytes: dshCollected.bytes,
                                isProtected: !verdict.isAllowed,
                                guardReason: verdict.detailText,
                                matchedCount: dshCollected.urls.count
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

            // 2.5 P1: 失效 Hook 与 MCP 服务器配置排查 (17 个 AI 配置 JSON)
            await self?.updateScanStatus("正在排查 AI 工具失效 Hook 与 MCP 配置…")
            let staleHookMCPItems = Self.inspectStaleHooksAndMCP(home: home, matcher: matcher)
            for item in staleHookMCPItems {
                foundTools.insert(item.toolName)
                collected.append(item)
            }

            // 2.6 P1: Claude Code 其他文件夹重复保存的旧对话
            let dupClaudeItems = Self.inspectDuplicateClaudeSessions(
                home: home,
                excluding: listedClaudeSessionURLs,
                matcher: matcher
            )
            if !dupClaudeItems.isEmpty {
                foundTools.insert("Claude Code")
                collected.append(contentsOf: dupClaudeItems)
            }

            // 2.7 P2: Codex 在文稿目录创建的项目文件夹 (~/Documents/Codex/*)
            let codexDocItems = Self.inspectCodexProjectFolders(home: home, now: now, matcher: matcher)
            if !codexDocItems.isEmpty {
                foundTools.insert("Codex")
                collected.append(contentsOf: codexDocItems)
            }

            // 3. Band 3 — Tools Maintenance (SQLite VACUUM, Local Models & Idle Tools)
            await self?.updateScanStatus("正在扫描数据库空间、本地大模型与闲置工具…")
            let sqliteTargets: [(tool: String, appName: String?, bundleID: String?, relPath: String)] = [
                ("Copilot", nil, nil, ".copilot/session-store.db"),
                ("OpenCode", "OpenCode", nil, ".local/share/opencode/opencode.db"),
                ("Cursor", "Cursor", "com.todesktop.230313mzl4w4u92", "Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
                ("Devin CLI", nil, nil, ".local/share/devin/cli/sessions.db"),
                ("Hermes", nil, nil, ".hermes/state.db"),
                ("Hermes Store", nil, nil, ".hermes/response_store.db")
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

            // Idle AI Desktop Apps (>30 days unused)
            let idleTools = Self.inspectIdleAITools(now: now)
            if !idleTools.isEmpty {
                collected.append(contentsOf: idleTools)
            }

            // Compute retention tier previews across [7, 14, 30, 90] days
            let tierPreviews = Self.computeRetentionTierPreviews(home: home, now: now)

            collected.sort {
                if $0.band != $1.band { return $0.band.rawValue < $1.band.rawValue }
                return $0.sizeBytes > $1.sizeBytes
            }

            let toolList = Array(foundTools).sorted()
            await self?.finishScan(items: collected, tools: toolList, tierPreviews: tierPreviews)
        }
    }

    private func updateScanStatus(_ text: String) {
        self.scanStatusText = text
    }

    private func finishScan(items: [AICleanItem], tools: [String], tierPreviews: [Int: (count: Int, bytes: Int64)]) {
        self.items = items
        self.detectedToolNames = tools
        self.retentionTierPreviews = tierPreviews
        self.lastScanDate = Date()
        self.isScanning = false
        self.scanStatusText = items.isEmpty
            ? "未发现需要维护的 AI 工具垃圾或过期对话"
            : "已扫描 \(tools.count) 个 AI 工具 · 发现可安全释放与待复核项目"

        // 默认只自动选中 Band 1 (安全缓存与旧版本) 中未被保护、允许默认勾选且不在废纸篓中的项
        self.selectedIDs = Set(
            items.filter { $0.band == .safeCaches && Self.isEligibleForSelectAll($0) }.map(\.id)
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
            let hasSessions = targets.contains {
                $0.kind == .sessionHistory || $0.kind == .orphanedAsset || $0.kind == .duplicateSessions
            }
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

                if item.kind == .staleHooksAndMCP {
                    for configURL in item.paths {
                        guard matcher.evaluateForAIToolCleanup(url: configURL).isAllowed else { continue }
                        guard fm.fileExists(atPath: configURL.path) else { continue }
                        let removedBytes = Self.cleanStaleHooksAndMCPConfig(at: configURL, refs: item.staleConfigRefs, home: fm.homeDirectoryForCurrentUser)
                        if removedBytes > 0 {
                            freed += removedBytes
                            processedCount += 1
                        }
                    }
                    continue
                }

                if item.kind == .idleTool {
                    for url in item.paths {
                        guard fm.fileExists(atPath: url.path) else { continue }
                        guard CleanProtectionStore.shared.matchedPattern(for: url.path) == nil else { continue }
                        let isAppInApplications = (url.path.hasPrefix("/Applications/") || url.path.hasPrefix("\(fm.homeDirectoryForCurrentUser.path)/Applications/"))
                            && url.pathExtension.lowercased() == "app"
                        guard isAppInApplications || matcher.evaluateForAIToolCleanup(url: url).isAllowed else { continue }
                        let sz = SystemCleanerEngine.calculateItemOrDirectorySize(url: url)
                        if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil {
                            freed += sz
                            processedCount += 1
                        }
                    }
                    continue
                }

                if item.kind == .localModel, let tag = item.ollamaModelTag {
                    if Self.removeOllamaModelViaCLI(modelTag: tag) {
                        freed += item.sizeBytes
                        processedCount += 1
                        continue
                    }
                }

                for url in item.paths {
                    guard matcher.evaluateForAIToolCleanup(url: url).isAllowed else { continue }
                    guard fm.fileExists(atPath: url.path) else { continue }
                    let sz = SystemCleanerEngine.calculateItemOrDirectorySize(url: url)

                    // 会话类额外留存恢复副本
                    if hasSessions && (item.kind == .sessionHistory || item.kind == .orphanedAsset || item.kind == .duplicateSessions), let recoveryDir {
                        let backupDest = recoveryDir.appendingPathComponent("\(item.toolName)-\(url.lastPathComponent)")
                        if (try? fm.copyItem(at: url, to: backupDest)) != nil {
                            hadSessionRecovery = true
                        }
                    }

                    // Band 2 对话、重复对话与文稿 Codex 项目目录统一移入废纸篓留双保险；Band 1 缓存直接移除
                    do {
                        if item.band == .reviewSessions
                            || item.kind == .localModel
                            || item.kind == .toolLeftover
                            || item.kind == .duplicateSessions
                            || item.kind == .codexProjectFolder {
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

        let manifestsRoot = ollamaModels.appendingPathComponent("manifests/registry.ollama.ai", isDirectory: true)
        let blobsDir = ollamaModels.appendingPathComponent("blobs", isDirectory: true)
        let verdict = matcher.evaluateForAIToolCleanup(url: ollamaModels)

        var perModelItems: [AICleanItem] = []
        let now = Date()

        // 遍历 registry.ollama.ai/<namespace>/<model>/<tag>
        if let namespaces = try? fm.contentsOfDirectory(at: manifestsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for ns in namespaces {
                guard let repos = try? fm.contentsOfDirectory(at: ns, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for repo in repos {
                    guard let tags = try? fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: [.contentModificationDateKey, .contentAccessDateKey], options: [.skipsHiddenFiles]) else { continue }
                    for tagURL in tags {
                        guard let data = try? Data(contentsOf: tagURL),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        var blobURLs: [URL] = []
                        var modelBytes: Int64 = 0
                        var digests: [String] = []
                        if let cfg = json["config"] as? [String: Any], let d = cfg["digest"] as? String {
                            digests.append(d)
                        }
                        if let layers = json["layers"] as? [[String: Any]] {
                            for layer in layers {
                                if let d = layer["digest"] as? String {
                                    digests.append(d)
                                }
                            }
                        }

                        for digest in digests {
                            let fileName = digest.replacingOccurrences(of: ":", with: "-")
                            let blobURL = blobsDir.appendingPathComponent(fileName)
                            if fm.fileExists(atPath: blobURL.path) {
                                blobURLs.append(blobURL)
                                modelBytes += SystemCleanerEngine.calculateItemOrDirectorySize(url: blobURL)
                            }
                        }
                        guard modelBytes > 1024 * 1024 else { continue }

                        let vals = try? tagURL.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
                        let lastUsed = vals?.contentAccessDate ?? vals?.contentModificationDate ?? now
                        let idleDays = max(0, Calendar.current.dateComponents([.day], from: lastUsed, to: now).day ?? 0)
                        let nsName = ns.lastPathComponent
                        let tagLabel = nsName == "library"
                            ? "\(repo.lastPathComponent):\(tagURL.lastPathComponent)"
                            : "\(nsName)/\(repo.lastPathComponent):\(tagURL.lastPathComponent)"

                        let idleNote = idleDays >= 14 ? "已闲置 \(idleDays) 天 · " : ""
                        let isSelectableModel = verdict.isAllowed || findOllamaBinaryPath() != nil

                        perModelItems.append(
                            AICleanItem(
                                band: .toolsMaintenance,
                                kind: .localModel,
                                toolName: "Ollama",
                                title: "Ollama 模型: \(tagLabel)",
                                detail: "\(idleNote)优先调用 ollama rm \(tagLabel) 安全移除（可随时重新 pull）",
                                paths: [tagURL],
                                sizeBytes: modelBytes,
                                isProtected: !isSelectableModel,
                                guardReason: isSelectableModel ? nil : verdict.detailText,
                                cliHintCommand: "ollama rm \(tagLabel)",
                                isSelectable: isSelectableModel,
                                defaultChecked: false,
                                ollamaModelTag: tagLabel
                            )
                        )
                    }
                }
            }
        }

        if !perModelItems.isEmpty {
            return perModelItems.sorted { $0.sizeBytes > $1.sizeBytes }
        }

        let totalBytes = SystemCleanerEngine.calculateDirectorySize(url: ollamaModels)
        guard totalBytes > 1024 * 1024 * 50 else { return [] }
        return [
            AICleanItem(
                band: .toolsMaintenance,
                kind: .localModel,
                toolName: "Ollama",
                title: "Ollama 本地模型仓库",
                detail: verdict.isAllowed
                    ? "可使用 ollama rm <模型> 精确删除，或移到废纸篓（之后可用 ollama pull 重下）"
                    : "默认受 ~/.config/syspulse/whitelist 保护，建议用 ollama list / ollama rm 管理",
                paths: [ollamaModels],
                sizeBytes: totalBytes,
                isProtected: !verdict.isAllowed,
                guardReason: verdict.detailText,
                cliHintCommand: "ollama list && ollama rm <model>",
                defaultChecked: false
            )
        ]
    }

    nonisolated private static func findOllamaBinaryPath() -> String? {
        let candidates = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func removeOllamaModelViaCLI(modelTag: String) -> Bool {
        guard let bin = findOllamaBinaryPath() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["rm", modelTag]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    nonisolated private static func inspectIdleAITools(now: Date) -> [AICleanItem] {
        let fm = FileManager.default
        let appCandidates: [(tool: String, appName: String, bundleID: String)] = [
            ("Cursor", "Cursor.app", "com.todesktop.230313mzl4w4u92"),
            ("Windsurf", "Windsurf.app", "com.exafunction.windsurf"),
            ("Claude", "Claude.app", "com.anthropic.claudefordesktop"),
            ("Codex", "Codex.app", "com.openai.codex"),
            ("ChatGPT", "ChatGPT.app", "com.openai.chat"),
            ("Cherry Studio", "Cherry Studio.app", "com.kangfenmao.CherryStudio"),
            ("LM Studio", "LM Studio.app", "ai.elementlabs.lmstudio"),
            ("Jan", "Jan.app", "jan.ai.app"),
            ("AnythingLLM", "AnythingLLM.app", "com.anythingllm"),
            ("Ollama", "Ollama.app", "com.electron.ollama"),
            ("Trae", "Trae.app", "com.trae.app"),
            ("Kiro", "Kiro.app", "dev.kiro.desktop"),
            ("Zed", "Zed.app", "dev.zed.Zed")
        ]

        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let homeApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let searchDirs = [URL(fileURLWithPath: "/Applications", isDirectory: true), homeApps]
        let thresholdDays = 30
        var results: [AICleanItem] = []

        for cand in appCandidates {
            if runningBundles.contains(cand.bundleID.lowercased()) { continue }
            var foundAppURL: URL?
            for dir in searchDirs {
                let candidateURL = dir.appendingPathComponent(cand.appName, isDirectory: true)
                if fm.fileExists(atPath: candidateURL.path) {
                    foundAppURL = candidateURL
                    break
                }
            }
            guard let appURL = foundAppURL else { continue }
            guard CleanProtectionStore.shared.matchedPattern(for: appURL.path) == nil else { continue }

            let lastUsed = lastUsedDate(for: appURL)
            guard let lastUsed else { continue }
            let idleDays = max(0, Calendar.current.dateComponents([.day], from: lastUsed, to: now).day ?? 0)
            guard idleDays >= thresholdDays else { continue }

            let appSize = SystemCleanerEngine.calculateDirectorySize(url: appURL, timeBudgetSeconds: 1.0)
            guard appSize > 1024 * 1024 * 10 else { continue }

            results.append(
                AICleanItem(
                    band: .toolsMaintenance,
                    kind: .idleTool,
                    toolName: cand.tool,
                    title: "长期闲置 AI 应用: \(cand.tool)（\(idleDays) 天未打开）",
                    detail: "清理仅将应用移入废纸篓，自动保留共享提示词、MCP 配置与密钥",
                    paths: [appURL],
                    sizeBytes: appSize,
                    ownerBundleID: cand.bundleID,
                    ownerAppName: cand.tool,
                    isSelectable: true,
                    defaultChecked: false
                )
            )
        }
        return results
    }

    nonisolated private static func lastUsedDate(for url: URL) -> Date? {
        if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
           let lastUsed = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
            return lastUsed
        }
        let rv = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        return rv?.contentAccessDate ?? rv?.contentModificationDate
    }

    nonisolated private static func collectCodexActiveSessionIDs(dirs: [URL]) -> Set<String> {
        let fm = FileManager.default
        var ids: Set<String> = []
        for dir in dirs where fm.fileExists(atPath: dir.path) {
            if let enumr = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let f as URL in enumr where f.pathExtension.lowercased() == "jsonl" {
                    let stem = f.deletingPathExtension().lastPathComponent.lowercased()
                    if !stem.isEmpty {
                        ids.insert(stem)
                        // 支持 rollout-<timestamp>-<uuid> 提取结尾 UUID
                        if stem.count >= 36 {
                            let tail = String(stem.suffix(36))
                            if UUID(uuidString: tail) != nil {
                                ids.insert(tail)
                            }
                        }
                    }
                }
            }
        }
        return ids
    }

    nonisolated private static func collectOrphanCodexAssets(in dir: URL, activeSessionIDs: Set<String>) -> (urls: [URL], bytes: Int64) {
        let fm = FileManager.default
        var urls: [URL] = []
        var total: Int64 = 0
        guard let enumr = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0)
        }
        for case let fileURL as URL in enumr {
            let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv?.isRegularFile == true else { continue }
            let pathLower = fileURL.path.lowercased()
            let matchesActiveSession = activeSessionIDs.contains { sid in
                pathLower.contains(sid)
            }
            if !matchesActiveSession {
                urls.append(fileURL)
                total += Int64(rv?.fileSize ?? 0)
            }
        }
        return (urls, total)
    }

    nonisolated private static func computeRetentionTierPreviews(home: URL, now: Date) -> [Int: (count: Int, bytes: Int64)] {
        let fm = FileManager.default
        var allSessionFiles: [(mdate: Date, bytes: Int64)] = []
        let candidateRoots: [URL] = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            home.appendingPathComponent(".dsh/sessions", isDirectory: true),
            home.appendingPathComponent(".dsh/archived_sessions", isDirectory: true),
            home.appendingPathComponent(".kimi/sessions", isDirectory: true),
            home.appendingPathComponent(".kimi-code/sessions", isDirectory: true),
            home.appendingPathComponent(".local/share/goose/sessions", isDirectory: true),
            home.appendingPathComponent(".local/share/amp/threads", isDirectory: true),
            home.appendingPathComponent(".factory/sessions", isDirectory: true),
            home.appendingPathComponent(".grok/sessions", isDirectory: true),
            home.appendingPathComponent(".hermes/sessions", isDirectory: true),
            home.appendingPathComponent(".openclaw/sessions", isDirectory: true),
            home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        ]

        for root in candidateRoots where fm.fileExists(atPath: root.path) {
            if let enumr = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let f as URL in enumr {
                    let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard vals?.isRegularFile == true else { continue }
                    if let md = vals?.contentModificationDate {
                        allSessionFiles.append((md, Int64(vals?.fileSize ?? 0)))
                    }
                }
            }
        }

        var result: [Int: (count: Int, bytes: Int64)] = [:]
        for days in [7, 14, 30, 90] {
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { continue }
            var cnt = 0
            var bytes: Int64 = 0
            for item in allSessionFiles where item.mdate < cutoff {
                cnt += 1
                bytes += item.bytes
            }
            result[days] = (cnt, bytes)
        }
        return result
    }

    nonisolated private static func collectOldFiles(in directories: [URL], olderThan cutoffDate: Date) -> (urls: [URL], bytes: Int64) {
        let fm = FileManager.default
        var urls: [URL] = []
        var total: Int64 = 0
        for dir in directories where fm.fileExists(atPath: dir.path) {
            guard !isPathInTrash(dir.path) else { continue }
            guard let enumr = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumr {
                guard !isPathInTrash(fileURL.path) else { continue }
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

    // MARK: - Stale Hook & MCP / Duplicate Sessions / Codex Docs Scanners

    nonisolated private static func inferToolName(fromConfigPath path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("/.claude/") || lower.hasSuffix("/.claude.json") || lower.contains("claude_desktop_config.json") { return "Claude" }
        if lower.contains("/.codex/") { return "Codex" }
        if lower.contains("/.gemini/antigravity") { return "Antigravity" }
        if lower.contains("/.gemini/") { return "Gemini CLI" }
        if lower.contains("/.cursor/") { return "Cursor" }
        if lower.contains("/.codeium/windsurf") { return "Windsurf" }
        if lower.contains("/zed/") { return "Zed" }
        if lower.contains("/opencode/") { return "OpenCode" }
        if lower.contains("/.kiro/") { return "Kiro" }
        if lower.contains("/.qoder") { return "Qoder" }
        if lower.contains("/.codebuddy/") { return "CodeBuddy" }
        if lower.contains("/.openclaude/") { return "OpenClaude" }
        if lower.contains("/.commandcode/") { return "CommandCode" }
        if lower.contains("/.factory/") { return "Factory" }
        if lower.contains("/devin/") { return "Devin" }
        if lower.contains("/.zcode/") { return "ZCode" }
        if lower.contains("/muse/") { return "Muse" }
        return "AI Tool"
    }

    nonisolated private static func expandHomeToken(_ token: String, homePath: String) -> String {
        var s = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("~/") {
            return homePath + "/" + s.dropFirst(2)
        }
        if s == "~" {
            return homePath
        }
        if s.hasPrefix("$HOME/") {
            return homePath + "/" + s.dropFirst("$HOME/".count)
        }
        return s
    }

    nonisolated private static func isLikelyExecutableOrScriptArg(_ expandedPath: String, homePath: String) -> Bool {
        guard expandedPath.hasPrefix("/") else { return false }
        guard !expandedPath.contains("*"), !expandedPath.contains("{"), !expandedPath.contains("}"),
              !expandedPath.contains("$"), !expandedPath.contains("=") else { return false }
        let blockedPrefixes = ["/dev/", "/System/", "/proc/"]
        if blockedPrefixes.contains(where: { expandedPath.hasPrefix($0) }) { return false }

        let ext = URL(fileURLWithPath: expandedPath).pathExtension.lowercased()
        let scriptExts: Set<String> = ["js", "mjs", "cjs", "ts", "mts", "py", "rb", "sh", "zsh", "bash", "jar", "dylib", "so"]
        if scriptExts.contains(ext) {
            return true
        }
        return expandedPath.hasPrefix("/Applications/")
            || expandedPath.hasPrefix("\(homePath)/")
            || expandedPath.hasPrefix("/opt/")
            || expandedPath.hasPrefix("/usr/local/")
    }

    nonisolated private static func findMissingTargetInMCP(commandTokens: [String], homePath: String, fm: FileManager) -> String? {
        guard let rawCmd = commandTokens.first?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCmd.isEmpty else {
            return nil
        }
        guard !rawCmd.contains("${"), !rawCmd.contains("$CLAUDE"), !rawCmd.hasPrefix("http://"), !rawCmd.hasPrefix("https://") else {
            return nil
        }

        let expandedCmd = expandHomeToken(rawCmd, homePath: homePath)
        if expandedCmd.hasPrefix("/") {
            if !fm.fileExists(atPath: expandedCmd) {
                return expandedCmd
            }
        }

        let cmdBase = URL(fileURLWithPath: expandedCmd).lastPathComponent.lowercased()
        let runners: Set<String> = ["node", "nodejs", "python", "python3", "sh", "bash", "zsh", "bun", "deno", "tsx", "ts-node", "ruby", "java", "php"]
        guard runners.contains(cmdBase) else { return nil }

        var skipNext = false
        for arg in commandTokens.dropFirst() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "-e" || arg == "-c" || arg == "--eval" || arg == "-m" {
                skipNext = true
                continue
            }
            guard !arg.hasPrefix("-"), !arg.contains("://"), !arg.contains("${"), !arg.contains("$CLAUDE") else { continue }
            let expandedArg = expandHomeToken(arg, homePath: homePath)
            if isLikelyExecutableOrScriptArg(expandedArg, homePath: homePath), !fm.fileExists(atPath: expandedArg) {
                return expandedArg
            }
        }
        return nil
    }

    nonisolated private static func splitShellQuotedTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        for ch in command {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && !inSingle {
                escaped = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if ch.isWhitespace && !inSingle && !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    nonisolated private static func findMissingTargetInHookCommand(_ command: String, homePath: String, fm: FileManager) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("$CLAUDE_PROJECT_DIR"),
              !trimmed.contains("${"),
              !trimmed.contains("$PWD") else { return nil }

        let tokens = splitShellQuotedTokens(trimmed)
        for token in tokens {
            guard !token.hasPrefix("-"), !token.contains("://"), !token.hasPrefix("./"), !token.hasPrefix("../") else { continue }
            let expanded = expandHomeToken(token, homePath: homePath)
            guard expanded.hasPrefix("/") else { continue }
            let isScopedPath = expanded.hasPrefix("/Applications/")
                || expanded.hasPrefix("\(homePath)/")
                || expanded.hasPrefix("/opt/homebrew/")
                || expanded.hasPrefix("/usr/local/")
            if isScopedPath && !expanded.contains("*") && !expanded.contains("$") {
                if !fm.fileExists(atPath: expanded) {
                    return expanded
                }
            }
        }
        return nil
    }

    nonisolated private static func collectStaleMCPFromDict(
        _ serversDict: [String: Any],
        sectionKey: String,
        homePath: String,
        fm: FileManager,
        into refs: inout [StaleHookMCPRef],
        estimatedBytes: inout Int64
    ) {
        for (serverName, rawEntry) in serversDict {
            guard let entry = rawEntry as? [String: Any] else { continue }
            if entry["url"] != nil || entry["httpUrl"] != nil || entry["serverUrl"] != nil { continue }
            if let t = (entry["type"] as? String)?.lowercased(),
               t == "sse" || t == "http" || t == "streamable-http" || t == "remote" {
                continue
            }

            var tokens: [String] = []
            if let cmdStr = entry["command"] as? String {
                tokens = splitShellQuotedTokens(cmdStr)
                if let args = entry["args"] as? [String] {
                    tokens.append(contentsOf: args)
                }
            } else if let cmdArray = entry["command"] as? [String] {
                tokens = cmdArray
            }
            guard !tokens.isEmpty else { continue }

            if let missing = findMissingTargetInMCP(commandTokens: tokens, homePath: homePath, fm: fm) {
                refs.append(StaleHookMCPRef(sectionKey: sectionKey, entryIdentifier: serverName, missingTargetPath: missing))
                if let serialized = try? JSONSerialization.data(withJSONObject: entry) {
                    estimatedBytes += Int64(max(64, serialized.count))
                } else {
                    estimatedBytes += 64
                }
            }
        }
    }

    nonisolated private static func inspectStaleHooksAndMCP(home: URL, matcher: CleanWhitelistMatcher) -> [AICleanItem] {
        let fm = FileManager.default
        let homePath = home.standardizedFileURL.path
        let configPaths = CleanWhitelistMatcher.aiToolConfigFilePaths(home: homePath)
        var results: [AICleanItem] = []

        for configPath in configPaths {
            let url = URL(fileURLWithPath: configPath)
            guard fm.fileExists(atPath: url.path) else { continue }
            let isSym = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard !isSym else { continue }
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            var refs: [StaleHookMCPRef] = []
            var estimatedBytes: Int64 = 0

            for key in ["mcpServers", "context_servers", "servers"] {
                if let dict = root[key] as? [String: Any] {
                    collectStaleMCPFromDict(dict, sectionKey: key, homePath: homePath, fm: fm, into: &refs, estimatedBytes: &estimatedBytes)
                }
            }
            if let mcpDict = root["mcp"] as? [String: Any] {
                if let innerServers = mcpDict["servers"] as? [String: Any] {
                    collectStaleMCPFromDict(innerServers, sectionKey: "mcp.servers", homePath: homePath, fm: fm, into: &refs, estimatedBytes: &estimatedBytes)
                } else {
                    collectStaleMCPFromDict(mcpDict, sectionKey: "mcp", homePath: homePath, fm: fm, into: &refs, estimatedBytes: &estimatedBytes)
                }
            }

            if let hooksDict = root["hooks"] as? [String: Any] {
                for (eventName, rawEventEntries) in hooksDict {
                    guard let eventArray = rawEventEntries as? [[String: Any]] else { continue }
                    for matcherEntry in eventArray {
                        if let nestedHooks = matcherEntry["hooks"] as? [[String: Any]] {
                            for hookObj in nestedHooks {
                                if let cmd = hookObj["command"] as? String,
                                   let missing = findMissingTargetInHookCommand(cmd, homePath: homePath, fm: fm) {
                                    refs.append(StaleHookMCPRef(sectionKey: "hooks.\(eventName)", entryIdentifier: cmd, missingTargetPath: missing))
                                    estimatedBytes += Int64(max(64, cmd.utf8.count))
                                }
                            }
                        } else if let cmd = matcherEntry["command"] as? String,
                                  let missing = findMissingTargetInHookCommand(cmd, homePath: homePath, fm: fm) {
                            refs.append(StaleHookMCPRef(sectionKey: "hooks.\(eventName)", entryIdentifier: cmd, missingTargetPath: missing))
                            estimatedBytes += Int64(max(64, cmd.utf8.count))
                        }
                    }
                }
            }

            // Deduplicate identical refs within the same config file
            var seenKeys: Set<String> = []
            refs = refs.filter { seenKeys.insert("\($0.sectionKey)\0\($0.entryIdentifier)").inserted }
            guard !refs.isEmpty else { continue }

            let toolName = inferToolName(fromConfigPath: configPath)
            let sampleTargets = refs.prefix(2).map { ref in
                "\(ref.sectionKey): \(URL(fileURLWithPath: ref.missingTargetPath).lastPathComponent)"
            }.joined(separator: "、")
            let verdict = matcher.evaluateForAIToolCleanup(url: url)

            results.append(
                AICleanItem(
                    band: .reviewSessions,
                    kind: .staleHooksAndMCP,
                    toolName: toolName,
                    title: "\(toolName) 失效 Hook / MCP 条目（\(refs.count) 处）",
                    detail: "目标已不存在（\(sampleTargets)）· 默认不勾选，清理前备份原配置到废纸篓",
                    paths: [url],
                    sizeBytes: max(Int64(64), estimatedBytes),
                    isProtected: !verdict.isAllowed,
                    guardReason: verdict.detailText,
                    matchedCount: refs.count,
                    defaultChecked: false,
                    staleConfigRefs: refs
                )
            )
        }

        return results
    }

    nonisolated private static func cleanStaleHooksAndMCPConfig(at configURL: URL, refs: [StaleHookMCPRef], home: URL) -> Int64 {
        let fm = FileManager.default
        guard !refs.isEmpty,
              let originalData = try? Data(contentsOf: configURL),
              var root = (try? JSONSerialization.jsonObject(with: originalData)) as? [String: Any] else {
            return 0
        }

        // Back up original config to Trash before modifying in place
        let backupName = "\(configURL.lastPathComponent).before-syspulse-clean-\(UUID().uuidString.prefix(4)).json"
        let backupURL = configURL.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            try originalData.write(to: backupURL, options: .atomic)
            try fm.trashItem(at: backupURL, resultingItemURL: nil)
        } catch {
            try? fm.removeItem(at: backupURL)
            return 0
        }

        var didModify = false
        for ref in refs {
            if ref.sectionKey == "mcp.servers" {
                if var mcpDict = root["mcp"] as? [String: Any],
                   var servers = mcpDict["servers"] as? [String: Any],
                   servers.removeValue(forKey: ref.entryIdentifier) != nil {
                    mcpDict["servers"] = servers
                    root["mcp"] = mcpDict
                    didModify = true
                }
            } else if ref.sectionKey == "mcpServers" || ref.sectionKey == "context_servers" || ref.sectionKey == "servers" || ref.sectionKey == "mcp" {
                if var dict = root[ref.sectionKey] as? [String: Any],
                   dict.removeValue(forKey: ref.entryIdentifier) != nil {
                    root[ref.sectionKey] = dict
                    didModify = true
                }
            } else if ref.sectionKey.hasPrefix("hooks.") {
                let eventName = String(ref.sectionKey.dropFirst("hooks.".count))
                if var hooksDict = root["hooks"] as? [String: Any],
                   let eventArray = hooksDict[eventName] as? [[String: Any]] {
                    var updatedMatchers: [[String: Any]] = []
                    for var matcherEntry in eventArray {
                        if let nested = matcherEntry["hooks"] as? [[String: Any]] {
                            let remaining = nested.filter { ($0["command"] as? String) != ref.entryIdentifier }
                            if remaining.count != nested.count { didModify = true }
                            if !remaining.isEmpty {
                                matcherEntry["hooks"] = remaining
                                updatedMatchers.append(matcherEntry)
                            }
                        } else if (matcherEntry["command"] as? String) == ref.entryIdentifier {
                            didModify = true
                        } else {
                            updatedMatchers.append(matcherEntry)
                        }
                    }
                    if updatedMatchers.isEmpty {
                        hooksDict.removeValue(forKey: eventName)
                    } else {
                        hooksDict[eventName] = updatedMatchers
                    }
                    root["hooks"] = hooksDict
                }
            }
        }

        guard didModify else { return 0 }
        guard var serialized = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return 0
        }
        serialized.append(0x0A)
        do {
            try serialized.write(to: configURL, options: .atomic)
            let diff = Int64(originalData.count) - Int64(serialized.count)
            return max(Int64(refs.count * 64), diff)
        } catch {
            return 0
        }
    }

    nonisolated private static func inspectDuplicateClaudeSessions(
        home: URL,
        excluding alreadyListed: Set<URL>,
        matcher: CleanWhitelistMatcher
    ) -> [AICleanItem] {
        let fm = FileManager.default
        let claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard fm.fileExists(atPath: claudeProjects.path),
              let projectDirs = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        struct SessionEntry {
            let url: URL
            let projName: String
            let mdate: Date
            let size: Int64
        }

        var bySessionUUID: [String: [SessionEntry]] = [:]
        for projDir in projectDirs {
            guard !isPathInTrash(projDir.path) else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: projDir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for f in files where f.pathExtension.lowercased() == "jsonl" {
                let stdURL = f.standardizedFileURL
                guard !isPathInTrash(stdURL.path), !alreadyListed.contains(stdURL) else { continue }
                let stem = f.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: stem) != nil else { continue }
                let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard vals?.isRegularFile == true else { continue }
                let sz = Int64(vals?.fileSize ?? 0)
                let md = vals?.contentModificationDate ?? .distantPast
                bySessionUUID[stem.lowercased(), default: []].append(
                    SessionEntry(url: f, projName: projDir.lastPathComponent, mdate: md, size: sz)
                )
            }
        }

        var duplicateFiles: [URL] = []
        var duplicateBytes: Int64 = 0
        for (_, entries) in bySessionUUID where entries.count >= 2 {
            let distinctProjects = Set(entries.map(\.projName))
            guard distinctProjects.count >= 2 else { continue }
            let sorted = entries.sorted { a, b in
                if a.mdate != b.mdate { return a.mdate > b.mdate }
                if a.size != b.size { return a.size > b.size }
                return a.url.path < b.url.path
            }
            for staleCopy in sorted.dropFirst() {
                duplicateFiles.append(staleCopy.url)
                duplicateBytes += staleCopy.size
            }
        }

        guard !duplicateFiles.isEmpty else { return [] }
        let verdict = matcher.evaluateForAIToolCleanup(url: claudeProjects)
        return [
            AICleanItem(
                band: .reviewSessions,
                kind: .duplicateSessions,
                toolName: "Claude Code",
                title: "Claude Code 其他文件夹重复旧对话（\(duplicateFiles.count) 份）",
                detail: "同一会话在不同项目文件夹重复保存，已保留最新修改副本 · 默认不勾选，移入废纸篓可还原",
                paths: duplicateFiles,
                sizeBytes: duplicateBytes,
                isProtected: !verdict.isAllowed,
                guardReason: verdict.detailText,
                matchedCount: duplicateFiles.count,
                defaultChecked: false
            )
        ]
    }

    nonisolated private static func inspectCodexProjectFolders(home: URL, now: Date, matcher: CleanWhitelistMatcher) -> [AICleanItem] {
        let fm = FileManager.default
        let docsCodex = home.appendingPathComponent("Documents/Codex", isDirectory: true)
        guard fm.fileExists(atPath: docsCodex.path),
              let children = try? fm.contentsOfDirectory(
                  at: docsCodex,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let pinnedPaths = loadCodexPinnedWorkspacePaths(home: home, fm: fm)
        let cutoff7d = now.addingTimeInterval(-7 * 24 * 3600)
        var items: [AICleanItem] = []

        for dir in children {
            guard !isPathInTrash(dir.path) else { continue }
            let vals = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }
            guard CleanWhitelistMatcher.isCodexDocumentsProjectChild(path: dir.standardizedFileURL.path, home: home.standardizedFileURL.path) else {
                continue
            }

            let resolvedDirPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
            if pinnedPaths.contains(dir.standardizedFileURL.path) || pinnedPaths.contains(resolvedDirPath) {
                continue
            }

            // Guard 1: > 7 days unmodified (root & top-2 levels)
            let rootMod = vals?.contentModificationDate ?? now
            guard rootMod <= cutoff7d, latestModificationDateShallow(in: dir, maxDepth: 2, fallback: rootMod) <= cutoff7d else {
                continue
            }

            // Guard 2: no dirty / unpushed git state
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                guard let gitStatus = runGit(in: dir, args: ["status", "--porcelain"]),
                      gitStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                if let unpushed = runGit(in: dir, args: ["rev-list", "--count", "@{u}..HEAD"]),
                   let count = Int(unpushed.trimmingCharacters(in: .whitespacesAndNewlines)),
                   count > 0 {
                    continue
                }
            }

            // Guard 3: no active file handles via lsof
            if hasOpenFileHandles(at: dir) {
                continue
            }

            let sz = SystemCleanerEngine.calculateDirectorySize(url: dir)
            guard sz > 1024 else { continue }
            let verdict = matcher.evaluateForAIToolCleanup(url: dir)
            items.append(
                AICleanItem(
                    band: .reviewSessions,
                    kind: .codexProjectFolder,
                    toolName: "Codex",
                    title: "Codex 文稿项目：\(dir.lastPathComponent)",
                    detail: "超过 7 天未修改、无未提交 Git 变更且无进程占用 · 默认不勾选，清理仅移入废纸篓",
                    paths: [dir],
                    sizeBytes: sz,
                    isProtected: !verdict.isAllowed,
                    guardReason: verdict.detailText,
                    ownerBundleID: "com.openai.codex",
                    ownerAppName: "Codex",
                    defaultChecked: false
                )
            )
        }

        return items
    }

    nonisolated private static func loadCodexPinnedWorkspacePaths(home: URL, fm: FileManager) -> Set<String> {
        var pinned: Set<String> = []
        let stateURL = home.appendingPathComponent(".codex/.codex-global-state.json")
        guard let attrs = try? fm.attributesOfItem(atPath: stateURL.path),
              let sz = attrs[.size] as? Int64, sz < 5 * 1024 * 1024,
              let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return pinned
        }

        func collectPinned(from node: Any, insidePinnedKey: Bool) {
            if let dict = node as? [String: Any] {
                for (k, v) in dict {
                    let kl = k.lowercased()
                    let nextFlag = insidePinnedKey || kl.contains("pinned") || kl.contains("favorite") || kl == "activeworkspaces"
                    collectPinned(from: v, insidePinnedKey: nextFlag)
                }
            } else if let arr = node as? [Any] {
                for item in arr {
                    collectPinned(from: item, insidePinnedKey: insidePinnedKey)
                }
            } else if insidePinnedKey, let s = node as? String, s.hasPrefix("/") {
                pinned.insert(URL(fileURLWithPath: s).resolvingSymlinksInPath().standardizedFileURL.path)
                pinned.insert(URL(fileURLWithPath: s).standardizedFileURL.path)
            }
        }
        collectPinned(from: json, insidePinnedKey: false)
        return pinned
    }

    nonisolated private static func latestModificationDateShallow(in dir: URL, maxDepth: Int, fallback: Date) -> Date {
        let fm = FileManager.default
        var latest = fallback
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return latest }

        for entry in entries {
            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard vals?.isSymbolicLink != true else { continue }
            if let md = vals?.contentModificationDate, md > latest {
                latest = md
            }
            if maxDepth > 1, vals?.isDirectory == true {
                let sub = latestModificationDateShallow(in: entry, maxDepth: maxDepth - 1, fallback: latest)
                if sub > latest { latest = sub }
            }
        }
        return latest
    }

    nonisolated private static func hasOpenFileHandles(at dir: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        p.arguments = ["-w", "-F", "n", "+D", dir.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { $0.hasPrefix("n") }
        } catch {
            return false
        }
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
