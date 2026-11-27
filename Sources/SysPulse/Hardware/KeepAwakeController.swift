import Foundation
import AppKit
import IOKit.pwr_mgt
import Observation
@preconcurrency import UserNotifications

// MARK: - 保持常亮控制器 (IOKit 电源管理断言)

public enum KeepAwakeBehavior: String, CaseIterable, Identifiable, Sendable {
    case displayOnly = "仅保持屏幕"
    case displayAndLid = "屏幕与任务"
    case taskOnly = "仅保持任务"

    public var id: String { rawValue }

    public var detailText: String {
        switch self {
        case .displayOnly:
            return "屏幕保持点亮，合盖后按系统设置休眠"
        case .displayAndLid:
            return "屏幕保持点亮，合盖后任务也继续运行"
        case .taskOnly:
            return "屏幕可以熄灭，合盖后仍让任务继续运行"
        }
    }
}

public enum KeepAwakeDuration: String, CaseIterable, Identifiable, Sendable {
    case indefinitely = "持续"
    case minutes15 = "15 分钟"
    case minutes30 = "30 分钟"
    case oneHour = "1 小时"
    case twoHours = "2 小时"
    case fourHours = "4 小时"
    case eightHours = "8 小时"
    case twelveHours = "12 小时"

    public var id: String { rawValue }

    public var seconds: TimeInterval? {
        switch self {
        case .indefinitely: return nil
        case .minutes15: return 900
        case .minutes30: return 1800
        case .oneHour: return 3600
        case .twoHours: return 7200
        case .fourHours: return 14400
        case .eightHours: return 28800
        case .twelveHours: return 43200
        }
    }
}

@Observable
@MainActor
public final class KeepAwakeController {
    public static let shared = KeepAwakeController()
    public static let clamshellMarkerPath = "/Library/Application Support/SysPulse/syspulse_keepawake_clamshell.state"

    nonisolated private static let enableClamshellShellScript =
        "/bin/mkdir -p '/Library/Application Support/SysPulse' && /usr/bin/pmset -a disablesleep 1 && /usr/bin/printf '1\\n' > '/Library/Application Support/SysPulse/syspulse_keepawake_clamshell.state'"
    nonisolated private static let disableClamshellShellScript =
        "/bin/rm -f '/Library/Application Support/SysPulse/syspulse_keepawake_clamshell.state' && /usr/bin/pmset -a disablesleep 0"
    nonisolated private static let removeMarkerOnlyShellScript =
        "/bin/rm -f '/Library/Application Support/SysPulse/syspulse_keepawake_clamshell.state'"

    public private(set) var isActive: Bool = false
    public private(set) var currentBehavior: KeepAwakeBehavior = .displayOnly
    public private(set) var currentDuration: KeepAwakeDuration = .indefinitely
    public private(set) var sessionEndsAt: Date? = nil
    public private(set) var remainingSeconds: TimeInterval = 0
    public private(set) var isPausedDueToLowBattery: Bool = false
    public private(set) var isClamshellKeepAwakeActive: Bool = false
    public private(set) var clamshellErrorMessage: String? = nil

    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var tickTimer: Timer?
    private var clamshellWatchdogTimer: Timer?
    private var clamshellOpInFlight: Bool = false

    private init() {
        observePowerSource()
    }

    private var needsClamshellLock: Bool {
        MacHardwareInfo.shared.isLaptop
            && isActive
            && !isPausedDueToLowBattery
            && (currentBehavior == .displayAndLid || currentBehavior == .taskOnly)
    }

    // MARK: - Core Operations

    /// 开启保持常亮
    public func activate(duration: KeepAwakeDuration = .indefinitely, behavior: KeepAwakeBehavior? = nil) {
        if let behavior {
            self.currentBehavior = behavior
        }
        self.currentDuration = duration
        self.isPausedDueToLowBattery = false
        self.clamshellErrorMessage = nil

        if let secs = duration.seconds {
            self.sessionEndsAt = Date().addingTimeInterval(secs)
            self.remainingSeconds = secs
        } else {
            self.sessionEndsAt = nil
            self.remainingSeconds = 0
        }

        applyAssertions()
        self.isActive = true
        if needsClamshellLock {
            applyClamshellIfNeeded(allowPrompt: true)
        } else {
            releaseClamshellIfNeeded(allowPrompt: false)
        }
        startTimer()
        sendNotification(title: "常亮已开启", body: startNotificationBody)
    }

