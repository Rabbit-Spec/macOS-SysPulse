import Foundation
import AppKit
import CoreBluetooth
import CoreServices
import UserNotifications
import ServiceManagement
import Observation
import LocalAuthentication

@MainActor
private final class BluetoothAuthorizationRequester: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let onComplete: @MainActor () -> Void

    init(onComplete: @escaping @MainActor () -> Void) {
        self.onComplete = onComplete
        super.init()
        self.manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.manager = nil
            self.onComplete()
        }
    }
}

@Observable
@MainActor
public final class SystemPermissionManager {
    public static let shared = SystemPermissionManager()

    public enum PermissionStatus: Sendable {
        case authorized
        case notDetermined
        case denied

        public var title: String {
            switch self {
            case .authorized: return "已开启"
            case .notDetermined: return "待开启"
            case .denied: return "未开启"
            }
        }

        public var isAuthorized: Bool { self == .authorized }
    }

    public private(set) var fullDiskAccessStatus: PermissionStatus = .notDetermined
    public private(set) var bluetoothStatus: PermissionStatus = .notDetermined
    public private(set) var notificationStatus: PermissionStatus = .notDetermined
    public private(set) var automationStatus: PermissionStatus = .notDetermined
    public private(set) var fanHelperStatus: PermissionStatus = .notDetermined
    public private(set) var optimizerHelperStatus: PermissionStatus = .notDetermined
    public private(set) var launchAtLoginStatus: PermissionStatus = .notDetermined

