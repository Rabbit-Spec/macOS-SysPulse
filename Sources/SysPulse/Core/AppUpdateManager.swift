import Foundation
import AppKit
import Observation

public struct GitHubReleaseInfo: Sendable, Equatable {
    public let tagName: String
    public let version: String
    public let title: String
    public let releaseNotes: String
    public let publishedAt: String
    public let htmlURL: URL
    public let dmgAssetURL: URL?
    public let dmgAssetName: String?
    public let dmgAssetSizeBytes: Int64?

    public var formattedSize: String? {
        guard let bytes = dmgAssetSizeBytes, bytes > 0 else { return nil }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

public enum UpdateCheckState: Sendable, Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String, checkedAt: String)
    case updateAvailable(GitHubReleaseInfo)
    case downloading(GitHubReleaseInfo, progress: Double, downloadedMB: Double, totalMB: Double)
    case installing(GitHubReleaseInfo, statusMessage: String)
    case failed(message: String)

    public var stateKey: String {
        switch self {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .updateAvailable: return "updateAvailable"
        case .downloading: return "downloading"
        case .installing: return "installing"
        case .failed: return "failed"
        }
    }
}

@Observable
@MainActor
public final class AppUpdateManager {
    public static let shared = AppUpdateManager()

    public static let repoOwner = "Rabbit-Spec"
    public static let repoName = "macOS-SysPulse"
    public static let repoWebURL = URL(string: "https://github.com/Rabbit-Spec/macOS-SysPulse")!
    public static let releasesWebURL = URL(string: "https://github.com/Rabbit-Spec/macOS-SysPulse/releases")!
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/Rabbit-Spec/macOS-SysPulse/releases/latest")!
    public static let tagsAPIURL = URL(string: "https://api.github.com/repos/Rabbit-Spec/macOS-SysPulse/tags")!

    public var state: UpdateCheckState = .idle
    public var availableRelease: GitHubReleaseInfo? = nil
    private var downloadTask: Task<Void, Never>? = nil
    private var currentDownloadTask: URLSessionDownloadTask? = nil
    private var currentURLSession: URLSession? = nil
    private var activeDownloadId = UUID()

