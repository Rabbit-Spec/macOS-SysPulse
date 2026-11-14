import Foundation

public struct AppMetadata {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.13"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "13"
    }

    public static var versionDisplay: String {
        "v\(version)"
    }

    public static var fullVersionDisplay: String {
        "版本 \(version) (Build \(build) · \(MacHardwareInfo.shared.macOSDisplayString) Native)"
    }
}
