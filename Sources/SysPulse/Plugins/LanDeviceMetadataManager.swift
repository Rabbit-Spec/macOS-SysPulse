import Foundation
import SwiftUI
import Observation
import AppKit

/// 用户自定义设备元数据模型 (绑定物理 MAC 地址)
public struct CustomDeviceProfile: Codable, Sendable, Equatable {
    public var customName: String?
    public var customIcon: String?
    public var isCustomImage: Bool
    public var updatedAt: Date

    public init(
        customName: String? = nil,
        customIcon: String? = nil,
        isCustomImage: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.customName = customName
        self.customIcon = customIcon
        self.isCustomImage = isCustomImage
        self.updatedAt = updatedAt
    }
}

/// 局域网设备自定义档案持久化管理器
@Observable
@MainActor
public final class LanDeviceMetadataManager {
    public static let shared = LanDeviceMetadataManager()

    public var profiles: [String: CustomDeviceProfile] = [:]

    private var storageFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SysPulse")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("LanDeviceMetadata.json")
    }

    public var iconsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SysPulse/DeviceIcons")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        loadProfiles()
    }

    public func loadProfiles() {
        guard let data = try? Data(contentsOf: storageFileURL),
              let dict = try? JSONDecoder().decode([String: CustomDeviceProfile].self, from: data) else {
            return
        }
        self.profiles = dict
    }

    public func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storageFileURL, options: .atomic)
    }

    public static func normalizeMAC(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sepParts = trimmed.split { $0 == ":" || $0 == "-" }
        if sepParts.count == 6 {
            let padded = sepParts.map { part -> String in
                let clean = part.filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
                return clean.count == 1 ? "0\(clean)" : clean
            }
            if padded.allSatisfy({ $0.count == 2 }) {
                return padded.joined(separator: ":")
            }
        }
        let hexChars = trimmed.filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        if hexChars.count == 12 {
            var bytes: [String] = []
            var idx = hexChars.startIndex
            for _ in 0..<6 {
                let next = hexChars.index(idx, offsetBy: 2)
                bytes.append(String(hexChars[idx..<next]))
                idx = next
            }
            return bytes.joined(separator: ":")
        }
        return nil
    }

    public func getProfile(for mac: String) -> CustomDeviceProfile? {
        let key = Self.normalizeMAC(mac) ?? mac.lowercased()
        return profiles[key]
    }

    @discardableResult
    public func batchSetCustomNames(_ mappings: [(mac: String, name: String)]) -> Int {
        var appliedCount = 0
        let now = Date()
        for entry in mappings {
            guard let cleanMac = Self.normalizeMAC(entry.mac) else { continue }
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            var profile = profiles[cleanMac] ?? CustomDeviceProfile()
            profile.customName = trimmedName
            profile.updatedAt = now
            profiles[cleanMac] = profile
            appliedCount += 1
        }
        if appliedCount > 0 {
            saveProfiles()
        }
        return appliedCount
    }

    public func setCustomName(for mac: String, name: String) {
        let cleanMac = mac.lowercased()
        var profile = profiles[cleanMac] ?? CustomDeviceProfile()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.customName = trimmed.isEmpty ? nil : trimmed
        profile.updatedAt = Date()
        profiles[cleanMac] = profile
        saveProfiles()
    }

    public func setCustomPresetIcon(for mac: String, icon: String) {
        let cleanMac = mac.lowercased()
        var profile = profiles[cleanMac] ?? CustomDeviceProfile()
        profile.customIcon = icon
        profile.isCustomImage = false
        profile.updatedAt = Date()
        profiles[cleanMac] = profile
        saveProfiles()
    }

    public func setCustomImageFile(for mac: String, sourceURL: URL) {
        let cleanMac = mac.lowercased().replacingOccurrences(of: ":", with: "_")
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let destURL = iconsDirectoryURL.appendingPathComponent("\(cleanMac).\(ext)")

        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            var profile = profiles[mac.lowercased()] ?? CustomDeviceProfile()
            profile.customIcon = destURL.path
            profile.isCustomImage = true
            profile.updatedAt = Date()
            profiles[mac.lowercased()] = profile
            saveProfiles()
        } catch {
            print("[SysPulse] 复制设备自定义图标失败: \(error)")
        }
    }

    public func resetProfile(for mac: String) {
        let cleanMac = mac.lowercased()
        if let p = profiles[cleanMac], p.isCustomImage, let path = p.customIcon {
            try? FileManager.default.removeItem(atPath: path)
        }
        profiles.removeValue(forKey: cleanMac)
        saveProfiles()
    }
}
