import Foundation
import AppKit

/// Structured block reasons for path safety and protection guard evaluation.
public enum CleanGuardBlockReason: String, Sendable, Equatable {
    case emptyPath
    case controlChars
    case notAbsolute
    case traversal
    case symlinkedPath
    case protectedSymlinkTarget
    case criticalSystemPath
    case userDataPath
    case protectedAppData
    case whitelisted
    case outsideAllowedZones

    public var localizedReason: String {
        switch self {
        case .emptyPath: return "路径为空"
        case .controlChars: return "路径含控制字符"
        case .notAbsolute: return "不是绝对路径"
        case .traversal: return "路径越出了自身目录"
        case .symlinkedPath: return "不穿过符号链接清理"
        case .protectedSymlinkTarget: return "链接指向受保护位置"
        case .criticalSystemPath: return "系统关键路径，受绝对保护"
        case .userDataPath: return "用户个人数据目录，已保留"
        case .protectedAppData: return "受保护的敏感数据 (.git / .ssh / 钥匙串等)"
        case .whitelisted: return "在清理保护名单中"
        case .outsideAllowedZones: return "不在安全清理白名单作用域内"
        }
    }
}

/// Result of evaluating whether a filesystem URL is safe to inspect or clean.
public enum CleanGuardVerdict: Sendable, Equatable {
    case allowed
    case blocked(reason: CleanGuardBlockReason, detail: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var blockReason: CleanGuardBlockReason? {
        if case .blocked(let reason, _) = self { return reason }
        return nil
    }

    public var detailText: String? {
        if case .blocked(let reason, let detail) = self {
            return detail.isEmpty ? reason.localizedReason : "\(reason.localizedReason): \(detail)"
        }
        return nil
    }
}

/// Ensures strict safety boundaries before scanning or deleting any file on disk.
public struct CleanWhitelistMatcher: Sendable {
    public static let shared = CleanWhitelistMatcher()

    /// System-protected prefixes that MUST NEVER be deleted under any circumstance.
    private static let forbiddenPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/private/etc",
        "/private/var/db",
        "/Library/Preferences",
        "/Library/Apple",
        "/Library/Keychains",
        "/Library/Security",
        "/Library/Audio/Plug-Ins"
    ]

    /// Sensitive system & user preference fragments that must never be touched by automated cleaners.
    private static let protectedPreferenceFragments: [String] = [
        "systemsettings",
        "systempreferences",
        "controlcenter",
        "backgroundtaskmanagement",
        "loginitems",
        "com.apple.sharedfilelist",
        "/tcc/",
        "com.apple.coreaudio"
    ]

    /// User critical personal folders that must never be scanned as junk.
    private static let forbiddenUserDirectories: [FileManager.SearchPathDirectory] = [
        .documentDirectory,
        .desktopDirectory,
        .picturesDirectory,
        .musicDirectory,
        .moviesDirectory
    ]

    public init() {}