    /// 停止常亮
    public func deactivate(notify: Bool = true) {
        releaseAssertions()
        self.isActive = false
        self.sessionEndsAt = nil
        self.remainingSeconds = 0
        self.isPausedDueToLowBattery = false
        releaseClamshellIfNeeded(allowPrompt: true)
        stopTimer()

        if notify {
            sendNotification(title: "保持常亮已关闭", body: "保持常亮已关闭，恢复正常睡眠。")
        }
    }

    /// 切换常亮模式（如从 仅保持屏幕 切换为 屏幕与任务）
    public func setBehavior(_ behavior: KeepAwakeBehavior) {
        self.currentBehavior = behavior
        if isActive && !isPausedDueToLowBattery {
            applyAssertions()
            if needsClamshellLock {
                applyClamshellIfNeeded(allowPrompt: true)
            } else {
                releaseClamshellIfNeeded(allowPrompt: true)
            }
        } else {
            releaseClamshellIfNeeded(allowPrompt: true)
        }
    }

    /// 切换常亮持续时长
    public func setDuration(_ duration: KeepAwakeDuration) {
        if isActive {
            activate(duration: duration, behavior: currentBehavior)
        } else {
            self.currentDuration = duration
        }
    }

    /// 切换常亮开关状态
    public func toggle(duration: KeepAwakeDuration = .indefinitely) {
        if isActive {
            deactivate()
        } else {
            activate(duration: duration)
        }
    }

    // MARK: - Formatted Status Texts

    public var remainingFormattedText: String {
        guard isActive else { return "未开启" }
        if currentDuration == .indefinitely || sessionEndsAt == nil {
            return "持续中"
        }
        let mins = Int(ceil(remainingSeconds / 60.0))
        if mins < 60 {
            return "剩余 \(max(1, mins))分钟"
        }
        let hours = mins / 60
        let remMins = mins % 60
        if remMins == 0 {
            return "剩余 \(hours)小时"
        }
        return "剩余 \(hours)小时\(remMins)分"
    }

    public var summaryStatusText: String {
        if !isActive { return "已关闭" }
        if isPausedDueToLowBattery { return "低电量已暂停" }
        if isClamshellKeepAwakeActive {
            return "\(currentBehavior.rawValue) (合盖防休眠) · \(remainingFormattedText)"
        }
        return "\(currentBehavior.rawValue) · \(remainingFormattedText)"
    }

