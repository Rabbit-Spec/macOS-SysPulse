import AppKit
import OSLog

/// Coordinates sleep, display-sleep, DarkWake, and wake lifecycle across SysPulse background monitors and hardware watchdogs.
/// Pauses Bluetooth, USB HID, hardware polling, and UI animations on both display sleep and system sleep (preventing DarkWake churn and USB/bluetoothd stalls),
/// and delays wake resumption until USB buses and Bluetooth controllers stabilize.
@MainActor
public final class SystemSleepCoordinator {
    public static let shared = SystemSleepCoordinator()

    private let logger = Logger(subsystem: "com.apple.powerglass", category: "SleepCoordinator")
    public private(set) var isSystemAsleep: Bool = false
    public private(set) var isScreenAsleep: Bool = false
    private var observers: [NSObjectProtocol] = []
    private var wakeResumeWorkItem: DispatchWorkItem?

    private init() {}

    public func start() {
        guard observers.isEmpty else { return }

        let wsCenter = NSWorkspace.shared.notificationCenter

        let sleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }

        let powerOffObserver = wsCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }

        let screenSleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreensDidSleep()
            }
        }

        let wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidWake()
            }
        }

        let screenWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreensDidWake()
            }
        }

        observers = [sleepObserver, powerOffObserver, screenSleepObserver, wakeObserver, screenWakeObserver]
    }

    private func handleScreensDidSleep() {
        wakeResumeWorkItem?.cancel()
        wakeResumeWorkItem = nil
        isScreenAsleep = true
        logger.info("Screens did sleep: pausing Bluetooth, HID watchdog, and visible UI redraws")

        AccessoryBatteryManager.shared.pauseForSleep()
        PowerSourceEngine.shared.handleScreenDidSleep()
        ActiveConnectionsViewModel.shared.stopAutoRefresh()
        MainStudioWindowController.shared.refreshEffectiveVisibility()
        SystemResourceMonitor.shared.refreshDemandFromMain()
    }

    private func handleScreensDidWake() {
        isScreenAsleep = false
        logger.info("Screens did wake: scheduling post-wake UI & peripheral resumption")
        scheduleStabilizedWakeResume()
    }

    private func handleWillSleep() {
        wakeResumeWorkItem?.cancel()
        wakeResumeWorkItem = nil
        guard !isSystemAsleep else { return }
        isSystemAsleep = true
        logger.info("System will sleep: pausing all periodic hardware, Bluetooth, and UI polling timers")

        SystemResourceMonitor.shared.pauseForSleep()
        NetworkTrafficPersistenceManager.shared.persistToDisk(force: true)
        PowerSourceEngine.shared.pauseForSleep()
        AccessoryBatteryManager.shared.pauseForSleep()
        KeepAwakeController.shared.pauseForSleep()
        FanController.shared.pauseForSleep()

        PSPortalPluginManager.shared.handleWillSleep()
        ActiveConnectionsViewModel.shared.stopAutoRefresh()
        AppUpdateManager.shared.pauseForSleep()
        MainStudioWindowController.shared.refreshEffectiveVisibility()
    }

    private func handleDidWake() {
        isSystemAsleep = false
        logger.info("System did wake (screenAsleep=\(self.isScreenAsleep)): scheduling stabilized hardware resume")
        scheduleStabilizedWakeResume()
    }

    private func scheduleStabilizedWakeResume() {
        wakeResumeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isSystemAsleep else { return }
                self.logger.info("Wake stabilization elapsed: resuming background monitors (screenAsleep=\(self.isScreenAsleep))")

                SystemResourceMonitor.shared.resumeFromWake()
                PowerSourceEngine.shared.resumeFromWake()
                KeepAwakeController.shared.resumeFromWake()
                FanController.shared.resumeFromWake()
                PSPortalPluginManager.shared.resumeFromWake()
                AppUpdateManager.shared.resumeFromWake()

                // Only resume Bluetooth and SwiftUI window rendering if a display is actually awake
                if !self.isScreenAsleep {
                    MainStudioWindowController.shared.refreshEffectiveVisibility()
                    AccessoryBatteryManager.shared.resumeFromWake()
                    if ActiveConnectionsWindowController.shared.window?.isVisible == true {
                        ActiveConnectionsViewModel.shared.startAutoRefresh()
                    }
                }
            }
        }
        wakeResumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}
