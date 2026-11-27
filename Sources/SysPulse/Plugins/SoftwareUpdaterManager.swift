import Foundation
import AppKit
import CoreServices
import Observation

// MARK: - 软件与 CLI 更新数据模型

public enum SoftwareUpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case sparkle = "Sparkle"
    case electron = "Electron"
    case website = "官网 / Cask"
    case homebrewCask = "Homebrew Cask"
    case homebrewFormula = "Homebrew CLI"
    case macAppStore = "App Store"

    public var id: String { rawValue }

    public var badgeColorName: String {
        switch self {
        case .sparkle: return "cyan"
        case .electron: return "indigo"
        case .website: return "teal"
        case .homebrewCask: return "orange"
        case .homebrewFormula: return "mint"
        case .macAppStore: return "blue"
        }
    }
}

public enum SoftwareUpdaterFilter: String, CaseIterable, Identifiable, Sendable {
    case updatesAvailable = "可更新"
    case cliFormulas = "CLI 公式"
    case allTracked = "全部受管应用"
    case ignored = "已忽略"

    public var id: String { rawValue }
}

public enum SoftwareUpdateExecutionState: Sendable, Equatable {
    case idle
    case downloading(progress: Double)
    case verifying
    case installing
    case waitingAppQuit
    case openedInstaller(String)
    case openedBrowser
    case completed
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }
}

public struct SoftwareUpdateItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String?
    public let bundleURL: URL?
    public let channel: SoftwareUpdateChannel
    public let currentVersion: String
    public let currentBuild: String?
    public let latestVersion: String?
    public let hasUpdate: Bool
    public let downloadURL: URL?
    public let masTrackID: String?
    public let brewToken: String?
    public let vendorInstallerAppName: String?
    public let releaseNotes: String
    public let minimumOSVersion: String?
    public let expectedFileSizeBytes: Int64?
    public let archTag: String
    public let isRunning: Bool
    public let isSelfManaged: Bool
    public var state: SoftwareUpdateExecutionState

    public init(
        id: String,
        name: String,
        bundleID: String?,
        bundleURL: URL?,
        channel: SoftwareUpdateChannel,
        currentVersion: String,
        latestVersion: String?,
        hasUpdate: Bool,
        downloadURL: URL? = nil,
        masTrackID: String? = nil,
        brewToken: String? = nil,
        releaseNotes: String = "",
        minimumOSVersion: String? = nil,
        expectedFileSizeBytes: Int64? = nil,
        archTag: String = "Universal",
        isRunning: Bool = false,
        isSelfManaged: Bool = false,
        state: SoftwareUpdateExecutionState = .idle,
        currentBuild: String? = nil,
        vendorInstallerAppName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.channel = channel
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.latestVersion = latestVersion
        self.hasUpdate = hasUpdate
        self.downloadURL = downloadURL
        self.masTrackID = masTrackID
        self.brewToken = brewToken
        self.vendorInstallerAppName = vendorInstallerAppName
        self.releaseNotes = releaseNotes
        self.minimumOSVersion = minimumOSVersion
        self.expectedFileSizeBytes = expectedFileSizeBytes
        self.archTag = archTag
        self.isRunning = isRunning
        self.isSelfManaged = isSelfManaged
        self.state = state
    }

    public var ignoreKey: String {
        "\(id)::\(latestVersion ?? currentVersion)"
    }
}

// MARK: - Homebrew Cask Catalog Cache Models

struct CaskCatalogEntry: Codable, Sendable {
    let token: String
    let version: String
    let url: String
    let homepage: String
    let autoUpdates: Bool
    let appNames: [String]
    let installerAppNames: [String]
    let bundleIDHints: [String]
    let hasLaunchctlOrDaemon: Bool
    let vendorInstallerAppName: String?
}

struct CachedCaskCatalog: Codable, Sendable {
    let schemaVersion: Int
    let fetchedAt: Date
    let entries: [CaskCatalogEntry]
}

// MARK: - 软件更新中心引擎

@Observable
@MainActor
public final class SoftwareUpdaterManager {
    public static let shared = SoftwareUpdaterManager()

    public var appUpdates: [SoftwareUpdateItem] = []
    public var formulaUpdates: [SoftwareUpdateItem] = []
    public var trackedItems: [SoftwareUpdateItem] = []

    public var isScanning: Bool = false
    public var scanProgress: Double = 0
    public var scanStageMessage: String = "尚未检测更新"
    public var lastScanDate: Date? = nil
    public var selectedFilter: SoftwareUpdaterFilter = .updatesAvailable
    public var searchQuery: String = ""
    public var selectedDetailItemID: String? = nil
    public var hoveredItemID: String? = nil
    public var isHomebrewInstalled: Bool = false
    public var homebrewPath: String? = nil
    public var liveLogLines: [String] = []
    public var isBatchUpdating: Bool = false
    public var runningConflictItem: SoftwareUpdateItem? = nil

