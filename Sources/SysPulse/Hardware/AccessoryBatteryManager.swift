import Foundation
import IOKit
import Observation

public struct AccessoryBatteryItem: Identifiable, Sendable {
    public var id: String { address.isEmpty ? name : address.lowercased() }
    public let name: String
    public let shortName: String
    public let iconName: String
    public let batteryLevel: Int
    public let isConnected: Bool
    public let detailText: String
    public let address: String

    public init(
        name: String,
        shortName: String = "",
        iconName: String,
        batteryLevel: Int,
        isConnected: Bool = true,
        detailText: String = "",
        address: String = ""
    ) {
        self.name = name
        self.shortName = shortName.isEmpty ? name : shortName
        self.iconName = iconName
        self.batteryLevel = max(0, min(100, batteryLevel))
        self.isConnected = isConnected
        self.detailText = detailText.isEmpty ? "\(name)：\(batteryLevel)%" : detailText
        self.address = address
    }
}

@Observable
@MainActor
public final class AccessoryBatteryManager {
    public static let shared = AccessoryBatteryManager()

    public private(set) var accessories: [AccessoryBatteryItem] = []

    private var timer: Timer?
    private var isQueryingBluetooth: Bool = false
    private var lastBTQueryTime: Date = .distantPast

    public init() {
        refresh()
        startPeriodicCheck()
    }

