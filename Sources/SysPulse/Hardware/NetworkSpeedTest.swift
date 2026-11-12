import Foundation
import Observation

// MARK: - 网络带宽与延迟测速引擎 (/usr/bin/networkQuality)

public enum SpeedTestStatus: Equatable, Sendable {
    case idle
    case measuring
    case completed(downloadMbps: Double, uploadMbps: Double, latencyMs: Double, responsivenessRPM: Double)
    case failed(message: String)
}

@Observable
@MainActor
public final class NetworkSpeedTest {
    public static let shared = NetworkSpeedTest()

    public private(set) var status: SpeedTestStatus = .idle
    public private(set) var isRunning: Bool = false
    public private(set) var downloadMbps: Double = 0
    public private(set) var uploadMbps: Double = 0
    public private(set) var latencyMs: Double = 0
    public private(set) var responsivenessRPM: Double = 0
    public private(set) var errorMessage: String? = nil
    public private(set) var progressSeconds: Double = 0
    public private(set) var liveDownloadSpeedFormatted: String = "0 KB/s"
    public private(set) var liveUploadSpeedFormatted: String = "0 KB/s"

    private var lastSampleTime: TimeInterval = 0
    private var lastInBytes: UInt64 = 0
    private var lastOutBytes: UInt64 = 0
    private var hasFirstSample: Bool = false
    private var process: Process?
    private var progressTimer: Timer?

    private init() {}

    public func startTest() {
        guard !isRunning else { return }

        isRunning = true
        status = .measuring
        errorMessage = nil
        downloadMbps = 0
        uploadMbps = 0
        latencyMs = 0
        responsivenessRPM = 0
        progressSeconds = 0

        let (initIn, initOut) = Self.sampleNetworkBytes()
        self.lastInBytes = initIn
        self.lastOutBytes = initOut
        self.lastSampleTime = Date().timeIntervalSince1970
        self.hasFirstSample = false
        self.liveDownloadSpeedFormatted = "0 KB/s"
        self.liveUploadSpeedFormatted = "0 KB/s"

        // 动态吞吐每秒严格刷新（首个采样 0.5s 快速出数，随后严格以 1.0s 为周期采样硬件字节差）
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                self.progressSeconds += 0.1
                let now = Date().timeIntervalSince1970
                let elapsed = now - self.lastSampleTime
                if (!self.hasFirstSample && elapsed >= 0.5) || elapsed >= 1.0 {
                    let (curIn, curOut) = Self.sampleNetworkBytes()
                    let dt = max(0.3, elapsed)
                    let inDelta = curIn >= self.lastInBytes ? (curIn - self.lastInBytes) : 0
                    let outDelta = curOut >= self.lastOutBytes ? (curOut - self.lastOutBytes) : 0
                    let downBps = Double(inDelta) / dt
                    let upBps = Double(outDelta) / dt
                    self.liveDownloadSpeedFormatted = Self.formatSpeed(downBps)
                    self.liveUploadSpeedFormatted = Self.formatSpeed(upBps)
                    self.lastInBytes = curIn
                    self.lastOutBytes = curOut
                    self.lastSampleTime = now
                    self.hasFirstSample = true
                }
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            // -c: 输出 JSON 格式, -M 8: 限制最大测速时长 8 秒
            proc.arguments = ["-c", "-M", "8"]

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            await MainActor.run {
                self?.process = proc
            }

            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()

                if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    let dlBps = (json["dl_throughput"] as? Double) ?? 0
                    let ulBps = (json["ul_throughput"] as? Double) ?? 0
                    let rtt = (json["base_rtt"] as? Double) ?? 0
                    let rpm = (json["responsiveness"] as? Double) ?? 0

                    let dlMbps = round((dlBps / 1_000_000.0) * 10) / 10.0
                    let ulMbps = round((ulBps / 1_000_000.0) * 10) / 10.0
                    let lat = round(rtt * 10) / 10.0
                    let resp = round(rpm)

                    await MainActor.run {
                        self?.progressTimer?.invalidate()
                        self?.progressTimer = nil
                        self?.isRunning = false
                        self?.process = nil
                        self?.downloadMbps = dlMbps
                        self?.uploadMbps = ulMbps
                        self?.latencyMs = lat
                        self?.responsivenessRPM = resp
                        self?.status = .completed(
                            downloadMbps: dlMbps,
                            uploadMbps: ulMbps,
                            latencyMs: lat,
                            responsivenessRPM: resp
                        )
                    }
                } else {
                    await MainActor.run {
                        self?.progressTimer?.invalidate()
                        self?.progressTimer = nil
                        self?.isRunning = false
                        self?.process = nil
                        self?.errorMessage = "这次没测成，再试一次"
                        self?.status = .failed(message: "这次没测成，再试一次")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.progressTimer?.invalidate()
                    self?.progressTimer = nil
                    self?.isRunning = false
                    self?.process = nil
                    self?.errorMessage = error.localizedDescription
                    self?.status = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    public func setResults(download: Double, upload: Double, latency: Double, rpm: Double) {
        self.downloadMbps = download
        self.uploadMbps = upload
        self.latencyMs = latency
        self.responsivenessRPM = rpm
        self.isRunning = false
        self.status = .completed(
            downloadMbps: download,
            uploadMbps: upload,
            latencyMs: latency,
            responsivenessRPM: rpm
        )
    }

    public func setSimulating(progressSeconds: Double, liveDownload: String, liveUpload: String) {
        self.isRunning = true
        self.status = .measuring
        self.progressSeconds = progressSeconds
        self.liveDownloadSpeedFormatted = liveDownload
        self.liveUploadSpeedFormatted = liveUpload
    }

    public func cancelTest() {
        guard isRunning else { return }
        process?.terminate()
        process = nil
        progressTimer?.invalidate()
        progressTimer = nil
        isRunning = false
        status = .idle
    }

    nonisolated private static func sampleNetworkBytes() -> (UInt64, UInt64) {
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let ifa = ptr!.pointee
                if ifa.ifa_addr != nil && ifa.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                    let name = String(cString: ifa.ifa_name)
                    if NetworkDetailModel.isCountablePhysicalInterfaceName(name) {
                        if let data = ifa.ifa_data {
                            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                            inBytes += UInt64(ifData.ifi_ibytes)
                            outBytes += UInt64(ifData.ifi_obytes)
                        }
                    }
                }
                ptr = ifa.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return (inBytes, outBytes)
    }

    nonisolated private static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1048576.0 {
            return String(format: "%.1f MB/s", bytesPerSec / 1048576.0)
        } else if bytesPerSec >= 1024.0 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else {
            return "0 KB/s"
        }
    }
}
