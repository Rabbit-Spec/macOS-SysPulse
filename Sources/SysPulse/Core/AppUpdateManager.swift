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

    public var hasUpdateAvailable: Bool {
        availableRelease != nil
    }

    private init() {}

    public func checkForUpdates(userInitiated: Bool = true) {
        if userInitiated {
            StudioWindowNavigationState.shared.openUpdateModal()
        }

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
        downloadTask?.cancel()
        downloadTask = nil
        if let rel = availableRelease {
            state = .updateAvailable(rel)
        } else {
            state = .idle
        }
    }

    public func downloadAndInstall(_ release: GitHubReleaseInfo) {
        downloadTask?.cancel()

        let fallbackURLString = "https://github.com/\(Self.repoOwner)/\(Self.repoName)/releases/download/\(release.tagName)/SysPulse-v\(release.version).dmg"
        guard let targetURL = release.dmgAssetURL ?? URL(string: fallbackURLString) else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        let expectedBytes = Double(release.dmgAssetSizeBytes ?? 15_000_000)
        state = .downloading(release, progress: 0.02, downloadedMB: 0.0, totalMB: max(1.0, expectedBytes / 1_048_576.0))

        downloadTask = Task { @MainActor in
            do {
                var request = URLRequest(url: targetURL)
                request.setValue("SysPulse/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 60

                let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(
                        domain: "AppUpdateManager",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "未找到对应版本的 DMG 安装包附件 (HTTP \(http.statusCode))，请点击下方按钮前往 GitHub Releases 页面查看。"]
                    )
                }

                let totalLength = response.expectedContentLength > 0 ? Double(response.expectedContentLength) : expectedBytes
                let totalMB = max(0.5, totalLength / 1_048_576.0)

                let destDMGPath = "/tmp/SysPulse-Update-v\(release.version).dmg"
                try? FileManager.default.removeItem(atPath: destDMGPath)
                FileManager.default.createFile(atPath: destDMGPath, contents: nil)
                guard let fileHandle = FileHandle(forWritingAtPath: destDMGPath) else {
                    throw NSError(domain: "AppUpdateManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法创建临时更新文件。"])
                }
                defer { try? fileHandle.close() }

                var buffer = Data()
                buffer.reserveCapacity(65536)
                var receivedBytes: Int64 = 0
                var lastUIUpdate = Date.distantPast

                for try await byte in asyncBytes {
                    if Task.isCancelled { return }
                    buffer.append(byte)
                    if buffer.count >= 65536 {
                        fileHandle.write(buffer)
                        receivedBytes += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)

                        let now = Date()
                        if now.timeIntervalSince(lastUIUpdate) >= 0.08 {
                            lastUIUpdate = now
                            let dlMB = Double(receivedBytes) / 1_048_576.0
                            let prog = min(0.98, max(0.02, Double(receivedBytes) / totalLength))
                            self.state = .downloading(release, progress: prog, downloadedMB: dlMB, totalMB: totalMB)
                        }
                    }
                }

                if !buffer.isEmpty {
                    fileHandle.write(buffer)
                    receivedBytes += Int64(buffer.count)
                    buffer.removeAll()
                }
                try? fileHandle.close()

                let dlMB = Double(receivedBytes) / 1_048_576.0
                self.state = .downloading(release, progress: 1.0, downloadedMB: dlMB, totalMB: max(dlMB, totalMB))
                try? await Task.sleep(nanoseconds: 250_000_000)

                self.state = .installing(release, statusMessage: "正在挂载更新镜像并校验签名…")
                try await Self.mountAndReplaceApp(dmgPath: destDMGPath, release: release)
            } catch is CancellationError {
                self.state = .updateAvailable(release)
            } catch {
                self.state = .failed(message: error.localizedDescription)
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

    private static func mountAndReplaceApp(dmgPath: String, release: GitHubReleaseInfo) async throws {
        let mountPoint = "/tmp/syspulse-ota-mount"
        let mountedAppPath = "\(mountPoint)/SysPulse.app"

        try await Task.detached(priority: .userInitiated) {
            // 先卸载可能残留的挂载点
            let detachOld = Process()
            detachOld.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detachOld.arguments = ["detach", mountPoint, "-force"]
            detachOld.standardOutput = Pipe()
            detachOld.standardError = Pipe()
            try? detachOld.run()
            detachOld.waitUntilExit()

            let attach = Process()
            attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            attach.arguments = ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint, dmgPath]
            let errPipe = Pipe()
            attach.standardOutput = Pipe()
            attach.standardError = errPipe
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

        let updaterScriptPath = "/tmp/syspulse_ota_updater.sh"
        let scriptContent = """
        #!/bin/bash
        sleep 0.8
        /usr/bin/killall -TERM SysPulse 2>/dev/null || true
        sleep 0.4
        rm -rf "\(targetAppPath)"
        cp -R "\(mountedAppPath)" "\(targetAppPath)"
        /usr/bin/xattr -cr "\(targetAppPath)" 2>/dev/null || true
        /usr/bin/hdiutil detach "\(mountPoint)" -force >/dev/null 2>&1 || true
        rm -f "\(dmgPath)"
        /usr/bin/open "\(targetAppPath)"
        """

        try scriptContent.write(toFile: updaterScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: updaterScriptPath)

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
        let cParts = normalizeVersion(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let curParts = normalizeVersion(current).split(separator: ".").map { Int($0) ?? 0 }
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
