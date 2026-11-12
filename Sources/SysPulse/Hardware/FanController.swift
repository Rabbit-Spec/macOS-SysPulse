import Foundation
import AppKit
import SwiftUI

// MARK: - 风扇转速与温控模式管理器

public enum PassiveThermalTier: String, CaseIterable, Identifiable, Sendable {
    case cool = "清凉"
    case warm = "温热"
    case hot = "高热"

    public var id: String { rawValue }
}

public enum FanMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "自动"
    case cool = "降温"
    case maxCool = "强冷"

    public var id: String { rawValue }

    public var strategyText: String {
        switch self {
        case .auto: return "由系统自动调节"
        case .cool: return "50% 起步，升温时加速"
        case .maxCool: return "保持全速"
        }
    }

    public var targetPercent: Int {
        switch self {
        case .auto: return 0
        case .cool: return 50
        case .maxCool: return 100
        }
    }
}

@Observable
@MainActor
public final class FanController {
    public static let shared = FanController()

    public private(set) var activeMode: FanMode = .auto
    public private(set) var statusText: String = "由系统自动调节"
    public private(set) var needsAuthorization: Bool = false
    public private(set) var isTransitioning: Bool = false
    public private(set) var currentRPM: Int = 1000
    public private(set) var maxRPM: Int = 3500
    public private(set) var minRPM: Int = 1000

    /// 当前设备是否配备物理散热风扇（MacBook Air 等被动散热机型返回 false）
    public var isFanSupported: Bool {
        if MacHardwareInfo.shared.isPassiveCoolingModel {
            return false
        }
        return SystemResourceMonitor.shared.hardware.isFanSupported
    }

    /// 被动散热机型的当前热工况等级
    public var passiveThermalTier: PassiveThermalTier {
        let temp = SystemResourceMonitor.shared.hardware.cpuTemperatureC
        let state = ProcessInfo.processInfo.thermalState
        if state == .serious || state == .critical || temp >= 72.0 {
            return .hot
        } else if state == .fair || temp >= 54.0 {
            return .warm
        }
        return .cool
    }

    public var passiveThermalAccentColor: Color {
        switch passiveThermalTier {
        case .cool:
            return Color.cyan
        case .warm:
            return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .hot:
            return Color.orange
        }
    }

    public var passiveThermalDetailText: String {
        switch passiveThermalTier {
        case .cool:
            return "无风扇架构 · 全机身被动静音导热"
        case .warm:
            return "中高负载运行 · 铝合金机身均热散逸"
        case .hot:
            return "已触发系统智能温控防过热保护"
        }
    }

    private var autoRestoreTimer: Timer?
    private var keepAliveTimer: Timer?
    private var lastModeChangeAt: Date = Date()
    private var modeBeforeSleep: FanMode = .auto
    private var isPausedForSleep: Bool = false

