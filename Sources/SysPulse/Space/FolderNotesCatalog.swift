import Foundation

/// 解析并缓存内置目录用途与 Bundle 名称映射库 `FolderNotes.json`（5,800+ 目录用途注解 & 5,700+ Bundle 名称映射）。
/// 线程安全、按需懒加载，用于空间分析目录说明与智能清理人类可读名称识别。
public final class FolderNotesCatalog: @unchecked Sendable {
    public static let shared = FolderNotesCatalog()

    private let lock = NSLock()
    private var isLoaded = false
    private var entries: [String: String] = [:]
    private var bundles: [String: String] = [:]
    private var teams: [String: String] = [:]
    private var names: [String: [String: String]] = [:]
    private var strings: [String: [String: String]] = [:]

    private init() {}

    private func ensureLoaded() {
        lock.lock()
        if isLoaded {
            lock.unlock()
            return
        }
        isLoaded = true
        lock.unlock()

        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "FolderNotes", withExtension: "json"),
            Bundle.main.resourceURL?.appendingPathComponent("FolderNotes.json"),
            URL(fileURLWithPath: "/Volumes/巨无霸/Antigravity/SysPulse/v0.1.13_Test1/Resources/FolderNotes.json")
        ]

        guard let fileURL = candidates.compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        let loadedEntries = raw["entries"] as? [String: String] ?? [:]
        let loadedBundles = raw["bundles"] as? [String: String] ?? [:]
        let loadedTeams = raw["teams"] as? [String: String] ?? [:]
        let loadedNames = raw["names"] as? [String: [String: String]] ?? [:]
        let loadedStrings = raw["strings"] as? [String: [String: String]] ?? [:]

        lock.lock()
        self.entries = loadedEntries
        self.bundles = loadedBundles
        self.teams = loadedTeams
        self.names = loadedNames
        self.strings = loadedStrings
        lock.unlock()
    }

    public func preloadInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.ensureLoaded()
        }
    }

    /// 返回目录或文件路径的中文用途说明（优先匹配 `entries`，其次 `bundles` 与 `teams`）
    public func note(forPath fullPath: String, isDirectory: Bool = true) -> String? {
        ensureLoaded()

        let home = NSHomeDirectory()
        let tildePath: String
        if fullPath == home {
            tildePath = "~"
        } else if fullPath.hasPrefix(home + "/") {
            tildePath = "~" + String(fullPath.dropFirst(home.count))
        } else {
            tildePath = fullPath
        }

        lock.lock()
        let entriesMap = self.entries
        let bundlesMap = self.bundles
        let teamsMap = self.teams
        let namesMap = self.names
        let stringsMap = self.strings
        lock.unlock()

        if let spec = entriesMap[tildePath] {
            return resolveSpec(spec, namesMap: namesMap, stringsMap: stringsMap)
        }

        guard isDirectory else { return nil }

        let url = URL(fileURLWithPath: fullPath)
        let folderName = url.lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent

        // Match bundle identifier in known macOS containers/caches/support directories
        if let bundleSpec = bundlesMap[folderName] ?? bundlesMap[folderName.lowercased()] {
            let tmplKey: String
            switch parentName {
            case "Caches": tmplKey = "third.cache"
            case "Containers": tmplKey = "third.container"
            case "Group Containers": tmplKey = "third.group"
            case "Application Support": tmplKey = "third.support"
            case "Logs": tmplKey = "third.logs"
            case "HTTPStorages": tmplKey = "third.http"
            case "WebKit": tmplKey = "third.webkit"
            case "Saved Application State": tmplKey = "third.state"
            default:
                return resolveArg(bundleSpec, namesMap: namesMap)
            }
            let appName = resolveArg(bundleSpec, namesMap: namesMap)
            if let rendered = renderTemplate(tmplKey, argName: appName, stringsMap: stringsMap) {
                return rendered
            }
            return appName
        }

        // Match Team ID prefix for Group Containers (e.g. "EQHXZ8M8AV.group....")
        if parentName == "Group Containers", let dotIdx = folderName.firstIndex(of: ".") {
            let teamPrefix = String(folderName[..<dotIdx])
            if let teamSpec = teamsMap[teamPrefix],
               let resolved = resolveSpec(teamSpec, namesMap: namesMap, stringsMap: stringsMap) {
                return resolved
            }
        }

        return nil
    }

    /// 通过 Bundle ID 或目录名解析人类可读的应用名称（如 `com.tencent.xinWeChat` -> `WeChat`）
    public func appDisplayName(forBundleID bundleID: String) -> String? {
        ensureLoaded()
        lock.lock()
        let bundlesMap = self.bundles
        let namesMap = self.names
        lock.unlock()

        if let spec = bundlesMap[bundleID] ?? bundlesMap[bundleID.lowercased()] {
            return resolveArg(spec, namesMap: namesMap)
        }
        return nil
    }

    // MARK: - Internal Resolution

    private func resolveSpec(
        _ spec: String,
        namesMap: [String: [String: String]],
        stringsMap: [String: [String: String]]
    ) -> String? {
        if spec.hasPrefix("hand:") {
            return localizedString(forKey: spec, stringsMap: stringsMap)
        }
        if !spec.contains("|") {
            return localizedString(forKey: spec, stringsMap: stringsMap)
        }
        let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let tmplKey = parts[0]
        let argSpec = parts[1]
        let argName = resolveArg(argSpec, namesMap: namesMap)
        return renderTemplate(tmplKey, argName: argName, stringsMap: stringsMap) ?? argName
    }

    private func resolveArg(_ argSpec: String, namesMap: [String: [String: String]]) -> String {
        if argSpec.hasPrefix("lit:") {
            return String(argSpec.dropFirst(4))
        }
        if let dict = namesMap[argSpec] {
            return dict["zh-Hans"] ?? dict["en"] ?? argSpec
        }
        if let colon = argSpec.firstIndex(of: ":") {
            return String(argSpec[argSpec.index(after: colon)...])
        }
        return argSpec
    }

    private func renderTemplate(
        _ key: String,
        argName: String,
        stringsMap: [String: [String: String]]
    ) -> String? {
        guard let tmpl = localizedString(forKey: key, stringsMap: stringsMap) else { return nil }
        return tmpl.replacingOccurrences(of: "{name}", with: argName)
    }

    private func localizedString(forKey key: String, stringsMap: [String: [String: String]]) -> String? {
        guard let dict = stringsMap[key] else { return nil }
        return dict["zh-Hans"] ?? dict["en"] ?? dict.values.first
    }
}
