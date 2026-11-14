import Foundation
import IOKit
import IOKit.hid
import OSLog

/// Raw snapshot directly fetched from UPS USB HID registers and Mac SMC PowerTelemetryData.
public struct RawHIDPowerState: Sendable {
    public var hasHIDDevice: Bool = false
    public var deviceName: String?
    public var vendorID: Int?
    public var acPresent: Bool?
    public var isDischarging: Bool?
    public var isCharging: Bool?
    public var batteryLevel: Int?
    public var runTimeToEmptySeconds: Int?
    public var voltageVolts: Double?
    public var upsLoadPercent: Double?
    public var configApparentPowerVA: Double?
    public var macSystemWatts: Double?
    public var timestamp: Date = Date()

    public init(
        hasHIDDevice: Bool = false,
        deviceName: String? = nil,
        vendorID: Int? = nil,
        acPresent: Bool? = nil,
        isDischarging: Bool? = nil,
        isCharging: Bool? = nil,
        batteryLevel: Int? = nil,
        runTimeToEmptySeconds: Int? = nil,
        voltageVolts: Double? = nil,
        upsLoadPercent: Double? = nil,
        configApparentPowerVA: Double? = nil,
        macSystemWatts: Double? = nil,
        timestamp: Date = Date()
    ) {
        self.hasHIDDevice = hasHIDDevice
        self.deviceName = deviceName
        self.vendorID = vendorID
        self.acPresent = acPresent
        self.isDischarging = isDischarging
        self.isCharging = isCharging
        self.batteryLevel = batteryLevel
        self.runTimeToEmptySeconds = runTimeToEmptySeconds
        self.voltageVolts = voltageVolts
        self.upsLoadPercent = upsLoadPercent
        self.configApparentPowerVA = configApparentPowerVA
        self.macSystemWatts = macSystemWatts
        self.timestamp = timestamp
    }
}

/// Asynchronous background hardware watchdog that polls UPS HID registers on a dedicated thread,
/// completely isolated from the AppKit main UI thread.
public final class HIDHardwareWatchdog: @unchecked Sendable {
    public static let shared = HIDHardwareWatchdog()

    private let logger = Logger(subsystem: "com.apple.powerglass", category: "HIDWatchdog")
    private let queue = DispatchQueue(label: "com.apple.powerglass.hidwatchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var hidManager: IOHIDManager?

    private enum HIDTargetRole: Sendable {
        case acPresent
        case isCharging
        case isDischarging
        case batteryLevel
        case runTimeToEmpty
        case voltageVolts
        case upsLoadPercent
        case configApparentPowerVA
    }

    private var cachedDevice: IOHIDDevice?
    private var cachedDeviceName: String?
    private var cachedVendorID: Int?
    private var cachedElements: [(role: HIDTargetRole, element: IOHIDElement)] = []

    private var activeIntervalSeconds: Double = 30.0
    private var skipIOPSRedundantUsages: Bool = false
    private var lastPollTimestamp: CFAbsoluteTime = 0
    private var elementFailureCounts: [Int: Int] = [:]
    private var isPausedForSleep: Bool = false
    private var pendingResumeWorkItem: DispatchWorkItem?

    public var onSnapshotUpdated: (@MainActor @Sendable (RawHIDPowerState) -> Void)?

    private init() {}

    private func ensureManagerOpened() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x84 // Power Device
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if ret == kIOReturnSuccess {
            self.hidManager = manager
            self.logger.info("Background HID hardware watchdog opened successfully")
        } else {
            self.logger.error("Failed to open background HID manager: \(ret)")
        }
    }

    private func scheduleTimerLocked(intervalSeconds: Double, fireImmediately: Bool) {
        stopTimerOnly()
        ensureManagerOpened()

        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        let startDeadline: DispatchTime = fireImmediately ? .now() : .now() + intervalSeconds
        timer.schedule(deadline: startDeadline, repeating: intervalSeconds, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.pollHardware()
        }
        timer.resume()
        self.timer = timer
    }

