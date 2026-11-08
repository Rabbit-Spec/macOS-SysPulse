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

    /// Verifies if a given path is legally in the safe clean target zone.
    public func isSafeToClean(url: URL) -> Bool {
        let path = url.standardized.path

        // 1. Guard against system root paths
        for forbidden in Self.forbiddenPrefixes {
            if path.hasPrefix(forbidden) {
                return false
            }
        }

        // 2. Guard against user documents / personal data
        let fm = FileManager.default
        for dir in Self.forbiddenUserDirectories {
            if let userDir = fm.urls(for: dir, in: .userDomainMask).first {
                let userDirPath = userDir.standardized.path
                if path.hasPrefix(userDirPath) {
                    return false
                }
            }
        }

        // 3. Guard against source code git repositories and credentials
        if path.contains("/.git/") || path.hasSuffix("/.git") || path.contains("/.ssh/") || path.contains("/.gnupg/") {
            return false
        }

        // 4. Guard against custom & default CleanProtectionStore whitelist rules
        if CleanProtectionStore.shared.isProtected(path: path) {
            return false
        }

        // 5. Must match one of our designated safe cleanup zones
        let home = fm.homeDirectoryForCurrentUser.standardized.path
        let allowedZones = [
            "\(home)/Library/Caches",
            "/Library/Caches",
            "\(home)/Library/Logs",
            "/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/.Trash",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/.npm/_cacache",
            "\(home)/Library/Caches/Homebrew",
            "\(home)/Downloads"
        ]

        let isInAllowedZone = allowedZones.contains { path.hasPrefix($0) }
        guard isInAllowedZone else { return false }

        // If in Downloads, ONLY allow .dmg, .pkg, or .iso installation media leftovers
        if path.hasPrefix("\(home)/Downloads") {
            let ext = url.pathExtension.lowercased()
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
