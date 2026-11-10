import Foundation
import AppKit
import CoreServices
import UserNotifications
import ServiceManagement
import Observation

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
        checkNotificationPermission()
        checkAutomationPermission()
        checkFanHelperPermission()
        checkLaunchAtLoginPermission()
    }

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

    public func checkFanHelperPermission() {
        fanHelperStatus = Self.checkInstalledFanHelperStatus()
    }

    public func requestFanHelperPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded = Self.installPrivilegedHelper(additionalFanPercent: nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if succeeded {
                    self.checkFanHelperPermission()
                    FanController.shared.syncAuthorizationGranted()
                } else {
                    self.fanHelperStatus = .denied
                }
            }
        }
    }

    public nonisolated static func checkInstalledFanHelperStatus() -> PermissionStatus {
        guard FileManager.default.isExecutableFile(atPath: installedHelperPath) else {
            return .notDetermined
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: installedHelperPath),
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber,
              owner.intValue == 0,
              (perms.intValue & 0o4000) != 0 else {
            return .notDetermined
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: installedHelperPath)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return .notDetermined }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let ver = Int(output), ver >= requiredHelperVersion {
                return .authorized
            }
        } catch {
            return .notDetermined
        }
        return .notDetermined
    }

    public nonisolated static func installPrivilegedHelper(additionalFanPercent: Int? = nil) -> Bool {
        let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SysPulseUPSHelper").path
        let fallbackPath = "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/MacOS/SysPulseUPSHelper"
        let sourceHelper = FileManager.default.isExecutableFile(atPath: bundledPath) ? bundledPath : fallbackPath
        guard FileManager.default.isExecutableFile(atPath: sourceHelper) else {
            return false
        }
        let installedDir = "/Library/Application Support/SysPulse"
        var shellCmd = "mkdir -p '\(installedDir)' && cp -f '\(sourceHelper)' '\(installedHelperPath)' && chown root:wheel '\(installedHelperPath)' && chmod 4755 '\(installedHelperPath)'"
        if let pct = additionalFanPercent {
            shellCmd += " && '\(installedHelperPath)' --fan \(pct)"
        }
        let script = "do shell script \"\(shellCmd)\" with administrator privileges"

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
                    self.openAutomationSettings()
                }
            }
        }
    }

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
                    self.openNotificationSettings()
                }
            }
        }
    }

    public func openFullDiskAccessSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkFullDiskAccess()
            return self.fullDiskAccessStatus.isAuthorized
        }
    }

    public func openNotificationSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.notifications")
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkNotificationPermission()
            return self.notificationStatus.isAuthorized
        }
    }

    public func openAutomationSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        startPermissionPoll { [weak self] in
            guard let self else { return true }
            self.checkAutomationPermission()
            return self.automationStatus.isAuthorized
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