    private static func otaStagingDirectory() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.rabbit.syspulse/OTAUpdate", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        return dir
    }

    public var hasUpdateAvailable: Bool {
        availableRelease != nil
    }

    private init() {}

    public func checkForUpdates(userInitiated: Bool = true, forceRefresh: Bool = false) {
        if userInitiated {
            StudioWindowNavigationState.shared.openUpdateModal()
        }

        // 如果已经解析出可用新版本且并非用户在弹窗内主动点击「重新检查」，则直接平滑展示已有更新内容，避免状态跳变闪烁
        if !forceRefresh, case .updateAvailable = state {
            return
        }

        // 如果已经在下载中或安装中，保持当前状态
        if case .downloading = state { return }
        if case .installing = state { return }

        state = .checking

        Task { @MainActor in
            do {
                let releaseInfo = try await Self.fetchLatestReleaseFromGitHub()
                let nowStr = Self.currentTimestampString()

                if let info = releaseInfo {
                    if Self.isVersion(info.version, newerThan: AppMetadata.version) {
                        self.availableRelease = info
                        self.state = .updateAvailable(info)
                    } else {
                        self.availableRelease = nil
                        self.state = .upToDate(currentVersion: AppMetadata.version, checkedAt: nowStr)
                    }
                } else {
                    // 仓库尚未创建首个 Release 或 Tag 时视为已是最新
                    self.availableRelease = nil
                    self.state = .upToDate(currentVersion: AppMetadata.version, checkedAt: nowStr)
                }
            } catch {
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    public func cancelDownload() {
        activeDownloadId = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        currentURLSession?.invalidateAndCancel()
        currentURLSession = nil
        if let rel = availableRelease {
            state = .updateAvailable(rel)
        } else {
            state = .idle
        }
    }

    public func downloadAndInstall(_ release: GitHubReleaseInfo) {
        let newDownloadId = UUID()
        self.activeDownloadId = newDownloadId

        downloadTask?.cancel()
        downloadTask = nil
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        currentURLSession?.invalidateAndCancel()
        currentURLSession = nil

        let fallbackURLString = "https://github.com/\(Self.repoOwner)/\(Self.repoName)/releases/download/\(release.tagName)/SysPulse-v\(release.version).dmg"
        guard let targetURL = release.dmgAssetURL ?? URL(string: fallbackURLString) else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        let expectedBytes = Double(release.dmgAssetSizeBytes ?? 15_000_000)
        let initTotalMB = max(1.0, expectedBytes / 1_048_576.0)
        self.state = .downloading(release, progress: 0.02, downloadedMB: 0.0, totalMB: initTotalMB)

        downloadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let stagingDir = try Self.otaStagingDirectory()
                let safeVersionFile = release.version.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
                let destDMGPath = stagingDir.appendingPathComponent("SysPulse-Update-v\(safeVersionFile).dmg").path

                var request = URLRequest(url: targetURL)
                request.setValue("SysPulse/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 120

                let tempDownloadedURL: URL = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let coordinator = DownloadCoordinator(
                            expectedBytes: expectedBytes,
                            stagingDirectory: stagingDir,
                            onProgress: { [weak self] prog, dlMB, totMB in
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self, self.activeDownloadId == newDownloadId else { return }
                                    self.state = .downloading(release, progress: prog, downloadedMB: dlMB, totalMB: totMB)
                                }
                            },
                            continuation: continuation
                        )

                        let sessionConfig = URLSessionConfiguration.default
                        let session = URLSession(configuration: sessionConfig, delegate: coordinator, delegateQueue: nil)
                        let task = session.downloadTask(with: request)
                        self.currentURLSession = session
                        self.currentDownloadTask = task
                        task.resume()
                    }
                } onCancel: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.activeDownloadId == newDownloadId else { return }
                        self.currentDownloadTask?.cancel()
                        self.currentDownloadTask = nil
                        self.currentURLSession?.invalidateAndCancel()
                        self.currentURLSession = nil
                    }
                }

                guard self.activeDownloadId == newDownloadId else { return }
                self.currentDownloadTask = nil
                self.currentURLSession = nil

                try? FileManager.default.removeItem(atPath: destDMGPath)
                try FileManager.default.moveItem(at: tempDownloadedURL, to: URL(fileURLWithPath: destDMGPath))

                let finalFileSize = (try? FileManager.default.attributesOfItem(atPath: destDMGPath)[.size] as? Int64) ?? Int64(expectedBytes)
                let finalMB = Double(finalFileSize) / 1_048_576.0
                self.state = .downloading(release, progress: 1.0, downloadedMB: finalMB, totalMB: finalMB)

                try? await Task.sleep(nanoseconds: 250_000_000)

                guard self.activeDownloadId == newDownloadId else { return }
                self.state = .installing(release, statusMessage: "正在挂载更新镜像并校验签名…")
                try await Self.mountAndReplaceApp(dmgPath: destDMGPath, release: release, stagingDir: stagingDir)
            } catch is CancellationError {
                if self.activeDownloadId == newDownloadId {
                    self.state = .updateAvailable(release)
                }
            } catch {
                guard self.activeDownloadId == newDownloadId else { return }
                if (error as NSError).code == NSURLErrorCancelled {
                    self.state = .updateAvailable(release)
                } else {
                    self.state = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - GitHub API Fetching

    private static func fetchLatestReleaseFromGitHub() async throws -> GitHubReleaseInfo? {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SysPulse/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AppUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的网络响应。"])
        }

        if http.statusCode == 200 {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parseReleaseJSON(json)
            }
        }

        // 若 latest release 返回 404（尚未发布 Release 或仅推送了 Git Tag），回退查询 Tags 列表
        if http.statusCode == 404 {
            return try await fetchLatestTagFromGitHub()
        }

        throw NSError(
            domain: "AppUpdateManager",
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "连接 GitHub Releases 失败 (HTTP \(http.statusCode))，请检查网络或代理设置。"]
        )
    }

    private static func fetchLatestTagFromGitHub() async throws -> GitHubReleaseInfo? {
        var request = URLRequest(url: tagsAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SysPulse/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200,
              let tags = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let firstTag = tags.first,
              let tagName = firstTag["name"] as? String else {
            return nil
        }

        let cleanVer = normalizeVersion(tagName)
        let dmgURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/\(tagName)/SysPulse-v\(cleanVer).dmg")
        let htmlURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tagName)") ?? releasesWebURL

        return GitHubReleaseInfo(
            tagName: tagName,
            version: cleanVer,
            title: "SysPulse \(tagName)",
            releaseNotes: "GitHub 标签版本 \(tagName) 已发布。点击「立即更新」即可下载并安装最新版本。",
            publishedAt: currentTimestampString(),
            htmlURL: htmlURL,
            dmgAssetURL: dmgURL,
            dmgAssetName: "SysPulse-v\(cleanVer).dmg",
            dmgAssetSizeBytes: nil
        )
    }

    private static func parseReleaseJSON(_ json: [String: Any]) -> GitHubReleaseInfo? {
        guard let tagName = json["tag_name"] as? String else { return nil }
        let cleanVer = normalizeVersion(tagName)
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (name?.isEmpty == false) ? name! : "SysPulse \(tagName)"
        let rawBody = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = rawBody.isEmpty ? "• 性能优化与体验改进。" : rawBody

        let publishedRaw = (json["published_at"] as? String) ?? ""
        let publishedFormatted = formatISO8601Date(publishedRaw)

        let htmlURLStr = (json["html_url"] as? String) ?? "https://github.com/\(repoOwner)/\(repoName)/releases"
        let htmlURL = URL(string: htmlURLStr) ?? releasesWebURL

        var dmgURL: URL? = nil
        var dmgName: String? = nil
        var dmgSize: Int64? = nil

        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let assetName = asset["name"] as? String,
                   let downloadStr = asset["browser_download_url"] as? String,
                   let url = URL(string: downloadStr),
                   assetName.lowercased().hasSuffix(".dmg") {
                    dmgURL = url
                    dmgName = assetName
                    if let sz = asset["size"] as? Int64 {
                        dmgSize = sz
                    } else if let szInt = asset["size"] as? Int {
                        dmgSize = Int64(szInt)
                    }
                    break
                }
            }
        }

        return GitHubReleaseInfo(
            tagName: tagName,
            version: cleanVer,
            title: title,
            releaseNotes: body,
            publishedAt: publishedFormatted,
            htmlURL: htmlURL,
            dmgAssetURL: dmgURL,
            dmgAssetName: dmgName,
            dmgAssetSizeBytes: dmgSize
        )
    }

    // MARK: - In-Place DMG Mounting & App Replacement

    private static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func mountAndReplaceApp(dmgPath: String, release: GitHubReleaseInfo, stagingDir: URL) async throws {
        let mountPoint = stagingDir.appendingPathComponent("mount", isDirectory: true).path
        let mountedAppPath = "\(mountPoint)/SysPulse.app"

        try await Task.detached(priority: .userInitiated) {
            // 先卸载可能残留的挂载点
            let detachOld = Process()
            detachOld.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detachOld.arguments = ["detach", mountPoint, "-force"]
            detachOld.standardOutput = FileHandle.nullDevice
            detachOld.standardError = FileHandle.nullDevice
            try? detachOld.run()
            detachOld.waitUntilExit()

            let attach = Process()
            attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            attach.arguments = ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint, dmgPath]
            attach.standardOutput = FileHandle.nullDevice
            attach.standardError = FileHandle.nullDevice
            try attach.run()
            attach.waitUntilExit()

            guard attach.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: mountedAppPath) else {
                throw NSError(
                    domain: "AppUpdateManager",
                    code: Int(attach.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "挂载更新镜像失败，已为您下载至 \(dmgPath)。"]
                )
            }

            // 校验挂载的 SysPulse.app 代码签名与 Bundle Identifier
            let verifyProc = Process()
            verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verifyProc.arguments = ["--verify", "--deep", "--strict", mountedAppPath]
            verifyProc.standardOutput = FileHandle.nullDevice
            verifyProc.standardError = FileHandle.nullDevice
            try? verifyProc.run()
            verifyProc.waitUntilExit()

            let infoProc = Process()
            infoProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            infoProc.arguments = ["-dv", mountedAppPath]
            let infoErrPipe = Pipe()
            infoProc.standardOutput = FileHandle.nullDevice
            infoProc.standardError = infoErrPipe
            var signInfoText = ""
            if (try? infoProc.run()) != nil {
                let errData = infoErrPipe.fileHandleForReading.readDataToEndOfFile()
                infoProc.waitUntilExit()
                signInfoText = String(data: errData, encoding: .utf8) ?? ""
            }

            let isSignatureValid = (verifyProc.terminationStatus == 0) &&
                infoProc.terminationStatus == 0 &&
                signInfoText.contains("Identifier=com.rabbit.syspulse")

            if !isSignatureValid {
                let detachBad = Process()
                detachBad.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detachBad.arguments = ["detach", mountPoint, "-force"]
                detachBad.standardOutput = FileHandle.nullDevice
                detachBad.standardError = FileHandle.nullDevice
                try? detachBad.run()
                detachBad.waitUntilExit()

                throw NSError(
                    domain: "AppUpdateManager",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "更新包签名校验失败，已中止安装。"]
                )
            }
        }.value

        AppUpdateManager.shared.state = .installing(release, statusMessage: "正在替换应用并准备重启 SysPulse…")
        try? await Task.sleep(nanoseconds: 400_000_000)

        let currentBundlePath = Bundle.main.bundlePath
        let targetAppPath: String = {
            if currentBundlePath.hasSuffix(".app") && FileManager.default.isWritableFile(atPath: (currentBundlePath as NSString).deletingLastPathComponent) {
                return currentBundlePath
            }
            return "/Applications/SysPulse.app"
        }()

        let updaterScriptPath = stagingDir.appendingPathComponent("syspulse_ota_updater.sh").path
        let qTarget = shellSingleQuoted(targetAppPath)
        let qMounted = shellSingleQuoted(mountedAppPath)
        let qMount = shellSingleQuoted(mountPoint)
        let qDmg = shellSingleQuoted(dmgPath)
        let scriptContent = """
        #!/bin/bash
        sleep 0.8
        /usr/bin/killall -TERM SysPulse 2>/dev/null || true
        sleep 0.4
        rm -rf \(qTarget)
        cp -R \(qMounted) \(qTarget)
        /usr/bin/xattr -cr \(qTarget) 2>/dev/null || true
        /usr/bin/hdiutil detach \(qMount) -force >/dev/null 2>&1 || true
        rm -f \(qDmg)
        /usr/bin/open \(qTarget)
        """

        try scriptContent.write(toFile: updaterScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updaterScriptPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [updaterScriptPath]
        try proc.run()

        NSApplication.shared.terminate(nil)
    }

    // MARK: - Version Comparison Helpers

    public static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s
    }

    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let parseParts: (String) -> [Int] = { ver in
            normalizeVersion(ver).split(separator: ".").map { seg in
                Int(String(seg.prefix(while: { $0.isNumber }))) ?? 0
            }
        }
        let cParts = parseParts(candidate)
        let curParts = parseParts(current)
        let maxCount = max(cParts.count, curParts.count)
        for i in 0..<maxCount {
            let v1 = i < cParts.count ? cParts[i] : 0
            let v2 = i < curParts.count ? curParts[i] : 0
            if v1 != v2 {
                return v1 > v2
            }
        }
        return false
    }

    private static func formatISO8601Date(_ iso: String) -> String {
        guard !iso.isEmpty else { return currentTimestampString() }
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: iso) {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            return df.string(from: date)
        }
        return iso
    }

    private static func currentTimestampString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: Date())
    }
}

