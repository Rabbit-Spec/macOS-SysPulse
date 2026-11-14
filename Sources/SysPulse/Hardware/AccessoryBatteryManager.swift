import Foundation
import IOBluetooth
import IOKit
import Observation

public struct AccessoryBatteryItem: Identifiable, Sendable {
    public var id: String {
        if !stableKey.isEmpty { return stableKey }
        return address.isEmpty ? name : address.lowercased()
    }
    public let name: String
    public let shortName: String
    public let iconName: String
    public let batteryLevel: Int
    public let isConnected: Bool
    public let detailText: String
    public let address: String
    public let hasMultiPartDetail: Bool
    private let stableKey: String

    public init(
        name: String,
        shortName: String = "",
        iconName: String,
        batteryLevel: Int,
        isConnected: Bool = true,
        detailText: String = "",
        address: String = "",
        hasMultiPartDetail: Bool = false,
        stableKey: String = ""
    ) {
        self.name = name
        self.shortName = shortName.isEmpty ? name : shortName
        self.iconName = iconName
        self.batteryLevel = max(0, min(100, batteryLevel))
        self.isConnected = isConnected
        self.detailText = detailText.isEmpty ? "\(name)：\(batteryLevel)%" : detailText
        self.address = address
        self.hasMultiPartDetail = hasMultiPartDetail
        self.stableKey = stableKey
    }
}

private struct BluetoothProfilerMetadata: Sendable {
    let displayName: String
    let minorType: String
    let vendorID: Int
    let productID: Int
    let mainBattery: Int?
    let leftBattery: Int?
    let rightBattery: Int?
    let caseBattery: Int?
    let isConnected: Bool
}

@Observable
@MainActor
public final class AccessoryBatteryManager {
    public static let shared = AccessoryBatteryManager()

    public private(set) var accessories: [AccessoryBatteryItem] = []

    private var timer: Timer?
    private var isQueryingBluetooth: Bool = false
    private var lastBTQueryTime: Date = .distantPast
    private var isPausedForSleep: Bool = false

    private var btProfilerCache: [String: BluetoothProfilerMetadata] = [:]
    private var spConnectedFallbacks: [AccessoryBatteryItem] = []

