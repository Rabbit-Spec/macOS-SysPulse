import Foundation
import AppKit
import Observation

// MARK: - 启动项管理数据模型

public enum StartupItemKind: String, CaseIterable, Identifiable, Sendable {
    case launchAgentUser = "用户启动代理"
    case launchAgentGlobal = "全局启动代理"
    case launchDaemon = "系统守护进程"
    case embeddedLoginItem = "应用内置登录项"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .launchAgentUser: return "person.crop.circle.badge.checkmark"
        case .launchAgentGlobal: return "gearshape.2.fill"
        case .launchDaemon: return "server.rack"
        case .embeddedLoginItem: return "app.badge.checkmark.fill"
        }
    }

    var sortPriority: Int {
        switch self {
        case .launchDaemon: return 0
        case .launchAgentGlobal: return 1
        case .launchAgentUser: return 2
        case .embeddedLoginItem: return 3
        }
    }
}

public enum StartupManagementPolicy: String, Sendable {
    case manageable = "可直接启停"
    case requiresAdmin = "需管理员权限"
    case systemSettings = "受系统保护"
}

public enum StartupRuntimeStatus: Sendable, Equatable {
    case running(pid: Int?)
    case loadedIdle
    case disabled
    case missingBinary
    case errorExit(Int)

    public var label: String {
        switch self {
        case .running(let pid):
            if let pid { return "运行中 · PID \(pid)" }
            return "运行中"
        case .loadedIdle: return "已加载待命"
        case .disabled: return "已禁用"
        case .missingBinary: return "程序缺失"
        case .errorExit(let code): return "异常退出 (\(code))"
        }
    }

    public var isAlert: Bool {
        switch self {
        case .missingBinary, .errorExit: return true
        default: return false
        }
    }
}

public enum StartupFilterOption: String, CaseIterable, Identifiable, Sendable {
    case all = "全部启动项"
    case active = "活跃 / 已启用"
    case userAgents = "用户自启"
    case daemons = "后台守护"
    case issues = "程序缺失 / 异常"

    public var id: String { rawValue }
}

public struct StartupItem: Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let displayName: String
    public let kind: StartupItemKind
    public let policy: StartupManagementPolicy
    public var runtimeStatus: StartupRuntimeStatus
    public let plistURL: URL
    public let programPath: String?
    public let programArguments: [String]
    public let ownerAppName: String
    public let ownerBundleURL: URL?
    public let groupKey: String
    public var isEnabled: Bool
    public let plistDisabledDefault: Bool
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let sizeBytes: Int64
    public let isOrphanedOwner: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        displayName: String,
        kind: StartupItemKind,
        policy: StartupManagementPolicy,
        runtimeStatus: StartupRuntimeStatus,
        plistURL: URL,
        programPath: String?,
        programArguments: [String],
        ownerAppName: String,
        ownerBundleURL: URL?,
        groupKey: String = "",
        isEnabled: Bool,
        plistDisabledDefault: Bool = false,
        runAtLoad: Bool,
        keepAlive: Bool,
        sizeBytes: Int64,
        isOrphanedOwner: Bool
    ) {
        self.id = id
        self.label = label
        self.displayName = displayName
        self.kind = kind
        self.policy = policy
        self.runtimeStatus = runtimeStatus
        self.plistURL = plistURL
        self.programPath = programPath
        self.programArguments = programArguments
        self.ownerAppName = ownerAppName
        self.ownerBundleURL = ownerBundleURL
        self.groupKey = groupKey.isEmpty ? label.lowercased() : groupKey
        self.isEnabled = isEnabled
        self.plistDisabledDefault = plistDisabledDefault
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.sizeBytes = sizeBytes
        self.isOrphanedOwner = isOrphanedOwner
    }
}

public struct StartupAppGroup: Identifiable, Sendable {
    public let id: String
    public let appName: String
    public let bundleURL: URL?
    public let items: [StartupItem]

    public var manageableItems: [StartupItem] {
        items.filter { $0.kind != .embeddedLoginItem && $0.policy != .systemSettings }
    }

    public var isOnlySystemSettingsManaged: Bool {
        manageableItems.isEmpty
    }

    public var enabledManageableCount: Int {
        manageableItems.filter(\.isEnabled).count
    }

    public var isEnabled: Bool {
        manageableItems.isEmpty ? items.contains(where: \.isEnabled) : enabledManageableCount > 0
    }

