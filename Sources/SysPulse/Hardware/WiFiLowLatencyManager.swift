import Foundation
import AppKit
import Observation
import UserNotifications

/// Wi-Fi 低延迟模式管理器 (awdl0 接口控制)
///
/// Pauses Apple Wireless Direct Link (awdl0) interface during intense network activities
/// (online gaming, live streaming, video conferencing) to eliminate periodic 100-500ms
/// channel-hopping latency spikes and jitter.
@Observable
@MainActor
public final class WiFiLowLatencyManager {
    public static let shared = WiFiLowLatencyManager()

    public private(set) var isLowLatencyActive: Bool = false
    public private(set) var isBusy: Bool = false
    public private(set) var statusMessage: String = "开启低延迟"

    private init() {
        if FeatureToggleManager.shared.enablePluginWiFiLatency {
            checkAWDLState()
        }
    }

    public func activate() {
        checkAWDLState()
    }

    public func deactivate() {
        if isLowLatencyActive {
            _ = Self.runInstalledHelperSilently(modeArg: "up")
        }
        isBusy = false
        isLowLatencyActive = false
        statusMessage = "开启低延迟"
    }

    /// Checks the real-time kernel status of awdl0 via Darwin getifaddrs
    public func checkAWDLState() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        var ptr = ifaddr
        var awdlFound = false
        var awdlUp = true

        while ptr != nil {
            let ifa = ptr!.pointee
            let name = String(cString: ifa.ifa_name)
            if name == "awdl0" {
                awdlFound = true
                let flags = Int32(ifa.ifa_flags)
                awdlUp = (flags & IFF_UP) != 0
                break
            }
            ptr = ifa.ifa_next
        }
        freeifaddrs(ifaddr)

        if awdlFound {
            self.isLowLatencyActive = !awdlUp
            self.statusMessage = self.isLowLatencyActive ? "低延迟" : "开启低延迟"
        }
    }

    /// Toggles Wi-Fi Low Latency (pausing / restoring awdl0)
    public func toggleLowLatency() {
        let isWiFi = (SystemResourceMonitor.shared.hardware.primaryInterfaceKind == "Wi-Fi")
        if !isWiFi && !isLowLatencyActive {
            showNotification(title: "WiFi 低延迟", body: "连接 WiFi 后即可使用")
            return
        }

        let targetActive = !isLowLatencyActive
        let modeArg = targetActive ? "down" : "up"
        isBusy = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var succeeded = Self.runInstalledHelperSilently(modeArg: modeArg)
            var errorMessage: String? = nil

            if !succeeded {
                let bundledPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SysPulseUPSHelper").path
                let fallbackPath = "/Applications/SysPulse.app/Contents/MacOS/SysPulseUPSHelper"
                let sourceHelper = FileManager.default.isExecutableFile(atPath: bundledPath) ? bundledPath : fallbackPath
                let installedDir = "/Library/Application Support/SysPulse"
                let installedHelper = "\(installedDir)/SysPulseUPSHelper"
                let qDir = SystemPermissionManager.shellSingleQuoted(installedDir)
                let qSrc = SystemPermissionManager.shellSingleQuoted(sourceHelper)
                let qDst = SystemPermissionManager.shellSingleQuoted(installedHelper)
                let qMode = SystemPermissionManager.shellSingleQuoted(modeArg)

                let shellCmd: String
                if FileManager.default.isExecutableFile(atPath: sourceHelper) {
                    shellCmd = "mkdir -p \(qDir) && chown root:wheel \(qDir) && chmod 755 \(qDir) && cp -f \(qSrc) \(qDst) && chown root:wheel \(qDst) && chmod 4755 \(qDst) && \(qDst) --awdl \(qMode)"
                } else {
                    shellCmd = "/sbin/ifconfig awdl0 \(qMode)"
                }
                let scriptSource = "do shell script \"\(SystemPermissionManager.appleScriptEscaped(shellCmd))\" with administrator privileges"

                var error: NSDictionary?
                let script = NSAppleScript(source: scriptSource)
                script?.executeAndReturnError(&error)
                if let err = error {
                    errorMessage = err[NSAppleScript.errorMessage] as? String ?? "授权未能完成"
                } else {
                    succeeded = true
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.checkAWDLState()

                if let msg = errorMessage, !succeeded {
                    self.showNotification(title: "WiFi 低延迟", body: msg)
                } else {
                    if self.isLowLatencyActive {
                        self.showNotification(
                            title: "WiFi 低延迟模式已开启",
                            body: "低延迟模式已生效，暂停 AWDL 直连，隔空投送和 iPhone 镜像可能暂时不可用，关闭后即可恢复。"
                        )
                    } else {
                        self.showNotification(
                            title: "WiFi 低延迟已关闭",
                            body: "已恢复标准网络模式，隔空投送与接力已重新启用。"
                        )
                    }
                }
            }
        }
    }

    /// Automatically restore awdl0 when application terminates without blocking on modal authorization
    public func restoreOnTermination() {
        guard isLowLatencyActive else { return }
        _ = Self.runInstalledHelperSilently(modeArg: "up")
    }

    nonisolated private static func runInstalledHelperSilently(modeArg: String) -> Bool {
        let installedHelper = "/Library/Application Support/SysPulse/SysPulseUPSHelper"
        if FileManager.default.isExecutableFile(atPath: installedHelper) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: installedHelper)
            proc.arguments = ["--awdl", modeArg]
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        } else if geteuid() == 0 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
            proc.arguments = ["awdl0", modeArg]
            try? proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        }
        return false
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