    /// Start periodic hardware polling in background.
    public func start(intervalSeconds: Double = 30.0) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeIntervalSeconds = intervalSeconds
            guard !self.isPausedForSleep else { return }
            self.scheduleTimerLocked(intervalSeconds: intervalSeconds, fireImmediately: true)
            self.logger.info("Background HID hardware polling started (interval: \(intervalSeconds)s)")
        }
    }

    /// Dynamically adjust polling interval without reopening IOHIDManager.
    public func setPollingInterval(
        _ intervalSeconds: Double,
        skipIOPSRedundantUsages: Bool = false,
        triggerImmediate: Bool = false
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = abs(self.activeIntervalSeconds - intervalSeconds) > 0.1
            self.activeIntervalSeconds = intervalSeconds
            self.skipIOPSRedundantUsages = skipIOPSRedundantUsages
            guard !self.isPausedForSleep else { return }
            let shouldPollNow = triggerImmediate && (CFAbsoluteTimeGetCurrent() - self.lastPollTimestamp >= 15.0)
            if changed || self.timer == nil {
                self.scheduleTimerLocked(intervalSeconds: intervalSeconds, fireImmediately: shouldPollNow)
            } else if shouldPollNow {
                self.pollHardware()
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingResumeWorkItem?.cancel()
            self.pendingResumeWorkItem = nil
            self.stopInternal()
        }
    }

    /// Pause HID timer and close IOHIDManager before macOS enters system sleep / DarkWake.
    public func pauseForSleep() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingResumeWorkItem?.cancel()
            self.pendingResumeWorkItem = nil
            self.isPausedForSleep = true
            self.stopInternal()
        }
    }

    /// Reopen IOHIDManager and resume polling after USB bus stabilizes post-wake.
    public func resumeFromWake(afterDelaySeconds delay: Double = 2.5) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingResumeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isPausedForSleep = false
                self.scheduleTimerLocked(intervalSeconds: self.activeIntervalSeconds, fireImmediately: true)
            }
            self.pendingResumeWorkItem = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func stopTimerOnly() {
        timer?.cancel()
        timer = nil
    }

    private var cachedRatedVA: Double?

    private func clearCachedDevice() {
        cachedDevice = nil
        cachedDeviceName = nil
        cachedVendorID = nil
        cachedRatedVA = nil
        elementFailureCounts.removeAll(keepingCapacity: false)
        cachedElements.removeAll(keepingCapacity: false)
    }

    private func stopInternal() {
        stopTimerOnly()
        clearCachedDevice()
        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
            logger.info("Background HID hardware watchdog closed and released")
        }
    }

    /// Force an immediate background query right now (e.g. user clicks refresh).
    public func triggerManualPoll() {
        queue.async { [weak self] in
            guard let self, !self.isPausedForSleep else { return }
            self.ensureManagerOpened()
            self.pollHardware()
        }
    }

    private static func targetRole(page: UInt32, usage: UInt32) -> HIDTargetRole? {
        if page == 0x85 {
            switch usage {
            case 0xD0: return .acPresent
            case 0x44: return .isCharging
            case 0x45: return .isDischarging
            case 0x66: return .batteryLevel
            case 0x68: return .runTimeToEmpty
            default: return nil
            }
        } else if page == 0x84 {
            switch usage {
            case 0x57: return .runTimeToEmpty
            case 0x30: return .voltageVolts
            case 0x35: return .upsLoadPercent
            case 0x43: return .configApparentPowerVA
            default: return nil
            }
        }
        return nil
    }

    private func ensureCachedElements(for dev: IOHIDDevice) {
        if let existing = cachedDevice, existing === dev, !cachedElements.isEmpty {
            return
        }
        clearCachedDevice()
        guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
              !elements.isEmpty else {
            return
        }
        cachedDevice = dev
        if let prod = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String {
            cachedDeviceName = prod.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int {
            cachedVendorID = vid
        }
        for el in elements {
            let page = IOHIDElementGetUsagePage(el)
            let usage = IOHIDElementGetUsage(el)
            if let role = Self.targetRole(page: page, usage: usage) {
                cachedElements.append((role: role, element: el))
            }
        }
    }

    private func pollHardware() {
        guard !isPausedForSleep else { return }
        lastPollTimestamp = CFAbsoluteTimeGetCurrent()
        var snapshot = RawHIDPowerState()

        if let manager = hidManager,
           let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
           let dev = devices.first {

            ensureCachedElements(for: dev)
            if !cachedElements.isEmpty {
                snapshot.hasHIDDevice = true
                snapshot.deviceName = cachedDeviceName
                snapshot.vendorID = cachedVendorID

                let seedValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, cachedElements[0].element, 0, 0)
                var valueRef = Unmanaged.passUnretained(seedValue)

                for (idx, entry) in cachedElements.enumerated() {
                    if entry.role == .configApparentPowerVA, let knownVA = cachedRatedVA {
                        snapshot.configApparentPowerVA = knownVA
                        continue
                    }
                    if skipIOPSRedundantUsages {
                        switch entry.role {
                        case .acPresent, .isCharging, .isDischarging, .batteryLevel, .runTimeToEmpty:
                            continue
                        case .voltageVolts, .upsLoadPercent, .configApparentPowerVA:
                            break
                        }
                    }
                    if (elementFailureCounts[idx] ?? 0) >= 3 {
                        continue
                    }
                    if IOHIDDeviceGetValue(dev, entry.element, &valueRef) == kIOReturnSuccess {
                        elementFailureCounts[idx] = 0
                        let val = IOHIDValueGetIntegerValue(valueRef.takeUnretainedValue())
                        switch entry.role {
                        case .acPresent:
                            snapshot.acPresent = (val == 1)
                        case .isCharging:
                            snapshot.isCharging = (val == 1)
                        case .isDischarging:
                            snapshot.isDischarging = (val == 1)
                        case .batteryLevel:
                            snapshot.batteryLevel = val
                        case .runTimeToEmpty:
                            if val > 0 && val < 65535 {
                                snapshot.runTimeToEmptySeconds = val
                            }
                        case .voltageVolts:
                            if val > 0 {
                                snapshot.voltageVolts = Double(val)
                            }
                        case .upsLoadPercent:
                            if val >= 0 && val <= 100 {
                                snapshot.upsLoadPercent = Double(val)
                            }
                        case .configApparentPowerVA:
                            if val > 0 {
                                let va = Double(val)
                                cachedRatedVA = va
                                snapshot.configApparentPowerVA = va
                            }
                        }
                    } else {
                        elementFailureCounts[idx, default: 0] += 1
                    }
                }
            }
        } else {
            clearCachedDevice()
        }

        DispatchQueue.main.async { [weak self, snapshot] in
            MainActor.assumeIsolated {
                self?.onSnapshotUpdated?(snapshot)
            }
        }
    }

    /// Reads real-time Mac Studio power consumption (Watts) directly from Apple Silicon SMC PowerTelemetryData.
    public static func readMacSystemPowerWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let prop = IORegistryEntryCreateCFProperty(
            service,
            "PowerTelemetryData" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let sysPowerInMW = (prop["SystemPowerIn"] as? Double)
            ?? (prop["SystemPowerIn"] as? Int).map(Double.init)
            ?? (prop["SystemLoad"] as? Double)
            ?? (prop["SystemLoad"] as? Int).map(Double.init)

        let adapterLossMW = (prop["AdapterEfficiencyLoss"] as? Double)
            ?? (prop["AdapterEfficiencyLoss"] as? Int).map(Double.init)
            ?? 0.0

        if let mw = sysPowerInMW, mw > 500 {
            return (mw + adapterLossMW) / 1000.0
        }
        return nil
    }
}
