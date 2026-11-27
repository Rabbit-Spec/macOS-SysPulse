import Foundation
import AppKit

/// 解析并缓存内置 `CommandLineToolIcons/manifest.json` 中的命令行工具与桌面工具图标。
@MainActor
public final class CommandLineToolIconStore {
    public static let shared = CommandLineToolIconStore()

    public struct Entry: Decodable, Sendable {
        public let file: String
        public let kind: String?
        public let source: String?
        public let title: String?
    }

    private struct Manifest: Decodable {
        let version: Int?
        let icons: [String: Entry]
    }

    private var entries: [String: Entry] = [:]
    private var imageCache: [String: NSImage] = [:]
    private var baseDirectoryURL: URL? = nil
    private var loaded = false

    private init() {
        loadIfNeeded()
    }

    private func resolveIconsDirectory() -> URL? {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("CommandLineToolIcons", isDirectory: true),
           fm.fileExists(atPath: resURL.appendingPathComponent("manifest.json").path) {
            return resURL
        }
        // Development workspace fallback
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            bundleParent.appendingPathComponent("Resources/CommandLineToolIcons", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/CommandLineToolIcons", isDirectory: true)
        ]
        for dir in candidates {
            if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) {
                return dir
            }
        }
        return nil
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let dir = resolveIconsDirectory() else { return }
        self.baseDirectoryURL = dir
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return
        }
        var normalized: [String: Entry] = [:]
        for (k, v) in manifest.icons {
            normalized[k.lowercased()] = v
        }
        self.entries = normalized
    }

    public func entry(forToolName name: String) -> Entry? {
        loadIfNeeded()
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = entries[lower] {
            return direct
        }
        // Strip tap prefix e.g. "homebrew/cask/codex" or version suffix e.g. "python@3.12"
        let lastSegment = lower.split(separator: "/").last.map(String.init) ?? lower
        let baseNoVersion = lastSegment.split(separator: "@").first.map(String.init) ?? lastSegment
        if let hit = entries[baseNoVersion] {
            return hit
        }
        let cleaned = baseNoVersion.replacingOccurrences(of: "-cli", with: "")
        if let hit = entries[cleaned] {
            return hit
        }
        return nil
    }

    public func icon(forToolName name: String) -> NSImage? {
        guard let entry = entry(forToolName: name), let baseDir = baseDirectoryURL else {
            return nil
        }
        if let cached = imageCache[entry.file] {
            return cached
        }
        let imgURL = baseDir.appendingPathComponent(entry.file)
        guard FileManager.default.fileExists(atPath: imgURL.path),
              let image = NSImage(contentsOf: imgURL) else {
            return nil
        }
        let scaled = AppIconManager.downsampledUIImage(from: image, maxPixelSize: 64)
        imageCache[entry.file] = scaled
        return scaled
    }
}