    public var ignoredKeys: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(ignoredKeys), forKey: "SP_SoftwareUpdater_IgnoredKeys")
        }
    }

    private var scanTask: Task<Void, Never>? = nil
    private var installerWatcherTasks: [String: Task<Void, Never>] = [:]
    private var appActiveObserver: NSObjectProtocol? = nil

    // 内置 Sparkle Appcast 覆盖源（处理未在 Info.plist 声明 feed 的常见桌面应用）
    nonisolated private static let sparkleFeedOverrides: [String: String] = [
        "com.openai.codex": "https://persistent.oaistatic.com/codex-app-prod/appcast.xml",
        "com.canva.affinity": "https://things.seriflabs.com/affinity-update-mac-retail-studiopro",
        "com.catforce.timemator.macos": "https://timemator.com/assets/updates/appcast.xml",
        "com.superhighfives.pika": "https://superhighfives.com/releases/pika",
        "ch.protonvpn.mac": "https://protonvpn.com/download/macos/updates/v5/sparkle.xml",
        "net.imput.helium": "https://updates.helium.computer/mac/appcast-arm64.xml",
        "com.mitchellh.ghostty": "https://release.files.ghostty.org/appcast.xml",
        "com.lwouis.alt-tab-macos": "https://raw.githubusercontent.com/lwouis/alt-tab-macos/master/appcast.xml",
        "com.ameba.swiftbar": "https://swiftbar.github.io/SwiftBar/appcast.xml",
        "com.pilotmoon.scroll-reverser": "https://softwareupdate.pilotmoon.com/update/scrollreverser/appcast.xml",
        "info.marcel-dierkes.keepingyouawake": "https://newmarcel.github.io/KeepingYouAwake/appcast.xml",
        "com.linguee.deeplcopytranslator": "https://appcast.deepl.com/macos/notify/appcast.xml",
        "com.coteditor.coteditor": "https://coteditor.com/appcast.xml",
        "com.wiheads.paste-direct": "https://api.pasteapp.io/v2/macos/appcast.xml"
    ]

    // 内置 Electron YAML 覆盖源
    nonisolated private static let electronYamlOverrides: [String: String] = [
        "com.milanote.app": "https://battle-station-desktop.s3.amazonaws.com/latest-mac.yml",
        "im.manus.desktop": "https://d31adb63638z8v.cloudfront.net/win_electron/latest-mac.yml"
    ]

    nonisolated private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "SP_SoftwareUpdater_IgnoredKeys") ?? []
        self.ignoredKeys = Set(saved)
        self.homebrewPath = Self.detectBrewBinary()
        self.isHomebrewInstalled = (self.homebrewPath != nil)
        self.appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileLocalInstalledVersions()
            }
        }
    }

    // MARK: - Computed Lists

    public var visibleAppUpdates: [SoftwareUpdateItem] {
        appUpdates.filter { $0.hasUpdate && !ignoredKeys.contains($0.ignoreKey) }
    }

    public var visibleFormulaUpdates: [SoftwareUpdateItem] {
        formulaUpdates.filter { $0.hasUpdate && !ignoredKeys.contains($0.ignoreKey) }
    }

    public var totalAvailableUpdatesCount: Int {
        visibleAppUpdates.count + visibleFormulaUpdates.count
    }

    public var ignoredUpdatesList: [SoftwareUpdateItem] {
        (appUpdates + formulaUpdates).filter { $0.hasUpdate && ignoredKeys.contains($0.ignoreKey) }
    }

    public var currentFilteredItems: [SoftwareUpdateItem] {
        let base: [SoftwareUpdateItem]
        switch selectedFilter {
        case .updatesAvailable:
            base = (appUpdates + formulaUpdates).filter {
                ($0.hasUpdate || $0.state == .completed) && !ignoredKeys.contains($0.ignoreKey)
            }
        case .cliFormulas:
            base = formulaUpdates
        case .allTracked:
            base = trackedItems
        case .ignored:
            base = ignoredUpdatesList
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q)
                || ($0.bundleID?.lowercased().contains(q) ?? false)
                || ($0.brewToken?.lowercased().contains(q) ?? false)
                || $0.channel.rawValue.lowercased().contains(q)
        }
    }

    public var selectedDetailItem: SoftwareUpdateItem? {
        guard let id = selectedDetailItemID else {
            return currentFilteredItems.first
        }
        return (appUpdates + formulaUpdates + trackedItems).first(where: { $0.id == id }) ?? currentFilteredItems.first
    }

    public func count(for filter: SoftwareUpdaterFilter) -> Int {
        switch filter {
        case .updatesAvailable: return totalAvailableUpdatesCount
        case .cliFormulas: return formulaUpdates.count
        case .allTracked: return trackedItems.count
        case .ignored: return ignoredUpdatesList.count
        }
    }

    // MARK: - Scanning Pipeline

    public func scanAllIfNeeded() {
        if lastScanDate != nil {
            if !isScanning {
                reconcileLocalInstalledVersions()
            }
            return
        }
        guard !isScanning else { return }
        startScan(forceRefresh: false)
    }

    public func startScan(forceRefresh: Bool = false) {
        guard !isScanning else { return }
        scanTask?.cancel()
        isScanning = true
        scanProgress = 0.05
        scanStageMessage = "正在盘点本机应用、App Store 收据与 Homebrew 环境…"
        liveLogLines.removeAll(keepingCapacity: true)

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let brewBin = Self.detectBrewBinary()
            await MainActor.run {
                self?.homebrewPath = brewBin
                self?.isHomebrewInstalled = (brewBin != nil)
                self?.scanProgress = 0.14
                self?.scanStageMessage = "正在加载软件源目录与 Homebrew 清单…"
            }

            async let brewSnapshotTask = Self.fetchHomebrewUpdatesAsync(brewPath: brewBin)
            async let catalogEntriesTask = Self.loadCaskCatalogEntries(forceRefresh: forceRefresh)

            let brewSnapshot = await brewSnapshotTask
            let catalogEntries = await catalogEntriesTask

            await MainActor.run {
                self?.scanProgress = 0.35
                self?.scanStageMessage = "正在并发校验 Sparkle / Electron / App Store / 官网源…"
            }

            let localResult = await Self.scanInstalledAppsUpdates(
                brewSnapshot: brewSnapshot,
                catalogEntries: catalogEntries
            )

            var combinedAppUpdates: [SoftwareUpdateItem] = localResult.updates
            let existingBrewTokens = Set(
                (localResult.updates + localResult.upToDateTracked)
                    .compactMap { $0.brewToken?.lowercased() }
            )
            for caskUpdate in brewSnapshot.caskUpdates where !existingBrewTokens.contains(caskUpdate.brewToken?.lowercased() ?? "") {
                combinedAppUpdates.append(caskUpdate)
            }

            combinedAppUpdates.sort {
                if $0.hasUpdate != $1.hasUpdate { return $0.hasUpdate && !$1.hasUpdate }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

            let formulas = brewSnapshot.formulaItems.sorted {
                if $0.hasUpdate != $1.hasUpdate { return $0.hasUpdate && !$1.hasUpdate }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

            let tracked = (combinedAppUpdates + localResult.upToDateTracked)
                .sorted {
                    if $0.hasUpdate != $1.hasUpdate { return $0.hasUpdate && !$1.hasUpdate }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }

            let finalApps = combinedAppUpdates
            let finalFormulas = formulas
            let finalTracked = tracked

            await MainActor.run {
                guard let self else { return }
                self.appUpdates = finalApps
                self.formulaUpdates = finalFormulas
                self.trackedItems = finalTracked
                self.scanProgress = 1.0
                self.lastScanDate = Date()
                self.isScanning = false
                let totalAvail = self.totalAvailableUpdatesCount
                self.scanStageMessage = totalAvail > 0
                    ? "检测到 \(totalAvail) 项可更新（\(self.visibleAppUpdates.count) 款应用 · \(self.visibleFormulaUpdates.count) 个 CLI 公式）"
                    : "全部受管应用与命令行工具均为最新版本"
                if self.selectedDetailItemID == nil || self.selectedDetailItem == nil {
                    self.selectedDetailItemID = self.currentFilteredItems.first?.id
                }
            }
        }
    }

    // MARK: - Ignore / Restore

    public func ignoreUpdate(_ item: SoftwareUpdateItem) {
        ignoredKeys.insert(item.ignoreKey)
    }

    public func unignoreUpdate(_ item: SoftwareUpdateItem) {
        ignoredKeys.remove(item.ignoreKey)
    }

    // MARK: - Update Execution

    public func triggerUpdate(_ item: SoftwareUpdateItem, forceQuitRunning: Bool = false) {
        if item.channel == .macAppStore {
            openMacAppStoreUpdate(for: item)
            return
        }

        if item.isSelfManaged {
            if let appURL = item.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
                appendLog("ℹ️ 已打开「\(item.name)」，请在应用内菜单执行「检查更新」完成升级。")
            } else if let dlURL = item.downloadURL {
                NSWorkspace.shared.open(dlURL)
                appendLog("ℹ️ 已在浏览器中打开「\(item.name)」官方下载页面。")
            }
            updateItemState(id: item.id, state: .openedBrowser)
            startWatchingAppUpdate(for: item, maxPolls: 150)
            return
        }

        // 检查正在运行的 GUI 应用（避免替换时文件锁冲突）
        if let bid = item.bundleID,
           let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }),
           !runningApp.isTerminated {
            if !forceQuitRunning {
                var blockedItem = item
                blockedItem.state = .waitingAppQuit
                updateItemState(id: item.id, state: .waitingAppQuit)
                self.runningConflictItem = blockedItem
                return
            }
        }

        runningConflictItem = nil
        updateItemState(id: item.id, state: .downloading(progress: 0.05))
        appendLog("开始更新 \(item.name) (\(item.currentVersion) -> \(item.latestVersion ?? "最新"))")

        let trashedBundleName = item.bundleURL?.lastPathComponent ?? "\(item.name).app"
        let trashedBundleID = item.bundleID ?? ""
        TrashRemnantWatcher.shared.recordSelfTrashedApp(bundleName: trashedBundleName, bundleID: trashedBundleID)

        let brewBin = self.homebrewPath
        Task.detached(priority: .userInitiated) { [weak self] in
            if item.channel == .homebrewCask || item.channel == .homebrewFormula {
                guard let brewBin, let token = item.brewToken else {
                    await MainActor.run {
                        self?.updateItemState(id: item.id, state: .failed("未定位到 Homebrew 路径"))
                    }
                    return
                }
                if forceQuitRunning, let bid = item.bundleID {
                    await Self.terminateRunningApp(bundleID: bid)
                }
                await MainActor.run {
                    TrashRemnantWatcher.shared.recordSelfTrashedApp(bundleName: trashedBundleName, bundleID: trashedBundleID)
                    self?.updateItemState(id: item.id, state: .installing)
                }
                let isCask = (item.channel == .homebrewCask)
                let res: (exitCode: Int32, stdout: String, stderr: String, userCancelledAuth: Bool)
                if isCask {
                    res = Self.runBrewCaskUpgradeWithAskpassIfNeeded(
                        brewBin: brewBin,
                        token: token,
                        appName: item.name
                    )
                } else {
                    let raw = Self.runProcess(brewBin, args: ["upgrade", token], timeoutSeconds: 180)
                    res = (raw.exitCode, raw.stdout, raw.stderr, false)
                }

                let freshLocal = isCask ? item.bundleURL.flatMap { Self.readNormalizedLocalVersion(at: $0, bundleID: item.bundleID) } : nil
                await MainActor.run {
                    guard let self else { return }
                    if !res.stdout.isEmpty {
                        for line in res.stdout.split(separator: "\n").suffix(6) {
                            self.appendLog(String(line))
                        }
                    }
                    if res.exitCode == 0 {
                        self.markItemCompleted(
                            item: item,
                            confirmedVersion: freshLocal?.shortVersion,
                            confirmedBuild: freshLocal?.buildVersion
                        )
                        self.appendLog("✅ \(item.name) 已升级至 \(freshLocal?.shortVersion ?? item.latestVersion ?? "最新版本")")
                    } else if res.userCancelledAuth {
                        self.updateItemState(id: item.id, state: .idle)
                        self.appendLog("ℹ️ 已取消管理员密码授权，\(item.name) 未执行升级")
                    } else {
                        let reason = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.updateItemState(id: item.id, state: .failed(reason.isEmpty ? "Homebrew 升级失败" : String(reason.prefix(160))))
                        self.appendLog("❌ \(item.name) 更新失败：\(reason)")
                    }
                }
                return
            }

            // 直接下载、校验与安装（Sparkle / Electron / 官网 Cask 源）
            guard let downloadURL = item.downloadURL, let targetAppURL = item.bundleURL else {
                await MainActor.run {
                    self?.updateItemState(id: item.id, state: .failed("缺少有效安装包下载地址"))
                }
                return
            }

            let installOutcome = await Self.downloadVerifyAndInstall(
                item: item,
                downloadURL: downloadURL,
                targetAppURL: targetAppURL,
                forceQuitRunning: forceQuitRunning,
                progressHandler: { progress in
                    await MainActor.run {
                        self?.updateItemState(id: item.id, state: .downloading(progress: progress))
                    }
                },
                stageHandler: { stageState, msg in
                    await MainActor.run {
                        if stageState == .installing {
                            TrashRemnantWatcher.shared.recordSelfTrashedApp(bundleName: trashedBundleName, bundleID: trashedBundleID)
                        }
                        self?.updateItemState(id: item.id, state: stageState)
                        self?.appendLog(msg)
                    }
                }
            )

            await MainActor.run {
                guard let self else { return }
                switch installOutcome {
                case .success(let outcome):
                    switch outcome {
                    case .replacedApp(let installedVersion, let installedBuild):
                        self.markItemCompleted(item: item, confirmedVersion: installedVersion, confirmedBuild: installedBuild)
                        self.appendLog("✅ \(item.name) 已通过签名校验并完成原子替换（当前版本 \(installedVersion ?? item.latestVersion ?? "最新")）")
                    case .openedInstaller(let installerPath, let label):
                        self.updateItemState(id: item.id, state: .openedInstaller(installerPath))
                        self.appendLog("✅ 已启动官方安装程序 \(label)，请按窗口提示完成安装")
                        self.startWatchingVendorInstaller(for: item)
                    case .openedBrowser(let pageURL):
                        self.updateItemState(id: item.id, state: .openedBrowser)
                        self.appendLog("ℹ️ 该下载地址返回官网页面，已为您在浏览器打开：\(pageURL.absoluteString)")
                    }
                case .failure(let err):
                    self.updateItemState(id: item.id, state: .failed(err.localizedDescription))
                    self.appendLog("❌ \(item.name) 安装失败：\(err.localizedDescription)")
                }
            }
        }
    }

    public func updateAllVisibleFormulas() {
        let targets = visibleFormulaUpdates.filter { !$0.state.isBusy }
        guard !targets.isEmpty else { return }
        isBatchUpdating = true
        for target in targets {
            triggerUpdate(target, forceQuitRunning: true)
        }
        isBatchUpdating = false
    }

    public func updateAllSafeApps() {
        let targets = visibleAppUpdates.filter {
            $0.channel != .macAppStore && !$0.isSelfManaged && !$0.state.isBusy && !$0.isRunning
        }
        guard !targets.isEmpty else { return }
        isBatchUpdating = true
        for target in targets {
            triggerUpdate(target, forceQuitRunning: false)
        }
        isBatchUpdating = false
    }

    public func openMacAppStoreUpdate(for item: SoftwareUpdateItem) {
        if let trackID = item.masTrackID,
           let url = URL(string: "macappstore://itunes.apple.com/app/id\(trackID)") {
            NSWorkspace.shared.open(url)
        } else if let fallback = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(fallback)
        }
        startWatchingAppUpdate(for: item, maxPolls: 150)
    }

    private func startWatchingVendorInstaller(for item: SoftwareUpdateItem) {
        startWatchingAppUpdate(for: item, maxPolls: 60)
    }

    private func startWatchingAppUpdate(for item: SoftwareUpdateItem, maxPolls: Int) {
        guard let targetURL = item.bundleURL else { return }
        installerWatcherTasks[item.id]?.cancel()
        installerWatcherTasks[item.id] = Task.detached(priority: .utility) { [weak self] in
            for _ in 0..<maxPolls {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard let fresh = Self.readNormalizedLocalVersion(at: targetURL, bundleID: item.bundleID) else { continue }
                let targetVer = item.latestVersion ?? ""
                let versionMatchesTarget = !targetVer.isEmpty && !Self.isRemoteUpdateStillNewer(
                    remoteVersion: targetVer,
                    channel: item.channel,
                    localShort: fresh.shortVersion,
                    localBuild: fresh.buildVersion
                )
                let changedFromBaseline = (fresh.shortVersion != item.currentVersion || fresh.buildVersion != (item.currentBuild ?? fresh.buildVersion))
                if versionMatchesTarget || (targetVer.isEmpty && changedFromBaseline) {
                    await MainActor.run {
                        self?.markItemCompleted(item: item, confirmedVersion: fresh.shortVersion, confirmedBuild: fresh.buildVersion)
                        self?.appendLog("✅ 检测到 \(item.name) 已升级至 \(fresh.shortVersion)")
                    }
                    return
                }
            }
        }
    }

    /// 零网络即时核验本地磁盘 `.app` 的真实 `Info.plist` 版本，消除系统级 `Bundle(url:)` 缓存导致的已升级应用误报。
    public func reconcileLocalInstalledVersions() {
        guard lastScanDate != nil && !isScanning else { return }
        let fm = FileManager.default
        var didChange = false

        func updatedItemIfNeeded(_ existing: SoftwareUpdateItem) -> (keep: Bool, item: SoftwareUpdateItem, changed: Bool) {
            guard !existing.state.isBusy, let bundleURL = existing.bundleURL else {
                return (true, existing, false)
            }
            if !fm.fileExists(atPath: bundleURL.path) {
                return (false, existing, true)
            }
            guard let fresh = Self.readNormalizedLocalVersion(at: bundleURL, bundleID: existing.bundleID) else {
                return (true, existing, false)
            }

            let stillHasUpdate: Bool
            if existing.hasUpdate, let targetVer = existing.latestVersion, !targetVer.isEmpty {
                stillHasUpdate = Self.isRemoteUpdateStillNewer(
                    remoteVersion: targetVer,
                    channel: existing.channel,
                    localShort: fresh.shortVersion,
                    localBuild: fresh.buildVersion
                )
            } else {
                stillHasUpdate = false
            }

            let oldBuild = existing.currentBuild ?? ""
            let versionChanged = (fresh.shortVersion != existing.currentVersion) || (!oldBuild.isEmpty && fresh.buildVersion != oldBuild)
            let clearedStaleUpdate = existing.hasUpdate && !stillHasUpdate
            guard versionChanged || clearedStaleUpdate else {
                return (true, existing, false)
            }

            let nextLatest = stillHasUpdate ? existing.latestVersion : fresh.shortVersion
            let nextState: SoftwareUpdateExecutionState
            if clearedStaleUpdate {
                nextState = .completed
            } else if stillHasUpdate {
                nextState = existing.state
            } else {
                nextState = .idle
            }

            let updated = SoftwareUpdateItem(
                id: existing.id,
                name: existing.name,
                bundleID: existing.bundleID,
                bundleURL: existing.bundleURL,
                channel: existing.channel,
                currentVersion: fresh.shortVersion,
                latestVersion: nextLatest,
                hasUpdate: stillHasUpdate,
                downloadURL: existing.downloadURL,
                masTrackID: existing.masTrackID,
                brewToken: existing.brewToken,
                releaseNotes: stillHasUpdate ? existing.releaseNotes : "当前已是最新版本。",
                minimumOSVersion: existing.minimumOSVersion,
                expectedFileSizeBytes: existing.expectedFileSizeBytes,
                archTag: existing.archTag,
                isRunning: existing.isRunning,
                isSelfManaged: existing.isSelfManaged,
                state: nextState,
                currentBuild: fresh.buildVersion,
                vendorInstallerAppName: existing.vendorInstallerAppName
            )
            return (true, updated, true)
        }

        var nextAppUpdates: [SoftwareUpdateItem] = []
        nextAppUpdates.reserveCapacity(appUpdates.count)
        for item in appUpdates {
            let res = updatedItemIfNeeded(item)
            if res.changed { didChange = true }
            if res.keep { nextAppUpdates.append(res.item) }
        }

        var nextTracked: [SoftwareUpdateItem] = []
        nextTracked.reserveCapacity(trackedItems.count)
        for item in trackedItems {
            let res = updatedItemIfNeeded(item)
            if res.changed { didChange = true }
            if res.keep { nextTracked.append(res.item) }
        }

        guard didChange else { return }
        appUpdates = nextAppUpdates
        trackedItems = nextTracked
        let totalAvail = totalAvailableUpdatesCount
        scanStageMessage = totalAvail > 0
            ? "检测到 \(totalAvail) 项可更新（\(visibleAppUpdates.count) 款应用 · \(visibleFormulaUpdates.count) 个 CLI 公式）"
            : "全部受管应用与命令行工具均为最新版本"
    }

    private func updateItemState(id: String, state: SoftwareUpdateExecutionState) {
        if let i = appUpdates.firstIndex(where: { $0.id == id }) { appUpdates[i].state = state }
        if let i = formulaUpdates.firstIndex(where: { $0.id == id }) { formulaUpdates[i].state = state }
        if let i = trackedItems.firstIndex(where: { $0.id == id }) { trackedItems[i].state = state }
    }

    private func markItemCompleted(item: SoftwareUpdateItem, confirmedVersion: String? = nil, confirmedBuild: String? = nil) {
        let newVer = confirmedVersion ?? item.latestVersion ?? item.currentVersion
        func patch(_ array: inout [SoftwareUpdateItem]) {
            if let idx = array.firstIndex(where: { $0.id == item.id }) {
                let existing = array[idx]
                array[idx] = SoftwareUpdateItem(
                    id: existing.id,
                    name: existing.name,
                    bundleID: existing.bundleID,
                    bundleURL: existing.bundleURL,
                    channel: existing.channel,
                    currentVersion: newVer,
                    latestVersion: newVer,
                    hasUpdate: false,
                    downloadURL: existing.downloadURL,
                    masTrackID: existing.masTrackID,
                    brewToken: existing.brewToken,
                    releaseNotes: existing.releaseNotes,
                    minimumOSVersion: existing.minimumOSVersion,
                    expectedFileSizeBytes: existing.expectedFileSizeBytes,
                    archTag: existing.archTag,
                    isRunning: existing.isRunning,
                    isSelfManaged: existing.isSelfManaged,
                    state: .completed,
                    currentBuild: confirmedBuild ?? existing.currentBuild,
                    vendorInstallerAppName: existing.vendorInstallerAppName
                )
            }
        }
        patch(&appUpdates)
        patch(&formulaUpdates)
        patch(&trackedItems)
    }

    private func appendLog(_ text: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        liveLogLines.append("[\(df.string(from: Date()))] \(text)")
        if liveLogLines.count > 100 {
            liveLogLines.removeFirst(liveLogLines.count - 100)
        }
    }

    // MARK: - Homebrew Environment & Caskroom Mapping

    nonisolated private static func detectBrewBinary() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    nonisolated private static func fetchHomebrewUpdatesAsync(brewPath: String?) async -> (
        caskUpdates: [SoftwareUpdateItem],
        formulaItems: [SoftwareUpdateItem],
        caskroomByAppName: [String: String],
        installedCaskTokens: Set<String>
    ) {
        let caskroom = discoverCaskroomApps()
        guard let brewPath else { return ([], [], caskroom.byAppName, caskroom.installedTokens) }

        let installedFormulasRaw = runProcess(brewPath, args: ["list", "--formula", "--versions"], timeoutSeconds: 15).stdout
        let outdatedRes = runProcess(brewPath, args: ["outdated", "--json=v2"], timeoutSeconds: 20)

        var outdatedFormulaMap: [String: (installed: String, current: String)] = [:]
        var outdatedCaskMap: [String: (installed: String, current: String)] = [:]

        if let jsonData = outdatedRes.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let formulas = root["formulae"] as? [[String: Any]] {
                for f in formulas {
                    if let name = f["name"] as? String,
                       let current = f["current_version"] as? String {
                        let installed = (f["installed_versions"] as? [String])?.last ?? "?"
                        outdatedFormulaMap[name] = (installed, current)
                    }
                }
            }
            if let casks = root["casks"] as? [[String: Any]] {
                for c in casks {
                    if let name = c["name"] as? String,
                       let current = c["current_version"] as? String {
                        let installedList = c["installed_versions"] as? [String]
                        let installed = installedList?.last ?? (c["installed_versions"] as? String) ?? "?"
                        outdatedCaskMap[name] = (installed, current)
                    }
                }
            }
        }

        var formulaItems: [SoftwareUpdateItem] = []
        for line in installedFormulasRaw.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let name = parts.first, let installedVer = parts.dropFirst().first else { continue }
            let outdated = outdatedFormulaMap[name]
            formulaItems.append(
                SoftwareUpdateItem(
                    id: "brew.formula.\(name)",
                    name: name,
                    bundleID: nil,
                    bundleURL: nil,
                    channel: .homebrewFormula,
                    currentVersion: outdated?.installed ?? installedVer,
                    latestVersion: outdated?.current ?? installedVer,
                    hasUpdate: outdated != nil,
                    brewToken: name,
                    releaseNotes: outdated != nil ? "可通过 `brew upgrade \(name)` 原地升级命令行公式。" : "已是 Homebrew 最新版本。",
                    archTag: ProcessInfo.processInfo.machineArchitectureTag
                )
            )
        }

        let caskUpdates: [SoftwareUpdateItem] = outdatedCaskMap.map { (token, ver) in
            SoftwareUpdateItem(
                id: "brew.cask.\(token)",
                name: token.replacingOccurrences(of: "-", with: " ").capitalized,
                bundleID: nil,
                bundleURL: nil,
                channel: .homebrewCask,
                currentVersion: ver.installed,
                latestVersion: ver.current,
                hasUpdate: true,
                brewToken: token,
                releaseNotes: "检测到 Homebrew Cask 新版本，可执行 `brew upgrade --cask \(token)`。",
                archTag: ProcessInfo.processInfo.machineArchitectureTag
            )
        }

        return (caskUpdates, formulaItems, caskroom.byAppName, caskroom.installedTokens)
    }

    nonisolated private static func discoverCaskroomApps() -> (byAppName: [String: String], installedTokens: Set<String>) {
        let fm = FileManager.default
        var map: [String: String] = [:]
        var tokensSet: Set<String> = []
        for rootPath in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            guard let tokens = try? fm.contentsOfDirectory(atPath: rootPath) else { continue }
            for token in tokens where !token.hasPrefix(".") {
                tokensSet.insert(token.lowercased())
                let tokenDir = URL(fileURLWithPath: rootPath).appendingPathComponent(token)
                guard let versions = try? fm.contentsOfDirectory(atPath: tokenDir.path) else { continue }
                for ver in versions where !ver.hasPrefix(".") {
                    let verDir = tokenDir.appendingPathComponent(ver)
                    guard let items = try? fm.contentsOfDirectory(atPath: verDir.path) else { continue }
                    for item in items where item.hasSuffix(".app") {
                        map[item.lowercased()] = token
                    }
                }
            }
        }
        return (map, tokensSet)
    }

    // MARK: - Homebrew Cask Catalog (formulae.brew.sh/api/cask.json)

    nonisolated private static func catalogCacheURL() -> URL {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SysPulse", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("homebrew-cask-catalog.json")
    }

    nonisolated private static func loadCaskCatalogEntries(forceRefresh: Bool = false) async -> [CaskCatalogEntry] {
        let cacheURL = catalogCacheURL()
        if !forceRefresh,
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedCaskCatalog.self, from: data),
           cached.schemaVersion == 2,
           Date().timeIntervalSince(cached.fetchedAt) < 6 * 3600,
           !cached.entries.isEmpty {
            return cached.entries
        }

        // 拉取 Homebrew Cask API 清单
        if let apiURL = URL(string: "https://formulae.brew.sh/api/cask.json"),
           let rawData = await fetchData(url: apiURL, timeout: 25),
           let rawArray = try? JSONSerialization.jsonObject(with: rawData) as? [[String: Any]] {
            let parsed = parseRawCaskCatalog(rawArray)
            if !parsed.isEmpty {
                let snapshot = CachedCaskCatalog(schemaVersion: 2, fetchedAt: Date(), entries: parsed)
                if let encoded = try? JSONEncoder().encode(snapshot) {
                    try? encoded.write(to: cacheURL, options: .atomic)
                }
                return parsed
            }
        }

        // 网络失败时退回本地旧缓存
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedCaskCatalog.self, from: data),
           cached.schemaVersion == 2 {
            return cached.entries
        }
        return []
    }

    nonisolated private static func hostMacOSCodename() -> String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        switch major {
        case 27...: return "golden_gate"
        case 26: return "tahoe"
        case 15: return "sequoia"
        case 14: return "sonoma"
        case 13: return "ventura"
        case 12: return "monterey"
        case 11: return "big_sur"
        default: return "sequoia"
        }
    }

    nonisolated private static func macOSMajorFromCatalogConstraint(_ token: String) -> Int? {
        let lower = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Int(lower.split(separator: ".").first ?? "") {
            return direct
        }
        switch lower {
        case "golden_gate": return 27
        case "tahoe": return 26
        case "sequoia": return 15
        case "sonoma": return 14
        case "ventura": return 13
        case "monterey": return 12
        case "big_sur": return 11
        case "catalina": return 10
        case "mojave": return 10
        default: return nil
        }
    }

    nonisolated private static func isCatalogDependsOnCompatible(_ dependsOn: [String: Any]?) -> Bool {
        guard let dependsOn else { return true }
        #if arch(arm64)
        let targetArch = "arm"
        #else
        let targetArch = "intel"
        #endif

        if let archList = dependsOn["arch"] as? [[String: Any]], !archList.isEmpty {
            let types = archList.compactMap { ($0["type"] as? String)?.lowercased() }
            if !types.isEmpty && !types.contains(targetArch) {
                return false
            }
        }

        if let macosDict = dependsOn["macos"] as? [String: Any], !macosDict.isEmpty {
            let hostMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            if let geList = macosDict[">="] as? [String] {
                for req in geList {
                    if let reqMajor = macOSMajorFromCatalogConstraint(req), hostMajor < reqMajor {
                        return false
                    }
                }
            }
            if let eqList = macosDict["=="] as? [String] {
                let allowedMajors = eqList.compactMap(macOSMajorFromCatalogConstraint)
                if !allowedMajors.isEmpty && !allowedMajors.contains(hostMajor) {
                    return false
                }
            }
            if let leList = macosDict["<="] as? [String] {
                for req in leList {
                    if let reqMajor = macOSMajorFromCatalogConstraint(req), hostMajor > reqMajor {
                        return false
                    }
                }
            }
        }
        return true
    }

    nonisolated private static func parseRawCaskCatalog(_ items: [[String: Any]]) -> [CaskCatalogEntry] {
        let codename = hostMacOSCodename()
        #if arch(arm64)
        let candidateKeys: [String] = ["arm64_\(codename)", "arm64_tahoe", "arm64_sequoia"]
        #else
        let candidateKeys: [String] = [codename]
        #endif

        var out: [CaskCatalogEntry] = []
        out.reserveCapacity(5000)

        for item in items {
            if (item["disabled"] as? Bool) == true || (item["deprecated"] as? Bool) == true { continue }
            if item["disable_date"] != nil && !(item["disable_date"] is NSNull) { continue }
            if item["deprecation_date"] != nil && !(item["deprecation_date"] is NSNull) { continue }
            guard let token = item["token"] as? String, !token.isEmpty else { continue }

            var version = item["version"] as? String ?? ""
            var url = item["url"] as? String ?? ""
            var dependsOn = item["depends_on"] as? [String: Any]
            var artifacts = item["artifacts"] as? [[String: Any]] ?? []
            let autoUpdates = (item["auto_updates"] as? Bool) ?? false
            let homepage = (item["homepage"] as? String) ?? ""

            // 关键：在 Homebrew cask.json 中，顶层字段为 arm64 主构架值，
            // 未加 arm64_ 前缀的 variations (如 "sequoia"/"tahoe") 是 Intel x86_64 覆盖项！
            if let variations = item["variations"] as? [String: [String: Any]] {
                if let key = candidateKeys.first(where: { variations[$0] != nil }),
                   let v = variations[key] {
                    if let vv = v["version"] as? String { version = vv }
                    if let vu = v["url"] as? String { url = vu }
                    if let vd = v["depends_on"] as? [String: Any] { dependsOn = vd }
                    if let va = v["artifacts"] as? [[String: Any]] { artifacts = va }
                }
            }

            guard !version.isEmpty, version.lowercased() != "latest", url.hasPrefix("http") else { continue }
            guard isCatalogDependsOnCompatible(dependsOn) else { continue }

            var appNames: [String] = []
            var installerAppNames: [String] = []
            var bundleIDHints: [String] = []
            var hasLaunchctlOrDaemon = false
            var vendorInstallerApp: String? = nil

            for art in artifacts {
                if let apps = art["app"] as? [Any] {
                    for entry in apps {
                        if let name = entry as? String, name.lowercased().hasSuffix(".app") {
                            let base = URL(fileURLWithPath: name).lastPathComponent
                            if !appNames.contains(base) { appNames.append(base) }
                        } else if let dict = entry as? [String: Any],
                                  let target = dict["target"] as? String,
                                  target.lowercased().hasSuffix(".app") {
                            let base = URL(fileURLWithPath: target).lastPathComponent
                            if !appNames.contains(base) { appNames.append(base) }
                        }
                    }
                }
                if let installers = art["installer"] as? [[String: Any]] {
                    for inst in installers {
                        let sub = (inst["script"] as? [String: Any]) ?? (inst["manual"] as? [String: Any])
                        if let exec = sub?["executable"] as? String,
                           let appComp = extractAppBundleName(fromPathString: exec) {
                            if !installerAppNames.contains(appComp) { installerAppNames.append(appComp) }
                            if vendorInstallerApp == nil { vendorInstallerApp = appComp }
                        } else if let manualStr = inst["manual"] as? String,
                                  let appComp = extractAppBundleName(fromPathString: manualStr) {
                            if !installerAppNames.contains(appComp) { installerAppNames.append(appComp) }
                            if vendorInstallerApp == nil { vendorInstallerApp = appComp }
                        }
                    }
                }
                if let uninstalls = art["uninstall"] as? [[String: Any]] {
                    for u in uninstalls {
                        collectStringValues(u["quit"], into: &bundleIDHints)
                        collectStringValues(u["pkgutil"], into: &bundleIDHints)
                        if u["launchctl"] != nil { hasLaunchctlOrDaemon = true }
                    }
                }
                if let zaps = art["zap"] as? [[String: Any]] {
                    for z in zaps {
                        var trashStrings: [String] = []
                        collectStringValues(z["trash"], into: &trashStrings)
                        collectStringValues(z["delete"], into: &trashStrings)
                        for path in trashStrings {
                            if let hint = extractBundleIDFromSupportPath(path),
                               !bundleIDHints.contains(hint) {
                                bundleIDHints.append(hint)
                            }
                        }
                    }
                }
            }

            guard !appNames.isEmpty || !installerAppNames.isEmpty else { continue }
            out.append(
                CaskCatalogEntry(
                    token: token,
                    version: version,
                    url: url,
                    homepage: homepage,
                    autoUpdates: autoUpdates,
                    appNames: appNames,
                    installerAppNames: installerAppNames,
                    bundleIDHints: bundleIDHints,
                    hasLaunchctlOrDaemon: hasLaunchctlOrDaemon,
                    vendorInstallerAppName: vendorInstallerApp
                )
            )
        }
        return out
    }

    nonisolated private static func extractAppBundleName(fromPathString path: String) -> String? {
        for component in path.split(separator: "/") {
            let s = String(component)
            if s.lowercased().hasSuffix(".app") {
                return s
            }
        }
        return nil
    }

    nonisolated private static func collectStringValues(_ any: Any?, into target: inout [String]) {
        if let s = any as? String {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !lower.isEmpty && !target.contains(lower) { target.append(lower) }
        } else if let arr = any as? [Any] {
            for element in arr {
                collectStringValues(element, into: &target)
            }
        }
    }

    nonisolated private static func extractBundleIDFromSupportPath(_ path: String) -> String? {
        let last = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let cleaned = last
            .replacingOccurrences(of: ".plist", with: "")
            .replacingOccurrences(of: ".savedstate", with: "")
            .replacingOccurrences(of: ".binarycookies", with: "")
            .replacingOccurrences(of: "*", with: "")
        let parts = cleaned.split(separator: ".")
        if parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) {
            return cleaned
        }
        return nil
    }

    nonisolated private static func readNormalizedLocalVersion(at appURL: URL, bundleID: String?) -> (shortVersion: String, buildVersion: String)? {
        guard let info = FreshBundleInfo.read(at: appURL, requireBundleID: false) else { return nil }
        let bid = (bundleID?.isEmpty == false ? bundleID! : info.bundleID)
        var shortVer = info.shortVersion ?? "0"
        if bid == "com.citrix.receiver.nomas",
           let citrixVer = info.citrixVersionString, !citrixVer.isEmpty {
            shortVer = citrixVer
        }
        if (bid == "com.sublimetext.4" || bid == "com.sublimemerge"),
           shortVer.lowercased().hasPrefix("build ") {
            shortVer = String(shortVer.dropFirst("build ".count)).trimmingCharacters(in: .whitespaces)
        }
        if bid == "com.mitchellh.ghostty",
           shortVer.range(of: "^[0-9a-fA-F]{7,40}$", options: .regularExpression) != nil {
            return nil
        }
        return (normalizeDisplayVersion(shortVer), info.buildVersion ?? "")
    }

    nonisolated private static func isRemoteUpdateStillNewer(
        remoteVersion: String,
        channel: SoftwareUpdateChannel,
        localShort: String,
        localBuild: String
    ) -> Bool {
        let primaryRaw = remoteVersion.split(separator: ",").first.map(String.init) ?? remoteVersion
        let cleanRemote = normalizeDisplayVersion(primaryRaw)
        if cleanRemote.isEmpty || cleanRemote.lowercased() == "latest" {
            return true
        }
        if isPureDigits(cleanRemote) && isPureDigits(localBuild) && !localShort.contains(cleanRemote) {
            return isNewerVersion(cleanRemote, than: localBuild)
        }
        if channel == .website || channel == .homebrewCask {
            return isCatalogCandidateNewer(
                candidateVersion: cleanRemote,
                installedShort: localShort,
                installedBuild: localBuild
            )
        }
        return isNewerVersion(cleanRemote, than: localShort)
    }

    // MARK: - Local Applications Multi-Channel Update Checker

    nonisolated private static func scanInstalledAppsUpdates(
        brewSnapshot: (caskUpdates: [SoftwareUpdateItem], formulaItems: [SoftwareUpdateItem], caskroomByAppName: [String: String], installedCaskTokens: Set<String>),
        catalogEntries: [CaskCatalogEntry]
    ) async -> (updates: [SoftwareUpdateItem], upToDateTracked: [SoftwareUpdateItem]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var seenPaths: Set<String> = []
        var appURLs: [URL] = []

        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in top {
                let stdPath = entry.standardizedFileURL.path
                if entry.pathExtension.lowercased() == "app" {
                    if seenPaths.insert(stdPath).inserted { appURLs.append(entry) }
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let sub = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for s in sub where s.pathExtension.lowercased() == "app" {
                        let subStd = s.standardizedFileURL.path
                        if seenPaths.insert(subStd).inserted { appURLs.append(s) }
                    }
                }
            }
        }

        let runningBIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let brewCaskByToken: [String: SoftwareUpdateItem] = Dictionary(
            brewSnapshot.caskUpdates.compactMap { item in
                guard let tok = item.brewToken?.lowercased() else { return nil }
                return (tok, item)
            },
            uniquingKeysWith: { first, _ in first }
        )

        enum AppCheckPlan: Sendable {
            case homebrewCask(token: String, outdated: SoftwareUpdateItem?)
            case appStore(adamID: String?)
            case sparkle(feedURL: URL)
            case electron(source: ElectronFeedSource)
            case websiteCatalog
        }

        struct CandidateApp: Sendable {
            let name: String
            let bundleID: String
            let appURL: URL
            let shortVersion: String
            let buildVersion: String
            let isNonStableVSCode: Bool
            let isRunning: Bool
            let plan: AppCheckPlan
        }

        func appBundlePriority(_ u: URL) -> Int {
            let parent = u.deletingLastPathComponent().standardizedFileURL.path
            if parent == "/Applications" { return 3 }
            if u.standardizedFileURL.path.hasPrefix("/Applications/") { return 2 }
            let homeApps = home.appendingPathComponent("Applications").standardizedFileURL.path
            if parent == homeApps { return 1 }
            return 0
        }

        func shouldReplaceCandidate(existing: CandidateApp, with incoming: CandidateApp) -> Bool {
            let oldPrio = appBundlePriority(existing.appURL)
            let newPrio = appBundlePriority(incoming.appURL)
            if newPrio != oldPrio { return newPrio > oldPrio }
            let cmpShort = compareVersionComponents(incoming.shortVersion, existing.shortVersion)
            if cmpShort != .orderedSame { return cmpShort == .orderedDescending }
            return compareVersionComponents(incoming.buildVersion, existing.buildVersion) == .orderedDescending
        }

        var candidatesByBundleID: [String: CandidateApp] = [:]
        var orderedBundleKeys: [String] = []
        for url in appURLs {
            if url.path.hasPrefix("/System") { continue }
            guard let info = FreshBundleInfo.read(at: url) else { continue }
            let bid = info.bundleID

            // 排除 SysPulse 本体、系统非商店应用、iOS 封装应用与卸载器助手
            if bid == Bundle.main.bundleIdentifier || bid == "com.rabbit.syspulse" { continue }
            let receiptExists = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
            if bid.hasPrefix("com.apple.") && !receiptExists { continue }

            if info.requiresIPhoneOS { continue }
            if info.supportedPlatforms.contains("iPhoneOS") && !info.supportedPlatforms.contains("MacOSX") {
                continue
            }

            let rawFileName = url.deletingPathExtension().lastPathComponent
            let displayName = info.displayName
                ?? info.bundleName
                ?? rawFileName
            if rawFileName.lowercased().contains("uninstall") || bid.lowercased().contains("uninstall") {
                continue
            }

            var shortVer = info.shortVersion ?? "0"
            if bid == "com.citrix.receiver.nomas",
               let citrixVer = info.citrixVersionString, !citrixVer.isEmpty {
                shortVer = citrixVer
            }
            if (bid == "com.sublimetext.4" || bid == "com.sublimemerge"),
               shortVer.lowercased().hasPrefix("build ") {
                shortVer = String(shortVer.dropFirst("build ".count)).trimmingCharacters(in: .whitespaces)
            }
            // Ghostty 提交哈希版本跳过
            if bid == "com.mitchellh.ghostty",
               shortVer.range(of: "^[0-9a-fA-F]{7,40}$", options: .regularExpression) != nil {
                continue
            }
            let buildVer = info.buildVersion ?? ""

            var isNonStableVSCode = false
            let productJsonURL = url.appendingPathComponent("Contents/Resources/app/product.json")
            if let pData = try? Data(contentsOf: productJsonURL, options: .uncached),
               let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
               let quality = pJson["quality"] as? String,
               quality.lowercased() != "stable" {
                isNonStableVSCode = true
            }

            let isRunning = runningBIDs.contains(bid)
            let normalizedShort = normalizeDisplayVersion(shortVer)
            let candidate: CandidateApp

            // 严格独占渠道判定（禁止跨渠道误落）
            // 1. Homebrew Caskroom（含 .app Cask 与经 .pkg 安装但存在 Caskroom token 的应用）
            let pkgMatchedCaskToken: String? = {
                if let direct = brewSnapshot.caskroomByAppName[url.lastPathComponent.lowercased()] {
                    return direct
                }
                if let entry = matchCatalogEntry(bundleID: bid, appURL: url, entries: catalogEntries),
                   brewSnapshot.installedCaskTokens.contains(entry.token.lowercased()) {
                    return entry.token
                }
                return nil
            }()

            if let caskToken = pkgMatchedCaskToken {
                candidate = CandidateApp(
                    name: displayName, bundleID: bid, appURL: url,
                    shortVersion: normalizedShort,
                    buildVersion: buildVer,
                    isNonStableVSCode: isNonStableVSCode,
                    isRunning: isRunning,
                    plan: .homebrewCask(token: caskToken, outdated: brewCaskByToken[caskToken.lowercased()])
                )
            } else if receiptExists {
                // 2. App Store (_MASReceipt/receipt 独占)
                var masAdamID: String? = nil
                let itunesPlist = url.appendingPathComponent("Contents/iTunesMetadata.plist")
                if let data = try? Data(contentsOf: itunesPlist, options: .uncached),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let itemId = plist["itemId"] {
                    masAdamID = String(describing: itemId)
                } else if let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
                          let adam = MDItemCopyAttribute(md, "kMDItemAppStoreAdamID" as CFString) {
                    masAdamID = String(describing: adam)
                }
                candidate = CandidateApp(
                    name: displayName, bundleID: bid, appURL: url,
                    shortVersion: normalizedShort,
                    buildVersion: buildVer,
                    isNonStableVSCode: isNonStableVSCode,
                    isRunning: isRunning,
                    plan: .appStore(adamID: masAdamID)
                )
            } else {
                // 3. Sparkle (仅当具备有效 http(s) SUFeedURL 或覆盖源)
                let plistFeedString = info.suFeedURL ?? info.suOriginalFeedURL
                let overrideFeedString = sparkleFeedOverrides[bid]
                let feedCandidateStr = overrideFeedString ?? plistFeedString
                if let feedStr = feedCandidateStr,
                   !feedStr.isEmpty,
                   let feedURL = URL(string: feedStr),
                   let scheme = feedURL.scheme?.lowercased(),
                   (scheme == "http" || scheme == "https") {
                    candidate = CandidateApp(
                        name: displayName, bundleID: bid, appURL: url,
                        shortVersion: normalizedShort,
                        buildVersion: buildVer,
                        isNonStableVSCode: isNonStableVSCode,
                        isRunning: isRunning,
                        plan: .sparkle(feedURL: feedURL)
                    )
                } else if let electronSource = resolveElectronFeedSource(appURL: url, bundleID: bid) {
                    // 4. Electron (app-update.yml 必须能解析出非空的有效更新地址或 GitHub 仓库)
                    candidate = CandidateApp(
                        name: displayName, bundleID: bid, appURL: url,
                        shortVersion: normalizedShort,
                        buildVersion: buildVer,
                        isNonStableVSCode: isNonStableVSCode,
                        isRunning: isRunning,
                        plan: .electron(source: electronSource)
                    )
                } else {
                    // 5. Website / Cask Catalog
                    candidate = CandidateApp(
                        name: displayName, bundleID: bid, appURL: url,
                        shortVersion: normalizedShort,
                        buildVersion: buildVer,
                        isNonStableVSCode: isNonStableVSCode,
                        isRunning: isRunning,
                        plan: .websiteCatalog
                    )
                }
            }

            let bidKey = bid.lowercased()
            if let existing = candidatesByBundleID[bidKey] {
                if shouldReplaceCandidate(existing: existing, with: candidate) {
                    candidatesByBundleID[bidKey] = candidate
                }
            } else {
                orderedBundleKeys.append(bidKey)
                candidatesByBundleID[bidKey] = candidate
            }
        }
        let candidates: [CandidateApp] = orderedBundleKeys.compactMap { candidatesByBundleID[$0] }

        // 并发检测更新
        let results: [SoftwareUpdateItem] = await withTaskGroup(of: SoftwareUpdateItem?.self) { group in
            for app in candidates {
                group.addTask {
                    switch app.plan {
                    case .homebrewCask(let token, let outdated):
                        var effectiveHasUpdate = false
                        var effectiveLatest = app.shortVersion
                        if let outdated, let remoteRaw = outdated.latestVersion {
                            let primaryRemote = remoteRaw.split(separator: ",").first.map(String.init) ?? remoteRaw
                            let cleanedRemote = normalizeDisplayVersion(primaryRemote)
                            if cleanedRemote.lowercased() == "latest" {
                                effectiveLatest = remoteRaw
                                effectiveHasUpdate = true
                            } else {
                                effectiveLatest = cleanedRemote
                                effectiveHasUpdate = isCatalogCandidateNewer(
                                    candidateVersion: cleanedRemote,
                                    installedShort: app.shortVersion,
                                    installedBuild: app.buildVersion
                                )
                            }
                        }
                        return SoftwareUpdateItem(
                            id: "brew.cask.\(token)",
                            name: app.name,
                            bundleID: app.bundleID,
                            bundleURL: app.appURL,
                            channel: .homebrewCask,
                            currentVersion: app.shortVersion,
                            latestVersion: effectiveLatest,
                            hasUpdate: effectiveHasUpdate,
                            brewToken: token,
                            releaseNotes: effectiveHasUpdate
                                ? "检测到 Homebrew Cask 新版本，可执行 `brew upgrade --cask \(token)`。"
                                : "受 Homebrew Cask 托管，当前已是最新版本。",
                            archTag: ProcessInfo.processInfo.machineArchitectureTag,
                            isRunning: app.isRunning,
                            currentBuild: app.buildVersion
                        )

                    case .appStore(let adamID):
                        return await checkMacAppStore(
                            name: app.name,
                            bundleID: app.bundleID,
                            appURL: app.appURL,
                            currentVersion: app.shortVersion,
                            buildVersion: app.buildVersion,
                            adamID: adamID,
                            isRunning: app.isRunning
                        )

                    case .sparkle(let feedURL):
                        return await checkSparkleFeed(
                            name: app.name,
                            bundleID: app.bundleID,
                            appURL: app.appURL,
                            shortVersion: app.shortVersion,
                            buildVersion: app.buildVersion,
                            feedURL: feedURL,
                            isRunning: app.isRunning
                        )

                    case .electron(let source):
                        return await checkElectronUpdater(
                            name: app.name,
                            bundleID: app.bundleID,
                            appURL: app.appURL,
                            currentVersion: app.shortVersion,
                            buildVersion: app.buildVersion,
                            source: source,
                            isRunning: app.isRunning
                        )

                    case .websiteCatalog:
                        return await checkWebsiteCatalog(
                            name: app.name,
                            bundleID: app.bundleID,
                            appURL: app.appURL,
                            shortVersion: app.shortVersion,
                            buildVersion: app.buildVersion,
                            isNonStableVSCode: app.isNonStableVSCode,
                            isRunning: app.isRunning,
                            catalogEntries: catalogEntries
                        )
                    }
                }
            }

            var out: [SoftwareUpdateItem] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }

        let updates = results.filter(\.hasUpdate)
        let tracked = results.filter { !$0.hasUpdate }
        return (updates, tracked)
    }

    // MARK: - Mac App Store Checker (itunes.apple.com + Storefront Confirmation)

    nonisolated private static func checkMacAppStore(
        name: String,
        bundleID: String,
        appURL: URL,
        currentVersion: String,
        buildVersion: String,
        adamID: String?,
        isRunning: Bool
    ) async -> SoftwareUpdateItem? {
        let country = Locale.current.region?.identifier.lowercased() ?? "cn"
        let lookupCountries = country == "us" ? ["us"] : [country, "us"]

        var matchedRecord: [String: Any]? = nil
        var usedCountry = country
        for cc in lookupCountries {
            var queryURLString: String? = nil
            if let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                queryURLString = "https://itunes.apple.com/lookup?bundleId=\(encoded)&entity=macSoftware&country=\(cc)"
            }
            if let urlStr = queryURLString,
               let url = URL(string: urlStr),
               let data = await fetchData(url: url, timeout: 8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                if let macResult = results.first(where: { isValidMacAppStoreResult($0) }) {
                    matchedRecord = macResult
                    usedCountry = cc
                    break
                }
            }
            if matchedRecord == nil, let adamID, !adamID.isEmpty,
               let url = URL(string: "https://itunes.apple.com/lookup?id=\(adamID)&entity=macSoftware&country=\(cc)"),
               let data = await fetchData(url: url, timeout: 8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let macResult = results.first(where: { isValidMacAppStoreResult($0) }) {
                matchedRecord = macResult
                usedCountry = cc
                break
            }
        }

        guard let first = matchedRecord,
              let rawStoreVersion = first["version"] as? String else {
            return SoftwareUpdateItem(
                id: "mas.\(bundleID)",
                name: name,
                bundleID: bundleID,
                bundleURL: appURL,
                channel: .macAppStore,
                currentVersion: currentVersion,
                latestVersion: currentVersion,
                hasUpdate: false,
                masTrackID: adamID,
                releaseNotes: "受 Mac App Store 托管",
                isRunning: isRunning,
                currentBuild: buildVersion
            )
        }

        let trackID = first["trackId"].map { String(describing: $0) } ?? adamID
        let notes = (first["releaseNotes"] as? String) ?? ""
        let minOS = first["minimumOsVersion"] as? String
        let kind = (first["kind"] as? String) ?? ""
        let storeVersion = normalizeDisplayVersion(rawStoreVersion)
        var effectiveStoreVersion = storeVersion
        var newer = isNewerVersion(effectiveStoreVersion, than: currentVersion) && isOSCompatible(minOS)

        // 对于 iosUniversal 应用 (kind == "software") 或 lookup 报告有新版本时，
        // 核验 apps.apple.com/...?platform=mac 页面上的真实 Mac 版号，避免 iOS 版更新导致误报
        if newer || kind != "mac-software" {
            if let trackID, !trackID.isEmpty,
               let storefrontVer = await fetchMacStorefrontVersion(trackID: trackID, country: usedCountry) {
                effectiveStoreVersion = normalizeDisplayVersion(storefrontVer)
                newer = isNewerVersion(effectiveStoreVersion, than: currentVersion) && isOSCompatible(minOS)
            } else if kind != "mac-software" {
                newer = false
                effectiveStoreVersion = currentVersion
            }
        }

        return SoftwareUpdateItem(
            id: "mas.\(bundleID)",
            name: name,
            bundleID: bundleID,
            bundleURL: appURL,
            channel: .macAppStore,
            currentVersion: currentVersion,
            latestVersion: effectiveStoreVersion,
            hasUpdate: newer,
            masTrackID: trackID,
            releaseNotes: notes.isEmpty ? (newer ? "可通过 Mac App Store 更新。" : "受 Mac App Store 托管，当前已是最新版本。") : notes,
            minimumOSVersion: minOS,
            isRunning: isRunning,
            currentBuild: buildVersion
        )
    }

    nonisolated private static func isValidMacAppStoreResult(_ dict: [String: Any]) -> Bool {
        if let kind = dict["kind"] as? String, kind == "mac-software" {
            return true
        }
        if let supported = dict["supportedDevices"] as? [String],
           supported.contains(where: { $0 == "MacDesktop-MacDesktop" || $0.lowercased().contains("mac") }) {
            return true
        }
        return false
    }

    nonisolated private static func fetchMacStorefrontVersion(trackID: String, country: String) async -> String? {
        guard let url = URL(string: "https://apps.apple.com/\(country)/app/id\(trackID)?platform=mac"),
              let data = await fetchData(url: url, timeout: 8),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        let patterns = [
            "\"mostRecentVersion\"\\s*:\\s*\"([^\"]+)\"",
            "(?:版本|Version)\\s+([0-9]+(?:\\.[0-9]+)+)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let candidate = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Sparkle Checker (Strict Appcast Parser)

    nonisolated private static func checkSparkleFeed(
        name: String,
        bundleID: String,
        appURL: URL,
        shortVersion: String,
        buildVersion: String,
        feedURL: URL,
        isRunning: Bool
    ) async -> SoftwareUpdateItem? {
        guard let data = await fetchData(url: feedURL, timeout: 10) else {
            return SoftwareUpdateItem(
                id: "sparkle.\(bundleID)",
                name: name,
                bundleID: bundleID,
                bundleURL: appURL,
                channel: .sparkle,
                currentVersion: shortVersion,
                latestVersion: shortVersion,
                hasUpdate: false,
                releaseNotes: "暂时无法访问 Sparkle Appcast 更新源。",
                archTag: ProcessInfo.processInfo.machineArchitectureTag,
                isRunning: isRunning,
                currentBuild: buildVersion
            )
        }

        let parser = SparkleFeedXMLParser(data: data)
        let entries = parser.parse()
        let installedIsPrerelease = containsPrereleaseTag(shortVersion)

        let compatibleEntries = entries.filter { entry in
            guard entry.enclosureURL != nil else { return false }
            // 仅接收默认稳定通道，过滤 beta / internal / nightly 等通道
            if let ch = entry.channel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !ch.isEmpty, ch != "default", ch != "stable" {
                return false
            }
            guard isOSCompatible(entry.minimumSystemVersion) else { return false }
            guard isMaxOSCompatible(entry.maximumSystemVersion) else { return false }
            guard isHardwareRequirementsCompatible(entry.hardwareRequirements) else { return false }
            let candidateLabel = entry.shortVersion ?? entry.buildVersion ?? ""
            if !installedIsPrerelease && containsPrereleaseTag(candidateLabel) {
                return false
            }
            return true
        }

        let best = compatibleEntries.max(by: { lhs, rhs in
            let lv = effectiveSparkleComparable(entry: lhs)
            let rv = effectiveSparkleComparable(entry: rhs)
            return compareVersionComponents(lv, rv) == .orderedAscending
        })

        guard let best else {
            return SoftwareUpdateItem(
                id: "sparkle.\(bundleID)",
                name: name,
                bundleID: bundleID,
                bundleURL: appURL,
                channel: .sparkle,
                currentVersion: shortVersion,
                latestVersion: shortVersion,
                hasUpdate: false,
                releaseNotes: "当前系统环境已处于适用最新版本。",
                archTag: ProcessInfo.processInfo.machineArchitectureTag,
                isRunning: isRunning,
                currentBuild: buildVersion
            )
        }

        let evaluation = evaluateSparkleUpdate(
            entry: best,
            installedShort: shortVersion,
            installedBuild: buildVersion
        )

        let dlURL = best.enclosureURL
        let archTag = (dlURL?.absoluteString.lowercased().contains("arm64") == true) ? "Apple Silicon" : ProcessInfo.processInfo.machineArchitectureTag
        let notesText = cleanHTMLText(best.descriptionHTML)
        let releaseInfo: String
        if !notesText.isEmpty {
            releaseInfo = notesText
        } else if let rlink = best.releaseNotesLink, !rlink.isEmpty {
            releaseInfo = "发布说明页面：\(rlink)"
        } else {
            releaseInfo = evaluation.hasUpdate ? "检测到 Sparkle 新版本发布。" : "当前已是最新版本。"
        }

        return SoftwareUpdateItem(
            id: "sparkle.\(bundleID)",
            name: name,
            bundleID: bundleID,
            bundleURL: appURL,
            channel: .sparkle,
            currentVersion: shortVersion,
            latestVersion: evaluation.displayVersion,
            hasUpdate: evaluation.hasUpdate && dlURL != nil,
            downloadURL: dlURL,
            releaseNotes: releaseInfo,
            minimumOSVersion: best.minimumSystemVersion,
            expectedFileSizeBytes: best.lengthBytes,
            archTag: archTag,
            isRunning: isRunning,
            currentBuild: buildVersion
        )
    }

    nonisolated private static func effectiveSparkleComparable(entry: SparkleFeedXMLParser.Entry) -> String {
        if let sv = entry.shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !sv.isEmpty {
            return normalizeDisplayVersion(sv)
        }
        if let bv = entry.buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !bv.isEmpty {
            return normalizeDisplayVersion(bv)
        }
        return "0"
    }

    nonisolated private static func evaluateSparkleUpdate(
        entry: SparkleFeedXMLParser.Entry,
        installedShort: String,
        installedBuild: String
    ) -> (hasUpdate: Bool, displayVersion: String) {
        let itemShort = entry.shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let itemBuild = entry.buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanInstalledShort = normalizeDisplayVersion(installedShort)
        let cleanInstalledBuild = installedBuild.trimmingCharacters(in: .whitespacesAndNewlines)

        // 若提供了 shortVersionString，严格以营销版本号进行比较（切勿拿纯整数 build 号和营销版本比较）
        if !itemShort.isEmpty {
            let cleanItemShort = normalizeDisplayVersion(itemShort)
            let newer = isNewerVersion(cleanItemShort, than: cleanInstalledShort)
            return (newer, cleanItemShort)
        }

        // 若未提供 shortVersionString，只有当 itemBuild 与 installedBuild 均为纯整数或均为点分版本号时才能比对
        if !itemBuild.isEmpty {
            if isPureDigits(itemBuild) {
                if isPureDigits(cleanInstalledBuild) && isNewerVersion(itemBuild, than: cleanInstalledBuild) {
                    let display = extractVersionFromTitle(entry.title) ?? itemBuild
                    return (true, display)
                }
                return (false, extractVersionFromTitle(entry.title) ?? cleanInstalledShort)
            } else {
                let cleanBuild = normalizeDisplayVersion(itemBuild)
                let newer = isNewerVersion(cleanBuild, than: cleanInstalledShort)
                return (newer, cleanBuild)
            }
        }

        return (false, cleanInstalledShort)
    }

    nonisolated private static func extractVersionFromTitle(_ title: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)+)"),
           let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let range = Range(match.range(at: 1), in: title) {
            return String(title[range])
        }
        return nil
    }

    // MARK: - Electron Checker

    enum ElectronFeedSource: Sendable {
        case directYAML(URL)
        case github(owner: String, repo: String)
    }

    nonisolated private static func resolveElectronFeedSource(appURL: URL, bundleID: String) -> ElectronFeedSource? {
        if let overrideStr = electronYamlOverrides[bundleID],
           let overrideURL = URL(string: overrideStr) {
            return .directYAML(overrideURL)
        }

        let appUpdateYml = appURL.appendingPathComponent("Contents/Resources/app-update.yml")
        guard FileManager.default.fileExists(atPath: appUpdateYml.path),
              let text = try? String(contentsOf: appUpdateYml, encoding: .utf8) else {
            return nil
        }

        let fields = parseSimpleYAMLKeyValues(text)
        let provider = fields["provider"]?.lowercased() ?? ""
        let channel = fields["channel"].flatMap { $0.isEmpty ? nil : $0 } ?? "latest"

        if provider == "github",
           let owner = fields["owner"], !owner.isEmpty,
           let repo = fields["repo"], !repo.isEmpty {
            return .github(owner: owner, repo: repo)
        }

        if provider == "s3" || provider == "spaces",
           let bucket = fields["bucket"], !bucket.isEmpty {
            let pathPrefix = (fields["path"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let joinedPath = pathPrefix.isEmpty ? "\(channel)-mac.yml" : "\(pathPrefix)/\(channel)-mac.yml"
            let urlStr = "https://\(bucket).s3.amazonaws.com/\(joinedPath)"
            if let u = URL(string: urlStr) {
                return .directYAML(u)
            }
        }

        if let baseURLString = fields["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !baseURLString.isEmpty,
           baseURLString != "''",
           baseURLString != "\"\"",
           var base = URL(string: baseURLString),
           let scheme = base.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            if !base.lastPathComponent.lowercased().hasSuffix(".yml") {
                base.appendPathComponent("\(channel)-mac.yml")
            }
            return .directYAML(base)
        }

        return nil
    }

    nonisolated private static func checkElectronUpdater(
        name: String,
        bundleID: String,
        appURL: URL,
        currentVersion: String,
        buildVersion: String,
        source: ElectronFeedSource,
        isRunning: Bool
    ) async -> SoftwareUpdateItem? {
        switch source {
        case .github(let owner, let repo):
            if let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"),
               let data = await fetchData(url: apiURL, timeout: 10),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                let cleanVer = normalizeDisplayVersion(tagName)
                let assets = (json["assets"] as? [[String: Any]]) ?? []
                let preferredAsset = selectBestMacAsset(assets: assets)
                let dlURL = (preferredAsset?["browser_download_url"] as? String).flatMap { URL(string: $0) }
                let size = preferredAsset?["size"] as? Int64
                let body = (json["body"] as? String) ?? ""
                let isNewer = isNewerVersion(cleanVer, than: currentVersion) && dlURL != nil

                return SoftwareUpdateItem(
                    id: "electron.gh.\(bundleID)",
                    name: name,
                    bundleID: bundleID,
                    bundleURL: appURL,
                    channel: .electron,
                    currentVersion: currentVersion,
                    latestVersion: cleanVer,
                    hasUpdate: isNewer,
                    downloadURL: dlURL,
                    releaseNotes: body.isEmpty ? "GitHub Releases 自动发布源" : body,
                    expectedFileSizeBytes: size,
                    archTag: ProcessInfo.processInfo.machineArchitectureTag,
                    isRunning: isRunning,
                    currentBuild: buildVersion
                )
            }

        case .directYAML(let yamlURL):
            if let data = await fetchData(url: yamlURL, timeout: 10),
               let yamlText = String(data: data, encoding: .utf8) {
                let fields = parseSimpleYAMLKeyValues(yamlText)
                if let rawRemote = fields["version"], !rawRemote.isEmpty {
                    let remoteVer = normalizeDisplayVersion(rawRemote)
                    let filePaths = parseElectronYAMLFiles(yamlText)
                    let chosenFile = selectBestElectronAssetName(paths: filePaths) ?? fields["path"]
                    var dlURL: URL? = nil
                    if let chosenFile, !chosenFile.isEmpty {
                        if chosenFile.hasPrefix("http") {
                            dlURL = URL(string: chosenFile)
                        } else {
                            dlURL = yamlURL.deletingLastPathComponent().appendingPathComponent(chosenFile)
                        }
                    }
                    let isNewer = isNewerVersion(remoteVer, than: currentVersion) && dlURL != nil
                    return SoftwareUpdateItem(
                        id: "electron.yml.\(bundleID)",
                        name: name,
                        bundleID: bundleID,
                        bundleURL: appURL,
                        channel: .electron,
                        currentVersion: currentVersion,
                        latestVersion: remoteVer,
                        hasUpdate: isNewer,
                        downloadURL: dlURL,
                        releaseNotes: fields["releaseNotes"].map(cleanHTMLText) ?? "Electron latest-mac.yml 分发源",
                        archTag: ProcessInfo.processInfo.machineArchitectureTag,
                        isRunning: isRunning,
                        currentBuild: buildVersion
                    )
                }
            }
        }

        return SoftwareUpdateItem(
            id: "electron.\(bundleID)",
            name: name,
            bundleID: bundleID,
            bundleURL: appURL,
            channel: .electron,
            currentVersion: currentVersion,
            latestVersion: currentVersion,
            hasUpdate: false,
            releaseNotes: "受 Electron 自动更新源托管。",
            archTag: ProcessInfo.processInfo.machineArchitectureTag,
            isRunning: isRunning,
            currentBuild: buildVersion
        )
    }

    // MARK: - Website / Direct Vendor & Homebrew Cask Catalog Checker

    nonisolated private static func checkWebsiteCatalog(
        name: String,
        bundleID: String,
        appURL: URL,
        shortVersion: String,
        buildVersion: String,
        isNonStableVSCode: Bool,
        isRunning: Bool,
        catalogEntries: [CaskCatalogEntry]
    ) async -> SoftwareUpdateItem? {
        if bundleID == "com.microsoft.VSCode", !isNonStableVSCode {
            if let apiURL = URL(string: "https://update.code.visualstudio.com/api/update/darwin-arm64/stable/latest"),
               let data = await fetchData(url: apiURL, timeout: 8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawVer = json["productVersion"] as? String,
               let urlStr = json["url"] as? String,
               let dlURL = URL(string: urlStr) {
                let remoteVer = normalizeDisplayVersion(rawVer)
                let newer = isNewerVersion(remoteVer, than: shortVersion)
                return SoftwareUpdateItem(
                    id: "website.\(bundleID)",
                    name: name,
                    bundleID: bundleID,
                    bundleURL: appURL,
                    channel: .website,
                    currentVersion: shortVersion,
                    latestVersion: remoteVer,
                    hasUpdate: newer,
                    downloadURL: dlURL,
                    releaseNotes: newer ? "Microsoft Visual Studio Code 官方更新源" : "已是官方最新稳定版。",
                    archTag: ProcessInfo.processInfo.machineArchitectureTag,
                    isRunning: isRunning,
                    currentBuild: buildVersion
                )
            }
        }

        if bundleID == "com.raycast.macos" {
            if let apiURL = URL(string: "https://releases.raycast.com/releases/latest?build=universal"),
               let data = await fetchData(url: apiURL, timeout: 8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawVer = json["version"] as? String,
               let urlStr = json["download_url"] as? String,
               let dlURL = URL(string: urlStr) {
                let remoteVer = normalizeDisplayVersion(rawVer)
                let newer = isNewerVersion(remoteVer, than: shortVersion)
                return SoftwareUpdateItem(
                    id: "website.\(bundleID)",
                    name: name,
                    bundleID: bundleID,
                    bundleURL: appURL,
                    channel: .website,
                    currentVersion: shortVersion,
                    latestVersion: remoteVer,
                    hasUpdate: newer,
                    downloadURL: dlURL,
                    releaseNotes: newer ? "Raycast 官方稳定版发布源" : "已是官方最新稳定版。",
                    archTag: ProcessInfo.processInfo.machineArchitectureTag,
                    isRunning: isRunning,
                    currentBuild: buildVersion
                )
            }
        }

        guard !isNonStableVSCode else { return nil }
        guard let entry = matchCatalogEntry(bundleID: bundleID, appURL: appURL, entries: catalogEntries) else {
            return nil
        }

        // Brave / OnyX 等明确支持经官网 / Cask 源直装升级的例外应用
        let directCatalogOverrideBundleIDs: Set<String> = [
            "com.brave.browser",
            "com.brave.browser.beta",
            "com.brave.browser.nightly",
            "com.titanium.onyx"
        ]
        let isExplicitDirectOverride = directCatalogOverrideBundleIDs.contains(bundleID.lowercased())
        let isSelfManaged = !isExplicitDirectOverride && entry.autoUpdates && isLikelySelfManagedApp(appURL: appURL, entry: entry)

        let installedIsPrerelease = containsPrereleaseTag(shortVersion)
        let primaryRaw = entry.version.split(separator: ",").first.map(String.init) ?? entry.version
        let candidateVer = normalizeDisplayVersion(primaryRaw)
        if !installedIsPrerelease && containsPrereleaseTag(candidateVer) {
            return nil
        }

        // 防止版本号体系差异（如日期构建号 vs 语义化版本、或过旧本地无效版本 "0"）造成误报
        let isNewer: Bool
        if shortVersion == "0" || hasIncompatibleVersionScheme(candidate: candidateVer, installed: shortVersion) {
            isNewer = false
        } else {
            isNewer = isCatalogCandidateNewer(
                candidateVersion: candidateVer,
                installedShort: shortVersion,
                installedBuild: buildVersion
            )
        }
        let dlURL = URL(string: entry.url)
        let hasValidUpdate = isNewer && (dlURL != nil || isSelfManaged)

        let notes: String
        if isSelfManaged && hasValidUpdate {
            notes = "检测到新版本（\(candidateVer)）。该应用内置自更新器，请打开「\(name)」在应用内检查并完成更新。"
        } else if hasValidUpdate {
            notes = entry.vendorInstallerAppName != nil
                ? "检测到官方网站新版（\(candidateVer)），将下载并引导运行官方安装器 \(entry.vendorInstallerAppName!) 完成升级。"
                : "检测到官网更新源新版本（\(candidateVer)），官网地址：\(entry.homepage)"
        } else {
            notes = "已是官网可用清单最新版本（\(candidateVer)）。官网：\(entry.homepage)"
        }

        return SoftwareUpdateItem(
            id: "website.\(bundleID)",
            name: name,
            bundleID: bundleID,
            bundleURL: appURL,
            channel: .website,
            currentVersion: shortVersion,
            latestVersion: candidateVer,
            hasUpdate: hasValidUpdate,
            downloadURL: dlURL,
            brewToken: entry.token,
            releaseNotes: notes,
            archTag: ProcessInfo.processInfo.machineArchitectureTag,
            isRunning: isRunning,
            isSelfManaged: isSelfManaged,
            currentBuild: buildVersion,
            vendorInstallerAppName: entry.vendorInstallerAppName
        )
    }

    nonisolated private static func hasIncompatibleVersionScheme(candidate: String, installed: String) -> Bool {
        let cFirst = Int(normalizeDisplayVersion(candidate).split(separator: ".").first?.prefix(while: \.isNumber) ?? "") ?? 0
        let iFirst = Int(normalizeDisplayVersion(installed).split(separator: ".").first?.prefix(while: \.isNumber) ?? "") ?? 0
        // 避免时间戳版本 (20250101) 与小主版本号 (1.2.3) 跨体系比较误报
        if (cFirst >= 20_000_000 && iFirst < 10_000) || (iFirst >= 20_000_000 && cFirst < 10_000) {
            return true
        }
        return false
    }

    nonisolated private static func matchCatalogEntry(
        bundleID: String,
        appURL: URL,
        entries: [CaskCatalogEntry]
    ) -> CaskCatalogEntry? {
        let appNameLower = appURL.lastPathComponent.lowercased()
        let bidLower = bundleID.lowercased()
        let bidVendorPrefix = bidLower.split(separator: ".").prefix(2).joined(separator: ".")

        // 防止 Cline / DBX / Tinycast 等无严格关联或非官方桌面分发应用的 Cask 误匹配更新
        let excludedFalsePositiveTokensByBundlePrefix: [String: Set<String>] = [
            "cline": ["cline"],
            "dbx": ["dbx", "dropbox-dash"],
            "tinycast": ["tinycast"]
        ]

        // 精准 Bundle ID -> Cask Token 提示（如 Brave / OnyX）
        let preferredTokenByBundleID: [String: String] = [
            "com.brave.browser": "brave-browser",
            "com.brave.browser.beta": "brave-browser@beta",
            "com.brave.browser.nightly": "brave-browser@nightly",
            "com.titanium.onyx": "onyx"
        ]
        if let preferredTok = preferredTokenByBundleID[bidLower],
           let directHit = entries.first(where: { $0.token.lowercased() == preferredTok }) {
            return directHit
        }

        let candidates = entries.filter { entry in
            entry.appNames.contains(where: { $0.lowercased() == appNameLower })
                || entry.installerAppNames.contains(where: { $0.lowercased() == appNameLower })
        }
        guard !candidates.isEmpty else { return nil }

        var scored: [(entry: CaskCatalogEntry, score: Int)] = []
        for entry in candidates {
            let lowerToken = entry.token.lowercased()
            if excludedFalsePositiveTokensByBundlePrefix.values.contains(where: { $0.contains(lowerToken) })
                && !entry.bundleIDHints.contains(bidLower) {
                continue
            }

            var score = 0
            if !entry.bundleIDHints.isEmpty {
                if entry.bundleIDHints.contains(bidLower) {
                    score += 100
                } else if !bidVendorPrefix.isEmpty,
                          entry.bundleIDHints.contains(where: { $0.hasPrefix(bidVendorPrefix + ".") }) {
                    score += 20
                } else {
                    // Cask 明确关联了完全不同的 Bundle ID，直接排除冲突条目
                    score -= 100
                }
            } else {
                // Cask 未声明 Bundle ID 时，对短名称/歧义名称校验官网域名与 Bundle ID 供应商段一致性
                let bareAppName = appURL.deletingPathExtension().lastPathComponent.lowercased()
                let rawSegments: [String] = bidLower.split(separator: ".").map { String($0) }
                let ignoredSegments: Set<String> = ["com", "org", "app", "mac"]
                let vendorTokens: [String] = rawSegments.filter { segment in
                    segment.count >= 3 && !ignoredSegments.contains(segment)
                }
                let hostLower = (URL(string: entry.homepage)?.host ?? entry.homepage).lowercased()
                if vendorTokens.contains(where: { hostLower.contains($0) }) {
                    score += 40
                } else if bareAppName.count <= 4 {
                    score -= 80
                }
            }
            if lowerToken.contains("@beta") || lowerToken.contains("@nightly") || lowerToken.contains("@dev") || lowerToken.contains("@canary") || lowerToken.contains("@alpha") {
                score -= 50
            } else if !lowerToken.contains("@") {
                score += 30
            }
            if score >= 0 {
                scored.append((entry, score))
            }
        }

        return scored.max(by: { $0.score < $1.score })?.entry
    }

    nonisolated private static func isLikelySelfManagedApp(appURL: URL, entry: CaskCatalogEntry) -> Bool {
        let fm = FileManager.default
        let checkPaths = [
            "Contents/Frameworks/Sparkle.framework",
            "Contents/Frameworks/Electron Framework.framework",
            "Contents/Frameworks/Squirrel.framework",
            "Contents/MacOS/ShipIt",
            "Contents/Helpers",
            "Contents/Library/LoginItems"
        ]
        for rel in checkPaths {
            if fm.fileExists(atPath: appURL.appendingPathComponent(rel).path) {
                return true
            }
        }
        if entry.hasLaunchctlOrDaemon {
            return true
        }
        return false
    }

    nonisolated private static func isCatalogCandidateNewer(
        candidateVersion: String,
        installedShort: String,
        installedBuild: String
    ) -> Bool {
        func stripPreAndParseSegments(_ raw: String) -> (nums: [Int], fourthDigits: String) {
            let clean = normalizeDisplayVersion(raw)
                .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? raw
            let rawParts = clean.split(separator: ".")
            let nums: [Int] = rawParts.map { part in
                let digits = part.prefix(while: \.isNumber)
                return Int(digits) ?? 0
            }
            let fourthDigits = rawParts.count >= 4
                ? String(rawParts[3].prefix(while: \.isNumber))
                : ""
            return (nums, fourthDigits)
        }

        let cand = stripPreAndParseSegments(candidateVersion)
        let inst = stripPreAndParseSegments(installedShort)

        if cand.nums.count >= 4 && inst.nums.count <= 3 {
            let candPrefix = (0..<3).map { cand.nums[$0] }
            let instPrefix = (0..<3).map { $0 < inst.nums.count ? inst.nums[$0] : 0 }
            if candPrefix != instPrefix {
                for i in 0..<3 {
                    if candPrefix[i] > instPrefix[i] { return true }
                    if candPrefix[i] < instPrefix[i] { return false }
                }
                return false
            }

            let cleanBuild = installedBuild.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPureDigits(cleanBuild),
               !cand.fourthDigits.isEmpty,
               abs(cand.fourthDigits.count - cleanBuild.count) <= 1,
               let buildVal = Int(cleanBuild) {
                return cand.nums[3] > buildVal
            }
            return false
        }

        return isNewerVersion(candidateVersion, than: installedShort)
    }

    // MARK: - Secure Download, Magic-Byte Detection, Verification & Atomic Replacement

    enum UpdaterInstallOutcome: Sendable {
        case replacedApp(installedVersion: String?, installedBuild: String?)
        case openedInstaller(path: String, label: String)
        case openedBrowser(url: URL)
    }

    enum UpdaterError: LocalizedError {
        case networkFailed(String)
        case extractFailed(String)
        case appNotFoundInArchive
        case bundleIDMismatch(expected: String, actual: String)
        case codeSignInvalid(String)
        case teamIDMismatch
        case architectureMismatch
        case downgradeBlocked
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .networkFailed(let m): return "下载安装包失败：\(m)"
            case .extractFailed(let m): return "解压或挂载安装包失败：\(m)"
            case .appNotFoundInArchive: return "安装包中未找到可用的 .app 本体或安装器"
            case .bundleIDMismatch(let e, let a): return "签名校验拦截：Bundle ID 不匹配 (\(a) != \(e))"
            case .codeSignInvalid(let m): return "代码签名校验未通过：\(m)"
            case .teamIDMismatch: return "开发者 Team ID 与已安装应用不一致，已拒绝覆盖"
            case .architectureMismatch: return "架构不兼容：当前 Apple Silicon 设备不能替换为仅 Intel x86_64 版本"
            case .downgradeBlocked: return "检测到安装包版本低于当前已安装版本，已阻止降级覆盖"
            case .replaceFailed(let m): return "替换目标应用失败（请确认管理员授权）：\(m)"
            }
        }
    }

    nonisolated private static func downloadVerifyAndInstall(
        item: SoftwareUpdateItem,
        downloadURL: URL,
        targetAppURL: URL,
        forceQuitRunning: Bool,
        progressHandler: @escaping @Sendable (Double) async -> Void,
        stageHandler: @escaping @Sendable (SoftwareUpdateExecutionState, String) async -> Void
    ) async -> Result<UpdaterInstallOutcome, UpdaterError> {
        let fm = FileManager.default
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("syspulse-update-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let downloadedFile = workDir.appendingPathComponent("download.tmp")
        await stageHandler(.downloading(progress: 0.05), "正在下载更新包：\(downloadURL.lastPathComponent)")

        let downloadResult: (httpResponse: HTTPURLResponse?, errorMessage: String?) = await downloadFileWithProgress(
            from: downloadURL,
            destinationURL: downloadedFile,
            progressHandler: progressHandler
        )

        if let errMsg = downloadResult.errorMessage {
            return .failure(.networkFailed(errMsg))
        }
        guard let http = downloadResult.httpResponse, (200..<300).contains(http.statusCode) else {
            let code = downloadResult.httpResponse?.statusCode ?? -1
            return .failure(.networkFailed("HTTP \(code)"))
        }

        // 检查是否返回了 HTML 网页而非二进制安装包
        if isHTMLPayload(fileURL: downloadedFile, mimeType: http.mimeType) {
            await MainActor.run {
                _ = NSWorkspace.shared.open(downloadURL)
            }
            return .success(.openedBrowser(url: downloadURL))
        }

        await stageHandler(.verifying, "正在识别封装格式并验证签名…")

        let detectedFormat = detectArchiveFormat(
            fileURL: downloadedFile,
            response: http,
            originalURL: downloadURL
        )
        let preferredName = resolveDownloadFilename(response: http, originalURL: downloadURL, fallbackExt: detectedFormat.fileExtension)
        let namedArchive = workDir.appendingPathComponent(preferredName)
        if namedArchive != downloadedFile {
            try? fm.removeItem(at: namedArchive)
            try? fm.moveItem(at: downloadedFile, to: namedArchive)
        }

        // 若直接是 .pkg 安装包，转入官网安装器暂存目录并唤起安装器
        if detectedFormat == .pkg {
            do {
                let staged = try stageInstallerArtifact(
                    sourceURL: namedArchive,
                    bundleID: item.bundleID ?? item.id,
                    filename: preferredName
                )
                await MainActor.run { _ = NSWorkspace.shared.open(staged) }
                return .success(.openedInstaller(path: staged.path, label: staged.lastPathComponent))
            } catch {
                return .failure(.replaceFailed(error.localizedDescription))
            }
        }

        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        var mountedPoints: [String] = []
        defer {
            for mp in mountedPoints {
                _ = runProcess("/usr/bin/hdiutil", args: ["detach", mp, "-force", "-quiet"], timeoutSeconds: 15)
            }
        }

        let searchRoots: [URL]
        switch detectedFormat {
        case .dmg:
            let attach = runProcess(
                "/usr/bin/hdiutil",
                args: ["attach", namedArchive.path, "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-plist"],
                timeoutSeconds: 60
            )
            guard attach.exitCode == 0,
                  let plistData = attach.stdout.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]] else {
                let detail = attach.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.extractFailed(detail.isEmpty ? "DMG 镜像挂载失败" : detail))
            }
            let mps = entities.compactMap { $0["mount-point"] as? String }.filter { !$0.isEmpty }
            guard !mps.isEmpty else {
                return .failure(.extractFailed("未找到有效的 DMG 挂载卷"))
            }
            mountedPoints = mps
            searchRoots = mps.map { URL(fileURLWithPath: $0, isDirectory: true) }

        case .zip:
            let ditto = runProcess("/usr/bin/ditto", args: ["-xk", namedArchive.path, extractDir.path], timeoutSeconds: 90)
            guard ditto.exitCode == 0 else {
                return .failure(.extractFailed(ditto.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            searchRoots = [extractDir]

        case .tarGz, .tarBz2:
            let tar = runProcess("/usr/bin/tar", args: ["-xf", namedArchive.path, "-C", extractDir.path], timeoutSeconds: 90)
            guard tar.exitCode == 0 else {
                return .failure(.extractFailed(tar.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            searchRoots = [extractDir]

        case .pkg:
            searchRoots = []
        }

        let scanArtifacts = discoverBundleAndPkgCandidates(in: searchRoots)

        // 情形 1：Cask 指定了独立官网安装器 (如 QuarkCloudDrive mini-installer)
        if let vendorInstallerName = item.vendorInstallerAppName {
            let matchingInstaller = scanArtifacts.apps.first(where: {
                $0.lastPathComponent.lowercased() == vendorInstallerName.lowercased()
            }) ?? scanArtifacts.apps.first
            if let installerApp = matchingInstaller {
                do {
                    if forceQuitRunning, let bid = item.bundleID {
                        await terminateRunningApp(bundleID: bid)
                    }
                    let staged = try stageInstallerArtifact(
                        sourceURL: installerApp,
                        bundleID: item.bundleID ?? item.id,
                        filename: installerApp.lastPathComponent
                    )
                    await MainActor.run {
                        let cfg = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.openApplication(at: staged, configuration: cfg) { _, _ in }
                    }
                    return .success(.openedInstaller(path: staged.path, label: staged.lastPathComponent))
                } catch {
                    return .failure(.replaceFailed(error.localizedDescription))
                }
            }
        }

        // 情形 2：包内仅包含 .pkg 而无匹配的目标 .app 本体
        let matchedTargetApp = selectReplacementApp(
            from: scanArtifacts.apps,
            expectedBundleID: item.bundleID,
            targetFileName: targetAppURL.lastPathComponent
        )

        if matchedTargetApp == nil, let pkgURL = scanArtifacts.pkgs.first {
            do {
                let staged = try stageInstallerArtifact(
                    sourceURL: pkgURL,
                    bundleID: item.bundleID ?? item.id,
                    filename: pkgURL.lastPathComponent
                )
                await MainActor.run { _ = NSWorkspace.shared.open(staged) }
                return .success(.openedInstaller(path: staged.path, label: staged.lastPathComponent))
            } catch {
                return .failure(.replaceFailed(error.localizedDescription))
            }
        }

        guard let newAppURL = matchedTargetApp else {
            return .failure(.appNotFoundInArchive)
        }

        // 检查是否实际上是一个不同 BundleID 的独立安装器/引导程序 (如 xxx.macinstaller / Installer.app)
        let newFreshInfo = FreshBundleInfo.read(at: newAppURL, requireBundleID: false)
        let newBID = (newFreshInfo?.bundleID.isEmpty == false) ? newFreshInfo?.bundleID : nil
        if let expectedBID = item.bundleID, let newBID,
           newBID.lowercased() != expectedBID.lowercased() {
            let lowerNewBID = newBID.lowercased()
            let lowerNewName = newAppURL.lastPathComponent.lowercased()
            if lowerNewBID.contains("installer") || lowerNewBID.contains("setup") || lowerNewName.contains("install") {
                do {
                    let staged = try stageInstallerArtifact(
                        sourceURL: newAppURL,
                        bundleID: expectedBID,
                        filename: newAppURL.lastPathComponent
                    )
                    await MainActor.run {
                        let cfg = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.openApplication(at: staged, configuration: cfg) { _, _ in }
                    }
                    return .success(.openedInstaller(path: staged.path, label: staged.lastPathComponent))
                } catch {
                    return .failure(.replaceFailed(error.localizedDescription))
                }
            }
            return .failure(.bundleIDMismatch(expected: expectedBID, actual: newBID))
        }

        // 安全检查 1：严格校验签名（不使用 --deep，与系统及官方行为一致）
        let verifyStrict = runProcess("/usr/bin/codesign", args: ["--verify", "--strict", newAppURL.path], timeoutSeconds: 30)
        if verifyStrict.exitCode != 0 {
            let detail = verifyStrict.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.codeSignInvalid(detail.isEmpty ? "签名完整性校验未通过" : detail))
        }

        // 安全检查 2：Developer ID Team ID 连续性核验
        let oldTeam = extractTeamIdentifier(at: targetAppURL)
        let newTeam = extractTeamIdentifier(at: newAppURL)
        if let oldTeam {
            let verifyAnchor = runProcess("/usr/bin/codesign", args: ["--verify", "-R=anchor apple generic", newAppURL.path], timeoutSeconds: 20)
            if verifyAnchor.exitCode != 0 {
                return .failure(.codeSignInvalid("新版应用未能满足 Apple 官方受信任锚点校验"))
            }
            if newTeam != oldTeam {
                return .failure(.teamIDMismatch)
            }
        }

        // 安全检查 3：Apple Silicon 架构连续性校验
        #if arch(arm64)
        if !isArchitectureCompatibleArm64(oldAppURL: targetAppURL, newAppURL: newAppURL) {
            return .failure(.architectureMismatch)
        }
        #endif

        // 安全检查 4：防降级检查
        let newShort = newFreshInfo?.shortVersion
            .map(normalizeDisplayVersion)
        if let newShort, isNewerVersion(item.currentVersion, than: newShort) {
            return .failure(.downgradeBlocked)
        }

        // 平滑结束目标进程，防止文件锁占用
        if forceQuitRunning, let bid = item.bundleID {
            await terminateRunningApp(bundleID: bid)
        }

        // 原子替换 (/Applications/.App.installing.UUID -> 备份旧应用至废纸篓 -> 原子改名；权限/TCC 受阻时提权)
        await stageHandler(.installing, "正在原子替换应用本体：\(targetAppURL.lastPathComponent)")
        let replaceResult = performAtomicAppReplacement(sourceNewApp: newAppURL, targetApp: targetAppURL)
        switch replaceResult {
        case .success:
            let freshAfter = readNormalizedLocalVersion(at: targetAppURL, bundleID: item.bundleID)
            return .success(.replacedApp(
                installedVersion: freshAfter?.shortVersion ?? newShort,
                installedBuild: freshAfter?.buildVersion ?? newFreshInfo?.buildVersion
            ))
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - Download Delegate & Format Detection

    private enum DetectedArchiveFormat {
        case dmg, zip, pkg, tarGz, tarBz2

        nonisolated var fileExtension: String {
            switch self {
            case .dmg: return "dmg"
            case .zip: return "zip"
            case .pkg: return "pkg"
            case .tarGz: return "tar.gz"
            case .tarBz2: return "tbz"
            }
        }
    }

    private final class DownloadProgressSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destinationURL: URL
        private let progressCallback: @Sendable (Double) -> Void
        private let completion: @Sendable (HTTPURLResponse?, String?) -> Void
        private var lastReportedTime: CFAbsoluteTime = 0
        private var capturedHTTPResponse: HTTPURLResponse?
        private var didFinish = false
        private let lock = NSLock()

        init(
            destinationURL: URL,
            progressCallback: @escaping @Sendable (Double) -> Void,
            completion: @escaping @Sendable (HTTPURLResponse?, String?) -> Void
        ) {
            self.destinationURL = destinationURL
            self.progressCallback = progressCallback
            self.completion = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            let shouldReport = (now - lastReportedTime) >= 0.15
            if shouldReport { lastReportedTime = now }
            lock.unlock()
            if shouldReport {
                let frac = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.0), 1.0)
                progressCallback(0.05 + frac * 0.65)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let http = downloadTask.response as? HTTPURLResponse
            let fm = FileManager.default
            var moveError: String? = nil
            do {
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.moveItem(at: location, to: destinationURL)
            } catch {
                moveError = error.localizedDescription
            }

            lock.lock()
            capturedHTTPResponse = http
            let alreadyDone = didFinish
            if moveError != nil || http != nil {
                didFinish = true
            }
            lock.unlock()

            if !alreadyDone && (moveError != nil || http != nil) {
                completion(http, moveError)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let alreadyDone = didFinish
            if !alreadyDone { didFinish = true }
            let http = (task.response as? HTTPURLResponse) ?? capturedHTTPResponse
            lock.unlock()
            if !alreadyDone {
                completion(http, error?.localizedDescription)
            }
        }
    }

    nonisolated private static func downloadFileWithProgress(
        from url: URL,
        destinationURL: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async -> (httpResponse: HTTPURLResponse?, errorMessage: String?) {
        await withCheckedContinuation { continuation in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            let delegate = DownloadProgressSessionDelegate(
                destinationURL: destinationURL,
                progressCallback: { progress in
                    Task { await progressHandler(progress) }
                },
                completion: { response, errorMsg in
                    continuation.resume(returning: (response, errorMsg))
                }
            )
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    nonisolated private static func isHTMLPayload(fileURL: URL, mimeType: String?) -> Bool {
        if let mime = mimeType?.lowercased(),
           mime.contains("text/html") || mime.contains("application/xhtml+xml") {
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        let headData = (try? handle.read(upToCount: 512)) ?? Data()
        guard let headText = String(data: headData, encoding: .utf8) else { return false }
        return headText.range(of: "(?i)<(?:!doctype\\s+html|html(?:\\s|>)|head(?:\\s|>)|body(?:\\s|>))", options: .regularExpression) != nil
    }

    nonisolated private static func detectArchiveFormat(fileURL: URL, response: HTTPURLResponse, originalURL: URL) -> DetectedArchiveFormat {
        // 1. 先查真实魔数
        if let handle = try? FileHandle(forReadingFrom: fileURL) {
            let magic = [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
            try? handle.close()
            if magic.count >= 4 {
                if magic[0] == 0x50 && magic[1] == 0x4B && magic[2] == 0x03 && magic[3] == 0x04 {
                    return .zip
                }
                if magic[0] == 0x78 && magic[1] == 0x61 && magic[2] == 0x72 && magic[3] == 0x21 {
                    return .pkg
                }
                if magic[0] == 0x1F && magic[1] == 0x8B {
                    return .tarGz
                }
                if magic[0] == 0x42 && magic[1] == 0x5A && magic[2] == 0x68 {
                    return .tarBz2
                }
            }
        }

        // 2. 再查响应文件名与 URL 后缀
        let names = [
            response.suggestedFilename ?? "",
            response.url?.lastPathComponent ?? "",
            originalURL.lastPathComponent
        ]
        for rawName in names {
            let lower = rawName.lowercased()
            if lower.hasSuffix(".dmg") { return .dmg }
            if lower.hasSuffix(".pkg") || lower.hasSuffix(".mpkg") { return .pkg }
            if lower.hasSuffix(".zip") { return .zip }
            if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGz }
            if lower.hasSuffix(".tbz") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tar.bz2") { return .tarBz2 }
        }

        // 3. 用 hdiutil imageinfo 探测是否为无后缀 DMG（常见于重定向 CDN）
        let imgInfo = runProcess("/usr/bin/hdiutil", args: ["imageinfo", fileURL.path], timeoutSeconds: 10)
        if imgInfo.exitCode == 0 {
            return .dmg
        }
        return .zip
    }

    nonisolated private static func resolveDownloadFilename(response: HTTPURLResponse, originalURL: URL, fallbackExt: String) -> String {
        let candidates = [
            response.suggestedFilename,
            response.url?.lastPathComponent,
            originalURL.lastPathComponent
        ]
        for cand in candidates {
            if let name = cand?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty,
               name != "/" {
                let sanitized = name.replacingOccurrences(of: "/", with: "_")
                if sanitized.lowercased().hasSuffix(".\(fallbackExt)") {
                    return sanitized
                }
                return "\(sanitized).\(fallbackExt)"
            }
        }
        return "update.\(fallbackExt)"
    }

    nonisolated private static func stageInstallerArtifact(sourceURL: URL, bundleID: String, filename: String) throws -> URL {
        let fm = FileManager.default
        let sanitizedBID = bundleID.replacingOccurrences(of: "/", with: "_")
        let baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SysPulse/WebsiteInstallers/\(sanitizedBID)", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let dest = baseDir.appendingPathComponent(filename)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        let cp = runProcess("/usr/bin/ditto", args: [sourceURL.path, dest.path], timeoutSeconds: 60)
        if cp.exitCode != 0 {
            try fm.copyItem(at: sourceURL, to: dest)
        }
        _ = runProcess("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", dest.path], timeoutSeconds: 10)
        return dest
    }

    // MARK: - Search & Verify Helpers

    nonisolated private static func discoverBundleAndPkgCandidates(in roots: [URL]) -> (apps: [URL], pkgs: [URL]) {
        let fm = FileManager.default
        var apps: [URL] = []
        var pkgs: [URL] = []

        func walk(_ dir: URL, depth: Int) {
            guard depth <= 3 else { return }
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for entry in items {
                let name = entry.lastPathComponent
                if name == "__MACOSX" || name.hasPrefix(".") { continue }
                let ext = entry.pathExtension.lowercased()
                if ext == "app" {
                    apps.append(entry)
                } else if ext == "pkg" || ext == "mpkg" {
                    pkgs.append(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk(entry, depth: depth + 1)
                }
            }
        }

        for r in roots {
            walk(r, depth: 0)
        }
        return (apps, pkgs)
    }

    nonisolated private static func selectReplacementApp(
        from candidates: [URL],
        expectedBundleID: String?,
        targetFileName: String
    ) -> URL? {
        if let expectedBundleID {
            let lowerExpected = expectedBundleID.lowercased()
            if let bidMatch = candidates.first(where: {
                FreshBundleInfo.read(at: $0)?.bundleID.lowercased() == lowerExpected
            }) {
                return bidMatch
            }
        }
        return candidates.first(where: { $0.lastPathComponent.lowercased() == targetFileName.lowercased() })
            ?? candidates.first
    }

    nonisolated private static func extractTeamIdentifier(at appURL: URL) -> String? {
        let res = runProcess("/usr/bin/codesign", args: ["-dv", "--verbose=4", appURL.path], timeoutSeconds: 15)
        let combined = res.stderr + "\n" + res.stdout
        for line in combined.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                let team = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return team == "not set" || team.isEmpty ? nil : team
            }
        }
        return nil
    }

    nonisolated private static func isArchitectureCompatibleArm64(oldAppURL: URL, newAppURL: URL) -> Bool {
        func archs(for appURL: URL) -> Set<String> {
            guard let execURL = FreshBundleInfo.read(at: appURL, requireBundleID: false)?.executableURL else { return [] }
            let res = runProcess("/usr/bin/lipo", args: ["-archs", execURL.path], timeoutSeconds: 10)
            guard res.exitCode == 0 else { return [] }
            return Set(res.stdout.split(whereSeparator: { $0.isWhitespace }).map { String($0).lowercased() })
        }
        let oldArchs = archs(for: oldAppURL)
        let newArchs = archs(for: newAppURL)
        if oldArchs.contains("arm64") && !newArchs.isEmpty && !newArchs.contains("arm64") {
            return false
        }
        return true
    }

    nonisolated private static func terminateRunningApp(bundleID: String) async {
        await MainActor.run {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated {
                app.terminate()
            }
        }
        for _ in 0..<25 {
            let stillRunning = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
            }
            if !stillRunning { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await MainActor.run {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated {
                app.forceTerminate()
            }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: - Atomic Bundle Replacement (User-Level -> Privileged Fallback)

    nonisolated private static func performAtomicAppReplacement(sourceNewApp: URL, targetApp: URL) -> Result<Void, UpdaterError> {
        let fm = FileManager.default
        let appName = targetApp.lastPathComponent
        let parentDir = targetApp.deletingLastPathComponent()
        let uuid = UUID().uuidString

        let tempStageDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("syspulse-atomic-\(uuid)", isDirectory: true)
        try? fm.createDirectory(at: tempStageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempStageDir) }

        let localSourceCopy = tempStageDir.appendingPathComponent(appName)
        let stageRes = runProcess("/usr/bin/ditto", args: [sourceNewApp.path, localSourceCopy.path], timeoutSeconds: 60)
        guard stageRes.exitCode == 0 else {
            return .failure(.replaceFailed("暂存新版安装包失败"))
        }
        _ = runProcess("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", localSourceCopy.path], timeoutSeconds: 10)
        _ = runProcess("/usr/bin/chflags", args: ["-R", "nouchg", localSourceCopy.path], timeoutSeconds: 10)

        let dirInstallStage = parentDir.appendingPathComponent(".\(appName).installing.\(uuid)")
        let dirBackupStage = parentDir.appendingPathComponent(".\(appName).backup.\(uuid)")

        // 先尝试同目录用户态原子替换
        let userCopy = runProcess("/usr/bin/ditto", args: [localSourceCopy.path, dirInstallStage.path], timeoutSeconds: 60)
        if userCopy.exitCode == 0 {
            do {
                if fm.fileExists(atPath: targetApp.path) {
                    try fm.moveItem(at: targetApp, to: dirBackupStage)
                }
                try fm.moveItem(at: dirInstallStage, to: targetApp)
                _ = runProcess("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", targetApp.path], timeoutSeconds: 10)
                if fm.fileExists(atPath: dirBackupStage.path) {
                    var trashedURL: NSURL? = nil
                    if (try? fm.trashItem(at: dirBackupStage, resultingItemURL: &trashedURL)) == nil {
                        try? fm.removeItem(at: dirBackupStage)
                    }
                }
                _ = runProcess(
                    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    args: ["-f", targetApp.path],
                    timeoutSeconds: 10
                )
                return .success(())
            } catch {
                // 回滚部分状态后转特权原子替换（绕过 /Applications root 或 TCC 保护限制）
                if !fm.fileExists(atPath: targetApp.path) && fm.fileExists(atPath: dirBackupStage.path) {
                    try? fm.moveItem(at: dirBackupStage, to: targetApp)
                }
                try? fm.removeItem(at: dirInstallStage)
            }
        } else {
            try? fm.removeItem(at: dirInstallStage)
        }

        // 特权脚本原子替换
        func shSingleQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let userTrashPath = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let scriptFile = tempStageDir.appendingPathComponent("replace.sh")
        let bashContent = """
        #!/bin/bash
        set -euo pipefail
        SOURCE_APP=\(shSingleQuote(localSourceCopy.path))
        TARGET_APP=\(shSingleQuote(targetApp.path))
        INSTALL_STAGE=\(shSingleQuote(dirInstallStage.path))
        BACKUP_STAGE=\(shSingleQuote(dirBackupStage.path))
        USER_TRASH=\(shSingleQuote(userTrashPath))
        APP_NAME=\(shSingleQuote(appName))

        /bin/rm -rf "$INSTALL_STAGE" "$BACKUP_STAGE" 2>/dev/null || true
        /usr/bin/chflags -R nouchg "$TARGET_APP" 2>/dev/null || true
        /usr/bin/ditto "$SOURCE_APP" "$INSTALL_STAGE"
        /usr/bin/xattr -dr com.apple.quarantine "$INSTALL_STAGE" 2>/dev/null || true
        if [[ -e "$TARGET_APP" ]]; then
          /bin/mv "$TARGET_APP" "$BACKUP_STAGE"
        fi
        if ! /bin/mv "$INSTALL_STAGE" "$TARGET_APP"; then
          [[ -e "$BACKUP_STAGE" && ! -e "$TARGET_APP" ]] && /bin/mv "$BACKUP_STAGE" "$TARGET_APP" || true
          /bin/rm -rf "$INSTALL_STAGE" 2>/dev/null || true
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
        if [[ -e "$BACKUP_STAGE" ]]; then
          TRASH_DEST="$USER_TRASH/$APP_NAME"
          if [[ -e "$TRASH_DEST" ]]; then
            TRASH_DEST="$USER_TRASH/${APP_NAME}.$(/bin/date +%Y%m%d%H%M%S)"
          fi
          /bin/mv "$BACKUP_STAGE" "$TRASH_DEST" 2>/dev/null || /bin/rm -rf "$BACKUP_STAGE" 2>/dev/null || true
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" 2>/dev/null || true
        """

        do {
            try bashContent.write(to: scriptFile, atomically: true, encoding: .utf8)
            _ = runProcess("/bin/chmod", args: ["700", scriptFile.path], timeoutSeconds: 5)
        } catch {
            return .failure(.replaceFailed(error.localizedDescription))
        }

        let adminRes = runAppleScriptPrivileged("/bin/bash \(shSingleQuote(scriptFile.path))")
        if adminRes.succeeded {
            return .success(())
        }
        return .failure(.replaceFailed(adminRes.errorMessage ?? "未获取管理员权限"))
    }

    // MARK: - Network, Version Comparison & OS Compatibility Helpers

    nonisolated private static func fetchData(url: URL, timeout: TimeInterval) async -> Data? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    nonisolated private static func normalizeDisplayVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            let after = s.dropFirst()
            if after.first?.isNumber == true {
                s = String(after)
            }
        }
        if let plusIdx = s.firstIndex(of: "+") {
            s = String(s[..<plusIdx])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func isPureDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isNumber)
    }

    nonisolated private static func containsPrereleaseTag(_ version: String) -> Bool {
        let lower = version.lowercased()
        if lower.range(
            of: "(?:^|[._-])(alpha|beta|canary|candidate|dev|nightly|preview|pre|rc|snapshot|testflight)(?:[0-9._-]|$)",
            options: .regularExpression
        ) != nil {
            return true
        }
        if lower.range(of: "\\b\\d+(?:\\.\\d+)+[ab]\\d+\\b", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    nonisolated private static func compareVersionComponents(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func numericParts(_ s: String) -> [Int] {
            let clean = normalizeDisplayVersion(s)
                .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? s
            return clean.split(separator: ".").map { part in
                let digits = part.prefix(while: \.isNumber)
                return Int(digits) ?? 0
            }
        }
        let a = numericParts(lhs)
        let b = numericParts(rhs)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va > vb { return .orderedDescending }
            if va < vb { return .orderedAscending }
        }
        return .orderedSame
    }

    nonisolated private static func isNewerVersion(_ candidate: String, than installed: String) -> Bool {
        compareVersionComponents(candidate, installed) == .orderedDescending
    }

    nonisolated private static func isOSCompatible(_ minVersion: String?) -> Bool {
        guard let minVersion, !minVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return !isNewerVersion(minVersion, than: currentStr)
    }

    nonisolated private static func isMaxOSCompatible(_ maxVersion: String?) -> Bool {
        guard let maxVersion, !maxVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return !isNewerVersion(currentStr, than: maxVersion)
    }

    nonisolated private static func isHardwareRequirementsCompatible(_ req: String?) -> Bool {
        guard let req = req?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !req.isEmpty else {
            return true
        }
        #if arch(arm64)
        return req.contains("arm64") || req.contains("aarch64") || req.contains("apple")
        #else
        return req.contains("x86_64") || req.contains("x64") || req.contains("intel")
        #endif
    }

    nonisolated private static func cleanHTMLText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func parseSimpleYAMLKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("-") { continue }
            guard let idx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            var val = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty && !val.isEmpty {
                result[key] = val
            }
        }
        return result
    }

    nonisolated private static func parseElectronYAMLFiles(_ text: String) -> [String] {
        var urls: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- url:") || trimmed.hasPrefix("url:") {
                let raw = trimmed
                    .replacingOccurrences(of: "- url:", with: "")
                    .replacingOccurrences(of: "url:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !raw.isEmpty { urls.append(raw) }
            }
        }
        return urls
    }

    nonisolated private static func selectBestElectronAssetName(paths: [String]) -> String? {
        let isArm = ProcessInfo.processInfo.machineArchitectureTag == "Apple Silicon"
        let macFiles = paths.filter {
            let lower = $0.lowercased()
            return lower.hasSuffix(".zip") || lower.hasSuffix(".dmg")
        }
        if isArm, let armZip = macFiles.first(where: { $0.lowercased().contains("arm64") && $0.lowercased().hasSuffix(".zip") }) {
            return armZip
        }
        if isArm, let armDmg = macFiles.first(where: { $0.lowercased().contains("arm64") && $0.lowercased().hasSuffix(".dmg") }) {
            return armDmg
        }
        return macFiles.first(where: { $0.lowercased().hasSuffix(".zip") }) ?? macFiles.first
    }

    nonisolated private static func selectBestMacAsset(assets: [[String: Any]]) -> [String: Any]? {
        let isArm = ProcessInfo.processInfo.machineArchitectureTag == "Apple Silicon"
        let macAssets = assets.filter {
            let name = ($0["name"] as? String ?? "").lowercased()
            return (name.hasSuffix(".dmg") || name.hasSuffix(".zip")) && !name.contains("windows") && !name.contains("linux")
        }
        if isArm {
            if let hit = macAssets.first(where: {
                let n = ($0["name"] as? String ?? "").lowercased()
                return n.contains("arm64") || n.contains("aarch64") || n.contains("universal")
            }) {
                return hit
            }
        }
        return macAssets.first(where: { ($0["name"] as? String ?? "").lowercased().contains("mac") || ($0["name"] as? String ?? "").lowercased().contains("darwin") })
            ?? macAssets.first
    }

    nonisolated private static func runProcess(
        _ launchPath: String,
        args: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval = 45
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in environment {
                merged[k] = v
            }
            proc.environment = merged
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let sema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sema.signal() }

        let waitResult = sema.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            proc.terminate()
            _ = sema.wait(timeout: .now() + 2)
            return (-1, "", "进程执行超时 (\(Int(timeoutSeconds))s)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            proc.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 升级包含 .pkg 安装包的 Homebrew Cask（如 Outlook / OneDrive 等）时自动提供临时 SUDO_ASKPASS 图形密码框，无需跳转终端
    nonisolated private static func runBrewCaskUpgradeWithAskpassIfNeeded(
        brewBin: String,
        token: String,
        appName: String
    ) -> (exitCode: Int32, stdout: String, stderr: String, userCancelledAuth: Bool) {
        let args = ["upgrade", "--cask", token]

        func caskLikelyUsesPkgInstaller() -> Bool {
            let infoRes = runProcess(brewBin, args: ["info", "--cask", "--json=v2", token], timeoutSeconds: 12)
            guard infoRes.exitCode == 0,
                  let data = infoRes.stdout.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let casks = root["casks"] as? [[String: Any]],
                  let first = casks.first,
                  let artifacts = first["artifacts"] as? [[String: Any]] else {
                return false
            }
            return artifacts.contains { $0["pkg"] != nil || $0["installer"] != nil }
        }

        func runWithAskpass() -> (exitCode: Int32, stdout: String, stderr: String, userCancelledAuth: Bool) {
            let fm = FileManager.default
            let cancelMarker = "SYSPULSE_ASKPASS_CANCELLED_\(UUID().uuidString)"
            let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("syspulse-askpass-\(UUID().uuidString).sh")
            let safeName = appName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let promptText = "SysPulse 需要管理员密码以完成「\(safeName)」(.pkg 安装包) 更新："
            let scriptContent = """
            #!/bin/bash
            PW=$(/usr/bin/osascript 2>/dev/null <<'EOF'
            try
              set resp to display dialog "\(promptText)" default answer "" with title "SysPulse 软件更新" with icon caution with hidden answer buttons {"取消", "好"} default button "好"
              return text returned of resp
            on error number -128
              return "\(cancelMarker)"
            end try
            EOF
            )
            if [[ "$PW" == "\(cancelMarker)" ]] || [[ -z "$PW" ]]; then
              exit 1
            fi
            printf '%s\\n' "$PW"
            """
            do {
                try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            } catch {
                return (-1, "", "创建临时密码授权脚本失败：\(error.localizedDescription)", false)
            }
            defer { try? fm.removeItem(at: scriptURL) }

            let env = [
                "SUDO_ASKPASS": scriptURL.path,
                "HOMEBREW_NO_AUTO_UPDATE": "1"
            ]
            let res = runProcess(brewBin, args: args, environment: env, timeoutSeconds: 240)
            let errLower = res.stderr.lowercased()
            let cancelled = res.exitCode != 0 && (
                errLower.contains("no password was provided")
                || errLower.contains("password is required")
                || errLower.contains("incorrect password attempts")
                || errLower.contains("1 incorrect password attempt")
            )
            return (res.exitCode, res.stdout, res.stderr, cancelled)
        }

        if caskLikelyUsesPkgInstaller() {
            return runWithAskpass()
        }

        let initial = runProcess(brewBin, args: args, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], timeoutSeconds: 180)
        if initial.exitCode == 0 {
            return (0, initial.stdout, initial.stderr, false)
        }
        let errLower = initial.stderr.lowercased()
        if errLower.contains("askpass")
            || errLower.contains("a terminal is required")
            || errLower.contains("sudo:")
            || errLower.contains("password is required") {
            return runWithAskpass()
        }
        return (initial.exitCode, initial.stdout, initial.stderr, false)
    }

    nonisolated private static func runAppleScriptPrivileged(_ shellCommand: String) -> (succeeded: Bool, errorMessage: String?) {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let res = runProcess("/usr/bin/osascript", args: ["-e", script], timeoutSeconds: 180)
        return (res.exitCode == 0, res.stderr.isEmpty ? nil : res.stderr)
    }
}

private extension ProcessInfo {
    nonisolated var machineArchitectureTag: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel x64"
        #endif
    }
}

// MARK: - Sparkle XML Appcast 解析器

private final class SparkleFeedXMLParser: NSObject, XMLParserDelegate {
    struct Entry {
        var title: String = ""
        var shortVersion: String?
        var buildVersion: String?
        var channel: String?
        var minimumSystemVersion: String?
        var maximumSystemVersion: String?
        var hardwareRequirements: String?
        var releaseNotesLink: String?
        var descriptionHTML: String = ""
        var enclosureURL: URL?
        var lengthBytes: Int64?
    }

    private let data: Data
    private var entries: [Entry] = []
    private var currentEntry: Entry? = nil
    private var currentText: String = ""
    private var deltasDepth: Int = 0

    init(data: Data) {
        self.data = data
    }

    func parse() -> [Entry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).lowercased()
        currentText = ""

        if name == "item" {
            currentEntry = Entry()
            deltasDepth = 0
        } else if name == "sparkle:deltas" || name == "deltas" {
            deltasDepth += 1
        } else if name == "enclosure", deltasDepth == 0, var item = currentEntry {
            // 跳过非 macOS 安装包（如 windows / ios）以及 delta 补丁包
            let osAttr = attributeDict["sparkle:os"]?.lowercased()
            guard osAttr == nil || osAttr == "macos" || osAttr == "osx" else { return }
            if attributeDict["sparkle:deltaFrom"] != nil { return }

            if let urlStr = attributeDict["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !urlStr.isEmpty,
               !urlStr.lowercased().hasSuffix(".delta"),
               let url = URL(string: urlStr) {
                if shouldPreferEnclosure(newURL: url, existingURL: item.enclosureURL) {
                    item.enclosureURL = url
                    if let lenStr = attributeDict["length"], let len = Int64(lenStr) {
                        item.lengthBytes = len
                    }
                }
            }
            if let sv = attributeDict["sparkle:shortVersionString"]?.trimmingCharacters(in: .whitespacesAndNewlines), !sv.isEmpty {
                item.shortVersion = sv
            }
            if let bv = attributeDict["sparkle:version"]?.trimmingCharacters(in: .whitespacesAndNewlines), !bv.isEmpty {
                item.buildVersion = bv
            }
            currentEntry = item
        }
    }

    private func shouldPreferEnclosure(newURL: URL, existingURL: URL?) -> Bool {
        guard let existingURL else { return true }
        let newLower = newURL.absoluteString.lowercased()
        let oldLower = existingURL.absoluteString.lowercased()
        #if arch(arm64)
        let newIsArm = newLower.contains("arm64") || newLower.contains("aarch64") || newLower.contains("apple")
        let oldIsArm = oldLower.contains("arm64") || oldLower.contains("aarch64") || oldLower.contains("apple")
        if newIsArm && !oldIsArm { return true }
        #endif
        return false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "sparkle:deltas" || name == "deltas" {
            deltasDepth = max(0, deltasDepth - 1)
        } else if name == "item" {
            if let entry = currentEntry {
                entries.append(entry)
            }
            currentEntry = nil
            deltasDepth = 0
        } else if deltasDepth == 0, var entry = currentEntry {
            switch name {
            case "title":
                if entry.title.isEmpty { entry.title = trimmed }
            case "description", "sparkle:markdowndescription", "markdowndescription":
                if !trimmed.isEmpty { entry.descriptionHTML = trimmed }
            case "sparkle:shortversionstring", "shortversionstring":
                if !trimmed.isEmpty { entry.shortVersion = trimmed }
            case "sparkle:version", "version":
                if !trimmed.isEmpty && (entry.buildVersion == nil || entry.buildVersion?.isEmpty == true) {
                    entry.buildVersion = trimmed
                }
            case "sparkle:channel", "channel":
                if !trimmed.isEmpty { entry.channel = trimmed }
            case "sparkle:minimumsystemversion", "minimumsystemversion":
                if !trimmed.isEmpty { entry.minimumSystemVersion = trimmed }
            case "sparkle:maximumsystemversion", "maximumsystemversion":
                if !trimmed.isEmpty { entry.maximumSystemVersion = trimmed }
            case "sparkle:hardwarerequirements", "hardwarerequirements":
                if !trimmed.isEmpty { entry.hardwareRequirements = trimmed }
            case "sparkle:releasenoteslink", "releasenoteslink":
                if entry.releaseNotesLink == nil && !trimmed.isEmpty { entry.releaseNotesLink = trimmed }
            default:
                break
            }
            currentEntry = entry
        }
        currentText = ""
    }
}
