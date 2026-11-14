import AppKit
import OSLog

/// Coordinates sleep and wake lifecycle across SysPulse background monitors and hardware watchdogs.
/// Responds ONLY to system sleep/wake (never display-only sleep) so UPS outage protection stays active while the screen is off.
@MainActor
public final class SystemSleepCoordinator {
    public static let shared = SystemSleepCoordinator()

    private let logger = Logger(subsystem: "com.apple.powerglass", category: "SleepCoordinator")
    public private(set) var isSystemAsleep: Bool = false
    private var observers: [NSObjectProtocol] = []

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

        let wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidWake()
            }
        }

        observers = [sleepObserver, wakeObserver]
    }

    private func handleWillSleep() {
        guard !isSystemAsleep else { return }
        isSystemAsleep = true
        logger.info("System will sleep: pausing periodic hardware & UI polling timers")

        SystemResourceMonitor.shared.pauseForSleep()
        NetworkTrafficPersistenceManager.shared.persistToDisk(force: true)
        PowerSourceEngine.shared.pauseForSleep()
        AccessoryBatteryManager.shared.pauseForSleep()
        KeepAwakeController.shared.pauseForSleep()
        FanController.shared.pauseForSleep()

        if PSPortalPluginManager.shared.isRunning || PSPortalPluginManager.shared.isListening {
            PSPortalPluginManager.shared.stopRelay()
        }
        ActiveConnectionsViewModel.shared.stopAutoRefresh()
    }

    private func handleDidWake() {
        guard isSystemAsleep else { return }
        isSystemAsleep = false
        logger.info("System did wake: resuming hardware & UI monitors")

        SystemResourceMonitor.shared.resumeFromWake()
        PowerSourceEngine.shared.resumeFromWake()
        AccessoryBatteryManager.shared.resumeFromWake()
        KeepAwakeController.shared.resumeFromWake()
        FanController.shared.resumeFromWake()
        if ActiveConnectionsWindowController.shared.window?.isVisible == true {
            ActiveConnectionsViewModel.shared.startAutoRefresh()
        }
    }
}
