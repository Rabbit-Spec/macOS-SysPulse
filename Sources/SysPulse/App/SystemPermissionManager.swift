import Foundation
import AppKit
import CoreServices
import UserNotifications
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

    private var pollTask: Task<Void, Never>? = nil

    private init() {
        checkAllPermissions()

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
            automationStatus = .authorized
        }
    }

    public func requestAutomationPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let targetDesc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            var resultStatus: OSStatus = noErr
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }

        // 启动连续轮询检测（每秒检测一次，持续 20 秒），确保用户在设置中切换开关时无缝即刻捕获授权状态
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self.checkFullDiskAccess()
                if self.fullDiskAccessStatus == .authorized {
                    break
                }
            }
        }
    }

    public func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
