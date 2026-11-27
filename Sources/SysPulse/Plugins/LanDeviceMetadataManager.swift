import Foundation
import SwiftUI
import Observation
import AppKit

/// 用户自定义设备元数据模型 (绑定物理 MAC 地址)
public struct CustomDeviceProfile: Codable, Sendable, Equatable {
    public var customName: String?
    public var customVendor: String?
    public var customIcon: String?
    public var isCustomImage: Bool
    public var updatedAt: Date

    public init(
        customName: String? = nil,
        customVendor: String? = nil,
        customIcon: String? = nil,
        isCustomImage: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.customName = customName
        self.customVendor = customVendor
        self.customIcon = customIcon
        self.isCustomImage = isCustomImage
        self.updatedAt = updatedAt
    }
}

/// 全局厂商名称 / MAC 前缀映射规则
public struct VendorMappingRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String { matchKey.lowercased() }
    public var matchKey: String
    public var targetVendor: String
    public var updatedAt: Date

    public init(
        matchKey: String,
        targetVendor: String,
        updatedAt: Date = Date()
    ) {
        self.matchKey = matchKey
        self.targetVendor = targetVendor
        self.updatedAt = updatedAt
    }
}

/// 局域网设备自定义档案持久化管理器
@Observable
@MainActor
public final class LanDeviceMetadataManager {
    public static let shared = LanDeviceMetadataManager()

    public var profiles: [String: CustomDeviceProfile] = [:]
    public var vendorRules: [VendorMappingRule] = []

