import Foundation
import Observation
import OSLog

@Observable
@MainActor
public final class NetworkNotifier {
    public static let shared = NetworkNotifier()

    private let logger = Logger(subsystem: "com.apple.powerglass", category: "NetworkNotifier")

    public var isEnabled: Bool = false
    public var webhookURL: String = "http://synology-nas.local:5000/api/ups-power-cut"
    public var triggerBatteryLevel: Int = 20

    public func notifyIfEligible(currentBattery: Int) {
        guard isEnabled, !webhookURL.isEmpty, let url = URL(string: webhookURL) else { return }
        guard currentBattery <= triggerBatteryLevel else { return }

        logger.warning("触发局域网 NAS 安全关机 Webhook: \(self.webhookURL)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5.0
        let payload = [
            "event": "UPS_BATTERY_LOW",
            "battery": currentBattery,
            "host": "Mac Studio",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ] as [String : Any]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        Task.detached {
            do {
                _ = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    PowerSourceEngine.shared.appendEvent(PowerEvent(
                        type: .networkNotified,
                        details: "已向局域网 NAS 发送紧急低电安全关机指令 (电量 \(currentBattery)%)"
                    ))
                }
            } catch {
                await MainActor.run {
                    self.logger.error("发送 NAS 联动通知失败: \(error.localizedDescription)")
                }
            }
        }
    }
}
