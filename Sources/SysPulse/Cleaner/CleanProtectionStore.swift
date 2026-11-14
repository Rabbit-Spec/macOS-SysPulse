import Foundation
import SwiftUI
import AppKit
import Observation

/// CleanProtectionStore - 白名单防护规则存储与管理器
/// 配置文件持久化保存在 ~/.config/syspulse/whitelist，支持自定义增删改、通配符与注释。
@Observable
public final class CleanProtectionStore: @unchecked Sendable {
    public static let shared = CleanProtectionStore()

    public var rawText: String = ""
    public var activePatterns: [String] = []
    public var customPatterns: [String] = []
    public var isProtectionSheetPresented: Bool = false
    public var lastErrorMessage: String? = nil

    // UI state for CleanProtectionListView
    public var showingProtectionList: Bool = false
    public var protectionViewMode: Int = 0
    public var protectionSearchQuery: String = ""
    public var protectionNewPathInput: String = ""
    public var protectionEditorContent: String = ""
    public var showResetConfirm: Bool = false
    public var saveSuccessMessage: String? = nil

    private let lock = NSLock()
    private let primaryConfigURL: URL
    private let secondaryConfigURL: URL

    public static let defaultContent: String = """
# SysPulse 清理保护名单 - 受保护路径绝对不会被清理或删除
# 每行一个路径或通配符规则，以 # 开头的行为注释。
# 支持 $HOME、~ 相对家目录以及 * 通配符。

# 1. 通讯与办公软件核心数据
$HOME/Library/Caches/com.tencent.xinWeChat*
$HOME/Library/Caches/com.tencent.WeChat*
$HOME/Library/Caches/com.tencent.qq*
$HOME/Library/Caches/com.alibaba.DingTalkMac*
$HOME/Library/Caches/com.bytedance.feishu*
$HOME/Library/Caches/com.electron.lark*
$HOME/Library/Caches/com.tinyspeck.slackmacgap*
$HOME/Library/Caches/com.hnc.Discord*
$HOME/Library/Caches/ru.keepcoder.Telegram*

# 2. 现代代码编辑器、IDE 与扩展插件
$HOME/Library/Application Support/Cursor/*
$HOME/Library/Caches/Cursor/*
$HOME/Library/Application Support/Code/*
$HOME/Library/Caches/com.microsoft.VSCode*
$HOME/Library/Application Support/JetBrains*
$HOME/Library/Caches/JetBrains*
$HOME/Library/Caches/com.jetbrains.toolbox*
$HOME/Library/Developer/Xcode/UserData/*

# 3. 机器学习、大模型权重与 AI 运行时
$HOME/.ollama/models/*
$HOME/.cache/huggingface*
$HOME/.cache/torch*

# 4. 开发语言依赖包与构建仓库
$HOME/.m2/repository/*
$HOME/.gradle/caches/*
$HOME/.gradle/daemon/*
$HOME/Library/Caches/pypoetry/virtualenvs*
$HOME/Library/Caches/ms-playwright*
$HOME/Library/Caches/tealdeer/tldr-pages

# 5. 网络代理与关键网络工具
$HOME/Library/Caches/com.nssurge.surge-mac/*
$HOME/Library/Application Support/com.nssurge.surge-mac/*
$HOME/Library/Caches/com.nssurge.surge-mac

# 6. 系统原生与云同步关键目录
$HOME/Library/Caches/com.apple.finder
$HOME/Library/Mobile Documents*
$HOME/Library/Caches/com.apple.FontRegistry*
$HOME/Library/Caches/com.apple.spotlight*
$HOME/Library/Caches/com.apple.Spotlight*
$HOME/Library/Caches/CloudKit*
"""

    public init() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        self.primaryConfigURL = home.appendingPathComponent(".config/syspulse/whitelist")
        self.secondaryConfigURL = home.appendingPathComponent("Library/Application Support/SysPulse/clean-whitelist.txt")

