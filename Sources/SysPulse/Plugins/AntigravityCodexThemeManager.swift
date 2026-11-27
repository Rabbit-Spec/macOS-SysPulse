import AppKit
import Darwin
import Foundation
import Observation

public enum CodexThemePreset: String, CaseIterable, Identifiable, Sendable {
    case pureWhite = "codex-pure-white"
    case dark = "codex-dark"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pureWhite: return "Codex 纯白"
        case .dark: return "Codex 炭灰深色"
        }
    }
}

public struct NodeRuntimeInfo: Sendable, Equatable {
    public let executablePath: String
    public let underlyingBinaryPath: String
    public let version: String
    public let isEmbeddedAntigravityElectron: Bool

    public var displayLabel: String {
        let prefix = isEmbeddedAntigravityElectron ? "内置 Node" : "系统 Node"
        return "\(prefix) \(version)"
    }
}

public struct CodexThemeUserConfig: Sendable, Equatable {
    public var enabled: Bool = true
    public var preset: CodexThemePreset = .pureWhite
    public var telemetryLayout: String = "compact"
    public var moduleTheme: Bool = true
    public var moduleI18n: Bool = true
    public var moduleMetrics: Bool = true
    public var moduleQuota: Bool = true
    public var moduleQuotaSidebar: Bool = true
    public var moduleDeadlockHealer: Bool = true
    public var moduleZoomShortcuts: Bool = true
    public var modulePromptSuggestions: Bool = false
    public var moduleCdpAutoRelaunch: Bool = true
    public var moduleCustomAssets: Bool = true
}

private struct CodexDoctorSnapshot: Sendable {
    let ok: Bool
    let daemonRunning: Bool
    let daemonPidCount: Int
    let cdpStatus: String
    let appVersion: String?
    let coreIntegrityOK: Bool
}

private struct CodexRefreshResult: Sendable {
    let bundledVersion: String
    let runtimeInfo: NodeRuntimeInfo?
    let isInstalled: Bool
    let installedVersion: String?
    let hasRollbackBackup: Bool
    let config: CodexThemeUserConfig
    let doctor: CodexDoctorSnapshot?
}

@Observable
@MainActor
public final class AntigravityCodexThemeManager {
    public static let shared = AntigravityCodexThemeManager()

    public var isInstalled: Bool = false
    public var installedVersion: String? = nil
    public var bundledVersion: String = "1.4.1"
    public var remoteLatestVersion: String? = nil
    public var updateAvailable: Bool = false
    public var canSyncMain: Bool = false
    public var runtimeInfo: NodeRuntimeInfo? = nil
    public var daemonRunning: Bool = false
    public var daemonPidCount: Int = 0
    public var cdpStatus: String = "unknown"
    public var appVersion: String? = nil
    public var coreIntegrityOK: Bool = true
    public var doctorOK: Bool = false
    public var hasRollbackBackup: Bool = false
    public var config: CodexThemeUserConfig = CodexThemeUserConfig()

    public var isRefreshing: Bool = false
    public var isBusy: Bool = false
    public var isCheckingUpdate: Bool = false
    public var statusMessage: String? = nil
    public var lastError: String? = nil
    public var isMoreMenuPresented: Bool = false

    private var hasCheckedInitial: Bool = false

    public static let repoURLString = "https://github.com/nkjDSLcvanv/antigravity-codex-theme"