    public func startPeriodicCheck() {
        timer?.invalidate()
        // Fast IOKit check every 5s; BT profiler check every 15s
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    public func refresh(forceBluetooth: Bool = false) {
        let isUIVisible = PowerSourceEngine.shared.isPanelVisible || MainStudioWindowController.shared.isWindowVisible

        // 1. Instant IOKit scan for connected Apple & 3rd-party HID peripherals
        let iokitItems = scanIOKitAccessories()
        
        // Merge with existing BT items if available
        mergeAndPublish(iokitItems: iokitItems)

        // 2. Trigger async Bluetooth scan with adaptive interval (15s when UI visible, 60s when backgrounded)
        let btInterval: TimeInterval = forceBluetooth ? 5.0 : (isUIVisible ? 15.0 : 60.0)
        if !isQueryingBluetooth && Date().timeIntervalSince(lastBTQueryTime) > btInterval {
            triggerAsyncBluetoothScan()
        }
    }

    // MARK: - 1. IOKit Real-Time Scanner (0.1ms, zero latency)

    private func scanIOKitAccessories() -> [AccessoryBatteryItem] {
        var items: [AccessoryBatteryItem] = []
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        var iterator: io_iterator_t = 0

        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    
                    let cat = dict["Accessory Category"] as? String ?? ""
                    var prod = dict["Product"] as? String ?? ""
                    let addr = dict["DeviceAddress"] as? String ?? ""
                    let transport = dict["Transport"] as? String ?? ""
                    
                    // Safely extract BatteryPercent (supports NSNumber or Int)
                    let level: Int? = {
                        if let num = dict["BatteryPercent"] as? NSNumber {
                            return num.intValue
                        }
                        if let i = dict["BatteryPercent"] as? Int {
                            return i
                        }
                        return nil
                    }()
                    
                    if let level = level {
                        let vendorID = (dict["VendorID"] as? NSNumber)?.intValue ?? 0
                        let resolved = Self.resolveNativePeripheralSymbol(
                            product: prod,
                            category: cat,
                            vendorID: vendorID
                        )
                        if prod.isEmpty { prod = resolved.defaultProductName }

                        let detail = "\(prod)：\(level)% (\(transport.isEmpty ? "已连接" : transport))"
                        let normalizedAddr = normalizeAddress(addr)
                        
                        // Deduplicate by address or name
                        if !items.contains(where: {
                            (!normalizedAddr.isEmpty && normalizeAddress($0.address) == normalizedAddr) || $0.name == prod
                        }) {
                            items.append(AccessoryBatteryItem(
                                name: prod,
                                shortName: resolved.shortName,
                                iconName: resolved.symbolName,
                                batteryLevel: level,
                                isConnected: true,
                                detailText: detail,
                                address: normalizedAddr
                            ))
                        }
                    }
                }
            }
        }
        return items
    }

    // MARK: - 2. Background Bluetooth Profiler Scanner (AirPods & BT Audio)

    private func triggerAsyncBluetoothScan() {
        isQueryingBluetooth = true
        lastBTQueryTime = Date()

        Task.detached(priority: .utility) {
            let btItems = Self.scanBluetoothViaSystemProfiler()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isQueryingBluetooth = false
                self.mergeBluetoothScanResults(btItems)
            }
        }
    }

    private nonisolated static func scanBluetoothViaSystemProfiler() -> [AccessoryBatteryItem] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return []
        }

        var results: [AccessoryBatteryItem] = []

        for item in items {
            for group in ["device_connected", "device_not_connected"] {
                guard let devs = item[group] as? [[String: Any]] else { continue }
                let isConnected = (group == "device_connected")
                for devDict in devs {
                    for (name, infoAny) in devDict {
                        guard let info = infoAny as? [String: Any] else { continue }
                        let minor = (info["device_minorType"] as? String ?? "").lowercased()
                        let addr = info["device_address"] as? String ?? ""

                        let mainStr = (info["device_batteryLevelMain"] as? String)?.replacingOccurrences(of: "%", with: "")
                        let leftStr = (info["device_batteryLevelLeft"] as? String)?.replacingOccurrences(of: "%", with: "")
                        let rightStr = (info["device_batteryLevelRight"] as? String)?.replacingOccurrences(of: "%", with: "")
                        let caseStr = (info["device_batteryLevelCase"] as? String)?.replacingOccurrences(of: "%", with: "")

                        var batt: Int? = nil
                        var detailParts: [String] = []

                        if let l = leftStr, let lVal = Int(l.trimmingCharacters(in: .whitespaces)) {
                            detailParts.append("左耳 \(lVal)%")
                        }
                        if let r = rightStr, let rVal = Int(r.trimmingCharacters(in: .whitespaces)) {
                            detailParts.append("右耳 \(rVal)%")
                        }
                        if let c = caseStr, let cVal = Int(c.trimmingCharacters(in: .whitespaces)) {
                            detailParts.append("充电盒 \(cVal)%")
                        }

                        if let m = mainStr, let val = Int(m.trimmingCharacters(in: .whitespaces)) {
                            batt = val
                        } else if let l = leftStr, let r = rightStr,
                                  let lVal = Int(l.trimmingCharacters(in: .whitespaces)),
                                  let rVal = Int(r.trimmingCharacters(in: .whitespaces)) {
                            batt = (lVal + rVal) / 2
                        } else if let l = leftStr, let lVal = Int(l.trimmingCharacters(in: .whitespaces)) {
                            batt = lVal
                        } else if let r = rightStr, let rVal = Int(r.trimmingCharacters(in: .whitespaces)) {
                            batt = rVal
                        } else if let c = caseStr, let cVal = Int(c.trimmingCharacters(in: .whitespaces)) {
                            batt = cVal
                        }

                        guard let level = batt else { continue }

                        let vendorStr = (info["device_vendorID"] as? String ?? "").lowercased()
                        let vendorID: Int = (vendorStr.contains("05ac") || vendorStr.contains("004c")) ? 0x05AC : 0
                        let resolved = Self.resolveNativePeripheralSymbol(
                            product: name,
                            category: minor,
                            vendorID: vendorID
                        )

                        let detail = detailParts.isEmpty ? "\(name)：\(level)%" : "\(name)：\(level)% (\(detailParts.joined(separator: " · ")))"
                        let normalizedAddr = addr.lowercased().replacingOccurrences(of: "-", with: ":")

                        results.append(AccessoryBatteryItem(
                            name: name,
                            shortName: resolved.shortName,
                            iconName: resolved.symbolName,
                            batteryLevel: level,
                            isConnected: isConnected,
                            detailText: detail,
                            address: normalizedAddr
                        ))
                    }
                }
            }
        }

        return results
    }

    // MARK: - Native Peripheral SF Symbol Resolver (Filled Input Peripherals + Model-Specific Audio)

    public nonisolated static func resolveNativePeripheralSymbol(
        product: String,
        category: String,
        vendorID: Int = 0
    ) -> (symbolName: String, shortName: String, defaultProductName: String) {
        let lower = (product + " " + category).lowercased()
        let isAppleVendor = (vendorID == 0x05AC || vendorID == 0x004C)

        // 1. Trackpad (妙控板 - 实心填充款 trackpad.fill)
        if lower.contains("trackpad") || lower.contains("妙控板") || lower.contains("触控板") {
            return ("trackpad.fill", "妙控板", "Magic Trackpad")
        }

        // 2. Keyboard (妙控键盘 / 蓝牙键盘 - 实心填充款 keyboard.fill)
        if lower.contains("keyboard") || lower.contains("键盘") {
            let short = (isAppleVendor || lower.contains("magic") || lower.contains("apple") || lower.contains("妙控")) ? "妙控键盘" : "蓝牙键盘"
            let defProd = short == "妙控键盘" ? "Magic Keyboard" : "Bluetooth Keyboard"
            return ("keyboard.fill", short, defProd)
        }

        // 3. Mouse (妙控鼠标 magicmouse.fill / 第三方鼠标 computermouse.fill)
        if lower.contains("mouse") || lower.contains("鼠标") {
            let isMagic = isAppleVendor || lower.contains("magic") || lower.contains("apple") || lower.contains("妙控")
            if isMagic {
                return ("magicmouse.fill", "妙控鼠标", "Magic Mouse")
            } else {
                return ("computermouse.fill", "蓝牙鼠标", "Bluetooth Mouse")
            }
        }

        // 4. Game Controller (游戏手柄 - 实心填充款 gamecontroller.fill)
        if lower.contains("gamepad") || lower.contains("controller") || lower.contains("dualshock")
            || lower.contains("dualsense") || lower.contains("xbox") || lower.contains("joy-con")
            || lower.contains("手柄") {
            return ("gamecontroller.fill", "游戏手柄", "Game Controller")
        }

        // 5. Apple Pencil
        if lower.contains("pencil") {
            return ("applepencil", "Apple Pencil", "Apple Pencil")
        }

        // 6. AirPods Series (按具体代际与型号匹配苹果原生图标)
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

        // 7. Beats Series (按头戴式、入耳式、耳翼式、耳挂式、颈挂式匹配苹果原生图标)
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

        // 8. Generic Headphones / Speakers
        if lower.contains("headphone") || lower.contains("headset") || lower.contains("earbud") || lower.contains("earphone") || lower.contains("耳机") {
            return ("headphones", product.isEmpty ? "蓝牙耳机" : product, "Bluetooth Headphones")
        }
        if lower.contains("speaker") || lower.contains("音箱") {
            return ("hifispeaker.fill", product.isEmpty ? "蓝牙音箱" : product, "Bluetooth Speaker")
        }

        // Fallback
        let fallbackShort = category.isEmpty ? "外设" : category
        return ("bolt.horizontal.fill", fallbackShort, product.isEmpty ? fallbackShort : product)
    }

    // MARK: - 3. Merge & Prioritize

    private func mergeAndPublish(iokitItems: [AccessoryBatteryItem]) {
        var merged = iokitItems

        // Retain existing known Bluetooth accessories (like AirPods) ONLY if actively connected
        for existing in self.accessories where existing.isConnected {
            let normalized = normalizeAddress(existing.address)
            if !merged.contains(where: {
                (!normalized.isEmpty && normalizeAddress($0.address) == normalized) || $0.name == existing.name
            }) {
                merged.append(existing)
            }
        }

        self.accessories = prioritizeAndSort(merged)
    }

    private func mergeBluetoothScanResults(_ btItems: [AccessoryBatteryItem]) {
        var merged = self.accessories

        for bt in btItems {
            let normalizedBT = normalizeAddress(bt.address)
            if let idx = merged.firstIndex(where: {
                (!normalizedBT.isEmpty && normalizeAddress($0.address) == normalizedBT) || $0.name == bt.name
            }) {
                // If IOKit already marked it connected, keep isConnected true
                let isConn = merged[idx].isConnected || bt.isConnected
                merged[idx] = AccessoryBatteryItem(
                    name: bt.name,
                    shortName: bt.shortName,
                    iconName: bt.iconName,
                    batteryLevel: bt.batteryLevel,
                    isConnected: isConn,
                    detailText: bt.detailText,
                    address: normalizedBT
                )
            } else if bt.isConnected {
                // Only append if actively connected
                merged.append(bt)
            }
        }

        self.accessories = prioritizeAndSort(merged)
    }

    private func prioritizeAndSort(_ items: [AccessoryBatteryItem]) -> [AccessoryBatteryItem] {
        // 仅保留当前已连接的设备
        let connectedOnly = items.filter { $0.isConnected }
        let sorted = connectedOnly.sorted { a, b in
            return priorityWeight(a) < priorityWeight(b)
        }

        // Return up to 4 items for harmonious card layout
        return Array(sorted.prefix(4))
    }

    private func priorityWeight(_ item: AccessoryBatteryItem) -> Int {
        let n = item.shortName
        if n.contains("键盘") { return 1 }
        if n.contains("板") || n.contains("鼠标") { return 2 }
        if n.contains("AirPods") || n.contains("耳机") { return 3 }
        return 4
    }

    private func normalizeAddress(_ addr: String) -> String {
        addr.lowercased().replacingOccurrences(of: "-", with: ":").trimmingCharacters(in: .whitespaces)
    }
}
