import Foundation
import AppKit

// MARK: - 风扇转速与温控模式管理器

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

    private var autoRestoreTimer: Timer?
    private var lastModeChangeAt: Date = Date()

    private init() {
        refreshFanStats()
    }

    public func setMode(_ mode: FanMode) {
        self.activeMode = mode
        self.lastModeChangeAt = Date()
        self.isTransitioning = true

        if mode == .auto {
            self.needsAuthorization = false
            self.statusText = mode.strategyText
            self.autoRestoreTimer?.invalidate()
            self.autoRestoreTimer = nil
            restoreAutoFanControl()
            self.isTransitioning = false
            return
        }

        // Cool or MaxCool mode:
        // 1. Try silent setuid helper or root execution first
        if Self.runInstalledHelperSilently(percent: mode.targetPercent) {
            self.needsAuthorization = false
            self.statusText = mode.strategyText
            self.isTransitioning = false
            setupAutoRestoreTimer()
            SystemResourceMonitor.shared.refreshNow()
            return
        }

        // 2. Helper not yet installed: request one-time administrator authorization to install & apply
        self.needsAuthorization = true
        self.statusText = "正在请求授权…"
        tryApplyPrivilegedFanControl(mode: mode)
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
        let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SysPulseUPSHelper").path
        let fallbackPath = "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/MacOS/SysPulseUPSHelper"
        let sourceHelper = FileManager.default.isExecutableFile(atPath: bundledPath) ? bundledPath : fallbackPath
        let installedDir = "/Library/Application Support/SysPulse"
        let installedHelper = "\(installedDir)/SysPulseUPSHelper"
        let pct = mode.targetPercent

        let shellCmd = "mkdir -p '\(installedDir)' && cp -f '\(sourceHelper)' '\(installedHelper)' && chown root:wheel '\(installedHelper)' && chmod 4755 '\(installedHelper)' && '\(installedHelper)' --fan \(pct)"
        let script = "do shell script \"\(shellCmd)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            var succeeded = false
            do {
                try proc.run()
                proc.waitUntilExit()
                succeeded = (proc.terminationStatus == 0)
            } catch {
                succeeded = false
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransitioning = false
                if succeeded {
                    self.needsAuthorization = false
                    self.statusText = mode.strategyText
                    self.lastModeChangeAt = Date()
                    self.setupAutoRestoreTimer()
                    SystemResourceMonitor.shared.refreshNow()
                } else {
                    self.activeMode = .auto
                    self.needsAuthorization = true
                    self.statusText = "未更改，需要授权"
                }
            }
        }
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
