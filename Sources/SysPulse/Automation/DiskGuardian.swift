import Foundation
import AppKit
import Observation
import OSLog

public struct ExternalDiskItem: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var isProtected: Bool

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    public var capacityString: String {
        formattedSize
    }
}

@Observable
@MainActor
public final class DiskGuardian {
    public static let shared = DiskGuardian()

    private let logger = Logger(subsystem: "com.apple.powerglass", category: "DiskGuardian")

    /// Whether auto-eject on battery power is enabled.
    public var isAutoEjectEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isAutoEjectEnabled, forKey: "SP_DiskGuardian_AutoEject")
        }
    }
    public var autoEjectEnabled: Bool {
        get { isAutoEjectEnabled }
        set { isAutoEjectEnabled = newValue }
    }
    /// Delay in seconds before triggering auto-eject after outage (e.g. 180s = 3 mins).
    public var delaySeconds: Int = 180 {
        didSet {
            UserDefaults.standard.set(delaySeconds, forKey: "SP_DiskGuardian_DelaySeconds")
        }
    }
    public var delayMinutes: Int {
        get { max(1, delaySeconds / 60) }
        set { delaySeconds = max(60, newValue * 60) }
    }
    /// Remaining seconds if countdown is active.
    public var remainingCountdown: Int? = nil

    public private(set) var externalDisks: [ExternalDiskItem] = []
    public var mountedExternalDisks: [ExternalDiskItem] { externalDisks }

    public func emergencyEjectAll() {
        executeSafeEjection()
    }

    private var countdownTimer: Timer?

    public init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "SP_DiskGuardian_AutoEject") != nil {
            self.isAutoEjectEnabled = defaults.bool(forKey: "SP_DiskGuardian_AutoEject")
        }
        let savedDelay = defaults.integer(forKey: "SP_DiskGuardian_DelaySeconds")
        if savedDelay >= 60 {
            self.delaySeconds = savedDelay
        }
        if FeatureToggleManager.shared.enablePluginUPSManager {
            refreshDisks()
        }
    }

    /// Discover external mounted volumes (skipping root macOS volume).
    public func refreshDisks() {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return
        }

        var results: [ExternalDiskItem] = []

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isInternal = values.volumeIsInternal ?? true
            let name = values.volumeName ?? url.lastPathComponent

            // Skip internal boot drive
            if isInternal && (url.path == "/" || name.contains("Macintosh")) {
                continue
            }

            // Exclude system mounts
            if url.path.hasPrefix("/System") || url.path.hasPrefix("/private") {
                continue
            }

            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)

            results.append(ExternalDiskItem(
                name: name,
                path: url.path,
                totalBytes: total,
                freeBytes: free,
                isProtected: true
            ))
        }

        self.externalDisks = results
    }

    // MARK: - Outage Trigger Handling

    public func handlePowerOutageStarted() {
        guard isAutoEjectEnabled, !externalDisks.isEmpty else { return }
        
        logger.warning("市电中断，启动外接磁盘安全保护倒计时: \(self.delaySeconds) 秒")
        remainingCountdown = delaySeconds

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let count = self.remainingCountdown, count > 1 {
                    self.remainingCountdown = count - 1
                } else {
                    self.executeSafeEjection()
                }
            }
        }
    }

    public func handlePowerRestored() {
        if countdownTimer != nil {
            logger.info("市电恢复，取消外接磁盘弹出倒计时")
            countdownTimer?.invalidate()
            countdownTimer = nil
            remainingCountdown = nil
        }
    }

    /// Safely unmount and eject all protected external drives
    public func executeSafeEjection() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        remainingCountdown = nil

        logger.notice("开始安全弹出外接磁盘保护数据...")

        let workspace = NSWorkspace.shared
        for disk in externalDisks where disk.isProtected {
            let url = URL(fileURLWithPath: disk.path)
            do {
                try workspace.unmountAndEjectDevice(at: url)
                logger.info("磁盘 \(disk.name) 已成功安全卸载")
                PowerSourceEngine.shared.appendEvent(PowerEvent(
                    type: .diskEjected,
                    details: "为防止断电掉盘，已自动安全弹出外接磁盘: [\(disk.name)]"
                ))
            } catch {
                logger.error("弹出磁盘 \(disk.name) 失败: \(error.localizedDescription)")
            }
        }
        refreshDisks()
    }

    /// Safely eject a specific external drive
    public func ejectDisk(at path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            logger.info("磁盘 \(path) 已安全弹出")
            refreshDisks()
        } catch {
            logger.error("弹出指定磁盘失败: \(error.localizedDescription)")
        }
    }
}
