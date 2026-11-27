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
    public var isEnabled: Bool
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
        isEnabled: Bool,
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
        self.isEnabled = isEnabled
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.sizeBytes = sizeBytes
        self.isOrphanedOwner = isOrphanedOwner
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

    private var currentScanTask: Task<Void, Never>? = nil

    public init() {}

    public var filteredItems: [StartupItem] {
        var result = items
        switch selectedFilter {
        case .all:
            break
        case .active:
            result = result.filter { $0.isEnabled }
        case .userAgents:
            result = result.filter { $0.kind == .launchAgentUser || $0.kind == .embeddedLoginItem }
        case .daemons:
            result = result.filter { $0.kind == .launchAgentGlobal || $0.kind == .launchDaemon }
        case .issues:
            result = result.filter { $0.runtimeStatus.isAlert || $0.isOrphanedOwner }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.label.lowercased().contains(q)
                    || $0.ownerAppName.lowercased().contains(q)
                    || ($0.programPath?.lowercased().contains(q) ?? false)
            }
        }
        return result
    }

    public var enabledCount: Int {
        items.filter(\.isEnabled).count
    }

    public var issuesCount: Int {
        items.filter { $0.runtimeStatus.isAlert || $0.isOrphanedOwner }.count
    }

    public func count(for filter: StartupFilterOption) -> Int {
        switch filter {
        case .all: return items.count
        case .active: return items.filter(\.isEnabled).count
        case .userAgents: return items.filter { $0.kind == .launchAgentUser || $0.kind == .embeddedLoginItem }.count
        case .daemons: return items.filter { $0.kind == .launchAgentGlobal || $0.kind == .launchDaemon }.count
        case .issues: return items.filter { $0.runtimeStatus.isAlert || $0.isOrphanedOwner }.count
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
                self.statusMessage = alerts > 0
                    ? "已扫描 \(discovered.count) 项自启服务，发现 \(alerts) 项异常或宿主缺失"
                    : "已扫描 \(discovered.count) 项系统与用户自启服务"
            }
        }
    }

    public func toggleItem(_ item: StartupItem) {
        guard !isBusy else { return }
        if item.kind == .embeddedLoginItem || item.policy == .systemSettings {
            openSystemLoginItemsSettings()
            return
        }

        let targetEnabled = !item.isEnabled
        isBusy = true
        statusMessage = "\(targetEnabled ? "正在启用" : "正在禁用") \(item.label)…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.applyEnableDisable(item: item, enable: targetEnabled)
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                if let err = result.error {
                    self.statusMessage = "操作失败：\(err)"
                } else {
                    if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                        self.items[idx].isEnabled = targetEnabled
                        self.items[idx].runtimeStatus = targetEnabled ? .loadedIdle : .disabled
                    }
                    self.statusMessage = "\(item.displayName) 已\(targetEnabled ? "启用" : "禁用")"
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
        statusMessage = "正在通过管理员授权读取系统 BTM 注册快照…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let output = Self.runAppleScriptPrivileged("/usr/bin/sfltool dumpbtm")
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

    nonisolated private static func scanAllStartupItems() -> [StartupItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let uid = getuid()

        // 1. Collect installed apps index to match ownership
        var installedAppsByLowerName: [String: URL] = [:]
        var installedAppsByLowerBID: [String: (name: String, url: URL)] = [:]
        var embeddedLoginItems: [StartupItem] = []

        for appDir in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            guard let contents = try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for appURL in contents where appURL.pathExtension == "app" {
                let rawName = appURL.deletingPathExtension().lastPathComponent
                installedAppsByLowerName[rawName.lowercased()] = appURL
                if let appInfo = FreshBundleInfo.read(at: appURL) {
                    let bid = appInfo.bundleID.lowercased()
                    let display = appInfo.displayName
                        ?? appInfo.bundleName
                        ?? rawName
                    installedAppsByLowerBID[bid] = (display, appURL)
                    installedAppsByLowerName[display.lowercased()] = appURL

                    let loginDir = appURL.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
                    if let subApps = try? fm.contentsOfDirectory(at: loginDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for subApp in subApps where subApp.pathExtension == "app" {
                            let subInfo = FreshBundleInfo.read(at: subApp, requireBundleID: false)
                            let subBID = (subInfo?.bundleID.isEmpty == false ? subInfo?.bundleID : nil) ?? subApp.deletingPathExtension().lastPathComponent
                            let subName = subInfo?.displayName
                                ?? subApp.deletingPathExtension().lastPathComponent
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
                                    isEnabled: true,
                                    runAtLoad: true,
                                    keepAlive: false,
                                    sizeBytes: 0,
                                    isOrphanedOwner: false
                                )
                            )
                        }
                    }
                }
            }
        }

        // 2. Fetch launchctl disabled map & active jobs list
        let guiDisabled = parseDisabledMap(runProcess("/bin/launchctl", args: ["print-disabled", "gui/\(uid)"]).stdout)
        let sysDisabled = parseDisabledMap(runProcess("/bin/launchctl", args: ["print-disabled", "system"]).stdout)
        let activeLaunchList = parseLaunchctlList(runProcess("/bin/launchctl", args: ["list"]).stdout)

        let searchDirs: [(url: URL, kind: StartupItemKind, policy: StartupManagementPolicy)] = [
            (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), .launchAgentUser, .manageable),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .launchAgentGlobal, .requiresAdmin),
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
                let domainDisabled = (source.kind == .launchAgentUser)
                    ? (guiDisabled[label] ?? plistDisabled)
                    : (sysDisabled[label] ?? guiDisabled[label] ?? plistDisabled)
                let isEnabled = !domainDisabled

                var resolvedOwnerName = inferOwnerName(from: label, plistURL: plistURL)
                var resolvedOwnerURL: URL? = nil

                if let matchedBID = installedAppsByLowerBID.first(where: { label.lowercased().hasPrefix($0.key) || $0.key.hasPrefix(label.lowercased()) }) {
                    resolvedOwnerName = matchedBID.value.name
                    resolvedOwnerURL = matchedBID.value.url
                } else if let prog = effectiveProgram, let appIdx = prog.range(of: ".app/") {
                    let appPath = String(prog[..<appIdx.upperBound].dropLast())
                    if fm.fileExists(atPath: appPath) {
                        let u = URL(fileURLWithPath: appPath)
                        resolvedOwnerURL = u
                        resolvedOwnerName = u.deletingPathExtension().lastPathComponent
                    }
                } else if let associated = (plist["AssociatedBundleIdentifiers"] as? [String])?.first?.lowercased(),
                          let hit = installedAppsByLowerBID[associated] {
                    resolvedOwnerName = hit.name
                    resolvedOwnerURL = hit.url
                } else if let nameHit = installedAppsByLowerName.first(where: { label.lowercased().contains($0.key) }) {
                    resolvedOwnerURL = nameHit.value
                    resolvedOwnerName = nameHit.value.deletingPathExtension().lastPathComponent
                }

                // Check whether target executable exists on disk
                let binaryMissing: Bool = {
                    guard let execPath = effectiveProgram, !execPath.isEmpty else { return false }
                    // Ignore shell commands without leading slash (rare) unless full path
                    if execPath.hasPrefix("/") {
                        return !fm.fileExists(atPath: execPath)
                    }
                    return false
                }()

                let runtime: StartupRuntimeStatus = {
                    if binaryMissing {
                        return .missingBinary
                    }
                    if !isEnabled {
                        return .disabled
                    }
                    if let job = activeLaunchList[label] {
                        if let pid = job.pid {
                            return .running(pid: pid)
                        }
                        if job.lastStatus != 0 && job.lastStatus != -15 && job.lastStatus != 78
                            && job.lastStatus != 143 && job.lastStatus != -9 && job.lastStatus != 137
                            && job.lastStatus != -2 && job.lastStatus != 130 && job.lastStatus != -1 {
                            return .errorExit(job.lastStatus)
                        }
                        return .loadedIdle
                    }
                    return .loadedIdle
                }()

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
                        isEnabled: isEnabled,
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

    nonisolated private static func applyEnableDisable(item: StartupItem, enable: Bool) -> (succeeded: Bool, error: String?) {
        let uid = getuid()
        if item.kind == .launchAgentUser {
            let domain = "gui/\(uid)"
            if enable {
                _ = runProcess("/bin/launchctl", args: ["enable", "\(domain)/\(item.label)"])
                let boot = runProcess("/bin/launchctl", args: ["bootstrap", domain, item.plistURL.path])
                if boot.exitCode != 0 && !boot.stderr.lowercased().contains("already") && !boot.stderr.lowercased().contains("in progress") {
                    // Fallback legacy load
                    _ = runProcess("/bin/launchctl", args: ["load", "-w", item.plistURL.path])
                }
            } else {
                _ = runProcess("/bin/launchctl", args: ["disable", "\(domain)/\(item.label)"])
                _ = runProcess("/bin/launchctl", args: ["bootout", domain, item.plistURL.path])
                _ = runProcess("/bin/launchctl", args: ["bootout", "\(domain)/\(item.label)"])
            }
            return (true, nil)
        } else {
            let escapedPlist = item.plistURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let escapedLabel = item.label.replacingOccurrences(of: "'", with: "'\\''")
            let cmd = enable
                ? "/bin/launchctl enable 'system/\(escapedLabel)' && /bin/launchctl bootstrap system '\(escapedPlist)'"
                : "/bin/launchctl disable 'system/\(escapedLabel)' ; /bin/launchctl bootout system '\(escapedPlist)'"
            let res = runAppleScriptPrivileged(cmd)
            return (res.succeeded, res.errorMessage)
        }
    }

    nonisolated private static func removeStartupPlist(item: StartupItem) -> String? {
        let uid = getuid()
        let fm = FileManager.default
        if item.kind == .launchAgentUser {
            _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)", item.plistURL.path])
            _ = runProcess("/bin/launchctl", args: ["bootout", "gui/\(uid)/\(item.label)"])
            do {
                try fm.trashItem(at: item.plistURL, resultingItemURL: nil)
                return nil
            } catch {
                return error.localizedDescription
            }
        } else {
            let escapedPlist = item.plistURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let escapedLabel = item.label.replacingOccurrences(of: "'", with: "'\\''")
            let cmd = "/bin/launchctl bootout system '\(escapedPlist)' ; /bin/launchctl bootout 'system/\(escapedLabel)' ; /bin/rm -f '\(escapedPlist)'"
            let res = runAppleScriptPrivileged(cmd)
            return res.succeeded ? nil : (res.errorMessage ?? "需要管理员权限移除系统级配置")
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

    nonisolated private static func runAppleScriptPrivileged(_ shellCommand: String) -> (succeeded: Bool, stdout: String, errorMessage: String?) {
        let escapedForAppleScript = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", scriptSource]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            if proc.terminationStatus == 0 {
                return (true, out, nil)
            }
            return (false, out, err.isEmpty ? "授权已取消" : err)
        } catch {
            return (false, "", error.localizedDescription)
        }
    }
}