    public nonisolated static var installDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/codex-theme", isDirectory: true)
    }

    public nonisolated static var embeddedNodeShimURL: URL {
        installDirURL.appendingPathComponent("bin/node", isDirectory: false)
    }

    public nonisolated static var embeddedNodePreloadURL: URL {
        installDirURL.appendingPathComponent("bin/preload.cjs", isDirectory: false)
    }

    private nonisolated static let preloadScriptContent: String = """
    delete process.env.ELECTRON_RUN_AS_NODE;
    if (process.env.SYSPULSE_NODE_SHIM_PATH) {
      process.execPath = process.env.SYSPULSE_NODE_SHIM_PATH;
    }
    """ + "\n"

    public nonisolated static var userConfigURL: URL {
        installDirURL.appendingPathComponent("user/config.json", isDirectory: false)
    }

    public nonisolated static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.antigravity.codex-theme.plist", isDirectory: false)
    }

    public nonisolated static func resolveBundledPluginDir() -> URL? {
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("Plugins/AntigravityCodexTheme", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("install.mjs").path) {
                return bundled
            }
        }
        let devFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Plugins/AntigravityCodexTheme", isDirectory: true)
        if FileManager.default.fileExists(atPath: devFallback.appendingPathComponent("install.mjs").path) {
            return devFallback
        }
        return nil
    }

    private nonisolated static func resolveBundledNodeShim() -> URL? {
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidate = execDir.appendingPathComponent("SysPulseNodeShim", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Ensures the signed `SysPulseNodeShim` and its sibling `preload.cjs` are deployed at
    /// `~/.gemini/antigravity/codex-theme/bin/` using byte-exact comparison so upgrades take effect
    /// immediately and `ELECTRON_RUN_AS_NODE` is stripped before child processes spawn.
    private nonisolated static func ensureEmbeddedNodeShim() -> String? {
        guard let src = resolveBundledNodeShim() else { return nil }
        let dest = embeddedNodeShimURL
        let preloadURL = embeddedNodePreloadURL
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let expectedPreloadData = preloadScriptContent.data(using: .utf8) {
            let currentPreloadData = try? Data(contentsOf: preloadURL)
            if currentPreloadData != expectedPreloadData {
                try? expectedPreloadData.write(to: preloadURL, options: .atomic)
            }
        }

        let srcData = try? Data(contentsOf: src)
        let destData = try? Data(contentsOf: dest)
        if !fm.fileExists(atPath: dest.path) || srcData == nil || srcData != destData {
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: src, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                _ = runQuickOutput(
                    executable: "/usr/bin/codesign",
                    arguments: ["--force", "-s", "-", "-i", "com.rabbit.syspulse.nodeshim", dest.path],
                    extraEnv: [:]
                )
            } catch {
                return nil
            }
        } else {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        return fm.isExecutableFile(atPath: dest.path) ? dest.path : nil
    }

    public var compactStatusBadge: String {
        if isRefreshing && !hasCheckedInitial {
            return "检测中"
        }
        if !isInstalled {
            return "未安装"
        }
        if cdpStatus == "ready" && daemonRunning {
            return "已运行"
        }
        if cdpStatus == "missing_opt_in_flag" {
            return "待激活 CDP"
        }
        if daemonRunning {
            return "守护待命中"
        }
        return "未运行"
    }

    public var cdpStatusDisplayText: String {
        if !isInstalled {
            return "未安装"
        }
        switch cdpStatus {
        case "ready": return "已就绪"
        case "missing_opt_in_flag": return "需重启激活"
        case "app_not_running", "not_running": return "Antigravity 未运行"
        case "stale_port_file": return "待重启刷新"
        default: return "检测中"
        }
    }

    private init() {}

    public func checkOnEntry() {
        guard !hasCheckedInitial || !isRefreshing else { return }
        hasCheckedInitial = true
        refreshStatus()
    }

    public func refreshStatus() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let defaultBundled = bundledVersion

        Task.detached(priority: .utility) { [weak self] in
            let bundledVer = Self.readPackageVersion(at: Self.resolveBundledPluginDir()) ?? defaultBundled
            let runtime = Self.detectNodeRuntime()
            let installDir = Self.installDirURL
            let daemonPath = installDir.appendingPathComponent("core/daemon.mjs").path
            let installed = FileManager.default.fileExists(atPath: daemonPath)
            let installedVer = installed ? Self.readPackageVersion(at: installDir) : nil
            let hasPrev = FileManager.default.fileExists(
                atPath: installDir.appendingPathComponent("core.prev").path
            )

            // Proactively heal unpatched LaunchAgent from earlier builds so daemon runs via bin/node shim
            if installed, let runtime, runtime.isEmbeddedAntigravityElectron,
               Self.launchAgentNeedsEmbeddedHeal() {
                Self.patchLaunchAgentIfEmbeddedNode(runtime: runtime)
            }

            let configSourceDir = installed ? installDir : Self.resolveBundledPluginDir()
            let configFile = configSourceDir?.appendingPathComponent("user/config.json")
            let loadedConfig = configFile.flatMap { Self.loadUserConfigSync(from: $0) } ?? CodexThemeUserConfig()

            var doctorSnap: CodexDoctorSnapshot? = nil
            if installed, let runtime {
                let installScript = installDir.appendingPathComponent("install.mjs").path
                if FileManager.default.fileExists(atPath: installScript) {
                    let res = Self.runScript(
                        runtime: runtime,
                        scriptPath: installScript,
                        args: ["doctor", "--target-dir", installDir.path],
                        cwd: installDir.path
                    )
                    doctorSnap = Self.parseDoctorOutput(res.stdout)
                }
            }

            let snapshot = CodexRefreshResult(
                bundledVersion: bundledVer,
                runtimeInfo: runtime,
                isInstalled: installed,
                installedVersion: installedVer,
                hasRollbackBackup: hasPrev,
                config: loadedConfig,
                doctor: doctorSnap
            )

            await MainActor.run {
                guard let self else { return }
                self.bundledVersion = snapshot.bundledVersion
                self.runtimeInfo = snapshot.runtimeInfo
                self.isInstalled = snapshot.isInstalled
                self.installedVersion = snapshot.installedVersion
                self.hasRollbackBackup = snapshot.hasRollbackBackup
                self.config = snapshot.config
                if let doc = snapshot.doctor {
                    self.doctorOK = doc.ok
                    self.daemonRunning = doc.daemonRunning
                    self.daemonPidCount = doc.daemonPidCount
                    self.cdpStatus = doc.cdpStatus
                    self.appVersion = doc.appVersion
                    self.coreIntegrityOK = doc.coreIntegrityOK
                } else {
                    self.doctorOK = false
                    self.daemonRunning = false
                    self.daemonPidCount = 0
                    self.cdpStatus = "unknown"
                    self.coreIntegrityOK = true
                }
                self.isRefreshing = false
            }
        }
    }

    public func installFromBundle(preset: CodexThemePreset? = nil) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        statusMessage = "正在安装 antigravity-codex-theme 扩展并注册后台守护..."
        let chosenPreset = preset ?? config.preset

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let bundledDir = Self.resolveBundledPluginDir() else {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "应用内置的 AntigravityCodexTheme 资源包缺失。"
                }
                return
            }
            guard let runtime = Self.detectNodeRuntime() else {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "未检测到 Node.js (>= 22.13.0) 或 Antigravity 内置运行时。"
                }
                return
            }

            // Copy to a temporary staging directory before invoking install.mjs so the sealed .app bundle stays untouched
            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("syspulse-codex-theme-staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            do {
                try FileManager.default.copyItem(at: bundledDir, to: stagingDir)
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "准备临时安装目录失败：\(error.localizedDescription)"
                }
                return
            }

            let scriptPath = stagingDir.appendingPathComponent("install.mjs").path
            let installPath = Self.installDirURL.path
            let res = Self.runScript(
                runtime: runtime,
                scriptPath: scriptPath,
                args: [
                    "install",
                    "--target-dir", installPath,
                    "--preset", chosenPreset.rawValue
                ],
                cwd: stagingDir.path
            )

            if res.exitCode != 0 {
                let errDetail = [res.stderr, res.stdout]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = errDetail.isEmpty ? "安装脚本执行失败 (退出码 \(res.exitCode))" : "安装失败：\(errDetail.prefix(240))"
                }
                return
            }

            Self.patchLaunchAgentIfEmbeddedNode(runtime: runtime)

            let installedScript = Self.installDirURL.appendingPathComponent("install.mjs").path
            let docRes = Self.runScript(
                runtime: runtime,
                scriptPath: installedScript,
                args: ["doctor", "--target-dir", installPath],
                cwd: installPath
            )
            let doctor = Self.parseDoctorOutput(docRes.stdout)

            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.refreshStatus()
                if doctor?.cdpStatus == "missing_opt_in_flag" {
                    self.statusMessage = "扩展已安装并启动后台守护。检测到当前 Antigravity 未开启 CDP 调试端口，请点击「重启 Antigravity 激活」。"
                } else {
                    self.statusMessage = "antigravity-codex-theme 安装并配置完成！"
                }
            }
        }
    }

    public func relaunchAntigravityWithCDP() {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        statusMessage = "正在安全重启 Antigravity 并注入 CDP 调试端口..."

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let runtime = Self.detectNodeRuntime() else {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "未检测到可用的 Node 运行时。"
                }
                return
            }
            let installDir = Self.installDirURL
            let scriptPath = installDir.appendingPathComponent("install.mjs").path
            guard FileManager.default.fileExists(atPath: scriptPath) else {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "请先安装主题与界面增强扩展。"
                }
                return
            }

            // Ensure LaunchAgent and bin/node shim are active before relaunching Antigravity
            Self.patchLaunchAgentIfEmbeddedNode(runtime: runtime)

            let res = Self.runScript(
                runtime: runtime,
                scriptPath: scriptPath,
                args: ["relaunch", "--target-dir", installDir.path],
                cwd: installDir.path
            )

            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                if res.exitCode == 2 {
                    self.statusMessage = nil
                    self.lastError = "检测到 Antigravity 最近 15 秒内有活跃对话写入，请等待回复结束后再点击重启激活。"
                } else if res.exitCode != 0 {
                    self.statusMessage = nil
                    if let parsed = Self.parseJSONDict(res.stdout) {
                        let live = parsed["live"] as? [String: Any]
                        let reachable = (live?["reachable"] as? Bool) ?? false
                        if !reachable {
                            self.lastError = "重启后未检测到 Antigravity CDP 端口响应，请确认主窗口已打开后点击刷新或重试。"
                        } else if let reason = parsed["reason"] as? String, !reason.isEmpty {
                            self.lastError = "重启激活失败：\(reason)"
                        } else {
                            self.lastError = "重启激活未能完成注入，请重试一次。"
                        }
                    } else {
                        let detail = [res.stderr, res.stdout]
                            .joined(separator: " ")
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.lastError = detail.isEmpty ? "重启激活失败 (退出码 \(res.exitCode))" : "重启激活失败：\(detail.prefix(120))"
                    }
                } else {
                    self.statusMessage = "Antigravity 已携带 CDP 参数重启并完成注入。"
                }
                self.refreshStatus()
            }
        }
    }

    public func checkForOnlineUpdates() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        lastError = nil

        Task.detached(priority: .utility) { [weak self] in
            let installDir = Self.installDirURL
            let installScript = installDir.appendingPathComponent("install.mjs").path

            if FileManager.default.fileExists(atPath: installScript),
               let runtime = Self.detectNodeRuntime() {
                let res = Self.runScript(
                    runtime: runtime,
                    scriptPath: installScript,
                    args: ["update", "--check", "--target-dir", installDir.path],
                    cwd: installDir.path
                )
                if let parsed = Self.parseJSONDict(res.stdout) {
                    let ok = (parsed["ok"] as? Bool) ?? false
                    let latest = (parsed["latestVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let avail = (parsed["updateAvailable"] as? Bool) ?? false
                    let syncMain = (parsed["canSyncMain"] as? Bool) ?? false
                    let errStr = parsed["error"] as? String

                    await MainActor.run {
                        guard let self else { return }
                        self.isCheckingUpdate = false
                        if !ok {
                            self.lastError = "检查更新失败：\(errStr ?? "无法连接 GitHub")"
                        } else {
                            self.remoteLatestVersion = latest.isEmpty ? nil : latest
                            self.updateAvailable = avail || syncMain
                            self.canSyncMain = syncMain
                            if self.updateAvailable {
                                let label = latest.isEmpty ? "main 最新提交" : "v\(latest)"
                                self.statusMessage = "发现上游可用更新：\(label)，点击「立即在线更新」即可无损同步。"
                            } else {
                                self.statusMessage = "当前已安装版本 v\(self.installedVersion ?? self.bundledVersion) 已是最新。"
                            }
                        }
                    }
                    return
                }
            }

            var fetchedVersion: String? = nil
            var fetchError: String? = nil
            if let url = URL(string: "https://api.github.com/repos/nkjDSLcvanv/antigravity-codex-theme/releases/latest") {
                var req = URLRequest(url: url, timeoutInterval: 10.0)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("SysPulse/1.0", forHTTPHeaderField: "User-Agent")
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode == 200,
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tag = obj["tag_name"] as? String {
                        fetchedVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n\t"))
                    } else {
                        fetchError = "GitHub API 返回异常状态"
                    }
                } catch {
                    fetchError = error.localizedDescription
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.isCheckingUpdate = false
                if let v = fetchedVersion, !v.isEmpty {
                    self.remoteLatestVersion = v
                    let base = self.installedVersion ?? self.bundledVersion
                    self.updateAvailable = Self.compareSemver(v, base) > 0
                    self.statusMessage = self.updateAvailable
                        ? "GitHub 最新版本为 v\(v)（当前内置快照 v\(self.bundledVersion)）。"
                        : "当前扩展版本 v\(base) 与 GitHub 最新正式版一致。"
                } else {
                    self.lastError = "检查更新失败：\(fetchError ?? "网络错误")"
                }
            }
        }
    }

    public func applyOnlineUpdate() {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        statusMessage = "正在从 GitHub 拉取并校验最新核心文件..."

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let runtime = Self.detectNodeRuntime() else {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "未检测到可用的 Node 运行时。"
                }
                return
            }
            let installDir = Self.installDirURL
            let scriptPath = installDir.appendingPathComponent("install.mjs").path
            guard FileManager.default.fileExists(atPath: scriptPath) else {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "请先安装扩展后再执行在线更新。"
                }
                return
            }

            let res = Self.runScript(
                runtime: runtime,
                scriptPath: scriptPath,
                args: ["update", "--target-dir", installDir.path],
                cwd: installDir.path
            )

            if res.exitCode != 0 {
                let errDetail = [res.stderr, res.stdout]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = errDetail.isEmpty ? "在线更新失败 (退出码 \(res.exitCode))" : "在线更新失败：\(errDetail.prefix(240))"
                }
                return
            }

            Self.patchLaunchAgentIfEmbeddedNode(runtime: runtime)

            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.updateAvailable = false
                self.canSyncMain = false
                self.statusMessage = "在线更新完成（user/ 个人配置已保留）并已重启后台守护。"
                self.refreshStatus()
            }
        }
    }

    public func rollbackToPreviousVersion() {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        statusMessage = "正在回滚到上一备份版本..."

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let runtime = Self.detectNodeRuntime() else {
                await MainActor.run {
                    self?.isBusy = false
                    self?.statusMessage = nil
                    self?.lastError = "未检测到可用的 Node 运行时。"
                }
                return
            }
            let installDir = Self.installDirURL
            let scriptPath = installDir.appendingPathComponent("install.mjs").path
            let res = Self.runScript(
                runtime: runtime,
                scriptPath: scriptPath,
                args: ["rollback", "--target-dir", installDir.path],
                cwd: installDir.path
            )
            if res.exitCode == 0 {
                Self.patchLaunchAgentIfEmbeddedNode(runtime: runtime)
            }

            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                if res.exitCode == 0 {
                    self.statusMessage = "已成功回滚至上一版本。"
                } else {
                    self.statusMessage = nil
                    self.lastError = "回滚失败：\(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                self.refreshStatus()
            }
        }
    }

    public func uninstallPlugin() {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        statusMessage = "正在停止守护进程并清理扩展..."

        Task.detached(priority: .userInitiated) { [weak self] in
            let installDir = Self.installDirURL
            let scriptPath = installDir.appendingPathComponent("install.mjs").path
            if let runtime = Self.detectNodeRuntime(),
               FileManager.default.fileExists(atPath: scriptPath) {
                _ = Self.runScript(
                    runtime: runtime,
                    scriptPath: scriptPath,
                    args: ["uninstall", "--target-dir", installDir.path],
                    cwd: installDir.path
                )
            }

            let fm = FileManager.default
            for item in ["bin", "core", "core.prev", "backups", "install.mjs", "package.json", "LICENSE", "README.md", "SKILL.md"] {
                try? fm.removeItem(at: installDir.appendingPathComponent(item))
            }

            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.updateAvailable = false
                self.canSyncMain = false
                self.statusMessage = "已卸载 antigravity-codex-theme 并恢复原生界面样式（个人配置保留在 user/）。"
                self.refreshStatus()
            }
        }
    }

    public func updateConfig(_ mutate: (inout CodexThemeUserConfig) -> Void) {
        var next = config
        mutate(&next)
        config = next
        lastError = nil

        let targetURL = Self.userConfigURL
        Task.detached(priority: .userInitiated) {
            Self.saveUserConfigSync(next, to: targetURL)
        }
    }

    public func openInstallFolder() {
        let dir = Self.installDirURL
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.open(dir)
        } else {
            NSWorkspace.shared.open(dir.deletingLastPathComponent())
        }
    }

    public func openGitHubRepo() {
        if let url = URL(string: Self.repoURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Runtime Discovery & Script Runner (nonisolated)

    public nonisolated static func detectNodeRuntime() -> NodeRuntimeInfo? {
        let fm = FileManager.default
        var candidates: [String] = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        if let pathFromWhich = runQuickOutput(
            executable: "/usr/bin/which",
            arguments: ["node"],
            extraEnv: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pathFromWhich.isEmpty,
           !candidates.contains(pathFromWhich) {
            candidates.insert(pathFromWhich, at: 0)
        }

        for path in candidates where fm.isExecutableFile(atPath: path) {
            if let ver = runQuickOutput(executable: path, arguments: ["-v"], extraEnv: [:])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               isSupportedNodeVersion(ver) {
                return NodeRuntimeInfo(
                    executablePath: path,
                    underlyingBinaryPath: path,
                    version: ver,
                    isEmbeddedAntigravityElectron: false
                )
            }
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let embeddedCandidates = [
            "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            "\(home)/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            "/Applications/Antigravity - Insiders.app/Contents/MacOS/Antigravity - Insiders",
            "\(home)/Applications/Antigravity - Insiders.app/Contents/MacOS/Antigravity - Insiders"
        ]
        for path in embeddedCandidates where fm.isExecutableFile(atPath: path) {
            if let ver = runQuickOutput(
                executable: path,
                arguments: ["-v"],
                extraEnv: ["ELECTRON_RUN_AS_NODE": "1"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
               isSupportedNodeVersion(ver) {
                let shimPath = ensureEmbeddedNodeShim() ?? path
                return NodeRuntimeInfo(
                    executablePath: shimPath,
                    underlyingBinaryPath: path,
                    version: ver,
                    isEmbeddedAntigravityElectron: true
                )
            }
        }

        return nil
    }

    private nonisolated static func isSupportedNodeVersion(_ raw: String) -> Bool {
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n\r\t"))
        let parts = clean.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        if parts[0] > 22 { return true }
        if parts[0] == 22 { return parts[1] >= 13 }
        return false
    }

    private nonisolated static func compareSemver(_ a: String, _ b: String) -> Int {
        let pa = a.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").compactMap { Int($0) }
        let pb = b.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").compactMap { Int($0) }
        for i in 0..<3 {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb ? 1 : -1 }
        }
        return 0
    }

    private nonisolated static func runQuickExitCode(
        executable: String,
        arguments: [String],
        extraEnv: [String: String] = [:]
    ) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv {
            env[k] = v
        }
        task.environment = env
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }

    private nonisolated static func runQuickOutput(
        executable: String,
        arguments: [String],
        extraEnv: [String: String]
    ) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv {
            env[k] = v
        }
        task.environment = env
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func runScript(
        runtime: NodeRuntimeInfo,
        scriptPath: String,
        args: [String],
        cwd: String?
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let execPath: String
        if runtime.isEmbeddedAntigravityElectron {
            execPath = ensureEmbeddedNodeShim() ?? runtime.executablePath
        } else {
            execPath = runtime.executablePath
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: execPath)
        task.arguments = ["--disable-warning=ExperimentalWarning", scriptPath] + args
        if let cwd, !cwd.isEmpty {
            task.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        if runtime.isEmbeddedAntigravityElectron {
            env["ELECTRON_RUN_AS_NODE"] = "1"
            env["SYSPULSE_EMBEDDED_NODE_BIN"] = runtime.underlyingBinaryPath
        }
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return (
            task.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private nonisolated static func launchAgentNeedsEmbeddedHeal() -> Bool {
        let plistURL = launchAgentPlistURL
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return false
        }
        let progArgs = (dict["ProgramArguments"] as? [String]) ?? []
        let shimPath = embeddedNodeShimURL.path
        if progArgs.first != shimPath || !FileManager.default.isExecutableFile(atPath: shimPath) {
            return true
        }
        if let expectedPreload = preloadScriptContent.data(using: .utf8) {
            let currentPreload = try? Data(contentsOf: embeddedNodePreloadURL)
            if currentPreload != expectedPreload {
                return true
            }
        }
        if let srcShim = resolveBundledNodeShim(),
           let srcBytes = try? Data(contentsOf: srcShim),
           (try? Data(contentsOf: embeddedNodeShimURL)) != srcBytes {
            return true
        }
        let uid = getuid()
        if runQuickExitCode(executable: "/bin/launchctl", arguments: ["print", "gui/\(uid)/com.antigravity.codex-theme"]) != 0 {
            return true
        }
        return false
    }

    private nonisolated static func patchLaunchAgentIfEmbeddedNode(runtime: NodeRuntimeInfo) {
        guard runtime.isEmbeddedAntigravityElectron else { return }
        let plistURL = launchAgentPlistURL
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              var dict = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil) as? [String: Any] else {
            return
        }

        if let shimPath = ensureEmbeddedNodeShim() {
            var progArgs = (dict["ProgramArguments"] as? [String]) ?? []
            if !progArgs.isEmpty {
                progArgs[0] = shimPath
            } else {
                progArgs = [shimPath]
            }
            dict["ProgramArguments"] = progArgs
        }

        var envVars = (dict["EnvironmentVariables"] as? [String: Any]) ?? [:]
        envVars["ELECTRON_RUN_AS_NODE"] = "1"
        envVars["SYSPULSE_EMBEDDED_NODE_BIN"] = runtime.underlyingBinaryPath
        dict["EnvironmentVariables"] = envVars

        guard let updatedData = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return
        }
        try? updatedData.write(to: plistURL, options: .atomic)

        let uid = getuid()
        let serviceTarget = "gui/\(uid)/com.antigravity.codex-theme"
        _ = runQuickExitCode(executable: "/bin/launchctl", arguments: ["bootout", serviceTarget])

        for _ in 0..<15 {
            if runQuickExitCode(executable: "/bin/launchctl", arguments: ["print", serviceTarget]) != 0 {
                break
            }
            usleep(150_000)
        }

        for _ in 0..<5 {
            if runQuickExitCode(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plistURL.path]) == 0 {
                break
            }
            usleep(250_000)
        }

        _ = runQuickExitCode(executable: "/bin/launchctl", arguments: ["kickstart", "-k", serviceTarget])
        usleep(300_000)
    }

    // MARK: - Config & JSON Parsers (nonisolated)

    private nonisolated static func readPackageVersion(at dir: URL?) -> String? {
        guard let dir else { return nil }
        let pkgURL = dir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ver = obj["version"] as? String else {
            return nil
        }
        return ver.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func loadUserConfigSync(from url: URL) -> CodexThemeUserConfig? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var cfg = CodexThemeUserConfig()
        if let enabled = root["enabled"] as? Bool { cfg.enabled = enabled }
        if let presetRaw = root["preset"] as? String,
           let preset = CodexThemePreset(rawValue: presetRaw) {
            cfg.preset = preset
        }
        if let layout = root["telemetryLayout"] as? String,
           layout == "compact" || layout == "detailed" {
            cfg.telemetryLayout = layout
        }
        if let modules = root["modules"] as? [String: Any] {
            if let v = modules["theme"] as? Bool { cfg.moduleTheme = v }
            if let v = modules["i18n"] as? Bool { cfg.moduleI18n = v }
            if let v = modules["metrics"] as? Bool { cfg.moduleMetrics = v }
            if let v = modules["quota"] as? Bool { cfg.moduleQuota = v }
            if let v = modules["quotaSidebar"] as? Bool { cfg.moduleQuotaSidebar = v }
            if let v = modules["deadlockHealer"] as? Bool { cfg.moduleDeadlockHealer = v }
            if let v = modules["zoomShortcuts"] as? Bool { cfg.moduleZoomShortcuts = v }
            if let v = modules["promptSuggestions"] as? Bool { cfg.modulePromptSuggestions = v }
            if let v = modules["cdpAutoRelaunch"] as? Bool { cfg.moduleCdpAutoRelaunch = v }
            let customCss = modules["customCss"] as? Bool
            let customJs = modules["customJs"] as? Bool
            if customCss != nil || customJs != nil {
                cfg.moduleCustomAssets = (customCss ?? true) || (customJs ?? true)
            }
        }
        return cfg
    }

    private nonisolated static func saveUserConfigSync(_ cfg: CodexThemeUserConfig, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: url),
           let existingObj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            root = existingObj
        } else if let bundledDefaultsURL = resolveBundledPluginDir()?.appendingPathComponent("user/config.json"),
                  let bundledData = try? Data(contentsOf: bundledDefaultsURL),
                  let bundledObj = try? JSONSerialization.jsonObject(with: bundledData) as? [String: Any] {
            root = bundledObj
        }

        root["enabled"] = cfg.enabled
        root["preset"] = cfg.preset.rawValue
        root["telemetryLayout"] = cfg.telemetryLayout

        var modules = (root["modules"] as? [String: Any]) ?? [:]
        modules["theme"] = cfg.moduleTheme
        modules["i18n"] = cfg.moduleI18n
        modules["metrics"] = cfg.moduleMetrics
        modules["quota"] = cfg.moduleQuota
        modules["quotaSidebar"] = cfg.moduleQuotaSidebar
        modules["deadlockHealer"] = cfg.moduleDeadlockHealer
        modules["zoomShortcuts"] = cfg.moduleZoomShortcuts
        modules["promptSuggestions"] = cfg.modulePromptSuggestions
        modules["cdpAutoRelaunch"] = cfg.moduleCdpAutoRelaunch
        modules["customCss"] = cfg.moduleCustomAssets
        modules["customJs"] = cfg.moduleCustomAssets
        root["modules"] = modules

        if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? outData.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func parseJSONDict(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start <= end {
            let sub = String(trimmed[start...end])
            if let data = sub.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    private nonisolated static func parseDoctorOutput(_ raw: String) -> CodexDoctorSnapshot? {
        guard let root = parseJSONDict(raw) else { return nil }
        let ok = (root["ok"] as? Bool) ?? false
        let daemon = root["daemon"] as? [String: Any]
        let runningCount = (daemon?["runningCount"] as? Int) ?? 0
        let ag = root["antigravity"] as? [String: Any]
        let cdp = (ag?["cdpStatus"] as? String) ?? "unknown"
        let appVer = ag?["appVersion"] as? String
        let integrity = root["coreIntegrity"] as? [String: Any]
        let clean = (integrity?["clean"] as? Bool) ?? true
        return CodexDoctorSnapshot(
            ok: ok,
            daemonRunning: runningCount > 0,
            daemonPidCount: runningCount,
            cdpStatus: cdp,
            appVersion: appVer,
            coreIntegrityOK: clean
        )
    }
}
