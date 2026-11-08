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

    public var onSnapshotUpdated: (@MainActor @Sendable (RawHIDPowerState) -> Void)?

    private init() {
        setupManager()
    }

    private func setupManager() {
        queue.async { [weak self] in
            guard let self else { return }
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
    }

    /// Start periodic hardware polling in background (every 2.0s).
    public func start(intervalSeconds: Double = 2.0) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: intervalSeconds)
            timer.setEventHandler { [weak self] in
                self?.pollHardware()
            }
            timer.resume()
            self.timer = timer
            self.logger.info("Background HID hardware polling started (interval: \(intervalSeconds)s)")
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        timer?.cancel()
        timer = nil
    }

    /// Force an immediate background query right now (e.g. user clicks refresh).
    public func triggerManualPoll() {
        queue.async { [weak self] in
            self?.pollHardware()
        }
    }

    private func pollHardware() {
        var snapshot = RawHIDPowerState()
        snapshot.macSystemWatts = Self.readMacSystemPowerWatts()

        if let manager = hidManager,
           let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
           let dev = devices.first,
           let elements = IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
           !elements.isEmpty {

            snapshot.hasHIDDevice = true
            if let prod = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String {
                snapshot.deviceName = prod.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int {
                snapshot.vendorID = vid
            }

            var dummy: Unmanaged<IOHIDValue> = Unmanaged.passRetained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, elements[0], 0, 0))

            for el in elements {
                let page = IOHIDElementGetUsagePage(el)
                let usage = IOHIDElementGetUsage(el)
                if IOHIDDeviceGetValue(dev, el, &dummy) == kIOReturnSuccess {
                    let val = IOHIDValueGetIntegerValue(dummy.takeUnretainedValue())
                    if page == 0x85 && usage == 0xD0 {
                        snapshot.acPresent = (val == 1)
                    } else if page == 0x85 && usage == 0x44 {
                        snapshot.isCharging = (val == 1)
                    } else if page == 0x85 && usage == 0x45 {
                        snapshot.isDischarging = (val == 1)
                    } else if page == 0x85 && usage == 0x66 {
                        snapshot.batteryLevel = val
                    } else if (page == 0x85 && usage == 0x68) || (page == 0x84 && usage == 0x57) {
                        if val > 0 && val < 65535 {
                            snapshot.runTimeToEmptySeconds = val
                        }
                    } else if page == 0x84 && usage == 0x30 && val > 0 {
                        snapshot.voltageVolts = Double(val)
                    } else if page == 0x84 && usage == 0x35 && val >= 0 && val <= 100 {
                        snapshot.upsLoadPercent = Double(val)
                    } else if page == 0x84 && usage == 0x43 && val > 0 {
                        snapshot.configApparentPowerVA = Double(val)
                    }
                }
            }
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