    private static func matchesPrefix(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    public static func defaultAllowedPrefixes(home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) -> [String] {
        [
            "\(home)/Library/Caches",
            "/Library/Caches",
            "\(home)/Library/Containers/com.apple.Safari/Data/Library/Caches",
            "\(home)/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches",
            "\(home)/Library/Application Support/com.apple.wallpaper/aerials/videos",
            "\(home)/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches",
            "\(home)/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat",
            "\(home)/Library/Logs",
            "/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/Application Support",
            "\(home)/Library/Containers",
            "\(home)/.Trash",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/visionOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/macOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/UserData/Previews/Simulator Devices",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/Library/Developer/CoreSimulator/Devices",
            "\(home)/.android/build-cache",
            "\(home)/.android/avd",
            "\(home)/.cocoapods/cache",
            "\(home)/.npm/_cacache",
            "\(home)/.pnpm-store",
            "\(home)/Library/pnpm/store",
            "\(home)/.cache",
            "\(home)/.gradle/caches",
            "\(home)/Library/Caches/Homebrew",
            "\(home)/.codex/crash_reports",
            "\(home)/Downloads",
            "\(home)/Desktop"
        ]
    }

    /// 严格校验系统临时目录下壁纸下载中断残留目录及其内部临时文件（仅匹配 `/private/var/folders/*/*/T/com.apple.idleassetsd`）
    public static func isAllowedIdleAssetsTempDir(_ path: String) -> Bool {
        guard !path.contains(".."),
              let regex = try? NSRegularExpression(pattern: #"^/private/var/folders/[A-Za-z0-9_+=-]{2}/[A-Za-z0-9_+=-]{10,}/T/com\.apple\.idleassetsd$"#) else {
            return false
        }
        let range = NSRange(location: 0, length: (path as NSString).length)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    public static func isAllowedIdleAssetsTempPath(_ path: String) -> Bool {
        guard !path.contains("..") else { return false }
        if isAllowedIdleAssetsTempDir(path) { return true }
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        return isAllowedIdleAssetsTempDir(dir) && url.lastPathComponent.hasPrefix("CFNetworkDownload_")
    }

    /// 支持扫描与清理失效 Hook / MCP 的 17 个 AI 工具配置文件清单
    public static func aiToolConfigFilePaths(home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) -> [String] {
        [
            "\(home)/.claude/settings.json",
            "\(home)/.codex/hooks.json",
            "\(home)/.cursor/hooks.json",
            "\(home)/.cursor/mcp.json",
            "\(home)/.gemini/settings.json",
            "\(home)/.gemini/config/hooks.json",
            "\(home)/.qwen/settings.json",
            "\(home)/.qoder/settings.json",
            "\(home)/.qoder-cn/settings.json",
            "\(home)/.codebuddy/settings.json",
            "\(home)/.openclaude/settings.json",
            "\(home)/.commandcode/settings.json",
            "\(home)/.factory/settings.json",
            "\(home)/.config/devin/config.json",
            "\(home)/.zcode/cli/config.json",
            "\(home)/.config/muse/settings.json",
            "\(home)/Library/Application Support/Claude/claude_desktop_config.json"
        ]
    }

    /// 校验是否为 `~/Documents/Codex` 下的直接子项目目录（仅允许深度 1，不放开整个文稿目录）
    public static func isCodexDocumentsProjectChild(path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) -> Bool {
        let codexRoot = "\(home)/Documents/Codex"
        guard path.hasPrefix(codexRoot + "/") else { return false }
        let suffix = String(path.dropFirst(codexRoot.count + 1))
        return !suffix.isEmpty && !suffix.contains("/") && !suffix.hasPrefix(".")
    }

    /// 校验是否为微信 4.0 `~/Documents/xwechat_files` 下允许清理的临时/缓存/日志目录（绝不放开聊天数据库）
    public static func isAllowedWeChat4CachePath(path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) -> Bool {
        let root = "\(home)/Documents/xwechat_files"
        guard path.hasPrefix(root + "/") else { return false }
        let lower = path.lowercased()
        let allowedLeafFragments = [
            "/cache",
            "/caches",
            "/log",
            "/logs",
            "/xlog",
            "/temp",
            "/msg/attach",
            "/msg/video",
            "/filestorage/image",
            "/filestorage/video",
            "/filestorage/cache",
            "/avatar"
        ]
        return allowedLeafFragments.contains { lower.hasSuffix($0) || lower.contains("\($0)/") }
    }

    /// Safe root prefixes dedicated to AI developer tools and caches inside the user home directory.
    public static func aiToolAllowedPrefixes(home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) -> [String] {
        [
            "\(home)/.claude",
            "\(home)/.codex",
            "\(home)/.cursor",
            "\(home)/.gemini",
            "\(home)/.ollama",
            "\(home)/.lmstudio",
            "\(home)/.copilot",
            "\(home)/.opencode",
            "\(home)/.cline",
            "\(home)/.codeium",
            "\(home)/.kiro",
            "\(home)/.trae",
            "\(home)/.trae-cn",
            "\(home)/.dsh",
            "\(home)/.kimi",
            "\(home)/.kimi-code",
            "\(home)/.factory",
            "\(home)/.grok",
            "\(home)/.hermes",
            "\(home)/.openclaw",
            "\(home)/.pi",
            "\(home)/.iflow",
            "\(home)/.qwenworkcn/cache",
            "\(home)/.cache",
            "\(home)/.local/share",
            "\(home)/.local/state",
            "\(home)/.local/bin",
            "\(home)/.config/opencode",
            "\(home)/Library/Application Support/Zed",
            "\(home)/Library/Application Support/Windsurf",
            "\(home)/Library/Application Support/CherryStudio",
            "\(home)/Library/Application Support/Claude",
            "\(home)/Library/Application Support/Claude-3p",
            "\(home)/Library/Application Support/Codex",
            "\(home)/Library/Application Support/Cursor",
            "\(home)/Library/Application Support/Antigravity",
            "\(home)/Library/Application Support/Antigravity IDE",
            "\(home)/Library/Application Support/Comfy Desktop",
            "\(home)/Library/Application Support/ai.opencode.desktop",
            "\(home)/Library/Application Support/com.openai.chat",
            "\(home)/Library/Application Support/t3code",
            "\(home)/Library/Application Support/t3code-v2",
            "\(home)/Library/Application Support/T3 Code (Alpha)",
            "\(home)/Library/Application Support/QwenWorkCN",
            "\(home)/Library/Application Support/DoubaoWork/gecko_cache",
            "\(home)/Library/Application Support/DoubaoWork/sandbox_runtime/downloads",
            "\(home)/Library/Caches/claude-cli-nodejs",
            "\(home)/Library/Caches/com.anthropic.claudefordesktop",
            "\(home)/Library/Caches/Codex",
            "\(home)/Library/Caches/com.openai.chat",
            "\(home)/Library/Caches/ChatGPTHelper",
            "\(home)/Library/Caches/com.lmstudio.lmstudio",
            "\(home)/Library/Caches/cn.qwenwork.desktop.mac",
            "\(home)/Library/Caches/DoubaoWork"
        ]
    }

    /// Evaluates whether a path is legally in a safe clean target zone and returns structured guard diagnostics.
    public func evaluate(url: URL, allowInstallersOnlyInDesktopDownloads: Bool = true) -> CleanGuardVerdict {
        evaluateInternal(url: url, zoneSet: .standardCleaner, allowInstallersOnlyInDesktopDownloads: allowInstallersOnlyInDesktopDownloads)
    }

    /// Evaluates whether a path is allowed inside the AI Tool Cleaner plugin while sharing the same whitelist & system guards.
    public func evaluateForAIToolCleanup(url: URL) -> CleanGuardVerdict {
        evaluateInternal(url: url, zoneSet: .aiTools, allowInstallersOnlyInDesktopDownloads: false)
    }

    /// Backward-compatible boolean helper used across Cleaner callers.
    public func isSafeToClean(url: URL) -> Bool {
        evaluate(url: url).isAllowed
    }

    private enum AllowedZoneSet {
        case standardCleaner
        case aiTools
    }

    private func evaluateInternal(
        url: URL,
        zoneSet: AllowedZoneSet,
        allowInstallersOnlyInDesktopDownloads: Bool
    ) -> CleanGuardVerdict {
        let fm = FileManager.default
        let inputPath = url.path

        // 0. Empty / control char / relative / traversal guards
        if inputPath.isEmpty {
            return .blocked(reason: .emptyPath, detail: "")
        }
        if inputPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .blocked(reason: .controlChars, detail: url.lastPathComponent)
        }
        if !inputPath.hasPrefix("/") {
            return .blocked(reason: .notAbsolute, detail: inputPath)
        }
        if inputPath.split(separator: "/").contains("..") {
            return .blocked(reason: .traversal, detail: inputPath)
        }

        let standardizedURL = url.standardizedFileURL
        let rawPath = standardizedURL.path
        let isSymbolicLink = (try? standardizedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        let resolvedURL = standardizedURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolvedURL.path

        // 1. Guard against system root paths (raw & resolved symlink target)
        for forbidden in Self.forbiddenPrefixes {
            if Self.matchesPrefix(rawPath, prefix: forbidden) {
                return .blocked(reason: .criticalSystemPath, detail: forbidden)
            }
            if Self.matchesPrefix(resolvedPath, prefix: forbidden) {
                return .blocked(reason: isSymbolicLink ? .protectedSymlinkTarget : .criticalSystemPath, detail: forbidden)
            }
        }

        let resolvedHome = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let rawHome = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        let isCodexDocsChild = (zoneSet == .aiTools)
            && !isSymbolicLink
            && (Self.isCodexDocumentsProjectChild(path: resolvedPath, home: resolvedHome)
                || Self.isCodexDocumentsProjectChild(path: rawPath, home: rawHome))
        let isWeChat4Cache = (zoneSet == .standardCleaner)
            && !isSymbolicLink
            && (Self.isAllowedWeChat4CachePath(path: resolvedPath, home: resolvedHome)
                || Self.isAllowedWeChat4CachePath(path: rawPath, home: rawHome))

        // 2. Guard against user documents / personal data (except installer .dmg/.pkg/.iso on Desktop, narrow ~/Documents/Codex/<subitem> for AI cleaner, or WeChat 4.0 cache folders)
        for dir in Self.forbiddenUserDirectories {
            if dir == .documentDirectory && (isCodexDocsChild || isWeChat4Cache) {
                continue
            }
            if let userDir = fm.urls(for: dir, in: .userDomainMask).first {
                let rawDirPath = userDir.standardizedFileURL.path
                let resolvedDirPath = userDir.resolvingSymlinksInPath().standardizedFileURL.path
                if dir == .desktopDirectory && allowInstallersOnlyInDesktopDownloads {
                    if Self.matchesPrefix(resolvedPath, prefix: resolvedDirPath) {
                        let ext = standardizedURL.pathExtension.lowercased()
                        if (ext == "dmg" || ext == "pkg" || ext == "iso") && !isSymbolicLink {
                            break
                        }
                        return .blocked(reason: .userDataPath, detail: userDir.lastPathComponent)
                    }
                } else if Self.matchesPrefix(rawPath, prefix: rawDirPath)
                            || Self.matchesPrefix(resolvedPath, prefix: rawDirPath)
                            || Self.matchesPrefix(resolvedPath, prefix: resolvedDirPath) {
                    return .blocked(reason: isSymbolicLink ? .protectedSymlinkTarget : .userDataPath, detail: userDir.lastPathComponent)
                }
            }
        }

        // 3. Guard against source code git repositories, credentials, and sensitive macOS system preferences/TCC state
        for candidate in [rawPath, resolvedPath] {
            if candidate.contains("/.git/") || candidate.hasSuffix("/.git")
                || candidate.contains("/.ssh/") || candidate.hasSuffix("/.ssh")
                || candidate.contains("/.gnupg/") || candidate.hasSuffix("/.gnupg") {
                return .blocked(reason: .protectedAppData, detail: ".git / .ssh / .gnupg")
            }
            let lower = candidate.lowercased()
            if let sensitive = Self.protectedPreferenceFragments.first(where: { lower.contains($0) }) {
                return .blocked(reason: .protectedAppData, detail: sensitive)
            }
        }

        // 4. Fail-closed whitelist guard + custom & default CleanProtectionStore whitelist rules
        if let readFailure = CleanProtectionStore.shared.readFailureReason() {
            return .blocked(reason: .whitelisted, detail: readFailure)
        }
        if let matched = CleanProtectionStore.shared.matchedPattern(for: rawPath)
            ?? CleanProtectionStore.shared.matchedPattern(for: resolvedPath) {
            return .blocked(reason: isSymbolicLink ? .protectedSymlinkTarget : .whitelisted, detail: matched)
        }

        // 4.1 Explicitly allow Trash folders & strict idleassetsd download temp dir for standard cleaner
        if zoneSet == .standardCleaner && (isWeChat4Cache || (
            resolvedPath.contains("/.Trashes/") || resolvedPath.hasSuffix("/.Trashes")
                || resolvedPath.contains("/.Trash/") || resolvedPath.hasSuffix("/.Trash")
        )) {
            return .allowed
        }
        if zoneSet == .standardCleaner && !isSymbolicLink && (
            Self.isAllowedIdleAssetsTempPath(rawPath) || Self.isAllowedIdleAssetsTempPath(resolvedPath)
        ) {
            return .allowed
        }
        if zoneSet == .aiTools && (isCodexDocsChild || (
            !isSymbolicLink && (
                Self.aiToolConfigFilePaths(home: resolvedHome).contains(resolvedPath)
                || Self.aiToolConfigFilePaths(home: rawHome).contains(rawPath)
            )
        )) {
            return .allowed
        }

        // 5. Must match one of the designated safe cleanup zones
        let baseZones: [String] = {
            switch zoneSet {
            case .standardCleaner:
                return Self.defaultAllowedPrefixes(home: resolvedHome)
                    + (rawHome == resolvedHome ? [] : Self.defaultAllowedPrefixes(home: rawHome))
            case .aiTools:
                return Self.aiToolAllowedPrefixes(home: resolvedHome)
                    + (rawHome == resolvedHome ? [] : Self.aiToolAllowedPrefixes(home: rawHome))
            }
        }()

        let isInAllowedZone = baseZones.contains { Self.matchesPrefix(resolvedPath, prefix: $0) }
        guard isInAllowedZone else {
            return .blocked(reason: .outsideAllowedZones, detail: standardizedURL.lastPathComponent)
        }

        // Downloads / Desktop in standard cleaner ONLY allow .dmg, .pkg, or .iso installation media leftovers
        if zoneSet == .standardCleaner && allowInstallersOnlyInDesktopDownloads {
            let desktopResolved = fm.urls(for: .desktopDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().standardizedFileURL.path ?? "\(resolvedHome)/Desktop"
            if Self.matchesPrefix(resolvedPath, prefix: "\(resolvedHome)/Downloads")
                || Self.matchesPrefix(resolvedPath, prefix: "\(rawHome)/Downloads")
                || Self.matchesPrefix(resolvedPath, prefix: desktopResolved) {
                let ext = standardizedURL.pathExtension.lowercased()
                return (ext == "dmg" || ext == "pkg" || ext == "iso")
                    ? .allowed
                    : .blocked(reason: .userDataPath, detail: "仅允许清理安装镜像 (.dmg/.pkg/.iso)")
            }
        }

        return .allowed
    }

    /// Checks if a file belongs to an actively running process and should be skipped for live stability.
    public func isActivelyLockedByRunningApp(url: URL, runningBundleIDs: Set<String>) -> Bool {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        if ext == "lock" || path.hasSuffix("-wal") || path.hasSuffix("-shm") {
            return true
        }

        for bundle in runningBundleIDs {
            if path.localizedCaseInsensitiveContains(bundle) {
                if ext == "db" || ext == "sqlite" || ext == "sqlite3" {
                    return true
                }
            }
        }

        return false
    }

    /// Returns true if the URL is an undownloaded iCloud Drive placeholder that must never trigger cloud download or deletion.
    public static func isICloudPlaceholder(url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") && url.pathExtension.lowercased() == "icloud" {
            return true
        }
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return true
        }
        return false
    }
}