    private var storageFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SysPulse")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("LanDeviceMetadata.json")
    }

    private var vendorRulesFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SysPulse")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("LanVendorRules.json")
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
        loadVendorRules()
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

    public func loadVendorRules() {
        guard let data = try? Data(contentsOf: vendorRulesFileURL),
              let rules = try? JSONDecoder().decode([VendorMappingRule].self, from: data) else {
            return
        }
        self.vendorRules = rules
    }

    public func saveVendorRules() {
        guard let data = try? JSONEncoder().encode(vendorRules) else { return }
        try? data.write(to: vendorRulesFileURL, options: .atomic)
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
        let cleanMac = Self.normalizeMAC(mac) ?? mac.lowercased()
        var profile = profiles[cleanMac] ?? CustomDeviceProfile()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.customName = trimmed.isEmpty ? nil : trimmed
        profile.updatedAt = Date()
        if profile.customName == nil && profile.customVendor == nil && profile.customIcon == nil {
            profiles.removeValue(forKey: cleanMac)
        } else {
            profiles[cleanMac] = profile
        }
        saveProfiles()
    }

    public func setCustomVendor(for mac: String, vendor: String) {
        let cleanMac = Self.normalizeMAC(mac) ?? mac.lowercased()
        var profile = profiles[cleanMac] ?? CustomDeviceProfile()
        let trimmed = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.customVendor = trimmed.isEmpty ? nil : trimmed
        profile.updatedAt = Date()
        if profile.customName == nil && profile.customVendor == nil && profile.customIcon == nil {
            profiles.removeValue(forKey: cleanMac)
        } else {
            profiles[cleanMac] = profile
        }
        saveProfiles()
    }

    public func setCustomNameAndVendor(
        for mac: String,
        name: String,
        vendor: String,
        defaultName: String? = nil,
        defaultVendor: String,
        applyRuleToVendor: Bool
    ) {
        let cleanMac = Self.normalizeMAC(mac) ?? mac.lowercased()
        var profile = profiles[cleanMac] ?? CustomDeviceProfile()

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || (defaultName != nil && trimmedName == defaultName) {
            profile.customName = nil
        } else {
            profile.customName = trimmedName
        }

        let trimmedVendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let canCreateVendorRule = applyRuleToVendor && !trimmedVendor.isEmpty && !defaultVendor.isEmpty && defaultVendor != "未知厂商"

        if canCreateVendorRule {
            if trimmedVendor.caseInsensitiveCompare(defaultVendor) == .orderedSame {
                removeVendorRule(matchKey: defaultVendor)
            } else {
                addOrUpdateVendorRule(matchKey: defaultVendor, targetVendor: trimmedVendor)
            }
            profile.customVendor = nil
        } else if trimmedVendor.isEmpty || trimmedVendor == defaultVendor {
            profile.customVendor = nil
        } else {
            profile.customVendor = trimmedVendor
        }

        profile.updatedAt = Date()
        if profile.customName == nil && profile.customVendor == nil && profile.customIcon == nil {
            profiles.removeValue(forKey: cleanMac)
        } else {
            profiles[cleanMac] = profile
        }
        saveProfiles()
    }

    /// 规范化 MAC / OUI 前缀（如 d0:da:24, d0:da:24:5, d0:da:24:50:a, d0-da-24 等），若非 MAC 前缀格式则返回 nil
    public static func normalizeMACPrefix(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let full = normalizeMAC(trimmed) {
            return full
        }

        if trimmed.contains(":") || trimmed.contains("-") {
            let sep: Character = trimmed.contains(":") ? ":" : "-"
            let parts = trimmed.split(separator: sep, omittingEmptySubsequences: false)
            guard parts.count >= 3 && parts.count <= 6 else { return nil }
            var normalizedParts: [String] = []
            normalizedParts.reserveCapacity(parts.count)
            for (idx, part) in parts.enumerated() {
                guard !part.isEmpty && part.count <= 2 && part.allSatisfy({ $0.isHexDigit }) else {
                    return nil
                }
                let isTrailingNibble = (idx == parts.count - 1) && (parts.count == 4 || parts.count == 5) && part.count == 1
                if isTrailingNibble {
                    normalizedParts.append(String(part))
                } else {
                    normalizedParts.append(part.count == 1 ? "0\(part)" : String(part))
                }
            }
            let joined = normalizedParts.joined(separator: ":")
            return joined.count >= 8 ? joined : nil
        }

        let hexOnly = trimmed.allSatisfy { $0.isHexDigit }
        if hexOnly && (trimmed.count == 6 || trimmed.count == 7 || trimmed.count == 9 || trimmed.count == 12) {
            var groups: [String] = []
            var cursor = trimmed.startIndex
            while cursor < trimmed.endIndex {
                let remaining = trimmed.distance(from: cursor, to: trimmed.endIndex)
                let step = min(2, remaining)
                let next = trimmed.index(cursor, offsetBy: step)
                groups.append(String(trimmed[cursor..<next]))
                cursor = next
            }
            return groups.joined(separator: ":")
        }

        return nil
    }

    public func addOrUpdateVendorRule(matchKey: String, targetVendor: String) {
        let cleanTarget = targetVendor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty else { return }

        let rawKey = matchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else { return }
        let normalizedKey = Self.normalizeMACPrefix(rawKey) ?? rawKey

        let now = Date()
        if let idx = vendorRules.firstIndex(where: { $0.matchKey.caseInsensitiveCompare(normalizedKey) == .orderedSame }) {
            vendorRules[idx].matchKey = normalizedKey
            vendorRules[idx].targetVendor = cleanTarget
            vendorRules[idx].updatedAt = now
        } else {
            vendorRules.insert(VendorMappingRule(matchKey: normalizedKey, targetVendor: cleanTarget, updatedAt: now), at: 0)
        }
        saveVendorRules()
    }

    public func removeVendorRule(matchKey: String) {
        let rawKey = matchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = Self.normalizeMACPrefix(rawKey) ?? rawKey
        vendorRules.removeAll {
            $0.matchKey.caseInsensitiveCompare(normalizedKey) == .orderedSame ||
            $0.matchKey.caseInsensitiveCompare(rawKey) == .orderedSame
        }
        saveVendorRules()
    }

    /// 解析设备最终显示厂商（优先级：单设备自定义 > MAC/OUI 前缀规则 > 厂商名称规则 > 识别默认厂商）
    public func resolveVendor(for mac: String, defaultVendor: String) -> String {
        if let custom = getProfile(for: mac)?.customVendor {
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let normMac = Self.normalizeMAC(mac) ?? mac.lowercased()
        let matchingPrefixRule = vendorRules
            .compactMap { rule -> (prefix: String, target: String)? in
                guard let prefix = Self.normalizeMACPrefix(rule.matchKey),
                      normMac == prefix || normMac.hasPrefix(prefix) else {
                    return nil
                }
                return (prefix, rule.targetVendor)
            }
            .max(by: { $0.prefix.count < $1.prefix.count })

        if let matchingPrefixRule {
            return matchingPrefixRule.target
        }

        if let nameRule = vendorRules.first(where: {
            Self.normalizeMACPrefix($0.matchKey) == nil &&
            $0.matchKey.caseInsensitiveCompare(defaultVendor) == .orderedSame
        }) {
            return nameRule.targetVendor
        }

        return defaultVendor
    }

    public func setCustomPresetIcon(for mac: String, icon: String) {
        let cleanMac = Self.normalizeMAC(mac) ?? mac.lowercased()
        var profile = profiles[cleanMac] ?? CustomDeviceProfile()
        profile.customIcon = icon
        profile.isCustomImage = false
        profile.updatedAt = Date()
        profiles[cleanMac] = profile
        saveProfiles()
    }

    public func setCustomImageFile(for mac: String, sourceURL: URL) {
        let normalizedMac = Self.normalizeMAC(mac) ?? mac.lowercased()
        let safeFileBase = normalizedMac.replacingOccurrences(of: ":", with: "_")
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let destURL = iconsDirectoryURL.appendingPathComponent("\(safeFileBase).\(ext)")

        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            var profile = profiles[normalizedMac] ?? CustomDeviceProfile()
            profile.customIcon = destURL.path
            profile.isCustomImage = true
            profile.updatedAt = Date()
            profiles[normalizedMac] = profile
            saveProfiles()
        } catch {
            print("[SysPulse] 复制设备自定义图标失败: \(error)")
        }
    }

    public func resetProfile(for mac: String) {
        let cleanMac = Self.normalizeMAC(mac) ?? mac.lowercased()
        if let p = profiles[cleanMac], p.isCustomImage, let path = p.customIcon {
            try? FileManager.default.removeItem(atPath: path)
        }
        profiles.removeValue(forKey: cleanMac)
        saveProfiles()
    }
}
