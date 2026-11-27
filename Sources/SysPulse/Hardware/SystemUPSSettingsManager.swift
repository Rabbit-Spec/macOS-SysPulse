import Foundation
import Observation
import OSLog
import AppKit

@_silgen_name("IOPMCopyUPSShutdownLevels")
private func PG_IOPMCopyUPSShutdownLevels(_ whichUPS: CFTypeRef) -> Unmanaged<CFDictionary>?

@Observable
@MainActor
public final class SystemUPSSettingsManager {
    public static let shared = SystemUPSSettingsManager()

    private let logger = Logger(subsystem: "com.apple.powerglass", category: "UPSSettings")
    private let syncQueue = DispatchQueue(label: "com.apple.powerglass.upssync", qos: .userInitiated)
    private var isReadingFromSystem = false
    public var hasPendingChanges = false

    public static let validMinuteOptions = [1, 5, 10, 15]
    public static let validPercentOptions = [1, 25, 50, 75, 100]

    // 1. UPS 电池达到以下使用时间后将 Mac 关机 (UPSShutdownAfterMinutes / haltafter)
    public var haltAfterEnabled: Bool = false {
        didSet {
            guard !isReadingFromSystem, oldValue != haltAfterEnabled else { return }
            handleUserModification()
        }
    }
    public var haltAfterMinutes: Int = 15 {
        didSet {
            let snapped = Self.snapToOptions(haltAfterMinutes, options: Self.validMinuteOptions)
            if haltAfterMinutes != snapped {
                haltAfterMinutes = snapped
                return
            }
            guard !isReadingFromSystem, oldValue != haltAfterMinutes else { return }
            handleUserModification()
        }
    }

    // 2. UPS 电池剩余使用时间达到以下时间时将 Mac 关机 (UPSShutdownAtMinutesLeft / haltremain)
    public var haltRemainEnabled: Bool = false {
        didSet {
            guard !isReadingFromSystem, oldValue != haltRemainEnabled else { return }
            handleUserModification()
        }
    }
    public var haltRemainMinutes: Int = 1 {
        didSet {
            let snapped = Self.snapToOptions(haltRemainMinutes, options: Self.validMinuteOptions)
            if haltRemainMinutes != snapped {
                haltRemainMinutes = snapped
                return
            }
            guard !isReadingFromSystem, oldValue != haltRemainMinutes else { return }
            handleUserModification()
        }
    }

    // 3. UPS 电池电量低于以下水平时将 Mac 关机 (UPSShutdownAtLevel / haltlevel)
    public var haltLevelEnabled: Bool = true {
        didSet {
            guard !isReadingFromSystem, oldValue != haltLevelEnabled else { return }
            handleUserModification()
        }
    }
    public var haltLevelPercent: Int = 25 {
        didSet {
            let snapped = Self.snapToOptions(haltLevelPercent, options: Self.validPercentOptions)
            if haltLevelPercent != snapped {
                haltLevelPercent = snapped
                return
            }
            guard !isReadingFromSystem, oldValue != haltLevelPercent else { return }
            handleUserModification()
        }
    }