    private var startNotificationBody: String {
        switch currentBehavior {
        case .displayOnly, .displayAndLid:
            if let sessionEndsAt {
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.hour, .minute]
                formatter.unitsStyle = .full
                let dur = formatter.string(from: sessionEndsAt.timeIntervalSinceNow) ?? "\(Int(remainingSeconds / 60)) 分钟"
                return "屏幕会保持点亮 \(dur)。"
            } else {
                return "屏幕会保持点亮，直到手动关闭。"
            }
        case .taskOnly:
            if let sessionEndsAt {
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.hour, .minute]
                formatter.unitsStyle = .full
                let dur = formatter.string(from: sessionEndsAt.timeIntervalSinceNow) ?? "\(Int(remainingSeconds / 60)) 分钟"
                return "任务会继续运行 \(dur)，期间屏幕可以睡眠。"
            } else {
                return "任务会持续运行直到手动关闭，期间屏幕可以睡眠。"
            }
        }
    }

    // MARK: - 低电量自动暂停常亮保护

    private func observePowerSource() {
        PowerSourceEngine.shared.addPowerStateObserver(id: "KeepAwakeController") { [weak self] _ in
            Task { @MainActor in
                self?.evaluateLowBatteryProtection()
            }
        }
    }

    private func evaluateLowBatteryProtection() {
        guard isActive else { return }
        let telemetry = PowerSourceEngine.shared.telemetry
        let isLaptop = SystemResourceMonitor.shared.loadRuntime.hasInternalBattery || telemetry.batteryLevel > 0
        guard isLaptop else { return }

        let isAC = telemetry.state.isAC
        let batteryPct = telemetry.batteryLevel

        if !isAC && batteryPct <= 20 && !isPausedDueToLowBattery {
            // 自动暂停常亮，避免电池耗尽
            releaseAssertions()
            releaseClamshellIfNeeded(allowPrompt: false)
            isPausedDueToLowBattery = true
            sendNotification(
                title: "保持常亮已暂停",
                body: "电量仅剩 \(batteryPct)%，保持常亮已暂停，恢复正常睡眠。"
            )
        } else if isAC && isPausedDueToLowBattery {
            // 接回电源自动恢复
            isPausedDueToLowBattery = false
            applyAssertions()
            if needsClamshellLock {
                applyClamshellIfNeeded(allowPrompt: false)
            }
            sendNotification(
                title: "保持常亮已恢复",
                body: "已接通电源，保持常亮已自动恢复\(sessionEndsAt != nil ? "，还剩 " + remainingFormattedText : "")。"
            )
        }
    }

    // MARK: - IOKit PM Assertions

    private func applyAssertions() {
        releaseAssertions()

        switch currentBehavior {
        case .displayOnly:
            var dId: IOPMAssertionID = 0
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SysPulse Keep Screen On" as CFString,
                &dId
            )
            if res == kIOReturnSuccess {
                displayAssertionID = dId
            }
        case .displayAndLid:
            var dId: IOPMAssertionID = 0
            var sId: IOPMAssertionID = 0
            _ = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SysPulse Keep Screen On" as CFString,
                &dId
            )
            _ = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SysPulse Keep System Awake" as CFString,
                &sId
            )
            displayAssertionID = dId
            systemAssertionID = sId
        case .taskOnly:
            var sId: IOPMAssertionID = 0
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SysPulse Task Background Assertion" as CFString,
                &sId
            )
            if res == kIOReturnSuccess {
                systemAssertionID = sId
            }
        }
    }

    private func releaseAssertions() {
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
    }

    // MARK: - Timer Countdown

    private var isPausedForSleep: Bool = false

    public func pauseForSleep() {
        isPausedForSleep = true
        stopTimer()
        stopClamshellWatchdog()
    }

    public func resumeFromWake() {
        isPausedForSleep = false
        if isActive {
            handleTick()
            if isActive {
                startTimer()
                if isClamshellKeepAwakeActive && needsClamshellLock {
                    verifyClamshellStillEnabledPassively()
                    startClamshellWatchdog()
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        guard !isPausedForSleep else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func handleTick() {
        guard isActive else { return }
        guard let sessionEndsAt else { return }

        let rem = sessionEndsAt.timeIntervalSinceNow
        if rem <= 0 {
            deactivate(notify: true)
        } else {
            self.remainingSeconds = rem
        }
    }

    // MARK: - Clamshell Sleep Prevention (Laptops Only)

    private func applyClamshellIfNeeded(allowPrompt: Bool) {
        guard MacHardwareInfo.shared.isLaptop,
              needsClamshellLock,
              !isClamshellKeepAwakeActive,
              !clamshellOpInFlight else {
            return
        }
        clamshellOpInFlight = true
        clamshellErrorMessage = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            let ok = Self.executePrivilegedShellCommand(
                script: Self.enableClamshellShellScript,
                allowPrompt: allowPrompt
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.clamshellOpInFlight = false
                if ok {
                    if self.needsClamshellLock {
                        self.isClamshellKeepAwakeActive = true
                        self.clamshellErrorMessage = nil
                        self.startClamshellWatchdog()
                    } else {
                        self.isClamshellKeepAwakeActive = true
                        self.releaseClamshellIfNeeded(allowPrompt: false)
                    }
                } else {
                    self.isClamshellKeepAwakeActive = false
                    self.clamshellErrorMessage = "未获得管理员授权，合盖防休眠未生效（仍保持常规防休眠）"
                }
            }
        }
    }

    private func releaseClamshellIfNeeded(allowPrompt: Bool) {
        stopClamshellWatchdog()
        let portalHoldsClamshell = PSPortalPluginManager.shared.isClamshellKeepAwakeActive
        let markerExists = FileManager.default.fileExists(atPath: Self.clamshellMarkerPath)
        guard isClamshellKeepAwakeActive || markerExists else {
            clamshellErrorMessage = nil
            return
        }

        isClamshellKeepAwakeActive = false
        clamshellErrorMessage = nil

        Task.detached(priority: .userInitiated) {
            if portalHoldsClamshell {
                _ = Self.runSudoNoPass(script: Self.removeMarkerOnlyShellScript)
            } else {
                let sudoOk = Self.runSudoNoPass(script: Self.disableClamshellShellScript)
                if !sudoOk && allowPrompt && Self.isSystemSleepDisabledViaPmset() {
                    _ = Self.runOsascriptAdmin(script: Self.disableClamshellShellScript)
                }
            }
        }
    }

    private func startClamshellWatchdog() {
        stopClamshellWatchdog()
        guard MacHardwareInfo.shared.isLaptop,
              isClamshellKeepAwakeActive,
              !isPausedForSleep else {
            return
        }
        let timer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.verifyClamshellStillEnabledPassively()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clamshellWatchdogTimer = timer
    }

    private func stopClamshellWatchdog() {
        clamshellWatchdogTimer?.invalidate()
        clamshellWatchdogTimer = nil
    }

    private func verifyClamshellStillEnabledPassively() {
        guard isClamshellKeepAwakeActive else {
            stopClamshellWatchdog()
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let stillDisabled = Self.isSystemSleepDisabledViaPmset()
            await MainActor.run { [weak self] in
                guard let self, self.isClamshellKeepAwakeActive else { return }
                if !stillDisabled {
                    self.isClamshellKeepAwakeActive = false
                    self.clamshellErrorMessage = "系统睡眠设置已被外部重置，合盖防休眠已暂停"
                    self.stopClamshellWatchdog()
                }
            }
        }
    }

    /// 启动崩溃自愈：仅当遗留状态文件存在且当前无人持锁时，恢复系统默认睡眠设置。
    public func recoverOrphanedClamshellStateOnLaunch() {
        guard FileManager.default.fileExists(atPath: Self.clamshellMarkerPath) else { return }
        Task.detached(priority: .utility) { [weak self] in
            let portalActive = await MainActor.run { PSPortalPluginManager.shared.isClamshellKeepAwakeActive }
            let keepAwakeActive = await MainActor.run { self?.isClamshellKeepAwakeActive ?? false }
            guard !portalActive && !keepAwakeActive else { return }

            if Self.isSystemSleepDisabledViaPmset() {
                let sudoOk = Self.runSudoNoPass(script: Self.disableClamshellShellScript)
                if !sudoOk && Self.isSystemSleepDisabledViaPmset() {
                    _ = Self.runOsascriptAdmin(script: Self.disableClamshellShellScript)
                }
            } else {
                _ = Self.runSudoNoPass(script: Self.removeMarkerOnlyShellScript)
            }
        }
    }

    /// 应用退出前同步恢复正常合盖睡眠，避免残留 `SleepDisabled 1`。
    public func restoreClamshellSynchronouslyForTermination() {
        stopClamshellWatchdog()
        releaseAssertions()
        let hadActive = isClamshellKeepAwakeActive || FileManager.default.fileExists(atPath: Self.clamshellMarkerPath)
        guard hadActive else { return }

        isClamshellKeepAwakeActive = false
        let portalHoldsClamshell = PSPortalPluginManager.shared.isClamshellKeepAwakeActive
        if portalHoldsClamshell {
            _ = Self.runSudoNoPass(script: Self.removeMarkerOnlyShellScript)
            return
        }

        let sudoOk = Self.runSudoNoPass(script: Self.disableClamshellShellScript)
        if !sudoOk && Self.isSystemSleepDisabledViaPmset() {
            _ = Self.runOsascriptAdmin(script: Self.disableClamshellShellScript)
        }
    }

    nonisolated private static func isSystemSleepDisabledViaPmset() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            proc.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return false }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("SleepDisabled") {
                    let parts = trimmed.split(whereSeparator: \.isWhitespace)
                    return parts.count >= 2 && parts[1] == "1"
                }
            }
            return false
        } catch {
            return false
        }
    }

    nonisolated private static func runSudoNoPass(script: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", "/bin/sh", "-c", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func runOsascriptAdmin(script: String) -> Bool {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func executePrivilegedShellCommand(script: String, allowPrompt: Bool) -> Bool {
        if runSudoNoPass(script: script) {
            return true
        }
        guard allowPrompt else { return false }
        return runOsascriptAdmin(script: script)
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "syspulse.keepawake.\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request)
        }
    }
}
