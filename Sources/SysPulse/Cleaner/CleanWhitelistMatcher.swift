import Foundation
import AppKit

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
        "/Library/Preferences",
        "/Library/Apple",
        "/Library/Keychains",
        "/Library/Security"
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
            "\(home)/Library/Logs",
            "/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/.Trash",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/.cocoapods/cache",
            "\(home)/.npm/_cacache",
            "\(home)/.gradle/caches",
            "\(home)/Library/Caches/Homebrew",
            "\(home)/Downloads"
        ]
    }

    /// Verifies if a given path is legally in the safe clean target zone.
    public func isSafeToClean(url: URL) -> Bool {
        let fm = FileManager.default
        let standardizedURL = url.standardizedFileURL
        let rawPath = standardizedURL.path

        let isSymbolicLink = (try? standardizedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        let resolvedURL = isSymbolicLink
            ? standardizedURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            : standardizedURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolvedURL.path

        // 1. Guard against system root paths
        for forbidden in Self.forbiddenPrefixes {
            if Self.matchesPrefix(rawPath, prefix: forbidden) || Self.matchesPrefix(resolvedPath, prefix: forbidden) {
                return false
            }
        }

        // 2. Guard against user documents / personal data
        for dir in Self.forbiddenUserDirectories {
            if let userDir = fm.urls(for: dir, in: .userDomainMask).first {
                let rawDirPath = userDir.standardizedFileURL.path
                let resolvedDirPath = userDir.resolvingSymlinksInPath().standardizedFileURL.path
                if Self.matchesPrefix(rawPath, prefix: rawDirPath)
                    || Self.matchesPrefix(resolvedPath, prefix: rawDirPath)
                    || Self.matchesPrefix(resolvedPath, prefix: resolvedDirPath) {
                    return false
                }
            }
        }

        // 3. Guard against source code git repositories and credentials
        for candidate in [rawPath, resolvedPath] {
            if candidate.contains("/.git/") || candidate.hasSuffix("/.git")
                || candidate.contains("/.ssh/") || candidate.hasSuffix("/.ssh")
                || candidate.contains("/.gnupg/") || candidate.hasSuffix("/.gnupg") {
                return false
            }
        }

        // 4. Guard against custom & default CleanProtectionStore whitelist rules
        if CleanProtectionStore.shared.isProtected(path: rawPath) || CleanProtectionStore.shared.isProtected(path: resolvedPath) {
            return false
        }

        // 4.1 Explicitly allow Trash folders on all volumes (Internal ~/.Trash and External /.Trashes)
        if resolvedPath.contains("/.Trashes/") || resolvedPath.hasSuffix("/.Trashes")
            || resolvedPath.contains("/.Trash/") || resolvedPath.hasSuffix("/.Trash") {
            return true
        }

        // 5. Must match one of our designated safe cleanup zones
        let resolvedHome = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let rawHome = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        let allowedZones = Self.defaultAllowedPrefixes(home: resolvedHome)
            + (rawHome == resolvedHome ? [] : Self.defaultAllowedPrefixes(home: rawHome))

        let isInAllowedZone = allowedZones.contains { Self.matchesPrefix(resolvedPath, prefix: $0) }
        guard isInAllowedZone else { return false }

        // If in Downloads, ONLY allow .dmg, .pkg, or .iso installation media leftovers
        if Self.matchesPrefix(resolvedPath, prefix: "\(resolvedHome)/Downloads")
            || Self.matchesPrefix(resolvedPath, prefix: "\(rawHome)/Downloads") {
            let ext = standardizedURL.pathExtension.lowercased()
            return ext == "dmg" || ext == "pkg" || ext == "iso"
        }

        return true
    }

    /// Checks if a file belongs to an actively running process and should be skipped for live stability.
    public func isActivelyLockedByRunningApp(url: URL, runningBundleIDs: Set<String>) -> Bool {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        if ext == "lock" || path.hasSuffix("-wal") || path.hasSuffix("-shm") {
            return true
        }

        // Check if bundle name in path matches running app
        for bundle in runningBundleIDs {
            if path.localizedCaseInsensitiveContains(bundle) {
                // If it's a critical live db or lock file, protect it
                if ext == "db" || ext == "sqlite" || ext == "sqlite3" {
                    return true
                }
            }
        }

        return false
    }
}