    public var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .authorized
    }

    public nonisolated static let installedHelperPath = "/Library/Application Support/SysPulse/SysPulseUPSHelper"
    public nonisolated static let requiredHelperVersion = 2
    public nonisolated static let installedOptimizeHelperPath = "/Library/Application Support/SysPulse/SysPulseOptimizeHelper"
    public nonisolated static let requiredOptimizeHelperVersion = 1
    public nonisolated static let installedPrivilegedHelperPath = "/Library/Application Support/SysPulse/SysPulsePrivilegedHelper"
    public nonisolated static let requiredPrivilegedHelperVersion = 2
    private static let launchAtLoginPrefKey = "SP_LaunchAtLogin_Preferred"

    private var pollTask: Task<Void, Never>? = nil
    private var bluetoothRequester: BluetoothAuthorizationRequester? = nil

    private init() {
        checkAllPermissions()
        applyDefaultLaunchAtLoginIfNeeded()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            if Self.upgradeExistingHelpersSilentlyIfPossible() {
                Task { @MainActor [weak self] in
                    self?.checkFanHelperPermission()
                    self?.checkOptimizerHelperPermission()
                }
            }
        }

        // 监听应用回到前台/激活通知，用户在系统设置中调整权限切回后立即刷新状态
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAllPermissions()
            }
        }
    }

    public func checkAllPermissions() {
        checkFullDiskAccess()
        checkBluetoothPermission()
        checkNotificationPermission()
        checkAutomationPermission()
        checkFanHelperPermission()
        checkOptimizerHelperPermission()
        checkLaunchAtLoginPermission()
    }

    // MARK: - Bluetooth Privacy Authorization

    public func checkBluetoothPermission() {
        switch CBCentralManager.authorization {
        case .allowedAlways:
            bluetoothStatus = .authorized
        case .denied, .restricted:
            bluetoothStatus = .denied
        case .notDetermined:
            bluetoothStatus = .notDetermined
        @unknown default:
            bluetoothStatus = .notDetermined
        }
    }

    public func requestBluetoothPermission() {
        if CBCentralManager.authorization == .notDetermined {
            bluetoothRequester = BluetoothAuthorizationRequester { [weak self] in
                guard let self else { return }
                self.checkBluetoothPermission()
                self.bluetoothRequester = nil
                if self.bluetoothStatus == .denied {
                    self.openBluetoothSettings()
                }
            }
        } else {
            openBluetoothSettings()
        }
    }

    public func openBluetoothSettings(expectAuthorized: Bool = true) {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkBluetoothPermission()
            return expectAuthorized ? self.bluetoothStatus.isAuthorized : !self.bluetoothStatus.isAuthorized
        }
    }

    // MARK: - Launch at Login

    public func checkLaunchAtLoginPermission() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginStatus = .authorized
        case .requiresApproval:
            launchAtLoginStatus = .denied
        case .notRegistered, .notFound:
            launchAtLoginStatus = .notDetermined
        @unknown default:
            launchAtLoginStatus = .notDetermined
        }
    }

    public func requestLaunchAtLoginPermission() {
        setLaunchAtLogin(true)
    }

    private func applyDefaultLaunchAtLoginIfNeeded() {
        let preferred = UserDefaults.standard.object(forKey: Self.launchAtLoginPrefKey) as? Bool ?? true
        if preferred && SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
            checkLaunchAtLoginPermission()
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginPrefKey)
        if enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // 若注册失败或需用户在系统设置登录项中手动确认，将在下方打开系统设置引导授权
            }
            checkLaunchAtLoginPermission()
            if launchAtLoginStatus != .authorized {
                openLoginItemsSettings()
            }
        } else {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                openLoginItemsSettings()
            }
            checkLaunchAtLoginPermission()
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkLaunchAtLoginPermission()
            return self.launchAtLoginStatus.isAuthorized
        }
    }

    // MARK: - Fan Helper Privileged Authorization

    public func checkFanHelperPermission() {
        guard Self.hasValidHelperBinaryAttributes() else {
            fanHelperStatus = .notDetermined
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = Self.checkInstalledFanHelperStatus()
            Task { @MainActor [weak self] in
                self?.fanHelperStatus = status
            }
        }
    }

    public func requestFanHelperPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded = Self.installPrivilegedHelper(
                additionalFanPercent: nil,
                touchIDReason: "开启风扇控制权限"
            )
            let fanStatus = Self.checkInstalledFanHelperStatus()
            let optStatus = Self.checkInstalledOptimizeHelperStatus()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fanHelperStatus = fanStatus
                self.optimizerHelperStatus = optStatus
                if succeeded && fanStatus == .authorized {
                    FanController.shared.syncAuthorizationGranted()
                }
            }
        }
    }

    public func revokeFanHelperPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded = Self.uninstallPrivilegedHelper()
            let updatedStatus = Self.checkInstalledFanHelperStatus()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fanHelperStatus = updatedStatus
                if succeeded || updatedStatus != .authorized {
                    FanController.shared.syncAuthorizationRevoked()
                }
            }
        }
    }

    private nonisolated static func hasValidHelperBinaryAttributes() -> Bool {
        hasValidHelperBinaryAttributes(at: installedHelperPath)
    }

    public nonisolated static func checkInstalledFanHelperStatus() -> PermissionStatus {
        checkSetuidHelperStatus(at: installedHelperPath, requiredVersion: requiredHelperVersion)
    }

    public nonisolated static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public nonisolated static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public nonisolated static func resolveBundledHelperPath(_ binaryName: String) -> String? {
        let candidates: [String] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(binaryName)").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(binaryName).path ?? "",
            "/Applications/SysPulse.app/Contents/MacOS/\(binaryName)"
        ]
        for path in candidates where !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private nonisolated static func stageBundledHelpersToTempMacOSDir(names: [String]) -> (rootDir: URL, macOSDir: URL)? {
        let rootDir = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("syspulse_stage_\(UUID().uuidString)", isDirectory: true)
        let contentsDir = rootDir.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contentsDir.appendingPathComponent("MacOS", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootDir.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contentsDir.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOSDir.path)
            var copied = 0
            for name in names {
                guard let src = resolveBundledHelperPath(name) else { continue }
                let dst = macOSDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                try fm.copyItem(at: URL(fileURLWithPath: src), to: dst)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
                copied += 1
            }
            guard copied > 0 else {
                try? fm.removeItem(at: rootDir)
                return nil
            }
            return (rootDir, macOSDir)
        } catch {
            try? fm.removeItem(at: rootDir)
            return nil
        }
    }

    private nonisolated static func stageSingleBundledHelperToTemp(_ binaryName: String) -> (rootDir: URL, fileURL: URL)? {
        guard let src = resolveBundledHelperPath(binaryName) else { return nil }
        let rootDir = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("syspulse_stage_\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootDir.appendingPathComponent(binaryName)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: rootDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootDir.path)
            try fm.copyItem(at: URL(fileURLWithPath: src), to: fileURL)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
            return (rootDir, fileURL)
        } catch {
            try? fm.removeItem(at: rootDir)
            return nil
        }
    }

    /// 生成一次授权安装全套 setuid 助手（UPS/风扇、系统优化、统一 Touch ID 特权助手）的 Shell 命令。
    /// 无论用户最初从哪一个模块给出管理员密码，都会同时部署三件套，让后续所有模块自动切换至 Touch ID 或静默执行。
    public nonisolated static func installAllHelpersShellSnippet(fromMacOSDir macOSDir: String? = nil, trailingCommand: String? = nil) -> String? {
        let installedDir = "/Library/Application Support/SysPulse"
        let qDir = shellSingleQuoted(installedDir)
        var segments = [
            "mkdir -p \(qDir)",
            "chown root:wheel \(qDir)",
            "chmod 755 \(qDir)"
        ]

        let helperPairs: [(name: String, dest: String)] = [
            ("SysPulseUPSHelper", installedHelperPath),
            ("SysPulseOptimizeHelper", installedOptimizeHelperPath),
            ("SysPulsePrivilegedHelper", installedPrivilegedHelperPath)
        ]

        var copiedAny = false
        for pair in helperPairs {
            let src: String?
            if let macOSDir {
                let candidate = URL(fileURLWithPath: macOSDir).appendingPathComponent(pair.name).path
                src = FileManager.default.isExecutableFile(atPath: candidate) ? candidate : resolveBundledHelperPath(pair.name)
            } else {
                src = resolveBundledHelperPath(pair.name)
            }
            guard let resolvedSrc = src else { continue }
            let qSrc = shellSingleQuoted(resolvedSrc)
            let qDst = shellSingleQuoted(pair.dest)
            segments.append("cp -f \(qSrc) \(qDst)")
            segments.append("chown root:wheel \(qDst)")
            segments.append("chmod 4755 \(qDst)")
            copiedAny = true
        }

        guard copiedAny else { return nil }
        if let trailingCommand, !trailingCommand.isEmpty {
            segments.append(trailingCommand)
        }
        return segments.joined(separator: " && ")
    }

    private nonisolated static func runBootstrapAllHelpers(trailingCommand: String? = nil) -> (succeeded: Bool, stdout: String, stderr: String, exitCode: Int32, errorMessage: String?) {
        let names = ["SysPulseUPSHelper", "SysPulseOptimizeHelper", "SysPulsePrivilegedHelper"]
        let staged = stageBundledHelpersToTempMacOSDir(names: names)
        defer {
            if let staged {
                try? FileManager.default.removeItem(at: staged.rootDir)
            }
        }
        guard let shellCmd = installAllHelpersShellSnippet(fromMacOSDir: staged?.macOSDir.path, trailingCommand: trailingCommand) else {
            return (false, "", "", -1, "找不到内置权限组件，请重新安装 SysPulse.app")
        }
        return runPrivilegedShellWithOutput(shellCmd)
    }

    public nonisolated static func installPrivilegedHelper(
        additionalFanPercent: Int? = nil,
        touchIDReason: String? = "开启风扇控制权限"
    ) -> Bool {
        _ = upgradeExistingHelpersSilentlyIfPossible()

        if checkInstalledFanHelperStatus() == .authorized {
            if let pct = additionalFanPercent {
                let clamped = max(0, min(100, pct))
                return runSimpleHelper(at: installedHelperPath, args: ["--fan", "\(clamped)"]).succeeded
            }
            return true
        }

        if checkInstalledPrivilegedHelperStatus() == .authorized {
            guard let staged = stageSingleBundledHelperToTemp("SysPulseUPSHelper") else {
                return false
            }
            defer { try? FileManager.default.removeItem(at: staged.rootDir) }

            let installRes = executePrivilegedHelper(
                args: ["--manage-subhelper", "install", "ups", staged.fileURL.path],
                touchIDReason: touchIDReason,
                allowBootstrapPrompt: false
            )
            guard installRes.succeeded else { return false }
            if let pct = additionalFanPercent {
                let clamped = max(0, min(100, pct))
                return runSimpleHelper(at: installedHelperPath, args: ["--fan", "\(clamped)"]).succeeded
            }
            return true
        }

        var trailing: String? = nil
        if let pct = additionalFanPercent {
            let clamped = max(0, min(100, pct))
            trailing = "\(shellSingleQuoted(installedHelperPath)) --fan \(clamped)"
        }
        return runBootstrapAllHelpers(trailingCommand: trailing).succeeded
    }

    public nonisolated static func uninstallPrivilegedHelper() -> Bool {
        guard FileManager.default.fileExists(atPath: installedHelperPath) else { return true }
        return executePrivilegedHelper(
            args: ["--manage-subhelper", "remove", "ups"],
            touchIDReason: "关闭风扇控制权限",
            allowBootstrapPrompt: true
        ).succeeded
    }

    private nonisolated static func runPrivilegedShell(_ shellCmd: String) -> Bool {
        runPrivilegedShellWithOutput(shellCmd).succeeded
    }

    private nonisolated static func runPrivilegedShellWithOutput(_ shellCmd: String) -> (succeeded: Bool, stdout: String, stderr: String, exitCode: Int32, errorMessage: String?) {
        let script = "do shell script \"\(appleScriptEscaped(shellCmd))\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            proc.waitUntilExit()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            if proc.terminationStatus == 0 {
                return (true, stdout, stderr, 0, nil)
            }
            return (false, stdout, stderr, proc.terminationStatus, stderr.isEmpty ? "授权已取消或失败" : stderr)
        } catch {
            return (false, "", error.localizedDescription, -1, error.localizedDescription)
        }
    }

    // MARK: - System Optimizer Privileged Authorization (Zero-Daemon Helper)

    public func checkOptimizerHelperPermission() {
        guard Self.hasValidHelperBinaryAttributes(at: Self.installedOptimizeHelperPath) else {
            optimizerHelperStatus = .notDetermined
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = Self.checkInstalledOptimizeHelperStatus()
            Task { @MainActor [weak self] in
                self?.optimizerHelperStatus = status
            }
        }
    }

    public func requestOptimizerHelperPermission(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded = Self.installOptimizePrivilegedHelper(touchIDReason: "开启系统优化权限")
            let updatedStatus = Self.checkInstalledOptimizeHelperStatus()
            let fanStatus = Self.checkInstalledFanHelperStatus()
            Task { @MainActor [weak self] in
                guard let self else {
                    completion?(false)
                    return
                }
                self.optimizerHelperStatus = updatedStatus
                self.fanHelperStatus = fanStatus
                let ok = succeeded && (updatedStatus == .authorized)
                if ok {
                    SystemOptimizerEngine.shared.syncPermanentAuthorizationGranted()
                }
                completion?(ok)
            }
        }
    }

    public func revokeOptimizerHelperPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded = Self.uninstallOptimizePrivilegedHelper()
            let updatedStatus = Self.checkInstalledOptimizeHelperStatus()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.optimizerHelperStatus = updatedStatus
                if succeeded || updatedStatus != .authorized {
                    SystemOptimizerEngine.shared.syncPermanentAuthorizationRevoked()
                }
            }
        }
    }

    private nonisolated static func hasValidHelperBinaryAttributes(at path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return owner.intValue == 0 && (perms.intValue & 0o4000) != 0
    }

    private nonisolated static func checkSetuidHelperStatus(at path: String, requiredVersion: Int) -> PermissionStatus {
        guard hasValidHelperBinaryAttributes(at: path) else {
            return .notDetermined
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return .notDetermined }
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let ver = Int(output), ver >= requiredVersion {
                return .authorized
            }
        } catch {
            return .notDetermined
        }
        return .notDetermined
    }

    public nonisolated static func checkInstalledOptimizeHelperStatus() -> PermissionStatus {
        checkSetuidHelperStatus(at: installedOptimizeHelperPath, requiredVersion: requiredOptimizeHelperVersion)
    }

    public nonisolated static func checkInstalledPrivilegedHelperStatus() -> PermissionStatus {
        checkSetuidHelperStatus(at: installedPrivilegedHelperPath, requiredVersion: requiredPrivilegedHelperVersion)
    }

    public nonisolated static var areAllHelpersUpToDate: Bool {
        checkInstalledFanHelperStatus() == .authorized
            && checkInstalledOptimizeHelperStatus() == .authorized
            && checkInstalledPrivilegedHelperStatus() == .authorized
    }

    @discardableResult
    public nonisolated static func upgradeExistingHelpersSilentlyIfPossible() -> Bool {
        guard hasValidHelperBinaryAttributes(at: installedPrivilegedHelperPath) else {
            return false
        }
        let fm = FileManager.default
        var namesToUpgrade: [String] = []
        if checkInstalledPrivilegedHelperStatus() != .authorized {
            namesToUpgrade.append("SysPulsePrivilegedHelper")
        }
        if fm.fileExists(atPath: installedHelperPath) && checkInstalledFanHelperStatus() != .authorized {
            namesToUpgrade.append("SysPulseUPSHelper")
        }
        if fm.fileExists(atPath: installedOptimizeHelperPath) && checkInstalledOptimizeHelperStatus() != .authorized {
            namesToUpgrade.append("SysPulseOptimizeHelper")
        }
        guard !namesToUpgrade.isEmpty else {
            return true
        }
        guard let staged = stageBundledHelpersToTempMacOSDir(names: namesToUpgrade) else {
            return false
        }
        defer { try? fm.removeItem(at: staged.rootDir) }
        return runSimpleHelper(
            at: installedPrivilegedHelperPath,
            args: ["--upgrade-helpers", staged.macOSDir.path]
        ).succeeded
    }

    public nonisolated static func installOptimizePrivilegedHelper(
        touchIDReason: String? = "开启系统优化权限"
    ) -> Bool {
        _ = upgradeExistingHelpersSilentlyIfPossible()

        if checkInstalledOptimizeHelperStatus() == .authorized {
            return true
        }

        if checkInstalledPrivilegedHelperStatus() == .authorized {
            guard let staged = stageSingleBundledHelperToTemp("SysPulseOptimizeHelper") else {
                return false
            }
            defer { try? FileManager.default.removeItem(at: staged.rootDir) }
            return executePrivilegedHelper(
                args: ["--manage-subhelper", "install", "optimize", staged.fileURL.path],
                touchIDReason: touchIDReason,
                allowBootstrapPrompt: false
            ).succeeded
        }

        return runBootstrapAllHelpers().succeeded
    }

    public nonisolated static func uninstallOptimizePrivilegedHelper() -> Bool {
        guard FileManager.default.fileExists(atPath: installedOptimizeHelperPath) else { return true }
        return executePrivilegedHelper(
            args: ["--manage-subhelper", "remove", "optimize"],
            touchIDReason: "关闭系统优化权限",
            allowBootstrapPrompt: true
        ).succeeded
    }

    // MARK: - Unified Touch ID & Privileged Execution (v0.1.19+)

    private final class AuthResultBox: @unchecked Sendable {
        var succeeded = false
        var errorMessage: String? = nil
    }

    public nonisolated static func evaluateOwnerAuthentication(reason: String) -> (succeeded: Bool, errorMessage: String?) {
        let context = LAContext()
        var policyError: NSError? = nil
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return (false, policyError?.localizedDescription ?? "当前设备不支持 Touch ID 或系统密码验证")
        }

        let box = AuthResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            box.succeeded = success
            if !success {
                box.errorMessage = error?.localizedDescription ?? "Touch ID / 系统验证已取消"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return (box.succeeded, box.errorMessage)
    }

    private nonisolated static func runSimpleHelper(
        at executablePath: String,
        args: [String]
    ) -> (succeeded: Bool, stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            proc.waitUntilExit()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            return (proc.terminationStatus == 0, stdout, stderr, proc.terminationStatus)
        } catch {
            return (false, "", error.localizedDescription, -1)
        }
    }

    /// **架构规范（v0.1.19+）：SysPulse 当前及未来所有需要管理员特权的功能，必须默认通过本方法接入统一特权助手与 Touch ID 验证通道。**
    ///
    /// 零新增开关策略：只要在任意模块通过一次 macOS 管理员密码授权，SysPulse 即自动部署全套特权助手；
    /// 之后全应用（含未来新增模块）的高权限/破坏性操作默认走 Touch ID / Apple Watch 验证，高频开关操作可直接静默执行。
    public nonisolated static func executePrivilegedHelper(
        args: [String],
        touchIDReason: String? = nil,
        allowBootstrapPrompt: Bool = true
    ) -> (succeeded: Bool, stdout: String, stderr: String, exitCode: Int32, errorMessage: String?) {
        _ = upgradeExistingHelpersSilentlyIfPossible()
        if checkInstalledPrivilegedHelperStatus() == .authorized {
            if let reason = touchIDReason, !reason.isEmpty {
                let auth = evaluateOwnerAuthentication(reason: reason)
                guard auth.succeeded else {
                    return (false, "", "", -2, auth.errorMessage ?? "已取消验证")
                }
            }
            let res = runSimpleHelper(at: installedPrivilegedHelperPath, args: args)
            return (res.succeeded, res.stdout, res.stderr, res.exitCode, res.succeeded ? nil : (res.stderr.isEmpty ? "操作执行失败 (退出码 \(res.exitCode))" : res.stderr))
        }

        guard allowBootstrapPrompt else {
            return (false, "", "", -1, "尚未开启系统管理权限")
        }

        let quotedArgs = args.map { shellSingleQuoted($0) }.joined(separator: " ")
        let trailing = "\(shellSingleQuoted(installedPrivilegedHelperPath)) \(quotedArgs)"
        return runBootstrapAllHelpers(trailingCommand: trailing)
    }

    public nonisolated static func runUnifiedHelperSelfTest() -> String {
        guard let helperPath = resolveBundledHelperPath("SysPulsePrivilegedHelper") else {
            fatalError("Bundled SysPulsePrivilegedHelper missing")
        }
        let verRes = runSimpleHelper(at: helperPath, args: ["--version"])
        let ver = verRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(verRes.succeeded && ver == "\(requiredPrivilegedHelperVersion)", "SysPulsePrivilegedHelper --version mismatch: \(ver)")

        let guardProc = Process()
        guardProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        guardProc.arguments = ["-c", "\(shellSingleQuoted(helperPath)) --clamshell disable"]
        guardProc.standardOutput = FileHandle.nullDevice
        guardProc.standardError = FileHandle.nullDevice
        try? guardProc.run()
        guardProc.waitUntilExit()
        assert(guardProc.terminationStatus == 77, "SysPulsePrivilegedHelper parent guard expected exit 77, got \(guardProc.terminationStatus)")

        let ctx = LAContext()
        var err: NSError? = nil
        let canOwnerAuth = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        assert(canOwnerAuth, "LAContext deviceOwnerAuthentication unavailable: \(err?.localizedDescription ?? "unknown")")

        return "UnifiedTouchIDHelper=OK(Guard=77, LAContext=\(canOwnerAuth))"
    }

    // MARK: - Automation (Apple Events)

    public func checkAutomationPermission() {
        let targetDesc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let aeDesc = targetDesc.aeDesc else {
            automationStatus = .notDetermined
            return
        }
        let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:
            automationStatus = .authorized
        case OSStatus(errAEEventNotPermitted):
            automationStatus = .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            automationStatus = .notDetermined
        default:
            automationStatus = .notDetermined
        }
    }

    public func requestAutomationPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let targetDesc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            var resultStatus: OSStatus = OSStatus(errAEEventWouldRequireUserConsent)
            if let aeDesc = targetDesc.aeDesc {
                resultStatus = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, true)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkAutomationPermission()
                if resultStatus == OSStatus(errAEEventNotPermitted) || self.automationStatus == .denied {
                    self.openAutomationSettings(expectAuthorized: true)
                }
            }
        }
    }

    // MARK: - Full Disk Access

    public func checkFullDiskAccess() {
        // Genuine TCC-protected directories on macOS that throw EPERM without Full Disk Access
        let tccPaths = [
            NSHomeDirectory() + "/Library/Safari",
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/Library/Suggestions",
            NSHomeDirectory() + "/Library/Messages"
        ]
        var granted = false
        var testedAtLeastOne = false

        for path in tccPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            testedAtLeastOne = true
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                granted = true
                break
            } catch {
                // Access denied or Operation not permitted
                granted = false
            }
        }

        // If none of the specific directories exist, test reading the user's Safari database directly
        if !testedAtLeastOne {
            let fallbackFile = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackFile), options: .mappedIfSafe), !data.isEmpty {
                granted = true
            }
        }

        fullDiskAccessStatus = granted ? .authorized : .denied
    }

    // MARK: - Notifications

    public func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                switch status {
                case .authorized, .provisional:
                    self.notificationStatus = .authorized
                case .notDetermined:
                    self.notificationStatus = .notDetermined
                case .denied:
                    self.notificationStatus = .denied
                @unknown default:
                    self.notificationStatus = .notDetermined
                }
            }
        }
    }

    public func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.notificationStatus = granted ? .authorized : .denied
                if !granted {
                    self.openNotificationSettings(expectAuthorized: true)
                }
            }
        }
    }

    // MARK: - System Settings Redirect + Polling

    public func openFullDiskAccessSettings(expectAuthorized: Bool = true) {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkFullDiskAccess()
            return expectAuthorized ? self.fullDiskAccessStatus.isAuthorized : !self.fullDiskAccessStatus.isAuthorized
        }
    }

    public func openNotificationSettings(expectAuthorized: Bool = true) {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.notifications")
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkNotificationPermission()
            return expectAuthorized ? self.notificationStatus.isAuthorized : !self.notificationStatus.isAuthorized
        }
    }

    public func openAutomationSettings(expectAuthorized: Bool = true) {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkAutomationPermission()
            return expectAuthorized ? self.automationStatus.isAuthorized : !self.automationStatus.isAuthorized
        }
    }

    private func openSettingsURL(_ rawURL: String) {
        if let url = URL(string: rawURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPermissionPoll(_ checkAndShouldStop: @escaping @MainActor () -> Bool) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                if checkAndShouldStop() {
                    break
                }
            }
        }
    }
}
