import Foundation

/// Uncached on-disk `Info.plist` reader for `.app` / sub-bundle inspection.
/// Avoids Foundation `Bundle(url:)` process-lifetime caching so in-place app updates
/// are immediately visible without restarting SysPulse.
public struct FreshBundleInfo: Sendable {
    public let bundleID: String
    public let displayName: String?
    public let bundleName: String?
    public let shortVersion: String?
    public let buildVersion: String?
    public let executableName: String?
    public let executableURL: URL?
    public let suFeedURL: String?
    public let suOriginalFeedURL: String?
    public let citrixVersionString: String?
    public let requiresIPhoneOS: Bool
    public let supportedPlatforms: [String]

    nonisolated public static func readInfoDictionary(at bundleURL: URL) -> [String: Any]? {
        let fm = FileManager.default
        let contentsPlist = bundleURL.appendingPathComponent("Contents/Info.plist")
        let directPlist = bundleURL.appendingPathComponent("Info.plist")
        let plistURL: URL
        if fm.fileExists(atPath: contentsPlist.path) {
            plistURL = contentsPlist
        } else if fm.fileExists(atPath: directPlist.path) {
            plistURL = directPlist
        } else {
            return nil
        }

        guard let data = try? Data(contentsOf: plistURL, options: .uncached),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return dict
    }

    nonisolated public static func read(at bundleURL: URL, requireBundleID: Bool = true) -> FreshBundleInfo? {
        guard let dict = readInfoDictionary(at: bundleURL) else { return nil }
        let rawBID = (dict["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requireBundleID && rawBID.isEmpty {
            return nil
        }

        let execName = (dict["CFBundleExecutable"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let execURL: URL?
        if let execName, !execName.isEmpty {
            let contentsExec = bundleURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(execName)
            let directExec = bundleURL.appendingPathComponent(execName)
            if FileManager.default.fileExists(atPath: contentsExec.path) {
                execURL = contentsExec
            } else if FileManager.default.fileExists(atPath: directExec.path) {
                execURL = directExec
            } else {
                execURL = contentsExec
            }
        } else {
            execURL = nil
        }

        let reqIPhone = (dict["LSRequiresIPhoneOS"] as? Bool) ?? false
        let platforms = (dict["CFBundleSupportedPlatforms"] as? [String]) ?? []

        return FreshBundleInfo(
            bundleID: rawBID,
            displayName: (dict["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleName: (dict["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            shortVersion: (dict["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            buildVersion: (dict["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            executableName: execName,
            executableURL: execURL,
            suFeedURL: (dict["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            suOriginalFeedURL: (dict["SUOriginalFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            citrixVersionString: (dict["CitrixVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            requiresIPhoneOS: reqIPhone,
            supportedPlatforms: platforms
        )
    }
}