    public init() {
        startPeriodicCheck()
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    public func startPeriodicCheck() {
        timer?.invalidate()
        guard !isPausedForSleep else { return }
        // Fast IOKit & IOBluetooth check every 5s when UI is visible
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func pauseForSleep() {
        isPausedForSleep = true
        timer?.invalidate()
        timer = nil
    }

    public func resumeFromWake() {
        isPausedForSleep = false
        refresh(forceBluetooth: true)
        startPeriodicCheck()
    }

    public func refresh(forceBluetooth: Bool = false) {
        guard !isPausedForSleep else { return }
        let nav = StudioWindowNavigationState.shared
        let isOverviewVisible = (MainStudioWindowController.shared.isWindowVisible || nav.isMainWindowVisible)
            && !nav.isModalPresented
            && nav.selectedTab == .status
        let isUIVisible = PowerSourceEngine.shared.isPanelVisible
            || isOverviewVisible
            || (MenuBarController.shared?.isPopoverShown ?? false)

        // When no UI shows accessories, only do occasional lightweight refresh
        guard isUIVisible || forceBluetooth || Date().timeIntervalSince(lastBTQueryTime) > 120.0 else {
            return
        }

        // 1. Instant IOKit scan (Apple HID + 3rd-party IOHIDDevice)
        let iokitItems = scanIOKitAccessories()

        // 2. Instant IOBluetooth scan (AirPods Max / Pro / Beats / BT Audio & HID)
        let btSnapshot = scanConnectedIOBluetoothDevices()

        // 3. Publish live merged snapshot immediately (prunes disconnected devices)
        mergeAndPublish(
            iokitItems: iokitItems,
            ioBluetoothItems: btSnapshot.connectedItems,
            disconnectedBTAddresses: btSnapshot.disconnectedAddresses
        )

        // 4. Only spawn system_profiler when forced, uncached newly-connected BT devices exist, or >120s stale
        if isUIVisible || forceBluetooth {
            let hasUncachedBTDevice = btSnapshot.connectedItems.contains { item in
                let addr = item.address.lowercased()
                return !addr.isEmpty && btProfilerCache[addr] == nil
            }
            let age = Date().timeIntervalSince(lastBTQueryTime)
            let shouldEnrichBT = forceBluetooth || lastBTQueryTime == .distantPast || hasUncachedBTDevice || age > 120.0
            if shouldEnrichBT && !isQueryingBluetooth && age > 5.0 {
                triggerAsyncBluetoothScan()
            }
        }
    }

    // MARK: - 1. IOKit Real-Time Scanner (Apple & 3rd-Party HID Peripherals)

    private func scanIOKitAccessories() -> [AccessoryBatteryItem] {
        var items: [AccessoryBatteryItem] = []
        var seenDedupeKeys: Set<String> = []

        for serviceClass in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            let matching = IOServiceMatching(serviceClass)
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any],
                      let level = Self.extractInt(dict["BatteryPercent"]),
                      level >= 0 && level <= 100 else {
                    continue
                }

                let usagePage = Self.extractInt(dict["PrimaryUsagePage"]) ?? 0
                let usage = Self.extractInt(dict["PrimaryUsage"]) ?? 0
                // Skip HID Power / Battery System (UPS devices handled by SystemUPSSettingsManager)
                if usagePage == 132 || usagePage == 84 || usagePage == 85 {
                    continue
                }

                let transport = (dict["Transport"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let upperTransport = transport.uppercased()
                if upperTransport == "SPU" || upperTransport == "SPMI" || upperTransport == "FIFO" {
                    continue
                }

                let cat = (dict["Accessory Category"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var prod = (dict["Product"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let addr = Self.normalizeAddress(dict["DeviceAddress"] as? String ?? "")
                let vendorID = Self.extractInt(dict["VendorID"]) ?? 0
                let productID = Self.extractInt(dict["ProductID"]) ?? 0
                let locationID = Self.extractInt(dict["LocationID"]) ?? 0

                let resolved = Self.resolveNativePeripheralSymbol(
                    product: prod,
                    category: cat,
                    vendorID: vendorID,
                    productID: productID,
                    hidUsagePage: usagePage,
                    hidUsage: usage
                )
                if prod.isEmpty { prod = resolved.defaultProductName }

                let dedupeKey: String = {
                    if !addr.isEmpty { return "addr:\(addr)" }
                    if vendorID != 0 || productID != 0 {
                        return "hid:\(vendorID):\(productID):\(locationID)"
                    }
                    var entryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(service, &entryID)
                    return "entry:\(entryID)"
                }()

                guard seenDedupeKeys.insert(dedupeKey).inserted else { continue }

                let transportLabel = transport.isEmpty ? "已连接" : transport
                let detail = "\(prod)：\(level)% (\(transportLabel))"

                items.append(AccessoryBatteryItem(
                    name: prod,
                    shortName: resolved.shortName,
                    iconName: resolved.symbolName,
                    batteryLevel: level,
                    isConnected: true,
                    detailText: detail,
                    address: addr,
                    stableKey: addr.isEmpty ? dedupeKey : addr
                ))
            }
        }

        return items
    }

    // MARK: - 2. Real-Time IOBluetooth Scanner (Zero-Latency AirPods / Audio / BT Peripherals)

    private func scanConnectedIOBluetoothDevices() -> (
        connectedItems: [AccessoryBatteryItem],
        disconnectedAddresses: Set<String>
    ) {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return ([], [])
        }

        var connectedItems: [AccessoryBatteryItem] = []
        var disconnectedAddresses: Set<String> = []

        for dev in paired {
            let addr = Self.normalizeAddress(dev.addressString ?? "")
            guard dev.isConnected() else {
                if !addr.isEmpty {
                    disconnectedAddresses.insert(addr)
                }
                continue
            }

            let meta = addr.isEmpty ? nil : btProfilerCache[addr]
            let ioName = (dev.name ?? dev.nameOrAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (meta?.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? ioName

            let left = Self.readBluetoothBatteryPercent(dev, key: "batteryPercentLeft")
            let right = Self.readBluetoothBatteryPercent(dev, key: "batteryPercentRight")
            let caseLevel = Self.readBluetoothBatteryPercent(dev, key: "batteryPercentCase") ?? meta?.caseBattery
            let combined = Self.readBluetoothBatteryPercent(dev, key: "batteryPercentCombined")
            let single = Self.readBluetoothBatteryPercent(dev, key: "batteryPercentSingle")
            let headset = Self.readBluetoothBatteryPercent(dev, key: "headsetBattery")

            let effectiveLeft = left ?? meta?.leftBattery
            let effectiveRight = right ?? meta?.rightBattery

            var detailParts: [String] = []
            if let l = effectiveLeft { detailParts.append("左耳 \(l)%") }
            if let r = effectiveRight { detailParts.append("右耳 \(r)%") }
            if let c = caseLevel { detailParts.append("充电盒 \(c)%") }

            let resolvedLevel: Int? = {
                if let l = effectiveLeft, let r = effectiveRight {
                    return (l + r) / 2
                }
                if let l = effectiveLeft { return l }
                if let r = effectiveRight { return r }
                if let c = combined { return c }
                if let s = single { return s }
                if let h = headset { return h }
                if let c = caseLevel { return c }
                return meta?.mainBattery
            }()

            guard let level = resolvedLevel else { continue }

            let resolved = Self.resolveNativePeripheralSymbol(
                product: displayName,
                category: meta?.minorType ?? "",
                vendorID: meta?.vendorID ?? 0,
                productID: meta?.productID ?? 0,
                deviceClassMajor: UInt32(dev.deviceClassMajor),
                deviceClassMinor: UInt32(dev.deviceClassMinor)
            )

            let finalName = displayName.isEmpty ? resolved.defaultProductName : displayName
            let hasMulti = !detailParts.isEmpty
            let detail = hasMulti
                ? "\(finalName)：\(level)% (\(detailParts.joined(separator: " · ")))"
                : "\(finalName)：\(level)% (蓝牙)"

            connectedItems.append(AccessoryBatteryItem(
                name: finalName,
                shortName: resolved.shortName,
                iconName: resolved.symbolName,
                batteryLevel: level,
                isConnected: true,
                detailText: detail,
                address: addr,
                hasMultiPartDetail: hasMulti,
                stableKey: addr.isEmpty ? finalName : addr
            ))
        }

        return (connectedItems, disconnectedAddresses)
    }

    // MARK: - 3. Background Bluetooth Profiler Scanner (Name, PID & Case Fallback Enrichment)

    private func triggerAsyncBluetoothScan() {
        isQueryingBluetooth = true
        lastBTQueryTime = Date()

        Task.detached(priority: .utility) {
            let parsed = Self.scanBluetoothViaSystemProfiler()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isQueryingBluetooth = false
                self.btProfilerCache.merge(parsed.metadataByAddress) { _, new in new }
                self.spConnectedFallbacks = parsed.connectedFallbackItems

                let iokitItems = self.scanIOKitAccessories()
                let btSnapshot = self.scanConnectedIOBluetoothDevices()
                self.mergeAndPublish(
                    iokitItems: iokitItems,
                    ioBluetoothItems: btSnapshot.connectedItems,
                    disconnectedBTAddresses: btSnapshot.disconnectedAddresses
                )
            }
        }
    }

    private nonisolated static func scanBluetoothViaSystemProfiler() -> (
        metadataByAddress: [String: BluetoothProfilerMetadata],
        connectedFallbackItems: [AccessoryBatteryItem]
    ) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        let data: Data
        do {
            try p.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            p.waitUntilExit()
        } catch {
            return ([:], [])
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return ([:], [])
        }

        var metadataByAddress: [String: BluetoothProfilerMetadata] = [:]
        var fallbackItems: [AccessoryBatteryItem] = []

        for item in items {
            for group in ["device_connected", "device_not_connected"] {
                guard let devs = item[group] as? [[String: Any]] else { continue }
                let isConnected = (group == "device_connected")

                for devDict in devs {
                    for (name, infoAny) in devDict {
                        guard let info = infoAny as? [String: Any] else { continue }
                        let minor = (info["device_minorType"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let addr = normalizeAddress(info["device_address"] as? String ?? "")
                        let vendorID = parseHexOrInt(info["device_vendorID"]) ?? 0
                        let productID = parseHexOrInt(info["device_productID"]) ?? 0

                        let mainBatt = parseBatteryPercent(info["device_batteryLevelMain"])
                        let leftBatt = parseBatteryPercent(info["device_batteryLevelLeft"])
                        let rightBatt = parseBatteryPercent(info["device_batteryLevelRight"])
                        let caseBatt = parseBatteryPercent(info["device_batteryLevelCase"])

                        if !addr.isEmpty {
                            metadataByAddress[addr] = BluetoothProfilerMetadata(
                                displayName: name,
                                minorType: minor,
                                vendorID: vendorID,
                                productID: productID,
                                mainBattery: mainBatt,
                                leftBattery: leftBatt,
                                rightBattery: rightBatt,
                                caseBattery: caseBatt,
                                isConnected: isConnected
                            )
                        }

                        guard isConnected else { continue }

                        var detailParts: [String] = []
                        if let l = leftBatt { detailParts.append("左耳 \(l)%") }
                        if let r = rightBatt { detailParts.append("右耳 \(r)%") }
                        if let c = caseBatt { detailParts.append("充电盒 \(c)%") }

                        let batt: Int? = {
                            if let m = mainBatt { return m }
                            if let l = leftBatt, let r = rightBatt { return (l + r) / 2 }
                            if let l = leftBatt { return l }
                            if let r = rightBatt { return r }
                            return caseBatt
                        }()

                        guard let level = batt else { continue }

                        let resolved = resolveNativePeripheralSymbol(
                            product: name,
                            category: minor,
                            vendorID: vendorID,
                            productID: productID
                        )

                        let hasMulti = !detailParts.isEmpty
                        let detail = hasMulti
                            ? "\(name)：\(level)% (\(detailParts.joined(separator: " · ")))"
                            : "\(name)：\(level)% (蓝牙)"

                        fallbackItems.append(AccessoryBatteryItem(
                            name: name,
                            shortName: resolved.shortName,
                            iconName: resolved.symbolName,
                            batteryLevel: level,
                            isConnected: true,
                            detailText: detail,
                            address: addr,
                            hasMultiPartDetail: hasMulti,
                            stableKey: addr.isEmpty ? name : addr
                        ))
                    }
                }
            }
        }

        return (metadataByAddress, fallbackItems)
    }

    // MARK: - Native Peripheral SF Symbol Resolver (Apple PID + Keywords + DeviceClass/HID Usage)

    public nonisolated static func resolveNativePeripheralSymbol(
        product: String,
        category: String,
        vendorID: Int = 0,
        productID: Int = 0,
        deviceClassMajor: UInt32 = 0,
        deviceClassMinor: UInt32 = 0,
        hidUsagePage: Int = 0,
        hidUsage: Int = 0
    ) -> (symbolName: String, shortName: String, defaultProductName: String) {
        let lower = (product + " " + category).lowercased()
        let isAppleVendor = (vendorID == 0x05AC || vendorID == 0x004C)

        // 0. Exact Apple ProductID match (immune to custom user renaming)
        if isAppleVendor, productID != 0 {
            switch productID {
            case 0x200A, 0x202D:
                return ("airpodsmax", "AirPods Max", "AirPods Max")
            case 0x200E, 0x2014, 0x2024:
                return ("airpodspro", "AirPods Pro", "AirPods Pro")
            case 0x2019, 0x201B:
                return ("airpods.gen4", "AirPods 4", "AirPods 4")
            case 0x2013:
                return ("airpods.gen3", "AirPods 3", "AirPods 3")
            case 0x2002, 0x200F:
                return ("airpods", "AirPods", "AirPods")
            default:
                break
            }
        }

        // 1. Trackpad
        if lower.contains("trackpad") || lower.contains("妙控板") || lower.contains("触控板")
            || (hidUsagePage == 13 && hidUsage == 5) {
            return ("trackpad.fill", "妙控板", "Magic Trackpad")
        }

        // 2. Keyboard
        if lower.contains("keyboard") || lower.contains("键盘")
            || (hidUsagePage == 1 && hidUsage == 6) {
            let short = (isAppleVendor || lower.contains("magic") || lower.contains("apple") || lower.contains("妙控")) ? "妙控键盘" : "蓝牙键盘"
            let defProd = short == "妙控键盘" ? "Magic Keyboard" : "Bluetooth Keyboard"
            return ("keyboard.fill", short, defProd)
        }

        // 3. Mouse
        if lower.contains("mouse") || lower.contains("鼠标")
            || (hidUsagePage == 1 && hidUsage == 2) {
            let isMagic = isAppleVendor || lower.contains("magic") || lower.contains("apple") || lower.contains("妙控")
            return isMagic
                ? ("magicmouse.fill", "妙控鼠标", "Magic Mouse")
                : ("computermouse.fill", "蓝牙鼠标", "Bluetooth Mouse")
        }

        // 4. Game Controller
        if lower.contains("gamepad") || lower.contains("controller") || lower.contains("dualshock")
            || lower.contains("dualsense") || lower.contains("xbox") || lower.contains("joy-con")
            || lower.contains("8bitdo") || lower.contains("switch pro") || lower.contains("手柄")
            || (hidUsagePage == 1 && (hidUsage == 4 || hidUsage == 5)) {
            return ("gamecontroller.fill", "游戏手柄", "Game Controller")
        }

        // 5. Stylus / Apple Pencil
        if lower.contains("pencil") {
            return ("applepencil", "Apple Pencil", "Apple Pencil")
        }
        if hidUsagePage == 13 && (hidUsage == 1 || hidUsage == 2) {
            return ("pencil.and.outline", product.isEmpty ? "数位板" : product, "Digitizer")
        }

        // 6. AirPods Series
        if lower.contains("airpod") {
            if lower.contains("max") {
                return ("airpodsmax", "AirPods Max", "AirPods Max")
            } else if lower.contains("pro") {
                return ("airpodspro", "AirPods Pro", "AirPods Pro")
            } else if lower.contains("airpods 4") || lower.contains("gen 4") || lower.contains("4th") || lower.contains("四代") || lower.contains("4代") {
                return ("airpods.gen4", "AirPods 4", "AirPods 4")
            } else if lower.contains("airpods 3") || lower.contains("gen 3") || lower.contains("3rd") || lower.contains("三代") || lower.contains("3代") {
                return ("airpods.gen3", "AirPods 3", "AirPods 3")
            } else {
                return ("airpods", "AirPods", "AirPods")
            }
        }

        // 7. Beats Series
        if lower.contains("beats") || lower.contains("powerbeats") {
            if lower.contains("fit pro") || lower.contains("fitpro") {
                return ("beats.fitpro", "Beats Fit Pro", "Beats Fit Pro")
            } else if lower.contains("studio buds") || lower.contains("studiobuds") || lower.contains("solo buds") {
                return ("beats.studiobuds", "Beats Buds", "Beats Studio Buds")
            } else if lower.contains("powerbeats pro") {
                return ("beats.powerbeatspro", "Powerbeats Pro", "Powerbeats Pro")
            } else if lower.contains("powerbeats") {
                return ("beats.powerbeats", "Powerbeats", "Powerbeats")
            } else if lower.contains("flex") || lower.contains("beatsx") || lower.contains("beats x") {
                return ("beats.earphones", "Beats Flex", "Beats Flex")
            } else {
                return ("beats.headphones", "Beats", "Beats Headphones")
            }
        }

        // 8. Generic Headphones / Speakers by keyword
        if lower.contains("headphone") || lower.contains("headset") || lower.contains("earbud") || lower.contains("earphone") || lower.contains("耳机") {
            return ("headphones", product.isEmpty ? "蓝牙耳机" : product, "Bluetooth Headphones")
        }
        if lower.contains("speaker") || lower.contains("音箱") {
            return ("hifispeaker.fill", product.isEmpty ? "蓝牙音箱" : product, "Bluetooth Speaker")
        }

        // 9. Classic Bluetooth CoD fallback (catches renamed keyboards, mice, gamepads, headphones, speakers)
        if deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) {
            if deviceClassMinor == UInt32(kBluetoothDeviceClassMinorAudioLoudspeaker) {
                return ("hifispeaker.fill", product.isEmpty ? "蓝牙音箱" : product, "Bluetooth Speaker")
            }
            return ("headphones", product.isEmpty ? "蓝牙耳机" : product, "Bluetooth Headphones")
        }
        if deviceClassMajor == UInt32(kBluetoothDeviceClassMajorPeripheral) {
            let minorPrimary = deviceClassMinor & 0x30
            let minorSecondary = deviceClassMinor & 0x0F
            if minorSecondary == UInt32(kBluetoothDeviceClassMinorPeripheral2Joystick)
                || minorSecondary == UInt32(kBluetoothDeviceClassMinorPeripheral2Gamepad) {
                return ("gamecontroller.fill", "游戏手柄", "Game Controller")
            }
            if minorSecondary == UInt32(kBluetoothDeviceClassMinorPeripheral2DigitizerTablet)
                || minorSecondary == UInt32(kBluetoothDeviceClassMinorPeripheral2DigitalPen) {
                return ("pencil.and.outline", product.isEmpty ? "数位板" : product, "Digitizer")
            }
            if minorPrimary == UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard) {
                return ("keyboard.fill", isAppleVendor ? "妙控键盘" : "蓝牙键盘", "Bluetooth Keyboard")
            }
            if minorPrimary == UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing) {
                return (isAppleVendor ? "magicmouse.fill" : "computermouse.fill", isAppleVendor ? "妙控鼠标" : "蓝牙鼠标", "Bluetooth Mouse")
            }
        }

        let fallbackShort = category.isEmpty ? (product.isEmpty ? "外设" : product) : category
        return ("bolt.horizontal.fill", fallbackShort, product.isEmpty ? fallbackShort : product)
    }

    // MARK: - 4. Merge & Prioritize (Live Snapshot, Zero Disconnected Zombies)

    private func mergeAndPublish(
        iokitItems: [AccessoryBatteryItem],
        ioBluetoothItems: [AccessoryBatteryItem],
        disconnectedBTAddresses: Set<String>
    ) {
        var merged = iokitItems

        func mergeBluetoothItem(_ bt: AccessoryBatteryItem) {
            let normalizedBT = Self.normalizeAddress(bt.address)
            if let idx = merged.firstIndex(where: { existing in
                let normalizedExisting = Self.normalizeAddress(existing.address)
                if !normalizedBT.isEmpty && !normalizedExisting.isEmpty {
                    return normalizedBT == normalizedExisting
                }
                return existing.name == bt.name
            }) {
                let existing = merged[idx]
                // Keep richer multi-ear detail or fresher Bluetooth name while preserving live IOKit battery for HID
                let preferBTDetail = bt.hasMultiPartDetail || !existing.hasMultiPartDetail
                merged[idx] = AccessoryBatteryItem(
                    name: bt.name.count >= existing.name.count ? bt.name : existing.name,
                    shortName: existing.shortName == "外设" ? bt.shortName : existing.shortName,
                    iconName: existing.iconName == "bolt.horizontal.fill" ? bt.iconName : existing.iconName,
                    batteryLevel: bt.hasMultiPartDetail ? bt.batteryLevel : existing.batteryLevel,
                    isConnected: true,
                    detailText: preferBTDetail ? bt.detailText : existing.detailText,
                    address: normalizedBT.isEmpty ? existing.address : normalizedBT,
                    hasMultiPartDetail: bt.hasMultiPartDetail || existing.hasMultiPartDetail,
                    stableKey: existing.id
                )
            } else {
                merged.append(bt)
            }
        }

        for bt in ioBluetoothItems {
            mergeBluetoothItem(bt)
        }

        // Only use SPBluetooth fallback if IOBluetooth hasn't already marked that address disconnected
        for sp in spConnectedFallbacks {
            let addr = Self.normalizeAddress(sp.address)
            if !addr.isEmpty && disconnectedBTAddresses.contains(addr) {
                continue
            }
            mergeBluetoothItem(sp)
        }

        self.accessories = prioritizeAndSort(merged)
    }

    private func prioritizeAndSort(_ items: [AccessoryBatteryItem]) -> [AccessoryBatteryItem] {
        let connectedOnly = items.filter { $0.isConnected }
        let sorted = connectedOnly.sorted { a, b in
            priorityWeight(a) < priorityWeight(b)
        }
        return Array(sorted.prefix(4))
    }

    private func priorityWeight(_ item: AccessoryBatteryItem) -> Int {
        let n = item.shortName
        if n.contains("键盘") { return 1 }
        if n.contains("板") || n.contains("鼠标") { return 2 }
        if n.contains("AirPods") || n.contains("Beats") || n.contains("耳机") { return 3 }
        return 4
    }

    // MARK: - Helpers

    private nonisolated static func normalizeAddress(_ addr: String) -> String {
        addr.lowercased().replacingOccurrences(of: "-", with: ":").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func extractInt(_ value: Any?) -> Int? {
        if let num = value as? NSNumber { return num.intValue }
        if let i = value as? Int { return i }
        return nil
    }

    private nonisolated static func parseBatteryPercent(_ value: Any?) -> Int? {
        if let i = extractInt(value), i >= 0, i <= 100 {
            return i
        }
        if let str = value as? String {
            let clean = str.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(clean), i >= 0, i <= 100 {
                return i
            }
        }
        return nil
    }

    private nonisolated static func parseHexOrInt(_ value: Any?) -> Int? {
        if let i = extractInt(value) { return i }
        if let raw = value as? String {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasPrefix("0x"), let parsed = Int(s.dropFirst(2), radix: 16) {
                return parsed
            }
            return Int(s)
        }
        return nil
    }

    private static func readBluetoothInt(_ dev: IOBluetoothDevice, key: String) -> Int? {
        let sel = NSSelectorFromString(key)
        guard dev.responds(to: sel) else { return nil }
        return extractInt(dev.value(forKey: key))
    }

    private static func readBluetoothBatteryPercent(_ dev: IOBluetoothDevice, key: String) -> Int? {
        // IOBluetoothDevice reports 0 as a sentinel when a battery slot is unavailable
        guard let val = readBluetoothInt(dev, key: key), val > 0, val <= 100 else {
            return nil
        }
        return val
    }
}
