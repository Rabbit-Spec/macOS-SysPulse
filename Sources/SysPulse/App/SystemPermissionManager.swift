import Foundation
import AppKit
import CoreBluetooth
import CoreServices
import UserNotifications
import ServiceManagement
import Observation

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
            case .authorized: return "已授权"
            case .notDetermined: return "待授权"
            case .denied: return "未授权"
            }
        }

        public var isAuthorized: Bool { self == .authorized }
    }

    public private(set) var fullDiskAccessStatus: PermissionStatus = .notDetermined
    public private(set) var bluetoothStatus: PermissionStatus = .notDetermined
    public private(set) var notificationStatus: PermissionStatus = .notDetermined
    public private(set) var automationStatus: PermissionStatus = .notDetermined
    public private(set) var fanHelperStatus: PermissionStatus = .notDetermined
    public private(set) var launchAtLoginStatus: PermissionStatus = .notDetermined

    public var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .authorized
    }

    public nonisolated static let installedHelperPath = "/Library/Application Support/SysPulse/SysPulseUPSHelper"
    public nonisolated static let requiredHelperVersion = 2
    private static let launchAtLoginPrefKey = "SP_LaunchAtLogin_Preferred"

    private var pollTask: Task<Void, Never>? = nil
    private var bluetoothRequester: BluetoothAuthorizationRequester? = nil

    private init() {
        checkAllPermissions()
        applyDefaultLaunchAtLoginIfNeeded()

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
            let succeeded = Self.installPrivilegedHelper(additionalFanPercent: nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkFanHelperPermission()
                if succeeded {
                    self.fanHelperStatus = .authorized
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
        guard FileManager.default.isExecutableFile(atPath: installedHelperPath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: installedHelperPath),
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return owner.intValue == 0 && (perms.intValue & 0o4000) != 0
    }

    public nonisolated static func checkInstalledFanHelperStatus() -> PermissionStatus {
        guard hasValidHelperBinaryAttributes() else {
            return .notDetermined
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: installedHelperPath)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return .notDetermined }
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let ver = Int(output), ver >= requiredHelperVersion {
                return .authorized
            }
        } catch {
            return .notDetermined
        }
        return .notDetermined
    }

    public nonisolated static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public nonisolated static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public nonisolated static func installPrivilegedHelper(additionalFanPercent: Int? = nil) -> Bool {
        let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SysPulseUPSHelper").path
        let appFallbackPath = "/Applications/SysPulse.app/Contents/MacOS/SysPulseUPSHelper"
        let sourceHelper = FileManager.default.isExecutableFile(atPath: bundledPath) ? bundledPath : appFallbackPath
        guard FileManager.default.isExecutableFile(atPath: sourceHelper) else {
            return false
        }
        let installedDir = "/Library/Application Support/SysPulse"
        let qDir = shellSingleQuoted(installedDir)
        let qSrc = shellSingleQuoted(sourceHelper)
        let qDst = shellSingleQuoted(installedHelperPath)
        var shellCmd = "mkdir -p \(qDir) && chown root:wheel \(qDir) && chmod 755 \(qDir) && cp -f \(qSrc) \(qDst) && chown root:wheel \(qDst) && chmod 4755 \(qDst)"
        if let pct = additionalFanPercent {
            let clamped = max(0, min(100, pct))
            shellCmd += " && \(qDst) --fan \(clamped)"
        }
        return runPrivilegedShell(shellCmd)
    }

    public nonisolated static func uninstallPrivilegedHelper() -> Bool {
        guard FileManager.default.fileExists(atPath: installedHelperPath) else { return true }
        let qDst = shellSingleQuoted(installedHelperPath)
        return runPrivilegedShell("rm -f \(qDst)")
    }

    private nonisolated static func runPrivilegedShell(_ shellCmd: String) -> Bool {
        let script = "do shell script \"\(appleScriptEscaped(shellCmd))\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
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