        self.load()
    }

    public var ruleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activePatterns.count
    }

    public var configFilePath: String {
        primaryConfigURL.path
    }

    // MARK: - Load & Save

    public func load() {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default

        // 1. Ensure directory exists
        let configDir = primaryConfigURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        // 2. Read from primary or fallback
        var content: String? = nil
        if fm.fileExists(atPath: primaryConfigURL.path),
           let str = try? String(contentsOf: primaryConfigURL, encoding: .utf8) {
            content = str
        } else if fm.fileExists(atPath: secondaryConfigURL.path),
                  let str = try? String(contentsOf: secondaryConfigURL, encoding: .utf8) {
            content = str
        }

        // 3. If file didn't exist, populate with defaults
        if content == nil || content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            content = Self.defaultContent
            try? content?.write(to: primaryConfigURL, atomically: true, encoding: .utf8)
            let secDir = secondaryConfigURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: secDir.path) {
                try? fm.createDirectory(at: secDir, withIntermediateDirectories: true)
            }
            try? content?.write(to: secondaryConfigURL, atomically: true, encoding: .utf8)
        }

        self.rawText = content ?? Self.defaultContent
        self.protectionEditorContent = self.rawText
        parsePatterns(from: self.rawText)
    }

    public func save(text: String) {
        lock.lock()
        defer { lock.unlock() }

        self.rawText = text
        self.protectionEditorContent = text
        let fm = FileManager.default

        let configDir = primaryConfigURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        do {
            try text.write(to: primaryConfigURL, atomically: true, encoding: .utf8)
            try? text.write(to: secondaryConfigURL, atomically: true, encoding: .utf8)
            self.lastErrorMessage = nil
        } catch {
            self.lastErrorMessage = "保存保护名单失败: \(error.localizedDescription)"
        }

        parsePatterns(from: text)
    }

    public func resetToDefaults() {
        save(text: Self.defaultContent)
    }

    public func addPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var patternToAdd = trimmed
        if patternToAdd.hasPrefix(homePath) {
            patternToAdd = "$HOME" + patternToAdd.dropFirst(homePath.count)
        } else if patternToAdd.hasPrefix("~") {
            patternToAdd = "$HOME" + patternToAdd.dropFirst(1)
        }

        var updated = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !updated.contains("# 用户自定义保护路径") {
            updated += "\n\n# 用户自定义保护路径\n"
        } else {
            updated += "\n"
        }
        updated += patternToAdd + "\n"

        save(text: updated)
    }

    public func removePattern(_ pattern: String) {
        let lines = rawText.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed != pattern && trimmed != pattern.replacingOccurrences(of: "$HOME", with: "~")
        }
        save(text: filtered.joined(separator: "\n"))
    }

    // MARK: - Pattern Parsing & Matching

    private func parsePatterns(from text: String) {
        let lines = text.components(separatedBy: .newlines)
        var patterns: [String] = []
        var customList: [String] = []
        var isCustomSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                if trimmed.contains("用户自定义") {
                    isCustomSection = true
                }
                continue
            }

            patterns.append(trimmed)
            if isCustomSection {
                customList.append(trimmed)
            }
        }

        self.activePatterns = patterns
        self.customPatterns = customList
    }

    /// Fast safe protection evaluation across any thread
    public func isProtected(path: String) -> Bool {
        lock.lock()
        let patterns = self.activePatterns
        lock.unlock()

        let home = FileManager.default.homeDirectoryForCurrentUser.standardized.path
        let standardizedTarget = URL(fileURLWithPath: path).standardized.path

        for pattern in patterns {
            let expandedPattern = pattern
                .replacingOccurrences(of: "$HOME", with: home)
                .replacingOccurrences(of: "~", with: home)

            // 1. Wildcard Pattern (ends with *)
            if expandedPattern.hasSuffix("*") {
                let prefix = String(expandedPattern.dropLast())
                if standardizedTarget.hasPrefix(prefix) {
                    return true
                }
            }

            // 2. Exact match
            if standardizedTarget == expandedPattern {
                return true
            }

            // 3. Directory containment match
            if standardizedTarget.hasPrefix(expandedPattern + "/") {
                return true
            }

            // 4. In case pattern is a Bundle ID or specific folder name
            if !expandedPattern.contains("/") && standardizedTarget.contains(expandedPattern) {
                return true
            }
        }

        return false
    }
}
