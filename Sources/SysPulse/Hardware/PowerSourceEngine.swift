import Foundation
import IOKit.ps
import Observation
import OSLog
import AppKit

@Observable
@MainActor
public final class PowerSourceEngine {
    public static let shared = PowerSourceEngine()

    private let logger = Logger(subsystem: "com.apple.powerglass", category: "Engine")

    public private(set) var telemetry = UPSTelemetry()
    public private(set) var events: [PowerEvent] = []
    public private(set) var isPanelVisible: Bool = false

    // Software simulation of outage for safe testing
    public var isSimulationOutage: Bool = false {
        didSet {
            refresh(forceUIUpdate: true)
        }
    }

    // Callback handlers for automation (multi-observer safe)
    public var onPowerStateChanged: (@MainActor @Sendable (PowerSupplyState) -> Void)?
    public var onTelemetryUpdated: (@MainActor @Sendable () -> Void)?
    private var powerStateObservers: [String: @MainActor @Sendable (PowerSupplyState) -> Void] = [:]

    public func addPowerStateObserver(id: String, handler: @escaping @MainActor @Sendable (PowerSupplyState) -> Void) {
        powerStateObservers[id] = handler
    }

    private var runLoopSource: CFRunLoopSource?
    private var previousState: PowerSupplyState = .unknown
    private var lastHIDSnapshot: RawHIDPowerState?
    public private(set) var outageStartTime: Date?
    private var hasTriggeredSoftwareProtectionThisOutage: Bool = false

    public init() {
        setupHIDWatchdog()
        refresh(forceUIUpdate: true)
        startListening()
        seedInitialEvent()
    }

