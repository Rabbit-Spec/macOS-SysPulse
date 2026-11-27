import Foundation
import AppKit
import Observation
import Darwin

// MARK: - 废纸篓卸载残留实时监控

@Observable
@MainActor
public final class TrashRemnantWatcher {
    public static let shared = TrashRemnantWatcher()

    public var detectedApp: InstalledAppInfo? = nil
    public var selectedComponentIDs: Set<UUID> = []
    public var isExpanded: Bool = false
    public var isCleaning: Bool = false
    public var statusMessage: String? = nil

    private let ignoredStorageKey = "SP_IgnoredTrashRemnantBundleIDs"
    private var ignoredBundleIDs: Set<String>
    private var selfTrashedBundleNames: [String: Date] = [:]
    private var selfTrashedBundleIDs: [String: Date] = [:]
    private var knownTrashAppNames: Set<String> = []

    private var trashMonitorSource: DispatchSourceFileSystemObject?
    private var trashFileDescriptor: Int32 = -1
    private var debounceTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: ignoredStorageKey) ?? []
        self.ignoredBundleIDs = Set(saved.map { $0.lowercased() })
    }

    public func startMonitoringIfEnabled() {
        guard FeatureToggleManager.shared.enableTrashRemnantWatch else { return }
        startMonitoring()
    }

    public func syncWithFeatureToggle() {
        if FeatureToggleManager.shared.enableTrashRemnantWatch {
            startMonitoring()
        } else {
            stopMonitoring()
            dismiss()
        }
    }

    public func recordSelfTrashedApp(bundleName: String, bundleID: String) {
        let now = Date()
        if !bundleName.isEmpty {
            selfTrashedBundleNames[bundleName] = now
        }
        if !bundleID.isEmpty {
            selfTrashedBundleIDs[bundleID.lowercased()] = now
        }
    }

    public func startMonitoring() {
        guard trashMonitorSource == nil else { return }
        let fm = FileManager.default
        let trashURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        guard fm.fileExists(atPath: trashURL.path) else { return }

        knownTrashAppNames = Self.currentTrashAppNames(in: trashURL, fm: fm)

        let fd = Darwin.open(trashURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        trashFileDescriptor = fd

        let queue = DispatchQueue(label: "com.rabbit.syspulse.trashwatcher", qos: .utility)
        let source = Self.makeDirectoryMonitorSource(fd: fd, queue: queue) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleScan()
            }
        }
        trashMonitorSource = source
        source.resume()
    }

    /// 必须在 nonisolated 上下文创建 DispatchSource 回调，避免 Swift 6 为后台队列注入 @MainActor 队列断言而触发 SIGTRAP
    nonisolated private static func makeDirectoryMonitorSource(
        fd: Int32,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void
    ) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: queue
        )
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler {
            Darwin.close(fd)
        }
        return source
    }

    public func stopMonitoring() {
        debounceTask?.cancel()
        debounceTask = nil
        trashMonitorSource?.cancel()
        trashMonitorSource = nil
        trashFileDescriptor = -1
    }

    /// 自检 VNODE 后台队列事件派发，确保不会因 Swift 6 @MainActor 隔离断言在安装/更新软件时崩溃
    public func runSelfTestProbe() -> Bool {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sp_trashwatcher_probe_\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(at: tempDir) }

        let fd = Darwin.open(tempDir.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        final class ProbeState: @unchecked Sendable {
            private let lock = NSLock()
            private var _fired = false
            var fired: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _fired
            }
            func markFired() {
                lock.lock()
                _fired = true
                lock.unlock()
            }
        }

        let probeState = ProbeState()
        let queue = DispatchQueue(label: "com.rabbit.syspulse.trashwatcher.probe", qos: .utility)
        let source = Self.makeDirectoryMonitorSource(fd: fd, queue: queue) {
            Task { @MainActor in
                probeState.markFired()
            }
        }
        source.resume()

        let markerFile = tempDir.appendingPathComponent("probe.tmp")
        try? Data([0x01]).write(to: markerFile)

        for _ in 0..<25 {
            if probeState.fired { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let ok = probeState.fired
        source.cancel()
        return ok
    }

    private func scheduleScan() {
        guard FeatureToggleManager.shared.enableTrashRemnantWatch else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self, FeatureToggleManager.shared.enableTrashRemnantWatch else { return }
            await self.performTrashDiffScan()
        }
    }

    private func performTrashDiffScan() async {
        let cutoff = Date().addingTimeInterval(-300)
        selfTrashedBundleNames = selfTrashedBundleNames.filter { $0.value > cutoff }
        selfTrashedBundleIDs = selfTrashedBundleIDs.filter { $0.value > cutoff }

        let knownSnapshot = knownTrashAppNames
        let ignoredSnapshot = ignoredBundleIDs
        let selfNamesSnapshot = Set(selfTrashedBundleNames.keys)
        let selfIDsSnapshot = Set(selfTrashedBundleIDs.keys)
        let currentlyPresentedPath = detectedApp?.bundleURL.path

        let result: (currentNames: Set<String>, match: InstalledAppInfo?) = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let trashURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: [.addedToDirectoryDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return (knownSnapshot, nil)
            }

            let appItems = items.filter { $0.pathExtension.lowercased() == "app" }
            let currentNames = Set(appItems.map(\.lastPathComponent))

            let newApps = appItems.filter { url in
                let name = url.lastPathComponent
                return !knownSnapshot.contains(name) && !selfNamesSnapshot.contains(name)
            }.sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey]))?.addedToDirectoryDate
                    ?? (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey]))?.addedToDirectoryDate
                    ?? (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                return lDate > rDate
            }

            for candidateURL in newApps {
                if candidateURL.path == currentlyPresentedPath { continue }
                guard let info = AppUninstallerEngine.scanRemnantsForTrashedApp(at: candidateURL) else { continue }
                let bidLower = info.bundleID.lowercased()
                if ignoredSnapshot.contains(bidLower) || selfIDsSnapshot.contains(bidLower) {
                    continue
                }
                return (currentNames, info)
            }
            return (currentNames, nil)
        }.value

        knownTrashAppNames = result.currentNames

        guard let match = result.match, !isCleaning else { return }
        detectedApp = match
        let autoIDs = Set(match.components.filter { $0.confidence == .auto }.map(\.id))
        selectedComponentIDs = autoIDs.isEmpty ? Set(match.components.map(\.id)) : autoIDs
        isExpanded = false
        statusMessage = nil
        TrashRemnantFloatingPanelController.shared.present()
    }

    public func toggleComponent(_ id: UUID) {
        if selectedComponentIDs.contains(id) {
            selectedComponentIDs.remove(id)
        } else {
            selectedComponentIDs.insert(id)
        }
    }

    public var selectedTotalBytes: Int64 {
        guard let detectedApp else { return 0 }
        return detectedApp.components
            .filter { selectedComponentIDs.contains($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    public func cleanSelectedRemnants() {
        guard !isCleaning, let app = detectedApp else { return }
        let protection = CleanProtectionStore.shared
        if let reason = protection.readFailureReason() {
            statusMessage = reason
            return
        }

        let targets = app.components.filter {
            selectedComponentIDs.contains($0.id) && !protection.isProtected(path: $0.path.path)
        }
        guard !targets.isEmpty else {
            dismiss()
            return
        }

        isCleaning = true
        let folderName = "\(app.name) 残留文件"
        let bundleID = app.bundleID
        let agentURLs = targets.filter { $0.type == .launchAgents || $0.type == .launchDaemons }.map(\.path)
        let targetPairs = targets.map { ($0.path, $0.sizeBytes) }

        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            StartupItemManager.bootoutMatchingServices(labels: [bundleID], plistURLs: agentURLs)

            var movedBytes: Int64 = 0
            var movedCount = 0
            for (url, sz) in targetPairs where fm.fileExists(atPath: url.path) {
                do {
                    try AppUninstallerEngine.moveResidueIntoTrashSubfolder(url, folderName: folderName, fm: fm)
                    if !fm.fileExists(atPath: url.path) {
                        movedBytes += sz
                        movedCount += 1
                    }
                } catch {}
            }

            let finalBytes = movedBytes
            let finalCount = movedCount
            await MainActor.run {
                guard let self else { return }
                self.isCleaning = false
                if finalCount > 0 {
                    let formatted = ByteCountFormatter.string(fromByteCount: finalBytes, countStyle: .file)
                    self.statusMessage = "已归档 \(finalCount) 项残留至废纸篓「\(folderName)」（释放 \(formatted)）"
                    SystemResourceMonitor.shared.refreshNow()
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self?.dismiss()
                }
            }
        }
    }

    public func ignoreCurrentApp() {
        if let app = detectedApp {
            ignoredBundleIDs.insert(app.bundleID.lowercased())
            UserDefaults.standard.set(Array(ignoredBundleIDs), forKey: ignoredStorageKey)
        }
        dismiss()
    }

    public func dismiss() {
        detectedApp = nil
        selectedComponentIDs.removeAll()
        isExpanded = false
        statusMessage = nil
        TrashRemnantFloatingPanelController.shared.dismiss()
    }

    nonisolated private static func currentTrashAppNames(in trashURL: URL, fm: FileManager) -> Set<String> {
        let items = (try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Set(items.filter { $0.pathExtension.lowercased() == "app" }.map(\.lastPathComponent))
    }
}
