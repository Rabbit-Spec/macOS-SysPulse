import Foundation
import Observation

/// Manages user-configurable feature and display toggles for both the Menu Bar Popover and the Studio Main Window.
/// 双层持久化存储配置（Application Support JSON + UserDefaults）。
@Observable
@MainActor
public final class FeatureToggleManager {
    public static let shared = FeatureToggleManager()

    public var onTogglesChanged: (@MainActor @Sendable () -> Void)?

    // MARK: - 1. Menu Bar Status Text Toggles (状态栏文字显示项)

    public var menuBarShowCpuGpu: Bool {
        didSet { save("SP_MB_ShowCpuGpu", menuBarShowCpuGpu) }
    }
    public var menuBarShowMemTemp: Bool {
        didSet { save("SP_MB_ShowMemTemp", menuBarShowMemTemp) }
    }
    public var menuBarShowNetworkSpeed: Bool {
        didSet { save("SP_MB_ShowNetworkSpeed", menuBarShowNetworkSpeed) }
    }
    public var menuBarShowSystemWatts: Bool {
        didSet { save("SP_MB_ShowSystemWatts", menuBarShowSystemWatts) }
    }

    // MARK: - 2. Core Telemetry Module Switches (核心监控功能模块开关)

    public var enableSystemPowerMonitor: Bool {
        didSet { save("SP_Mod_SystemPower", enableSystemPowerMonitor) }
    }
    public var enableMemoryMonitor: Bool {
        didSet { save("SP_Mod_Memory", enableMemoryMonitor) }
    }
    public var enableDiskIOMonitor: Bool {
        didSet { save("SP_Mod_DiskIO", enableDiskIOMonitor) }
    }
    public var enableTopEnergyAppsMonitor: Bool {
        didSet { save("SP_Mod_TopEnergyApps", enableTopEnergyAppsMonitor) }
    }
    public var enableLoadRuntimeMonitor: Bool {
        didSet { save("SP_Mod_LoadRuntime", enableLoadRuntimeMonitor) }
    }
    public var enableDiskGuardian: Bool {
        didSet { save("SP_Mod_DiskGuardian", enableDiskGuardian) }
    }
    public var enableStorageCleaner: Bool {
        didSet { save("SP_Mod_StorageCleaner", enableStorageCleaner) }
    }
    public var enableAppManager: Bool {
        didSet { save("SP_Mod_AppManager", enableAppManager) }
    }
    public var enablePowerEvents: Bool {
        didSet { save("SP_Mod_PowerEvents", enablePowerEvents) }
    }
    public var enableMacBookDemoMode: Bool {
        didSet { save("SP_Mod_MacBookDemoMode", enableMacBookDemoMode) }
    }

    // MARK: - Persistence Engine

    private static var settingsFileURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SysPulse", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private static func loadPersistentDict() -> [String: Bool] {
        let fileURL = settingsFileURL
        if let data = try? Data(contentsOf: fileURL),
           let dict = try? JSONDecoder().decode([String: Bool].self, from: data) {
            return dict
        }
        return [:]
    }

    private init() {
        let persistent = Self.loadPersistentDict()
        let d = UserDefaults.standard

        func readBool(_ key: String, legacyKey: String = "", defaultValue: Bool) -> Bool {
            if let val = d.object(forKey: key) as? Bool { return val }
            if let val = persistent[key] { return val }
            if !legacyKey.isEmpty, let val = d.object(forKey: legacyKey) as? Bool { return val }
            return defaultValue
        }

        self.menuBarShowCpuGpu = readBool("SP_MB_ShowCpuGpu", defaultValue: true)
        self.menuBarShowMemTemp = readBool("SP_MB_ShowMemTemp", defaultValue: false)
        self.menuBarShowNetworkSpeed = readBool("SP_MB_ShowNetworkSpeed", defaultValue: false)
        self.menuBarShowSystemWatts = readBool("SP_MB_ShowSystemWatts", legacyKey: "PG_MB_ShowSystemWatts", defaultValue: false)

        self.enableSystemPowerMonitor = readBool("SP_Mod_SystemPower", legacyKey: "PG_Mod_SystemPower", defaultValue: true)
        self.enableMemoryMonitor = readBool("SP_Mod_Memory", legacyKey: "PG_Mod_Memory", defaultValue: true)
        self.enableDiskIOMonitor = readBool("SP_Mod_DiskIO", legacyKey: "PG_Mod_DiskIO", defaultValue: true)
        self.enableTopEnergyAppsMonitor = readBool("SP_Mod_TopEnergyApps", legacyKey: "PG_Mod_TopEnergyApps", defaultValue: true)
        self.enableLoadRuntimeMonitor = readBool("SP_Mod_LoadRuntime", legacyKey: "PG_Mod_LoadRuntime", defaultValue: true)
        self.enableDiskGuardian = readBool("SP_Mod_DiskGuardian", legacyKey: "PG_Mod_DiskGuardian", defaultValue: true)
        self.enableStorageCleaner = readBool("SP_Mod_StorageCleaner", legacyKey: "PG_Mod_StorageCleaner", defaultValue: true)
        self.enableAppManager = readBool("SP_Mod_AppManager", legacyKey: "PG_Mod_AppManager", defaultValue: true)
        self.enablePowerEvents = readBool("SP_Mod_PowerEvents", legacyKey: "PG_Mod_PowerEvents", defaultValue: true)
        self.enableMacBookDemoMode = readBool("SP_Mod_MacBookDemoMode", legacyKey: "PG_enableMacBookDemoMode", defaultValue: false)

        saveAllToDisk()
    }

    private func save(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        saveAllToDisk()
        onTogglesChanged?()
    }

    private func saveAllToDisk() {
        let dict: [String: Bool] = [
            "SP_MB_ShowCpuGpu": menuBarShowCpuGpu,
            "SP_MB_ShowMemTemp": menuBarShowMemTemp,
            "SP_MB_ShowNetworkSpeed": menuBarShowNetworkSpeed,
            "SP_MB_ShowSystemWatts": menuBarShowSystemWatts,

            "SP_Mod_SystemPower": enableSystemPowerMonitor,
            "SP_Mod_Memory": enableMemoryMonitor,
            "SP_Mod_DiskIO": enableDiskIOMonitor,
            "SP_Mod_TopEnergyApps": enableTopEnergyAppsMonitor,
            "SP_Mod_LoadRuntime": enableLoadRuntimeMonitor,
            "SP_Mod_DiskGuardian": enableDiskGuardian,
            "SP_Mod_StorageCleaner": enableStorageCleaner,
            "SP_Mod_AppManager": enableAppManager,
            "SP_Mod_PowerEvents": enablePowerEvents,
            "SP_Mod_MacBookDemoMode": enableMacBookDemoMode
        ]
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: Self.settingsFileURL, options: .atomic)
        }
    }

    public func resetToDefaults() {
        menuBarShowCpuGpu = true
        menuBarShowMemTemp = false
        menuBarShowNetworkSpeed = false
        menuBarShowSystemWatts = false

        enableSystemPowerMonitor = true
        enableMemoryMonitor = true
        enableDiskIOMonitor = true
        enableTopEnergyAppsMonitor = true
        enableLoadRuntimeMonitor = true
        enableDiskGuardian = true
        enableStorageCleaner = true
        enableAppManager = true
        enablePowerEvents = true
        enableMacBookDemoMode = false
        saveAllToDisk()
    }
}