    // 4. 软件级主动 UPS 断电保护
    public var softwareProtectionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(softwareProtectionEnabled, forKey: "PG_UPS_SoftwareProtectionEnabled")
        }
    }

    /// 触发阈值后的执行动作: "sleep" (立即安全退盘并睡眠) 或 "shutdown" (立即安全退盘并关机)
    public var protectionAction: String = "sleep" {
        didSet {
            UserDefaults.standard.set(protectionAction, forKey: "PG_UPS_ProtectionAction")
        }
    }

    public init() {
        let d = UserDefaults.standard
        if d.object(forKey: "PG_UPS_SoftwareProtectionEnabled") != nil {
            self.softwareProtectionEnabled = d.bool(forKey: "PG_UPS_SoftwareProtectionEnabled")
        }
        if let action = d.string(forKey: "PG_UPS_ProtectionAction") {
            self.protectionAction = action
        }
        if FeatureToggleManager.shared.enablePluginUPSManager {
            readSystemDefaults()
        }
    }

    public func refreshIfEnabled() {
        guard FeatureToggleManager.shared.enablePluginUPSManager else { return }
        readSystemDefaults()
    }

    /// Snaps any integer to the closest allowed discrete option (e.g. [1, 5, 10, 15] or [1, 25, 50, 75, 100]).
    public static func snapToOptions(_ value: Int, options: [Int]) -> Int {
        guard let first = options.first else { return value }
        return options.min(by: { abs($0 - value) < abs($1 - value) }) ?? first
    }

    /// Reads the live macOS UPS shutdown settings directly from IOKit (`IOPMCopyUPSShutdownLevels`),
    /// falling back to local UserDefaults on MacBooks where system UPS thresholds may not be initialized.
    public func readSystemDefaults() {
        isReadingFromSystem = true
        defer { isReadingFromSystem = false }

        let d = UserDefaults.standard
        if let unmanaged = PG_IOPMCopyUPSShutdownLevels("UPSDefaultThresholds" as CFString),
           let dict = unmanaged.takeRetainedValue() as? [String: [String: Any]],
           !dict.isEmpty {

            if let after = dict["UPSShutdownAfterMinutes"] {
                let en = (after["Enabled"] as? Bool) ?? ((after["Enabled"] as? Int ?? 0) != 0)
                let val = (after["Value"] as? Int) ?? 15
                self.haltAfterEnabled = en
                self.haltAfterMinutes = Self.snapToOptions(max(1, val), options: Self.validMinuteOptions)
            }

            if let remain = dict["UPSShutdownAtMinutesLeft"] {
                let en = (remain["Enabled"] as? Bool) ?? ((remain["Enabled"] as? Int ?? 0) != 0)
                let val = (remain["Value"] as? Int) ?? 1
                self.haltRemainEnabled = en
                self.haltRemainMinutes = Self.snapToOptions(max(1, val), options: Self.validMinuteOptions)
            }

            if let level = dict["UPSShutdownAtLevel"] {
                let en = (level["Enabled"] as? Bool) ?? ((level["Enabled"] as? Int ?? 0) != 0)
                let val = (level["Value"] as? Int) ?? 25
                self.haltLevelEnabled = en
                self.haltLevelPercent = Self.snapToOptions(max(1, val), options: Self.validPercentOptions)
            }

            saveLocalFallbackDefaults()
            self.hasPendingChanges = false
        } else if d.object(forKey: "PG_UPS_HaltLevelPercent") != nil {
            self.haltAfterEnabled = d.bool(forKey: "PG_UPS_HaltAfterEnabled")
            self.haltAfterMinutes = Self.snapToOptions(max(1, d.integer(forKey: "PG_UPS_HaltAfterMinutes")), options: Self.validMinuteOptions)
            self.haltRemainEnabled = d.bool(forKey: "PG_UPS_HaltRemainEnabled")
            self.haltRemainMinutes = Self.snapToOptions(max(1, d.integer(forKey: "PG_UPS_HaltRemainMinutes")), options: Self.validMinuteOptions)
            self.haltLevelEnabled = d.bool(forKey: "PG_UPS_HaltLevelEnabled")
            self.haltLevelPercent = Self.snapToOptions(max(1, d.integer(forKey: "PG_UPS_HaltLevelPercent")), options: Self.validPercentOptions)
            self.hasPendingChanges = false
        }
    }

    private func saveLocalFallbackDefaults() {
        let d = UserDefaults.standard
        d.set(haltAfterEnabled, forKey: "PG_UPS_HaltAfterEnabled")
        d.set(haltAfterMinutes, forKey: "PG_UPS_HaltAfterMinutes")
        d.set(haltRemainEnabled, forKey: "PG_UPS_HaltRemainEnabled")
        d.set(haltRemainMinutes, forKey: "PG_UPS_HaltRemainMinutes")
        d.set(haltLevelEnabled, forKey: "PG_UPS_HaltLevelEnabled")
        d.set(haltLevelPercent, forKey: "PG_UPS_HaltLevelPercent")
    }

    private func handleUserModification() {
        saveLocalFallbackDefaults()
        hasPendingChanges = true
        let args = currentHelperArguments()

        syncQueue.async { [weak self] in
            if Self.runInstalledHelperSilently(args: args) {
                Task { @MainActor in
                    self?.hasPendingChanges = false
                }
            }
        }
    }

    /// Commits changes to macOS System UPS settings when clicking "同步写入系统" or "完成" (Done).
    /// If the setuid helper is not yet installed, requests one-time macOS administrator authorization.
    public func commitChangesToSystem(forceAuthorize: Bool = false, completion: @escaping @MainActor @Sendable () -> Void) {
        let args = currentHelperArguments()
        let shouldAuthorize = forceAuthorize || self.hasPendingChanges

        syncQueue.async { [weak self] in
            // 1. Try silent setuid helper first (and silently sync sibling Touch ID helpers if needed)
            if Self.runInstalledHelperSilently(args: args) {
                SystemPermissionManager.upgradeExistingHelpersSilentlyIfPossible()
                Task { @MainActor in
                    self?.hasPendingChanges = false
                    self?.readSystemDefaults()
                    completion()
                }
                return
            }

            // 2. If user made changes and helper needs authorization, authorize via Touch ID / one-time bootstrap
            if shouldAuthorize {
                if SystemPermissionManager.installPrivilegedHelper(
                    additionalFanPercent: nil,
                    touchIDReason: "开启 UPS 关机保护同步权限"
                ) {
                    _ = Self.runInstalledHelperSilently(args: args)
                }
            }

            Task { @MainActor in
                self?.hasPendingChanges = false
                self?.readSystemDefaults()
                completion()
            }
        }
    }

    private func currentHelperArguments() -> [String] {
        return [
            haltAfterEnabled ? "1" : "0",
            "\(haltAfterMinutes)",
            haltRemainEnabled ? "1" : "0",
            "\(haltRemainMinutes)",
            haltLevelEnabled ? "1" : "0",
            "\(haltLevelPercent)"
        ]
    }

    nonisolated private static func runInstalledHelperSilently(args: [String]) -> Bool {
        let paths = [
            "/Library/Application Support/SysPulse/SysPulseUPSHelper",
            "/Library/Application Support/PowerGlass/PowerGlassUPSHelper"
        ]
        guard let installedHelper = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: installedHelper)
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    public func openSystemPreferencesUPS() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension?ups") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(url, configuration: config)
        }
    }
}
