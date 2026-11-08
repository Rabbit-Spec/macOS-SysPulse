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

    public private(set) var isActive: Bool = false
    public private(set) var currentBehavior: KeepAwakeBehavior = .displayOnly
    public private(set) var currentDuration: KeepAwakeDuration = .indefinitely
    public private(set) var sessionEndsAt: Date? = nil
    public private(set) var remainingSeconds: TimeInterval = 0
    public private(set) var isPausedDueToLowBattery: Bool = false

    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var tickTimer: Timer?

    private init() {
        observePowerSource()
    }

    // MARK: - Core Operations

    /// 开启保持常亮
    public func activate(duration: KeepAwakeDuration = .indefinitely, behavior: KeepAwakeBehavior? = nil) {
        if let behavior {
            self.currentBehavior = behavior
        }
        self.currentDuration = duration
        self.isPausedDueToLowBattery = false

        if let secs = duration.seconds {
            self.sessionEndsAt = Date().addingTimeInterval(secs)
            self.remainingSeconds = secs
        } else {
            self.sessionEndsAt = nil
            self.remainingSeconds = 0
        }

        applyAssertions()
        self.isActive = true
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
            isPausedDueToLowBattery = true
            sendNotification(
                title: "保持常亮已暂停",
                body: "电量仅剩 \(batteryPct)%，保持常亮已暂停，恢复正常睡眠。"
            )
        } else if isAC && isPausedDueToLowBattery {
            // 接回电源自动恢复
            isPausedDueToLowBattery = false
            applyAssertions()
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

    private func startTimer() {
        stopTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleTick()
            }
        }
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