    private init() {
        refreshFanStats()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activeMode != .auto else { return }
                _ = Self.runInstalledHelperSilently(percent: 0)
            }
        }
    }

    public func pauseForSleep() {
        isPausedForSleep = true
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        autoRestoreTimer?.invalidate()
        autoRestoreTimer = nil

        if activeMode != .auto {
            modeBeforeSleep = activeMode
            activeMode = .auto
            statusText = "睡眠前已交还系统自动控速"
            _ = Self.runInstalledHelperSilently(percent: 0)
        }
    }

    public func resumeFromWake() {
        isPausedForSleep = false
        refreshFanStats()
        let savedMode = modeBeforeSleep
        modeBeforeSleep = .auto
        if savedMode != .auto {
            setMode(savedMode)
        }
    }

    public func setMode(_ mode: FanMode) {
        self.activeMode = mode
        self.lastModeChangeAt = Date()
        self.isTransitioning = true
        SystemResourceMonitor.shared.refreshDemandFromMain()

        if mode == .auto {
            self.needsAuthorization = false
            self.statusText = mode.strategyText
            self.autoRestoreTimer?.invalidate()
            self.autoRestoreTimer = nil
            self.keepAliveTimer?.invalidate()
            self.keepAliveTimer = nil
            restoreAutoFanControl()
            self.isTransitioning = false
            return
        }

        // Cool or MaxCool mode:
        // 1. Only use installed helper silently if it matches the latest bundled binary (prevents stale 0.1.7 helper)
        if Self.isInstalledHelperUpToDate() {
            let pct = mode.targetPercent
            self.needsAuthorization = false
            self.statusText = "正在调节风扇…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = Self.runInstalledHelperSilently(percent: pct)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isTransitioning = false
                    if ok && self.activeMode == mode {
                        self.needsAuthorization = false
                        self.statusText = mode.strategyText
                        self.setupAutoRestoreTimer()
                        self.setupKeepAliveTimer(percent: pct)
                        self.schedulePostSwitchRefreshes()
                    } else if !ok {
                        self.needsAuthorization = true
                        self.statusText = "正在请求更新控速组件…"
                        self.tryApplyPrivilegedFanControl(mode: mode)
                    }
                }
            }
            return
        }

        // 2. Helper missing or outdated: request administrator authorization to install/update & apply
        self.needsAuthorization = true
        self.statusText = "正在请求授权…"
        tryApplyPrivilegedFanControl(mode: mode)
    }

    private func setupKeepAliveTimer(percent: Int) {
        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeMode != .auto, !self.needsAuthorization else {
                    self?.keepAliveTimer?.invalidate()
                    self?.keepAliveTimer = nil
                    return
                }
                let currentPct = self.activeMode.targetPercent
                DispatchQueue.global(qos: .utility).async {
                    _ = Self.runInstalledHelperSilently(percent: currentPct)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func schedulePostSwitchRefreshes() {
        SystemResourceMonitor.shared.refreshNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            SystemResourceMonitor.shared.refreshNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            SystemResourceMonitor.shared.refreshNow()
        }
    }

    private func setupAutoRestoreTimer() {
        autoRestoreTimer?.invalidate()
        autoRestoreTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.setMode(.auto)
                self?.statusText = "已恢复自动，温度已降"
            }
        }
    }

    public func refreshFanStats() {
        let monitor = SystemResourceMonitor.shared
        self.currentRPM = monitor.hardware.fanSpeedRPM
        if self.currentRPM < 0 {
            self.currentRPM = 0
        }
        let isLaptop = monitor.loadRuntime.hasInternalBattery
        if monitor.hardware.fanMaxRPM > 1000 {
            self.maxRPM = monitor.hardware.fanMaxRPM
        } else {
            self.maxRPM = isLaptop ? 5500 : 3500
        }
        if monitor.hardware.fanMinRPM > 300 {
            self.minRPM = monitor.hardware.fanMinRPM
        } else {
            self.minRPM = isLaptop ? 1200 : 1000
        }

        // If in Cool mode and authorized, check if cooled down (< 48°C)
        if activeMode == .cool && !needsAuthorization {
            if monitor.hardware.cpuTemperatureC < 48.0 && Date().timeIntervalSince(lastModeChangeAt) > 60 {
                setMode(.auto)
                self.statusText = "已恢复自动，温度已降"
            }
        }
    }

    private func restoreAutoFanControl() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runInstalledHelperSilently(percent: 0)
            Task { @MainActor in
                SystemResourceMonitor.shared.refreshNow()
            }
        }
    }

    private func tryApplyPrivilegedFanControl(mode: FanMode) {
        let pct = mode.targetPercent

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded = SystemPermissionManager.installPrivilegedHelper(additionalFanPercent: pct)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransitioning = false
                SystemPermissionManager.shared.checkFanHelperPermission()
                if succeeded {
                    self.needsAuthorization = false
                    self.statusText = mode.strategyText
                    self.lastModeChangeAt = Date()
                    self.setupAutoRestoreTimer()
                    self.setupKeepAliveTimer(percent: pct)
                    self.schedulePostSwitchRefreshes()
                } else {
                    self.activeMode = .auto
                    self.keepAliveTimer?.invalidate()
                    self.keepAliveTimer = nil
                    self.needsAuthorization = true
                    self.statusText = "未更改，需要授权"
                }
            }
        }
    }

    public func syncAuthorizationGranted() {
        if needsAuthorization {
            needsAuthorization = false
            if activeMode == .auto {
                statusText = activeMode.strategyText
            }
        }
    }

    nonisolated private static func isInstalledHelperUpToDate() -> Bool {
        if SystemPermissionManager.checkInstalledFanHelperStatus() == .authorized {
            return true
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SysPulseUPSHelper").path
        return geteuid() == 0 && FileManager.default.isExecutableFile(atPath: bundled)
    }

    nonisolated private static func runInstalledHelperSilently(percent: Int) -> Bool {
        let installedHelper = "/Library/Application Support/SysPulse/SysPulseUPSHelper"
        let candidatePath: String
        if FileManager.default.isExecutableFile(atPath: installedHelper) {
            candidatePath = installedHelper
        } else if geteuid() == 0 {
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SysPulseUPSHelper").path
            guard FileManager.default.isExecutableFile(atPath: bundled) else { return false }
            candidatePath = bundled
        } else {
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: candidatePath)
        proc.arguments = ["--fan", "\(percent)"]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