    public func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        if visible {
            HIDHardwareWatchdog.shared.triggerManualPoll()
            refresh(forceUIUpdate: true)
        }
    }

    // MARK: - Lifecycle & Listeners

    private func setupHIDWatchdog() {
        HIDHardwareWatchdog.shared.onSnapshotUpdated = { [weak self] snapshot in
            self?.handleBackgroundHIDSnapshot(snapshot)
        }
        HIDHardwareWatchdog.shared.start(intervalSeconds: 2.5)
    }

    private func handleBackgroundHIDSnapshot(_ snapshot: RawHIDPowerState) {
        self.lastHIDSnapshot = snapshot

        // 1. Multi-signal outage check:
        let isHardwareOutage = (snapshot.acPresent == false) || (snapshot.isDischarging == true)
        if isHardwareOutage && telemetry.state.isAC {
            logger.warning("Background HID watchdog detected outage before IOKit notification!")
            refresh(forceUIUpdate: true)
            return
        }
        if !isHardwareOutage && snapshot.acPresent == true && !telemetry.state.isAC && !isSimulationOutage {
            refresh(forceUIUpdate: true)
            return
        }

        // 2. If battery level or voltage or ratedVA changed, or if the popover panel is currently open, refresh telemetry
        let battChanged = (snapshot.batteryLevel != nil && snapshot.batteryLevel != telemetry.batteryLevel)
        let voltChanged = (snapshot.voltageVolts != nil && Int(snapshot.voltageVolts ?? 0) != Int(telemetry.voltageVolts))
        let vaChanged = (snapshot.configApparentPowerVA != nil && Int(snapshot.configApparentPowerVA ?? 0) != (telemetry.ratedVA ?? 0))
        if battChanged || voltChanged || vaChanged || isPanelVisible {
            refresh(forceUIUpdate: isPanelVisible || vaChanged)
        }
    }

    public func startListening() {
        guard runLoopSource == nil else { return }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let source = IOPSNotificationCreateRunLoopSource({ info in
            guard let info else { return }
            let engine = Unmanaged<PowerSourceEngine>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                engine.refresh(forceUIUpdate: true)
            }
        }, context).takeRetainedValue()

        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
        self.runLoopSource = source
    }

    public func stopListening() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
            runLoopSource = nil
        }
        HIDHardwareWatchdog.shared.stop()
    }

    // MARK: - Telemetry Collection

    public func refresh(forceUIUpdate: Bool = false) {
        var foundUPS = false

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            let providingType = (IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as? String) ?? ""

            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }

                let type = desc[kIOPSTypeKey] as? String ?? ""
                let transport = desc[kIOPSTransportTypeKey] as? String ?? ""

                // Strictly match external UPS device (never mistake MacBook's InternalBattery for a UPS)
                let isExternalUPS = (type == kIOPSUPSType) || (transport == "USB" && type != kIOPSInternalBatteryType)
                if isExternalUPS {
                    parseUPSDescription(desc, providingType: providingType, forceUIUpdate: forceUIUpdate)
                    foundUPS = true
                    break
                }
            }
        }

        // MacBook / Direct USB HID Fallback:
        // If IOPSCopyPowerSourcesList only listed InternalBattery-0 on a MacBook, construct UPS telemetry directly from USB HID!
        if !foundUPS, let hid = lastHIDSnapshot, hid.hasHIDDevice {
            parseHIDOnlyUPS(hid, forceUIUpdate: forceUIUpdate)
            foundUPS = true
        }

        if !foundUPS {
            updateDisconnected()
        }
    }

    private func parseHIDOnlyUPS(_ hid: RawHIDPowerState, forceUIUpdate: Bool) {
        let name = (hid.deviceName?.isEmpty == false ? hid.deviceName! : "USB UPS")
        let brand = UPSBrand.detect(name: name, vendorID: hid.vendorID)

        var isAC = (hid.acPresent ?? true) && !(hid.isDischarging ?? false)
        if isSimulationOutage {
            isAC = false
        }
        let currentState: PowerSupplyState = isAC ? .acPower : .batteryPower
        let clampedPercent = min(100, max(0, hid.batteryLevel ?? 100))
        let isCharging = hid.isCharging ?? false
        let voltage = isAC ? (hid.voltageVolts ?? 230.0) : 0.0

        let isUserMuted = UserDefaults.standard.bool(forKey: "PowerGlass_AlarmMuted")
        let alarmEnabled = !isUserMuted

        let calculatedMinutes: Int = {
            if clampedPercent <= 2 { return 0 }
            if let sec = hid.runTimeToEmptySeconds, sec > 0 && sec < 65535 {
                return max(1, sec / 60)
            }
            return max(0, Int(round(24.0 * (Double(clampedPercent) / 100.0))))
        }()

        let liveMacWatts = hid.macSystemWatts
            ?? (forceUIUpdate ? HIDHardwareWatchdog.readMacSystemPowerWatts() : telemetry.loadWatts)
            ?? (isAC ? 27.0 : 29.0)
        let ratedVA = hid.configApparentPowerVA ?? 850.0
        let ratedWatts = max(300.0, ratedVA * 0.6)
        let estimatedLoadPercent = max(1.0, round((liveMacWatts / ratedWatts) * 100.0))
        let liveLoadPercent = (hid.upsLoadPercent ?? 0) > 0 ? (hid.upsLoadPercent ?? estimatedLoadPercent) : estimatedLoadPercent
        let hardwareRatedVA = hid.configApparentPowerVA.map { Int($0) }

        applyParsedTelemetry(
            name: name,
            brand: brand,
            currentState: currentState,
            clampedPercent: clampedPercent,
            isAC: isAC,
            isCharging: isCharging,
            calculatedMinutes: calculatedMinutes,
            voltage: voltage,
            liveLoadPercent: liveLoadPercent,
            liveMacWatts: liveMacWatts,
            hardwareRatedVA: hardwareRatedVA,
            alarmEnabled: alarmEnabled,
            forceUIUpdate: forceUIUpdate
        )
    }

    private func parseUPSDescription(_ desc: [String: Any], providingType: String, forceUIUpdate: Bool) {
        let rawName = desc[kIOPSNameKey] as? String ?? "USB UPS"
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let vendorID = desc["Vendor ID"] as? Int
        let brand = UPSBrand.detect(name: name, vendorID: vendorID)

        let stateString = desc[kIOPSPowerSourceStateKey] as? String ?? ""

        // Multi-signal outage detection:
        var isAC = (stateString == kIOPSACPowerValue)
        if isSimulationOutage {
            isAC = false
        } else if let hid = lastHIDSnapshot {
            if hid.acPresent == false || hid.isDischarging == true {
                isAC = false
            }
        }
        if isAC {
            if providingType == "Battery Power" || providingType == "UPS Power" {
                isAC = false
            } else if stateString == kIOPSBatteryPowerValue || stateString == kIOPSOffLineValue {
                isAC = false
            }
        }

        let currentState: PowerSupplyState = isAC ? .acPower : .batteryPower

        let currentCap = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        let maxCap = max(1, desc[kIOPSMaxCapacityKey] as? Int ?? 100)
        var percent = Int((Double(currentCap) / Double(maxCap)) * 100.0)
        if let hidBattery = lastHIDSnapshot?.batteryLevel, hidBattery >= 0 && hidBattery <= 100 {
            percent = hidBattery
        }
        let clampedPercent = min(100, max(0, percent))

        let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int

        // Voltage in millivolts (e.g. 230000 -> 230.0V). If on battery, line input is 0V
        var voltage = isAC ? 230.0 : 0.0
        if isAC {
            if let hidVolt = lastHIDSnapshot?.voltageVolts, hidVolt > 50.0 {
                voltage = hidVolt
            } else if let rawVoltage = desc[kIOPSVoltageKey] as? Double ?? (desc[kIOPSVoltageKey] as? Int).map(Double.init) {
                voltage = rawVoltage > 1000 ? (rawVoltage / 1000.0) : rawVoltage
            }
        }

        // Persistent user mute override
        let isUserMuted = UserDefaults.standard.bool(forKey: "PowerGlass_AlarmMuted")
        let rawAlarmEnabled = (desc["Enable Audible Alarm"] as? Int ?? 1) == 1
        let alarmEnabled = isUserMuted ? false : rawAlarmEnabled

        // Accurate remaining time calculation
        let calculatedMinutes: Int = {
            if clampedPercent <= 2 {
                return 0
            }
            if let reported = timeToEmpty, reported > 0 && reported < 65535 {
                let mins = reported > 120 ? (reported / 60) : reported
                return mins
            }
            let estimated = Int(round(24.0 * (Double(clampedPercent) / 100.0)))
            return max(0, estimated)
        }()

        // Use background-polled Mac Studio SMC wattage (avoids main-thread IOKit calls when idle)
        let liveMacWatts = lastHIDSnapshot?.macSystemWatts
            ?? (forceUIUpdate ? HIDHardwareWatchdog.readMacSystemPowerWatts() : telemetry.loadWatts)
            ?? (isAC ? 27.0 : 29.0)

        let ratedVA = lastHIDSnapshot?.configApparentPowerVA ?? 850.0
        let ratedWatts = max(300.0, ratedVA * 0.6)
        let estimatedLoadPercent = max(1.0, round((liveMacWatts / ratedWatts) * 100.0))
        let liveLoadPercent: Double = {
            if let hidLoad = lastHIDSnapshot?.upsLoadPercent, hidLoad > 0 {
                return hidLoad
            }
            return estimatedLoadPercent
        }()

        let hardwareRatedVA = lastHIDSnapshot?.configApparentPowerVA.map { Int($0) }

        applyParsedTelemetry(
            name: name,
            brand: brand,
            currentState: currentState,
            clampedPercent: clampedPercent,
            isAC: isAC,
            isCharging: isCharging,
            calculatedMinutes: calculatedMinutes,
            voltage: voltage,
            liveLoadPercent: liveLoadPercent,
            liveMacWatts: liveMacWatts,
            hardwareRatedVA: hardwareRatedVA,
            alarmEnabled: alarmEnabled,
            forceUIUpdate: forceUIUpdate
        )
    }

    private func applyParsedTelemetry(
        name: String,
        brand: UPSBrand,
        currentState: PowerSupplyState,
        clampedPercent: Int,
        isAC: Bool,
        isCharging: Bool,
        calculatedMinutes: Int,
        voltage: Double,
        liveLoadPercent: Double,
        liveMacWatts: Double,
        hardwareRatedVA: Int?,
        alarmEnabled: Bool,
        forceUIUpdate: Bool
    ) {
        // Check for state transitions (AC Power <-> Battery)
        let stateChanged = (previousState != .unknown && previousState != currentState)
        if stateChanged {
            let transitionTelemetry = UPSTelemetry(
                isConnected: true,
                deviceName: name,
                brand: brand,
                state: currentState,
                batteryLevel: clampedPercent,
                isCharging: isAC && isCharging,
                timeRemainingMinutes: calculatedMinutes,
                voltageVolts: voltage,
                loadPercent: liveLoadPercent,
                loadWatts: liveMacWatts,
                ratedVA: hardwareRatedVA,
                frequencyHz: isAC ? 50.0 : 0.0,
                isAudibleAlarmEnabled: alarmEnabled,
                lastUpdated: Date()
            )
            handleStateTransition(from: previousState, to: currentState, telemetry: transitionTelemetry)
        }
        previousState = currentState

        if currentState == .batteryPower {
            if outageStartTime == nil {
                outageStartTime = Date()
            }
            evaluateSoftwareUPSProtection(
                batteryPercent: clampedPercent,
                remainingMinutes: calculatedMinutes
            )
        } else {
            outageStartTime = nil
            hasTriggeredSoftwareProtectionThisOutage = false
        }

        // Determine if status bar or visible panel actually needs a UI update
        let statusBarFieldsChanged =
            !telemetry.isConnected ||
            telemetry.deviceName != name ||
            telemetry.ratedVA != hardwareRatedVA ||
            telemetry.state != currentState ||
            telemetry.batteryLevel != clampedPercent ||
            telemetry.isCharging != (isAC && isCharging) ||
            telemetry.timeRemainingMinutes != calculatedMinutes ||
            Int(telemetry.voltageVolts) != Int(voltage) ||
            telemetry.isAudibleAlarmEnabled != alarmEnabled

        guard forceUIUpdate || isPanelVisible || stateChanged || statusBarFieldsChanged else {
            return
        }

        let newTelemetry = UPSTelemetry(
            isConnected: true,
            deviceName: name,
            brand: brand,
            state: currentState,
            batteryLevel: clampedPercent,
            isCharging: isAC && isCharging,
            timeRemainingMinutes: calculatedMinutes,
            voltageVolts: voltage,
            loadPercent: liveLoadPercent,
            loadWatts: liveMacWatts,
            ratedVA: hardwareRatedVA,
            frequencyHz: isAC ? 50.0 : 0.0,
            isAudibleAlarmEnabled: alarmEnabled,
            lastUpdated: Date()
        )

        self.telemetry = newTelemetry
        if statusBarFieldsChanged || forceUIUpdate {
            onTelemetryUpdated?()
        }
    }

    /// Evaluates user-configured UPS shutdown/sleep rules in software.
    /// This enables full UPS threshold protection on MacBooks (where macOS hides the system UPS settings sheet)
    /// as well as desktop Macs.
    private func evaluateSoftwareUPSProtection(batteryPercent: Int, remainingMinutes: Int) {
        guard !hasTriggeredSoftwareProtectionThisOutage, !isSimulationOutage else { return }
        let mgr = SystemUPSSettingsManager.shared
        guard mgr.softwareProtectionEnabled else { return }

        var triggerReason: String?

        if mgr.haltLevelEnabled && batteryPercent <= mgr.haltLevelPercent {
            triggerReason = "UPS 电量已降至 \(batteryPercent)%（低于阈值 \(mgr.haltLevelPercent)%）"
        } else if mgr.haltRemainEnabled && remainingMinutes > 0 && remainingMinutes <= mgr.haltRemainMinutes {
            triggerReason = "UPS 剩余续航仅剩 \(remainingMinutes) 分钟（低于阈值 \(mgr.haltRemainMinutes) 分钟）"
        } else if mgr.haltAfterEnabled, let start = outageStartTime {
            let elapsedMinutes = Int(Date().timeIntervalSince(start) / 60.0)
            if elapsedMinutes >= mgr.haltAfterMinutes {
                triggerReason = "UPS 电池供电已满 \(elapsedMinutes) 分钟（达到设定阈值 \(mgr.haltAfterMinutes) 分钟）"
            }
        }

        guard let reason = triggerReason else { return }
        hasTriggeredSoftwareProtectionThisOutage = true
        let actionLabel = (mgr.protectionAction == "shutdown") ? "安全关机" : "安全睡眠"
        logger.warning("触发 PowerGlass 主动 UPS 保护: \(reason)，即将执行\(actionLabel)")

        appendEvent(PowerEvent(
            type: .batteryLow,
            details: "【主动保护触发】\(reason)，正在弹出外置硬盘并执行系统\(actionLabel)",
            batteryLevel: batteryPercent,
            voltageVolts: 0.0
        ))

        if FeatureToggleManager.shared.enableDiskGuardian {
            DiskGuardian.shared.emergencyEjectAll()
        }

        let isShutdown = (mgr.protectionAction == "shutdown")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
            let proc = Process()
            if isShutdown {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", "tell application \"System Events\" to shut down"]
            } else {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                proc.arguments = ["sleepnow"]
            }
            try? proc.run()
        }
    }

    private func handleStateTransition(from oldState: PowerSupplyState, to newState: PowerSupplyState, telemetry: UPSTelemetry) {
        if newState == .batteryPower {
            logger.warning("市电中断！切换至 UPS 电池供电")
            let event = PowerEvent(
                type: .powerCut,
                details: "市电中断，UPS (\(telemetry.deviceName)) 开始逆变供电 (电池电量 \(telemetry.batteryLevel)%)",
                batteryLevel: telemetry.batteryLevel,
                voltageVolts: telemetry.voltageVolts
            )
            appendEvent(event)
            onPowerStateChanged?(.batteryPower)
            for observer in powerStateObservers.values {
                observer(.batteryPower)
            }

            if telemetry.isAudibleAlarmEnabled {
                NSSound.beep()
            }
        } else if newState == .acPower {
            logger.info("市电恢复正常！")
            let event = PowerEvent(
                type: .powerRestored,
                details: "市电恢复正常，UPS 转入旁路供电并开始浮充 (电压 \(Int(telemetry.voltageVolts))V)",
                batteryLevel: telemetry.batteryLevel,
                voltageVolts: telemetry.voltageVolts
            )
            appendEvent(event)
            onPowerStateChanged?(.acPower)
            for observer in powerStateObservers.values {
                observer(.acPower)
            }
        }
    }

    private func updateDisconnected() {
        guard telemetry.isConnected else { return }
        self.telemetry = UPSTelemetry(isConnected: false)
        onTelemetryUpdated?()
    }

    private func seedInitialEvent() {
        if events.isEmpty {
            events.append(PowerEvent(
                type: .powerRestored,
                details: "系统启动就绪，山特 TG-BOX 供电正常 (230V 满电)",
                batteryLevel: 100,
                voltageVolts: 230.0
            ))
        }
    }

    public func appendEvent(_ event: PowerEvent) {
        events.insert(event, at: 0)
        if events.count > 100 {
            events.removeLast()
        }
    }

    public func clearEvents() {
        events.removeAll()
        onTelemetryUpdated?()
    }

    // MARK: - Actions

    public func toggleAudibleAlarm() {
        let currentlyMuted = UserDefaults.standard.bool(forKey: "PowerGlass_AlarmMuted")
        let newMuted = !currentlyMuted
        UserDefaults.standard.set(newMuted, forKey: "PowerGlass_AlarmMuted")

        telemetry.isAudibleAlarmEnabled = !newMuted
        logger.info("蜂鸣器状态切换为: \(newMuted ? "已静音" : "开启")")

        appendEvent(PowerEvent(
            type: .selfTest,
            details: newMuted ? "已将 UPS 蜂鸣器设为静音模式（断电时不发声）" : "已恢复开启 UPS 蜂鸣器提示音（断电时蜂鸣警报）",
            batteryLevel: telemetry.batteryLevel,
            voltageVolts: telemetry.voltageVolts
        ))
        onTelemetryUpdated?()
    }
}