    public var isPartiallyEnabled: Bool {
        !manageableItems.isEmpty && enabledManageableCount > 0 && enabledManageableCount < manageableItems.count
    }

    public var hasAlert: Bool {
        items.contains { $0.runtimeStatus.isAlert || $0.isOrphanedOwner }
    }

    public var hasRunning: Bool {
        items.contains {
            if case .running = $0.runtimeStatus { return true }
            return false
        }
    }

    public var hasDaemon: Bool {
        items.contains { $0.kind == .launchDaemon }
    }

    public var hasKeepAlive: Bool {
        items.contains(where: \.keepAlive)
    }

    public var subtitleSummary: String {
        if items.count == 1 {
            return items[0].label
        }
        return items.map(\.label).joined(separator: " · ")
    }

    public var kindBadgeText: String {
        if items.count == 1 {
            return items[0].kind.rawValue
        }
        let hasAgents = items.contains { $0.kind == .launchAgentUser || $0.kind == .launchAgentGlobal }
        let hasEmbedded = items.contains { $0.kind == .embeddedLoginItem }
        if hasDaemon && hasAgents {
            return "代理 + 守护"
        }
        if hasEmbedded && (hasAgents || hasDaemon) {
            return "混合自启项"
        }
        if hasDaemon {
            return StartupItemKind.launchDaemon.rawValue
        }
        if hasEmbedded {
            return StartupItemKind.embeddedLoginItem.rawValue
        }
        return items[0].kind.rawValue
    }

    public var statusBadgeText: String {
        if hasAlert { return "含异常项" }
        if isOnlySystemSettingsManaged { return "系统登录项" }
        if enabledManageableCount == 0 { return "已禁用" }
        if isPartiallyEnabled { return "已启用 \(enabledManageableCount)/\(manageableItems.count)" }
        if hasRunning { return "运行中" }
        return "已启用"
    }
}

// MARK: - 启动项管理引擎

public struct BTMDiagnosticRecord: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let identifier: String
    public let disposition: String
    public let type: String
    public let urlPath: String
    public let parentIdentifier: String
}

@Observable
@MainActor
public final class StartupItemManager {
    public static let shared = StartupItemManager()

    public var items: [StartupItem] = []
    public var isScanning: Bool = false
    public var isBusy: Bool = false
    public var searchQuery: String = ""
    public var selectedFilter: StartupFilterOption = .all
    public var statusMessage: String = ""
    public var btmRawReport: String = ""
    public var btmRecords: [BTMDiagnosticRecord] = []
    public var showStructuredBtmView: Bool = true
    public var isBtmSheetPresented: Bool = false
    public var hoveredItemID: UUID? = nil
    public var hoveredGroupID: String? = nil
    public var expandedGroupIDs: Set<String> = []

    private var currentScanTask: Task<Void, Never>? = nil

    public init() {}

    public var allGroups: [StartupAppGroup] {
        buildGroups(from: items)
    }