// MARK: - Efficient Block-Level Download Coordinator

private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Double
    private let stagingDirectory: URL
    private let onProgress: @Sendable (Double, Double, Double) -> Void
    private let continuation: CheckedContinuation<URL, Error>
    private var isResumed = false
    private var lastReportTime: TimeInterval = 0
    private let lock = NSLock()

    init(
        expectedBytes: Double,
        stagingDirectory: URL,
        onProgress: @escaping @Sendable (Double, Double, Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.expectedBytes = expectedBytes
        self.stagingDirectory = stagingDirectory
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldReport = (now - lastReportTime >= 0.08) || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite)
        if shouldReport {
            lastReportTime = now
        }
        lock.unlock()

        if shouldReport {
            let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : expectedBytes
            let downloadedMB = Double(totalBytesWritten) / 1_048_576.0
            let totalMB = max(0.5, total / 1_048_576.0)
            let prog = min(0.98, max(0.02, Double(totalBytesWritten) / total))
            onProgress(prog, downloadedMB, totalMB)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempTarget = stagingDirectory.appendingPathComponent("SysPulse-Update-\(UUID().uuidString).dmg")
        do {
            try? FileManager.default.removeItem(at: tempTarget)
            try FileManager.default.copyItem(at: location, to: tempTarget)
            lock.lock()
            defer { lock.unlock() }
            if !isResumed {
                isResumed = true
                continuation.resume(returning: tempTarget)
            }
        } catch {
            lock.lock()
            defer { lock.unlock() }
            if !isResumed {
                isResumed = true
                continuation.resume(throwing: error)
            }
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            lock.lock()
            defer { lock.unlock() }
            if !isResumed {
                isResumed = true
                continuation.resume(throwing: error)
            }
        }
        session.finishTasksAndInvalidate()
    }
}
