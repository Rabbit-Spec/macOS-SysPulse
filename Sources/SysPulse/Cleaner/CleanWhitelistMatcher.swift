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
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/.cocoapods/cache",
            "\(home)/.npm/_cacache",
            "\(home)/.pnpm-store",
            "\(home)/Library/pnpm/store",
            "\(home)/.cache",
            "\(home)/.gradle/caches",
            "\(home)/Library/Caches/Homebrew",
            "\(home)/Downloads",
            "\(home)/Desktop"
        ]
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
            "\(home)/.cache",
            "\(home)/.local/share",
            "\(home)/.local/state",
            "\(home)/.local/bin",
            "\(home)/.config/opencode",
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
            "\(home)/Library/Caches/claude-cli-nodejs",
            "\(home)/Library/Caches/com.anthropic.claudefordesktop",
            "\(home)/Library/Caches/Codex",
            "\(home)/Library/Caches/com.openai.chat",
            "\(home)/Library/Caches/ChatGPTHelper",
            "\(home)/Library/Caches/com.lmstudio.lmstudio"
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

        // 2. Guard against user documents / personal data (except installer .dmg/.pkg/.iso on Desktop if requested)
        for dir in Self.forbiddenUserDirectories {
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

        // 4.1 Explicitly allow Trash folders on all volumes for standard cleaner
        if zoneSet == .standardCleaner && (
            resolvedPath.contains("/.Trashes/") || resolvedPath.hasSuffix("/.Trashes")
                || resolvedPath.contains("/.Trash/") || resolvedPath.hasSuffix("/.Trash")
        ) {
            return .allowed
        }

        // 5. Must match one of the designated safe cleanup zones
        let resolvedHome = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let rawHome = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
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