    public var filteredGroups: [StartupAppGroup] {
        var result = allGroups.filter { groupMatches($0, filter: selectedFilter) }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            result = result.filter { group in
                if group.appName.lowercased().contains(q) {
                    return true
                }
                return group.items.contains {
                    $0.displayName.lowercased().contains(q)
                        || $0.label.lowercased().contains(q)
                        || $0.ownerAppName.lowercased().contains(q)
                        || ($0.programPath?.lowercased().contains(q) ?? false)
                }
            }
        }
        return result
    }

    public var filteredItems: [StartupItem] {
        filteredGroups.flatMap(\.items)
    }

    public var enabledCount: Int {
        items.filter(\.isEnabled).count
    }

    public var enabledGroupsCount: Int {
        allGroups.filter(\.isEnabled).count
    }

    public var issuesCount: Int {
        items.filter { $0.runtimeStatus.isAlert || $0.isOrphanedOwner }.count
    }

    public func count(for filter: StartupFilterOption) -> Int {
        allGroups.filter { groupMatches($0, filter: filter) }.count
    }

    public func toggleGroupExpanded(_ groupID: String) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
    }

    private func groupMatches(_ group: StartupAppGroup, filter: StartupFilterOption) -> Bool {
        switch filter {
        case .all:
            return true
        case .active:
            return group.isEnabled
        case .userAgents:
            return group.items.contains {
                $0.kind == .launchAgentUser || $0.kind == .launchAgentGlobal || $0.kind == .embeddedLoginItem
            }
        case .daemons:
            return group.items.contains { $0.kind == .launchDaemon }
        case .issues:
            return group.hasAlert
        }
    }

    private func buildGroups(from sourceItems: [StartupItem]) -> [StartupAppGroup] {
        var buckets: [String: [StartupItem]] = [:]
        var bucketOrder: [String] = []
        for item in sourceItems {
            if buckets[item.groupKey] == nil {
                bucketOrder.append(item.groupKey)
            }
            buckets[item.groupKey, default: []].append(item)
        }

        let groups: [StartupAppGroup] = bucketOrder.compactMap { key in
            guard let groupItems = buckets[key], !groupItems.isEmpty else { return nil }
            let sortedItems = groupItems.sorted { lhs, rhs in
                if lhs.kind.sortPriority != rhs.kind.sortPriority {
                    return lhs.kind.sortPriority < rhs.kind.sortPriority
                }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
            let primaryBundleURL = sortedItems.compactMap(\.ownerBundleURL).first
            let primaryName = sortedItems.first(where: { $0.ownerBundleURL != nil })?.ownerAppName
                ?? sortedItems[0].ownerAppName
            return StartupAppGroup(
                id: key,
                appName: primaryName,
                bundleURL: primaryBundleURL,
                items: sortedItems
            )
        }

        return groups.sorted { lhs, rhs in
            if lhs.hasAlert != rhs.hasAlert {
                return lhs.hasAlert && !rhs.hasAlert
            }
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }
            return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
        }
    }

    public func startScan() {
        currentScanTask?.cancel()
        isScanning = true
        statusMessage = "正在枚举 LaunchAgents / LaunchDaemons / 内置登录项…"

        currentScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let discovered = Self.scanAllStartupItems()
            await MainActor.run {
                guard let self else { return }
                self.items = discovered
                self.isScanning = false
                let alerts = discovered.filter { $0.runtimeStatus.isAlert || $0.isOrphanedOwner }.count
                let groupCount = self.allGroups.count
                self.statusMessage = alerts > 0
                    ? "已扫描 \(groupCount) 款应用共 \(discovered.count) 项自启服务，发现 \(alerts) 项异常或宿主缺失"
                    : "已扫描 \(groupCount) 款应用共 \(discovered.count) 项系统与用户自启服务"
            }
        }
    }

    public func toggleGroup(_ group: StartupAppGroup) {
        guard !isBusy else { return }
        if group.isOnlySystemSettingsManaged {
            openSystemLoginItemsSettings()
            return
        }
        let targetEnabled = !group.isEnabled
        performToggle(items: group.manageableItems, enable: targetEnabled, title: group.appName)
    }

    public func toggleItem(_ item: StartupItem) {
        guard !isBusy else { return }
        if item.kind == .embeddedLoginItem || item.policy == .systemSettings {
            openSystemLoginItemsSettings()
            return
        }
        performToggle(items: [item], enable: !item.isEnabled, title: item.label)
    }

    private func performToggle(items targetItems: [StartupItem], enable: Bool, title: String) {
        let actionable = targetItems.filter { $0.kind != .embeddedLoginItem && $0.policy != .systemSettings }
        guard !actionable.isEmpty else { return }

        isBusy = true
        statusMessage = "\(enable ? "正在启用" : "正在禁用") \(title)…"
        let currentItemsSnapshot = self.items

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.applyBatchEnableDisable(items: actionable, enable: enable)
            let refreshedItems = Self.refreshRuntimeStates(items: currentItemsSnapshot)
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.items = refreshedItems
                if let err = result.error {
                    self.statusMessage = "操作失败：\(err)"
                } else {
                    self.statusMessage = "\(title) 已\(enable ? "启用" : "禁用")"
                }
            }
        }
    }

    public func trashStartupItem(_ item: StartupItem) {
        guard !isBusy, item.kind != .embeddedLoginItem else { return }
        isBusy = true
        statusMessage = "正在卸载自启配置 \(item.label)…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let err = Self.removeStartupPlist(item: item)
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                if let err {
                    self.statusMessage = "移除失败：\(err)"
                } else {
                    self.items.removeAll { $0.id == item.id }
                    self.statusMessage = "已移出并卸载 \(item.label)"
                }
            }
        }
    }

    public func openSystemLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public func loadPrivilegedBtmDump() {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在通过启动项管理权限读取系统 BTM 注册快照…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let output = SystemPermissionManager.executePrivilegedHelper(
                args: ["--dump-btm"],
                touchIDReason: "使用启动项管理权限读取系统 BTM 快照",
                allowBootstrapPrompt: true
            )
            let parsedRecords = Self.parseBtmDump(output.stdout)
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                if output.succeeded {
                    self.btmRawReport = output.stdout.isEmpty ? "无 BTM 记录返回" : output.stdout
                    self.btmRecords = parsedRecords
                    self.isBtmSheetPresented = true
                    self.statusMessage = "已读取系统 BTM 后台任务管理快照（解析 \(parsedRecords.count) 条记录）"
                } else {
                    self.statusMessage = output.errorMessage ?? "已取消或授权失败"
                }
            }
        }
    }

    nonisolated public static func parseBtmDump(_ raw: String) -> [BTMDiagnosticRecord] {
        guard !raw.isEmpty else { return [] }
        var records: [BTMDiagnosticRecord] = []

        var curName = ""
        var curIdentifier = ""
        var curDisposition = ""
        var curType = ""
        var curURL = ""
        var curParent = ""

        func flushCurrent() {
            guard !curName.isEmpty || !curIdentifier.isEmpty else { return }
            records.append(
                BTMDiagnosticRecord(
                    name: curName.isEmpty ? curIdentifier : curName,
                    identifier: curIdentifier.isEmpty ? "—" : curIdentifier,
                    disposition: curDisposition.isEmpty ? "—" : curDisposition,
                    type: curType.isEmpty ? "—" : curType,
                    urlPath: curURL.isEmpty ? "—" : curURL,
                    parentIdentifier: curParent
                )
            )
            curName = ""
            curIdentifier = ""
            curDisposition = ""
            curType = ""
            curURL = ""
            curParent = ""
        }

        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("UUID:") || trimmed.hasPrefix("#") || trimmed.isEmpty {
                if trimmed.hasPrefix("UUID:") || trimmed.hasPrefix("#") {
                    flushCurrent()
                }
                continue
            }
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            guard !val.isEmpty, val != "(null)" else { continue }

            switch key {
            case "name":
                if !curName.isEmpty { flushCurrent() }
                curName = val
            case "identifier", "bundle identifier":
                curIdentifier = val
            case "disposition":
                curDisposition = val
            case "type":
                curType = val
            case "url", "executable path":
                curURL = val
            case "parent identifier", "assoc. bundle ids":
                curParent = val
            default:
                break
            }
        }
        flushCurrent()
        return records
    }

    /// 供应用卸载引擎在清理前自动注销关联 launchd 代理。
    nonisolated public static func bootoutMatchingServices(labels: [String], plistURLs: [URL]) {
        let uid = getuid()
        for label in Set(labels) where !label.isEmpty {
            _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)/\(label)"])
            _ = runProcess("/bin/launchctl", args: ["disable", "gui/\(uid)/\(label)"])
        }
        for url in plistURLs {
            if url.path.hasPrefix("/Users/") {
                _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)", url.path])
            }
        }
    }

    // MARK: - Background Scanner Implementation

    private struct InstalledAppCatalogEntry {
        let displayName: String
        let rawName: String
        let bundleIDLower: String
        let prefix3: String?
        let url: URL
    }

    nonisolated private static func threeSegmentPrefix(_ rawIdentifier: String) -> String? {
        let parts = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: ".")
            .map(String.init)
        let commonTLDs: Set<String> = ["com", "net", "org", "io", "app", "cn", "me", "dev", "ai", "co"]
        guard parts.count >= 3, commonTLDs.contains(parts[0]), parts[2].count >= 3 else {
            return nil
        }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    nonisolated private static func extractAppBundleURL(from commandArgs: [String], fm: FileManager) -> URL? {
        for rawArg in commandArgs {
            guard let range = rawArg.range(of: ".app", options: .caseInsensitive) else { continue }
            let endIdx = range.upperBound
            let remainder = rawArg[endIdx...]
            guard remainder.isEmpty || remainder.hasPrefix("/") else { continue }
            let candidate = String(rawArg[..<endIdx])
            guard candidate.hasPrefix("/"), fm.fileExists(atPath: candidate) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    nonisolated private static func scanAllStartupItems() -> [StartupItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. Collect installed apps catalog (including subfolders like /Applications/Utilities)
        var catalog: [InstalledAppCatalogEntry] = []
        var embeddedLoginItems: [StartupItem] = []

        var discoveredAppURLs: [URL] = []
        let appRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true)
        ]
        for root in appRoots {
            guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in contents {
                if entry.pathExtension.lowercased() == "app" {
                    discoveredAppURLs.append(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let subItems = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for sub in subItems where sub.pathExtension.lowercased() == "app" {
                        discoveredAppURLs.append(sub)
                    }
                }
            }
        }

        for appURL in discoveredAppURLs {
            let rawName = appURL.deletingPathExtension().lastPathComponent
            guard let appInfo = FreshBundleInfo.read(at: appURL) else { continue }
            let bidLower = appInfo.bundleID.lowercased()
            let display = appInfo.displayName ?? appInfo.bundleName ?? rawName
            let appGroupKey = "app:\(appURL.standardizedFileURL.path.lowercased())"

            catalog.append(
                InstalledAppCatalogEntry(
                    displayName: display,
                    rawName: rawName,
                    bundleIDLower: bidLower,
                    prefix3: threeSegmentPrefix(bidLower),
                    url: appURL
                )
            )

            let loginDir = appURL.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
            if let subApps = try? fm.contentsOfDirectory(at: loginDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for subApp in subApps where subApp.pathExtension.lowercased() == "app" {
                    let subInfo = FreshBundleInfo.read(at: subApp, requireBundleID: false)
                    let subBID = (subInfo?.bundleID.isEmpty == false ? subInfo?.bundleID : nil) ?? subApp.deletingPathExtension().lastPathComponent
                    let subName = subInfo?.displayName ?? subApp.deletingPathExtension().lastPathComponent
                    embeddedLoginItems.append(
                        StartupItem(
                            label: subBID,
                            displayName: "\(display) · \(subName)",
                            kind: .embeddedLoginItem,
                            policy: .systemSettings,
                            runtimeStatus: .loadedIdle,
                            plistURL: subApp,
                            programPath: subInfo?.executableURL?.path ?? subApp.path,
                            programArguments: [],
                            ownerAppName: display,
                            ownerBundleURL: appURL,
                            groupKey: appGroupKey,
                            isEnabled: true,
                            plistDisabledDefault: false,
                            runAtLoad: true,
                            keepAlive: false,
                            sizeBytes: 0,
                            isOrphanedOwner: false
                        )
                    )
                }
            }
        }

        let sortedCatalog = catalog.sorted { $0.bundleIDLower.count > $1.bundleIDLower.count }
        let runtimeSnapshot = captureRuntimeSnapshot()

        let searchDirs: [(url: URL, kind: StartupItemKind, policy: StartupManagementPolicy)] = [
            (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), .launchAgentUser, .manageable),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .launchAgentGlobal, .manageable),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), .launchDaemon, .requiresAdmin)
        ]

        var collected: [StartupItem] = []

        for source in searchDirs {
            guard let files = try? fm.contentsOfDirectory(at: source.url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for plistURL in files where plistURL.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    continue
                }
                let label = (plist["Label"] as? String) ?? plistURL.deletingPathExtension().lastPathComponent
                let labelLower = label.lowercased()
                let program = plist["Program"] as? String
                let programArgs = plist["ProgramArguments"] as? [String] ?? []
                let effectiveProgram = program ?? programArgs.first
                let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
                let keepAlive: Bool = {
                    if let b = plist["KeepAlive"] as? Bool { return b }
                    if plist["KeepAlive"] is [String: Any] { return true }
                    return false
                }()
                let plistDisabled = (plist["Disabled"] as? Bool) ?? false
                let isEnabled = !resolveDomainDisabled(
                    label: label,
                    kind: source.kind,
                    plistDisabledDefault: plistDisabled,
                    snapshot: runtimeSnapshot
                )

                var associatedIDs: [String] = []
                if let arr = plist["AssociatedBundleIdentifiers"] as? [String] {
                    associatedIDs = arr.map { $0.lowercased() }
                } else if let single = plist["AssociatedBundleIdentifiers"] as? String, !single.isEmpty {
                    associatedIDs = [single.lowercased()]
                }

                let labelPrefix3 = threeSegmentPrefix(labelLower)
                var matchedApp: InstalledAppCatalogEntry? = nil

                // Priority 1: AssociatedBundleIdentifiers
                for assoc in associatedIDs {
                    if let hit = sortedCatalog.first(where: {
                        $0.bundleIDLower == assoc
                            || $0.bundleIDLower.hasPrefix(assoc + ".")
                            || assoc.hasPrefix($0.bundleIDLower + ".")
                    }) {
                        matchedApp = hit
                        break
                    }
                    if let assocP3 = threeSegmentPrefix(assoc),
                       let hit = sortedCatalog.first(where: { $0.prefix3 == assocP3 }) {
                        matchedApp = hit
                        break
                    }
                }

                // Priority 2: Exact or prefix bundleID match against label
                if matchedApp == nil {
                    matchedApp = sortedCatalog.first(where: {
                        labelLower == $0.bundleIDLower
                            || labelLower.hasPrefix($0.bundleIDLower + ".")
                            || $0.bundleIDLower.hasPrefix(labelLower + ".")
                    })
                }

                // Priority 3: 3-segment vendor+product prefix (e.g. com.youqu.todesk -> com.youqu.todesk.mac, com.tencent.lemon*)
                if matchedApp == nil, let labelPrefix3 {
                    matchedApp = sortedCatalog.first(where: { $0.prefix3 == labelPrefix3 })
                }

                // Priority 4: Main /Applications or ~/Applications .app path referenced in Program / ProgramArguments
                let cmdCandidates = ([program].compactMap { $0 }) + programArgs
                let embeddedArgAppURL = extractAppBundleURL(from: cmdCandidates, fm: fm)
                if matchedApp == nil, let embeddedArgAppURL {
                    let argPath = embeddedArgAppURL.standardizedFileURL.path
                    if argPath.hasPrefix("/Applications/") || argPath.hasPrefix(home.appendingPathComponent("Applications").path + "/") {
                        matchedApp = sortedCatalog.first(where: { $0.url.standardizedFileURL.path == argPath })
                    }
                }

                var resolvedOwnerName = inferOwnerName(from: label, plistURL: plistURL)
                var resolvedOwnerURL: URL? = nil
                var groupKey = ""

                if let matchedApp {
                    resolvedOwnerName = matchedApp.displayName
                    resolvedOwnerURL = matchedApp.url
                    groupKey = "app:\(matchedApp.url.standardizedFileURL.path.lowercased())"
                } else if let embeddedArgAppURL {
                    let info = FreshBundleInfo.read(at: embeddedArgAppURL, requireBundleID: false)
                    resolvedOwnerName = info?.displayName ?? info?.bundleName ?? embeddedArgAppURL.deletingPathExtension().lastPathComponent
                    resolvedOwnerURL = embeddedArgAppURL
                    groupKey = "app:\(embeddedArgAppURL.standardizedFileURL.path.lowercased())"
                } else if let labelPrefix3 {
                    groupKey = "vendor:\(labelPrefix3)"
                } else {
                    groupKey = "owner:\(resolvedOwnerName.lowercased())"
                }

                let binaryMissing: Bool = {
                    guard let execPath = effectiveProgram, !execPath.isEmpty else { return false }
                    if execPath.hasPrefix("/") {
                        return !fm.fileExists(atPath: execPath)
                    }
                    return false
                }()

                let runtime = resolveRuntimeStatus(
                    label: label,
                    programPath: effectiveProgram,
                    isEnabled: isEnabled,
                    binaryMissing: binaryMissing,
                    snapshot: runtimeSnapshot
                )

                let sizeBytes = Int64((try? plistURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let isOrphan = (resolvedOwnerURL == nil) && binaryMissing

                collected.append(
                    StartupItem(
                        label: label,
                        displayName: label,
                        kind: source.kind,
                        policy: source.policy,
                        runtimeStatus: runtime,
                        plistURL: plistURL,
                        programPath: effectiveProgram,
                        programArguments: programArgs,
                        ownerAppName: resolvedOwnerName,
                        ownerBundleURL: resolvedOwnerURL,
                        groupKey: groupKey,
                        isEnabled: isEnabled,
                        plistDisabledDefault: plistDisabled,
                        runAtLoad: runAtLoad,
                        keepAlive: keepAlive,
                        sizeBytes: sizeBytes,
                        isOrphanedOwner: isOrphan
                    )
                )
            }
        }

        collected.append(contentsOf: embeddedLoginItems)
        return collected.sorted {
            if $0.runtimeStatus.isAlert != $1.runtimeStatus.isAlert {
                return $0.runtimeStatus.isAlert && !$1.runtimeStatus.isAlert
            }
            if $0.isEnabled != $1.isEnabled {
                return $0.isEnabled && !$1.isEnabled
            }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private struct LaunchRuntimeSnapshot {
        let guiDisabled: [String: Bool]
        let sysDisabled: [String: Bool]
        let activeLaunchList: [String: (pid: Int?, lastStatus: Int)]
        let runningPIDByCommPath: [String: Int]
        let runningPIDByExecName: [String: Int]
    }

    nonisolated private static func captureRuntimeSnapshot() -> LaunchRuntimeSnapshot {
        let uid = getuid()
        let guiDisabled = parseDisabledMap(runProcess("/bin/launchctl", args: ["print-disabled", "gui/\(uid)"]).stdout)
        let sysDisabled = parseDisabledMap(runProcess("/bin/launchctl", args: ["print-disabled", "system"]).stdout)
        let activeLaunchList = parseLaunchctlList(runProcess("/bin/launchctl", args: ["list"]).stdout)

        var pidByPath: [String: Int] = [:]
        var pidByName: [String: Int] = [:]
        let psOut = runProcess("/bin/ps", args: ["-axo", "pid=,comm="]).stdout
        for line in psOut.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(where: \.isWhitespace),
                  let pid = Int(trimmed[..<spaceIdx]) else { continue }
            let comm = trimmed[spaceIdx...].trimmingCharacters(in: .whitespaces)
            guard !comm.isEmpty else { continue }
            pidByPath[comm] = pid
            let baseName = URL(fileURLWithPath: comm).lastPathComponent
            if !baseName.isEmpty && pidByName[baseName] == nil {
                pidByName[baseName] = pid
            }
        }

        return LaunchRuntimeSnapshot(
            guiDisabled: guiDisabled,
            sysDisabled: sysDisabled,
            activeLaunchList: activeLaunchList,
            runningPIDByCommPath: pidByPath,
            runningPIDByExecName: pidByName
        )
    }

    nonisolated private static func resolveDomainDisabled(
        label: String,
        kind: StartupItemKind,
        plistDisabledDefault: Bool,
        snapshot: LaunchRuntimeSnapshot
    ) -> Bool {
        switch kind {
        case .launchAgentUser, .launchAgentGlobal:
            return snapshot.guiDisabled[label] ?? plistDisabledDefault
        case .launchDaemon:
            return snapshot.sysDisabled[label] ?? plistDisabledDefault
        case .embeddedLoginItem:
            return false
        }
    }

    nonisolated private static func resolveRuntimeStatus(
        label: String,
        programPath: String?,
        isEnabled: Bool,
        binaryMissing: Bool,
        snapshot: LaunchRuntimeSnapshot
    ) -> StartupRuntimeStatus {
        if binaryMissing {
            return .missingBinary
        }
        if !isEnabled {
            return .disabled
        }
        if let job = snapshot.activeLaunchList[label] {
            if let pid = job.pid {
                return .running(pid: pid)
            }
            if job.lastStatus != 0 && job.lastStatus != -15 && job.lastStatus != 78
                && job.lastStatus != 143 && job.lastStatus != -9 && job.lastStatus != 137
                && job.lastStatus != -2 && job.lastStatus != 130 && job.lastStatus != -1 {
                return .errorExit(job.lastStatus)
            }
        }
        if let prog = programPath {
            if let pid = snapshot.runningPIDByCommPath[prog] {
                return .running(pid: pid)
            }
            let baseName = URL(fileURLWithPath: prog).lastPathComponent
            if let pid = snapshot.runningPIDByExecName[baseName] {
                return .running(pid: pid)
            }
        }
        return .loadedIdle
    }

    nonisolated private static func refreshRuntimeStates(items: [StartupItem]) -> [StartupItem] {
        let fm = FileManager.default
        let snapshot = captureRuntimeSnapshot()
        return items.map { item in
            var updated = item
            guard item.kind != .embeddedLoginItem else { return updated }
            let disabled = resolveDomainDisabled(
                label: item.label,
                kind: item.kind,
                plistDisabledDefault: item.plistDisabledDefault,
                snapshot: snapshot
            )
            let enabled = !disabled
            let binaryMissing: Bool = {
                guard let execPath = item.programPath, !execPath.isEmpty, execPath.hasPrefix("/") else { return false }
                return !fm.fileExists(atPath: execPath)
            }()
            updated.isEnabled = enabled
            updated.runtimeStatus = resolveRuntimeStatus(
                label: item.label,
                programPath: item.programPath,
                isEnabled: enabled,
                binaryMissing: binaryMissing,
                snapshot: snapshot
            )
            return updated
        }
    }

    nonisolated private static func applyBatchEnableDisable(items: [StartupItem], enable: Bool) -> (succeeded: Bool, error: String?) {
        let uid = getuid()
        let guiItems = items.filter { $0.kind == .launchAgentUser || $0.kind == .launchAgentGlobal }
        let daemonItems = items.filter { $0.kind == .launchDaemon }

        // 1. User & Global LaunchAgents run in gui/<uid> domain and never need an admin password prompt
        let userDomain = "gui/\(uid)"
        for item in guiItems {
            if enable {
                _ = runProcess("/bin/launchctl", args: ["enable", "\(userDomain)/\(item.label)"])
                let boot = runProcess("/bin/launchctl", args: ["bootstrap", userDomain, item.plistURL.path])
                if boot.exitCode != 0 {
                    _ = runProcess("/bin/launchctl", args: ["kickstart", "-k", "\(userDomain)/\(item.label)"])
                }
            } else {
                _ = runProcess("/bin/launchctl", args: ["disable", "\(userDomain)/\(item.label)"])
                _ = runProcess("/bin/launchctl", args: ["bootout", "\(userDomain)/\(item.label)"])
                _ = runProcess("/bin/launchctl", args: ["bootout", userDomain, item.plistURL.path])
            }
        }

        // 2. Root LaunchDaemons run in system domain — batch via unified Touch ID helper
        guard !daemonItems.isEmpty else {
            return (true, nil)
        }

        var helperArgs = ["--daemon-batch", enable ? "enable" : "disable"]
        for item in daemonItems {
            helperArgs.append(item.label)
            helperArgs.append(item.plistURL.path)
        }
        let res = SystemPermissionManager.executePrivilegedHelper(
            args: helperArgs,
            touchIDReason: enable ? "使用启动项管理权限启用系统启动项" : "使用启动项管理权限停用系统启动项",
            allowBootstrapPrompt: true
        )
        return (res.succeeded, res.errorMessage)
    }

    nonisolated private static func removeStartupPlist(item: StartupItem) -> String? {
        let uid = getuid()
        let fm = FileManager.default
        if item.kind == .launchAgentUser {
            _ = runProcess("/bin/launchctl", args: ["disable", "gui/\(uid)/\(item.label)"])
            _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)", item.plistURL.path])
            _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)/\(item.label)"])
            do {
                try fm.trashItem(at: item.plistURL, resultingItemURL: nil)
                return nil
            } catch {
                return error.localizedDescription
            }
        } else if item.kind == .launchAgentGlobal {
            _ = runProcess("/bin/launchctl", args: ["disable", "gui/\(uid)/\(item.label)"])
            _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)", item.plistURL.path])
            _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)/\(item.label)"])
            let res = SystemPermissionManager.executePrivilegedHelper(
                args: ["--remove-startup-plist", "global", item.label, item.plistURL.path],
                touchIDReason: "使用启动项管理权限删除全局启动项",
                allowBootstrapPrompt: true
            )
            return res.succeeded ? nil : (res.errorMessage ?? "需要启动项管理权限移除全局启动项配置")
        } else {
            let res = SystemPermissionManager.executePrivilegedHelper(
                args: ["--remove-startup-plist", "daemon", item.label, item.plistURL.path],
                touchIDReason: "使用启动项管理权限停用并删除守护进程",
                allowBootstrapPrompt: true
            )
            return res.succeeded ? nil : (res.errorMessage ?? "需要启动项管理权限移除系统级配置")
        }
    }

    nonisolated private static func parseDisabledMap(_ text: String) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { continue }
            let parts = trimmed.components(separatedBy: "\" => ")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let val = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if val == "true" || val == "disabled" {
                map[label] = true
            } else if val == "false" || val == "enabled" {
                map[label] = false
            }
        }
        return map
    }

    nonisolated private static func parseLaunchctlList(_ text: String) -> [String: (pid: Int?, lastStatus: Int)] {
        var dict: [String: (Int?, Int)] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard cols.count >= 3, cols[0] != "PID" else { continue }
            let pid = Int(cols[0])
            let code = Int(cols[1]) ?? 0
            let label = cols[2...].joined(separator: " ")
            dict[label] = (pid, code)
        }
        return dict
    }

    nonisolated private static func inferOwnerName(from label: String, plistURL: URL) -> String {
        let parts = label.split(separator: ".").map(String.init)
        if parts.count >= 3 {
            return parts[1].capitalized
        }
        if let first = parts.first, first.count > 2 {
            return first.capitalized
        }
        return plistURL.deletingPathExtension().lastPathComponent
    }

    nonisolated private static func runProcess(_ launchPath: String, args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (
                proc.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
