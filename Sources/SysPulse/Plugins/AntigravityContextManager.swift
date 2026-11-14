import AppKit
import CryptoKit
import Foundation
import Observation

// MARK: - Antigravity 上下文预设与状态模型

public enum AntigravityContextPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case unclamped = "unclamped"
    case k900 = "900k"
    case k512 = "512k"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unclamped: return "解除 256K 限制（推荐）"
        case .k900: return "900K (921,600)"
        case .k512: return "512K (524,288)"
        case .custom: return "自定义阈值"
        }
    }

    public var shortLabel: String {
        switch self {
        case .unclamped: return "全量 ~983K"
        case .k900: return "900K"
        case .k512: return "512K"
        case .custom: return "自定义"
        }
    }

    public var fixedTokenValue: UInt32? {
        switch self {
        case .unclamped: return nil
        case .k900: return 900 * 1024
        case .k512: return 512 * 1024
        case .custom: return nil
        }
    }
}

public enum ClampState: Equatable, Sendable {
    case original256K
    case unlocked
    case custom(Int)
    case mixed(String)

    public var displayTitle: String {
        switch self {
        case .original256K: return "受限于 256K 上限（原版）"
        case .unlocked: return "已解除 256K 限制（全量 ~983K）"
        case .custom(let val): return "已锁定自定义阈值（\(Self.formatTokens(val))）"
        case .mixed(let detail): return "混合状态（\(detail)）"
        }
    }

    public var compactBadge: String {
        switch self {
        case .original256K: return "受限 256K"
        case .unlocked: return "已解锁 ~983K"
        case .custom(let val): return "自定义 \(Self.formatTokens(val))"
        case .mixed: return "状态异常"
        }
    }

    public var isPatched: Bool {
        switch self {
        case .original256K: return false
        case .unlocked, .custom: return true
        case .mixed: return true
        }
    }

    public static func formatTokens(_ value: Int) -> String {
        if value >= 1_048_576 && value % 1_048_576 == 0 {
            return "\(value / 1_048_576)M"
        }
        if value >= 1_024 && value % 1_024 == 0 {
            return "\(value / 1_024)K"
        }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

public enum EnvironmentCheckLevel: Sendable, Equatable {
    case ready
    case warning
    case blocked
}

public struct EnvironmentCheckItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let level: EnvironmentCheckLevel
    public let actionTitle: String?

    public init(id: String, title: String, detail: String, level: EnvironmentCheckLevel, actionTitle: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.level = level
        self.actionTitle = actionTitle
    }
}

public enum AntigravityVersionWatchState: Equatable, Sendable {
    case idle
    case targetNotFound
    case analysisFailed(String)
    case neverPatchedOriginal(currentVersion: String?)
    case externalPatchedUnrecorded(currentVersion: String?, clamp: ClampState)
    case activeMatched(version: String?, clamp: ClampState)
    case versionChangedReverted(oldVersion: String, newVersion: String)
    case versionChangedStillActive(oldVersion: String, newVersion: String, clamp: ClampState)
    case patchInvalidatedSameVersion(version: String?)

    public var needsReapplyWarning: Bool {
        switch self {
        case .versionChangedReverted, .patchInvalidatedSameVersion, .versionChangedStillActive:
            return true
        default:
            return false
        }
    }

    public var bannerTitle: String? {
        switch self {
        case .versionChangedReverted(let oldV, let newV):
            return "检测到 Antigravity 已更新（v\(oldV) → v\(newV)），上下文限制已恢复为 256K，请重新执行解锁"
        case .patchInvalidatedSameVersion(let ver):
            let vText = ver.map { "v\($0) " } ?? ""
            return "检测到当前 \(vText)的上下文解锁已失效（已回退至 256K 原版），请重新执行"
        case .versionChangedStillActive(let oldV, let newV, _):
            return "检测到 Antigravity 版本已变更（v\(oldV) → v\(newV)），建议核对并重新同步版本记忆"
        case .externalPatchedUnrecorded(let ver, _):
            let vText = ver.map { "v\($0)" } ?? "当前版本"
            return "检测到二进制已在外部解锁（\(vText)），点击「记录当前状态」即可纳入版本更新自动监测"
        default:
            return nil
        }
    }
}

public struct AntigravityTargetCandidate: Identifiable, Hashable, Sendable {
    public let path: String
    public let appName: String
    public let appBundlePath: String?
    public let appVersion: String?
    public let isRunning: Bool

    public var id: String { path }

    public var displayName: String {
        if let ver = appVersion, !ver.isEmpty {
            return "\(appName) v\(ver)"
        }
        return appName
    }
}

public struct AntigravityBinaryEdit: Identifiable, Sendable {
    public let id: Int
    public let fileOffset: Int
    public let originalBytes: Data
    public let replacementBytes: Data

    public var originalHex: String {
        originalBytes.map { String(format: "%02x", $0) }.joined()
    }

    public var replacementHex: String {
        replacementBytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct AntigravityAnalysisReport: Sendable {
    public let targetPath: String
    public let sliceOffset: Int
    public let textFileOffset: Int
    public let textVirtualSize: Int
    public let pclnOffset: Int
    public let pclnVersion: String
    public let functionCount: Int
    public let symbolOffset: Int
    public let symbolSize: Int
    public let clampState: ClampState
    public let binarySHA256: String
    public let edits: [AntigravityBinaryEdit]

    public var alreadyMatchesTarget: Bool {
        !edits.isEmpty && edits.allSatisfy { $0.originalBytes == $0.replacementBytes }
    }
}

public struct AntigravityMemoryRecord: Codable, Sendable {
    public var lastKnownVersion: String?
    public var lastPatchedTargetPath: String?
    public var lastPatchedBinarySHA256: String?
    public var lastAppliedPresetRaw: String?
    public var lastAppliedCustomTokens: Int?
    public var lastPatchedAt: Date?
    public var managedBackupPath: String?
    public var managedBackupSHA256: String?
}

// MARK: - 纯 Swift 原生 Mach-O ARM64 / Go pclntab 二进制解析与修补引擎

public enum AntigravityPatchError: LocalizedError, Sendable {
    case fileReadFailed(String)
    case invalidMachO(String)
    case pclntabNotFound
    case symbolNotFound(String)
    case symbolOutOfBounds
    case clampSiteNotFound
    case invalidCustomSize(String)
    case verificationFailed(String)
    case signingFailed(String)
    case permissionOrWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileReadFailed(let msg): return "无法读取二进制文件：\(msg)"
        case .invalidMachO(let msg): return "Mach-O 结构校验失败：\(msg)"
        case .pclntabNotFound: return "未在 ARM64 切片中找到 Go pclntab 符号表"
        case .symbolNotFound(let sym): return "未找到目标符号：\(sym)"
        case .symbolOutOfBounds: return "目标函数地址超出 __TEXT,__text 节范围"
        case .clampSiteNotFound: return "未在 GetCheckpointConfig 中定位到可识别的 ARM64 上下文上限指令"
        case .invalidCustomSize(let msg): return msg
        case .verificationFailed(let msg): return "字节校验失败：\(msg)"
        case .signingFailed(let msg): return "代码重签名或验签失败：\(msg)"
        case .permissionOrWriteFailed(let msg): return "写入目标文件失败：\(msg)"
        }
    }
}

public enum AntigravityBinaryPatcher {
    public static let targetSymbol = "google3/third_party/jetski/cortex/utils/utils.GetCheckpointConfig"
    public static let unclampedMarker: UInt32 = 0x0FFFFFFF

    private static let mhMagic64: UInt32 = 0xFEEDFACF
    private static let fatMagic: UInt32 = 0xCAFEBABE
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    private static let cpuTypeARM64: UInt32 = 0x0100000C
    private static let lcSegment64: UInt32 = 0x19

    public struct Segment64: Sendable {
        public let name: String
        public let vmaddr: UInt64
        public let vmsize: UInt64
        public let fileoff: UInt64
        public let filesize: UInt64
    }

    public struct Section64: Sendable {
        public let segmentName: String
        public let sectionName: String
        public let addr: UInt64
        public let size: UInt64
        public let offset: UInt32
    }

    public struct Arm64Slice: Sendable {
        public let sliceOffset: Int
        public let sliceSize: Int
        public let segments: [Segment64]
        public let sections: [Section64]
        public let textFileOffset: Int
        public let textVirtualSize: Int

        public func inText(_ sliceRelOff: Int) -> Bool {
            sliceRelOff >= textFileOffset && sliceRelOff < (textFileOffset + textVirtualSize)
        }

        public func vmaddrToFileOffset(_ vmaddr: UInt64) -> Int? {
            for seg in segments {
                if vmaddr >= seg.vmaddr && vmaddr < seg.vmaddr &+ seg.filesize {
                    return Int(seg.fileoff &+ (vmaddr - seg.vmaddr))
                }
            }
            return nil
        }
    }

    public struct PclntabInfo: Sendable {
        public let sliceRelOffset: Int
        public let versionLabel: String
        public let nfunc: Int
        public let textstart: UInt64
        public let fnOffset: Int
        public let pclnOffset: Int
    }

    private struct ClampCandidate {
        let pos1: Int
        let pos2: Int
        let reg: UInt32
        let is64Bit: Bool
        let kind: String
        let value: UInt32
        let registerMatched: Bool
    }

    // MARK: - 字节读取工具

    @inline(__always)
    private static func readU16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0 && offset + 2 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    @inline(__always)
    private static func readU32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0 && offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    @inline(__always)
    private static func readU32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0 && offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24)
            | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }

    @inline(__always)
    private static func readU64LE(_ data: Data, at offset: Int) -> UInt64? {
        guard let lo = readU32LE(data, at: offset),
              let hi = readU32LE(data, at: offset + 4) else { return nil }
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    @inline(__always)
    private static func readU64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard let hi = readU32BE(data, at: offset),
              let lo = readU32BE(data, at: offset + 4) else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }

    private static func readFixedString(_ data: Data, at offset: Int, maxLen: Int) -> String {
        guard offset >= 0 && offset + maxLen <= data.count else { return "" }
        let start = data.startIndex + offset
        let sub = data[start ..< (start + maxLen)]
        let trimmed = sub.prefix { $0 != 0 }
        return String(bytes: trimmed, encoding: .utf8) ?? String(bytes: trimmed, encoding: .isoLatin1) ?? ""
    }

    public static func isMachOFile(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let hdr = try? fh.read(upToCount: 4), hdr.count == 4 else { return false }
        let le = readU32LE(hdr, at: 0) ?? 0
        let be = readU32BE(hdr, at: 0) ?? 0
        return le == mhMagic64 || be == fatMagic || be == fatMagic64
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func parseTokenInput(_ text: String) throws -> UInt32 {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var mult: UInt64 = 1
        if cleaned.hasSuffix("K") {
            mult = 1024
            cleaned.removeLast()
        } else if cleaned.hasSuffix("M") {
            mult = 1024 * 1024
            cleaned.removeLast()
        }
        guard let baseVal = UInt64(cleaned.replacingOccurrences(of: ",", with: "")),
              baseVal > 0 else {
            throw AntigravityPatchError.invalidCustomSize("无效的上下文大小格式：\(text)")
        }
        let total = baseVal.multipliedReportingOverflow(by: mult)
        if total.overflow || total.partialValue < 1_000 || total.partialValue > 4_000_000 {
            throw AntigravityPatchError.invalidCustomSize("自定义阈值必须在 1,000 到 4,000,000 tokens 之间")
        }
        return UInt32(total.partialValue)
    }

    // MARK: - Mach-O ARM64 切片提取

    public static func extractArm64Slice(from data: Data) throws -> Arm64Slice {
        guard data.count >= 32 else {
            throw AntigravityPatchError.invalidMachO("文件过小，不是有效的 Mach-O 二进制")
        }
        let magicLE = readU32LE(data, at: 0) ?? 0
        let magicBE = readU32BE(data, at: 0) ?? 0

        if magicLE == mhMagic64 {
            return try parseArm64Slice(data, sliceOffset: 0, sliceSize: data.count)
        }

        if magicBE == fatMagic || magicBE == fatMagic64 {
            guard let nfat = readU32BE(data, at: 4), nfat > 0, nfat < 32 else {
                throw AntigravityPatchError.invalidMachO("Universal Fat 头部架构数量异常")
            }
            var off = 8
            for _ in 0 ..< nfat {
                if magicBE == fatMagic {
                    guard let cputype = readU32BE(data, at: off),
                          let sOff = readU32BE(data, at: off + 8),
                          let sSize = readU32BE(data, at: off + 12) else {
                        throw AntigravityPatchError.invalidMachO("Fat 架构描述越界")
                    }
                    off += 20
                    if cputype == cpuTypeARM64 {
                        return try parseArm64Slice(data, sliceOffset: Int(sOff), sliceSize: Int(sSize))
                    }
                } else {
                    guard let cputype = readU32BE(data, at: off),
                          let sOff = readU64BE(data, at: off + 8),
                          let sSize = readU64BE(data, at: off + 16) else {
                        throw AntigravityPatchError.invalidMachO("Fat64 架构描述越界")
                    }
                    off += 32
                    if cputype == cpuTypeARM64 {
                        return try parseArm64Slice(data, sliceOffset: Int(sOff), sliceSize: Int(sSize))
                    }
                }
            }
            throw AntigravityPatchError.invalidMachO("当前 Universal 二进制中不包含 Apple Silicon (ARM64) 切片")
        }

        throw AntigravityPatchError.invalidMachO("非 64 位 Mach-O 或 Universal 二进制")
    }

    private static func parseArm64Slice(_ data: Data, sliceOffset: Int, sliceSize: Int) throws -> Arm64Slice {
        guard sliceOffset >= 0, sliceSize >= 32, sliceOffset + sliceSize <= data.count else {
            throw AntigravityPatchError.invalidMachO("Mach-O 切片偏移越界")
        }
        guard let magic = readU32LE(data, at: sliceOffset),
              let cputype = readU32LE(data, at: sliceOffset + 4),
              let ncmds = readU32LE(data, at: sliceOffset + 16) else {
            throw AntigravityPatchError.invalidMachO("无法读取 Mach-O 头部")
        }
        guard magic == mhMagic64 else {
            throw AntigravityPatchError.invalidMachO(String(format: "不支持的 Mach-O 魔数: 0x%x", magic))
        }
        guard cputype == cpuTypeARM64 else {
            throw AntigravityPatchError.invalidMachO(String(format: "非 ARM64 切片 (cputype=0x%x)", cputype))
        }

        var segments: [Segment64] = []
        var sections: [Section64] = []
        var cmdOff = sliceOffset + 32

        for _ in 0 ..< ncmds {
            guard let cmd = readU32LE(data, at: cmdOff),
                  let cmdsize = readU32LE(data, at: cmdOff + 4),
                  cmdsize >= 8,
                  cmdOff + Int(cmdsize) <= sliceOffset + sliceSize else {
                throw AntigravityPatchError.invalidMachO("Mach-O Load Command 损坏或越界")
            }
            if cmd == lcSegment64 {
                guard cmdsize >= 72,
                      let vmaddr = readU64LE(data, at: cmdOff + 24),
                      let vmsize = readU64LE(data, at: cmdOff + 32),
                      let fileoff = readU64LE(data, at: cmdOff + 40),
                      let filesize = readU64LE(data, at: cmdOff + 48),
                      let nsects = readU32LE(data, at: cmdOff + 64) else {
                    throw AntigravityPatchError.invalidMachO("LC_SEGMENT_64 解析越界")
                }
                let segname = readFixedString(data, at: cmdOff + 8, maxLen: 16)
                segments.append(Segment64(name: segname, vmaddr: vmaddr, vmsize: vmsize, fileoff: fileoff, filesize: filesize))

                var sectOff = cmdOff + 72
                for _ in 0 ..< nsects {
                    guard sectOff + 80 <= cmdOff + Int(cmdsize),
                          let sAddr = readU64LE(data, at: sectOff + 32),
                          let sSize = readU64LE(data, at: sectOff + 40),
                          let sOffset = readU32LE(data, at: sectOff + 48) else {
                        throw AntigravityPatchError.invalidMachO("Section64 解析越界")
                    }
                    let sectname = readFixedString(data, at: sectOff, maxLen: 16)
                    let segOfSect = readFixedString(data, at: sectOff + 16, maxLen: 16)
                    sections.append(Section64(segmentName: segOfSect, sectionName: sectname, addr: sAddr, size: sSize, offset: sOffset))
                    sectOff += 80
                }
            }
            cmdOff += Int(cmdsize)
        }

        guard let textSect = sections.first(where: { $0.segmentName == "__TEXT" && $0.sectionName == "__text" }) else {
            throw AntigravityPatchError.invalidMachO("ARM64 切片中未找到 __TEXT,__text 代码节")
        }

        return Arm64Slice(
            sliceOffset: sliceOffset,
            sliceSize: sliceSize,
            segments: segments,
            sections: sections,
            textFileOffset: Int(textSect.offset),
            textVirtualSize: Int(textSect.size)
        )
    }

    // MARK: - Go pclntab 定位与符号解析

    public static func findPclntab(in data: Data, slice: Arm64Slice) throws -> PclntabInfo {
        let baseOff = slice.sliceOffset
        let endLimit = baseOff + slice.sliceSize
        var ranges: [(Int, Int)] = []

        if let gopcln = slice.sections.first(where: { $0.sectionName == "__gopclntab" }) {
            let s = baseOff + Int(gopcln.offset)
            let e = min(endLimit, s + Int(gopcln.size))
            if s < e { ranges.append((s, e)) }
        }
        ranges.append((baseOff, endLimit))

        let magics: [(Data, String)] = [
            (Data([0xF1, 0xFF, 0xFF, 0xFF]), "go1.20+"),
            (Data([0xF0, 0xFF, 0xFF, 0xFF]), "go1.18")
        ]

        let baseIndex = data.startIndex
        for (startBound, endBound) in ranges {
            for (magicData, ver) in magics {
                var pos = startBound
                while pos + 72 <= endLimit {
                    let searchRange = (baseIndex + pos) ..< (baseIndex + endLimit)
                    guard let hitRange = data.range(of: magicData, in: searchRange) else { break }
                    let i = hitRange.lowerBound - baseIndex
                    if i >= endBound { break }
                    pos = i + 4
                    guard i + 72 <= endLimit else { continue }

                    let pad1 = data[baseIndex + i + 4]
                    let pad2 = data[baseIndex + i + 5]
                    let minlc = data[baseIndex + i + 6]
                    let ptrsize = data[baseIndex + i + 7]
                    guard pad1 == 0, pad2 == 0, minlc == 4, ptrsize == 8 else { continue }

                    guard let nfunc64 = readU64LE(data, at: i + 8),
                          let textstart = readU64LE(data, at: i + 24),
                          let fnOff64 = readU64LE(data, at: i + 32),
                          let pclnOff64 = readU64LE(data, at: i + 64) else { continue }
                    guard nfunc64 > 500 && nfunc64 < 3_000_000 else { continue }

                    let nfunc = Int(nfunc64)
                    let fnOff = Int(fnOff64)
                    let pclnOff = Int(pclnOff64)
                    guard fnOff >= 0, pclnOff >= 0,
                          i + fnOff < endLimit,
                          i + pclnOff + nfunc * 8 <= endLimit else { continue }

                    let fdata = i + pclnOff
                    guard let nameOff32 = readU32LE(data, at: fdata + 4) else { continue }
                    let nameStart = i + fnOff + Int(nameOff32)
                    guard nameStart < endLimit else { continue }

                    let maxNameEnd = min(endLimit, nameStart + 64)
                    var validNameCount = 0
                    var allPrintable = true
                    var cursor = nameStart
                    while cursor < maxNameEnd {
                        let b = data[baseIndex + cursor]
                        if b == 0 { break }
                        if b < 32 || b >= 127 {
                            allPrintable = false
                            break
                        }
                        validNameCount += 1
                        cursor += 1
                    }
                    guard validNameCount > 0 && allPrintable else { continue }

                    return PclntabInfo(
                        sliceRelOffset: i - baseOff,
                        versionLabel: ver,
                        nfunc: nfunc,
                        textstart: textstart,
                        fnOffset: fnOff,
                        pclnOffset: pclnOff
                    )
                }
            }
        }
        throw AntigravityPatchError.pclntabNotFound
    }

    public static func resolveSymbol(
        in data: Data,
        slice: Arm64Slice,
        pcln: PclntabInfo,
        symbol: String
    ) throws -> (relOffset: Int, size: Int) {
        let sOff = slice.sliceOffset
        let sEnd = sOff + slice.sliceSize
        let functab = sOff + pcln.sliceRelOffset + pcln.pclnOffset
        let fnTab = sOff + pcln.sliceRelOffset + pcln.fnOffset
        let targetBytes = Array(symbol.utf8)

        var entries: [UInt32] = []
        entries.reserveCapacity(pcln.nfunc)
        var hit: (relOff: Int, ent: UInt32)? = nil
        let baseIndex = data.startIndex

        for i in 0 ..< pcln.nfunc {
            guard let ent = readU32LE(data, at: functab + i * 8),
                  let foff = readU32LE(data, at: functab + i * 8 + 4) else { break }
            entries.append(ent)

            guard hit == nil else { continue }
            let fdata = functab + Int(foff)
            guard fdata + 8 <= sEnd,
                  let nameOff = readU32LE(data, at: fdata + 4) else { continue }
            let nameStart = fnTab + Int(nameOff)
            guard nameStart + targetBytes.count < sEnd else { continue }

            // 快速精确匹配符号名 + NULL 终止符检查，避免全量字符串解码开销
            var matched = true
            for idx in 0 ..< targetBytes.count {
                if data[baseIndex + nameStart + idx] != targetBytes[idx] {
                    matched = false
                    break
                }
            }
            if matched && data[baseIndex + nameStart + targetBytes.count] == 0 {
                let relOff: Int?
                if pcln.textstart == 0 {
                    relOff = slice.textFileOffset + Int(ent)
                } else {
                    relOff = slice.vmaddrToFileOffset(pcln.textstart &+ UInt64(ent))
                }
                guard let validOff = relOff, slice.inText(validOff) else {
                    throw AntigravityPatchError.symbolOutOfBounds
                }
                hit = (validOff, ent)
            }
        }

        guard let found = hit else {
            throw AntigravityPatchError.symbolNotFound(symbol)
        }

        var nextEnt: UInt32? = nil
        for e in entries where e > found.ent {
            if let cur = nextEnt {
                if e < cur { nextEnt = e }
            } else {
                nextEnt = e
            }
        }

        let rawSize = nextEnt.map { Int($0 - found.ent) } ?? (slice.textVirtualSize - Int(found.ent))
        let maxRemaining = max(0, (slice.textFileOffset + slice.textVirtualSize) - found.relOff)
        return (found.relOff, min(rawSize, maxRemaining))
    }

    // MARK: - ARM64 指令编码与依赖安全匹配

    private static func encodeMovzMovk(reg: UInt32, is64Bit: Bool, val: UInt32) -> (UInt32, UInt32) {
        let lo16 = val & 0xFFFF
        let hi16 = (val >> 16) & 0xFFFF
        let sf: UInt32 = is64Bit ? (1 << 31) : 0
        let movz = sf | 0x52800000 | (lo16 << 5) | (reg & 0x1F)
        let movk = sf | 0x72A00000 | (hi16 << 5) | (reg & 0x1F)
        return (movz, movk)
    }

    private static func isMovzHw0(_ insn: UInt32) -> (reg: UInt32, is64: Bool, lo16: UInt32)? {
        guard (insn & 0x7F800000) == 0x52800000, ((insn >> 21) & 0x3) == 0 else { return nil }
        return (insn & 0x1F, ((insn >> 31) & 1) == 1, (insn >> 5) & 0xFFFF)
    }

    private static func isMovkHw1(_ insn: UInt32, expectedRd: UInt32, expectedSf: Bool) -> UInt32? {
        guard (insn & 0x7F800000) == 0x72800000, ((insn >> 21) & 0x3) == 1 else { return nil }
        guard (insn & 0x1F) == expectedRd, (((insn >> 31) & 1) == 1) == expectedSf else { return nil }
        return (insn >> 5) & 0xFFFF
    }

    private static func insnClobbersReg(_ insn: UInt32, reg: UInt32) -> Bool {
        if reg == 31 || (insn & 0x1F) != reg { return false }
        if (insn & 0xFF000010) == 0x54000000 { return false } // B.cond
        if (insn & 0x7C000000) == 0x14000000 { return false } // B / BL
        return true
    }

    public static func analyze(
        data: Data,
        targetPath: String,
        targetOverrideTokens: UInt32?
    ) throws -> AntigravityAnalysisReport {
        let slice = try extractArm64Slice(from: data)
        let pcln = try findPclntab(in: data, slice: slice)
        let (symRelOff, symSize) = try resolveSymbol(in: data, slice: slice, pcln: pcln, symbol: targetSymbol)

        let base = slice.sliceOffset
        let start = symRelOff
        let end = min(symRelOff + symSize, slice.textFileOffset + slice.textVirtualSize)
        guard end - start >= 8 else {
            throw AntigravityPatchError.clampSiteNotFound
        }

        var candidates: [ClampCandidate] = []
        var pos1 = start
        while pos1 <= end - 8 {
            guard let insn1 = readU32LE(data, at: base + pos1),
                  let mMovz = isMovzHw0(insn1) else {
                pos1 += 4
                continue
            }

            var movkPos: Int? = nil
            var hi16: UInt32? = nil
            var pos2 = pos1 + 4
            let lookEnd = min(end, pos1 + 28)
            while pos2 < lookEnd {
                guard let insn2 = readU32LE(data, at: base + pos2) else { break }
                if let h = isMovkHw1(insn2, expectedRd: mMovz.reg, expectedSf: mMovz.is64) {
                    movkPos = pos2
                    hi16 = h
                    break
                }
                if insnClobbersReg(insn2, reg: mMovz.reg) {
                    break
                }
                pos2 += 4
            }

            guard let foundMovk = movkPos, let foundHi = hi16 else {
                pos1 += 4
                continue
            }

            let val = (foundHi << 16) | mMovz.lo16
            var hasCmpOrCsel = false
            var hasRegisterMatch = false
            let winStart = max(start, pos1 - 16)
            let winEnd = min(end, foundMovk + 40)
            var look = winStart
            while look < winEnd {
                if let ins = readU32LE(data, at: base + look) {
                    let isCsel = (ins & 0x7FE00000) == 0x1A800000
                    let isCmp = (ins & 0x7F20001F) == 0x6B00001F
                    if isCsel || isCmp {
                        hasCmpOrCsel = true
                        let rn = (ins >> 5) & 0x1F
                        let rm = (ins >> 16) & 0x1F
                        let rd = ins & 0x1F
                        if rn == mMovz.reg || rm == mMovz.reg || (isCsel && rd == mMovz.reg) {
                            hasRegisterMatch = true
                        }
                    }
                }
                look += 4
            }

            if hasCmpOrCsel {
                if val == 256_000 {
                    candidates.append(ClampCandidate(pos1: pos1, pos2: foundMovk, reg: mMovz.reg, is64Bit: mMovz.is64, kind: "original", value: val, registerMatched: hasRegisterMatch))
                } else if val == unclampedMarker {
                    candidates.append(ClampCandidate(pos1: pos1, pos2: foundMovk, reg: mMovz.reg, is64Bit: mMovz.is64, kind: "removed", value: val, registerMatched: hasRegisterMatch))
                } else if val >= 1_000 && val <= 4_000_000 && val != 40_000 && val != 65_536 {
                    candidates.append(ClampCandidate(pos1: pos1, pos2: foundMovk, reg: mMovz.reg, is64Bit: mMovz.is64, kind: "forced", value: val, registerMatched: hasRegisterMatch))
                }
            }

            pos1 += 4
        }

        // 若同时命中多处，优先保留寄存器真实参与 CMP/CSEL 依赖的站点，降低误改风险
        let regMatched = candidates.filter { $0.registerMatched }
        let selected = regMatched.isEmpty ? candidates : regMatched
        guard !selected.isEmpty else {
            throw AntigravityPatchError.clampSiteNotFound
        }

        let kinds = Set(selected.map(\.kind))
        let clampState: ClampState
        if kinds == ["original"] {
            clampState = .original256K
        } else if kinds == ["removed"] {
            clampState = .unlocked
        } else if kinds == ["forced"], let firstVal = selected.first?.value, selected.allSatisfy({ $0.value == firstVal }) {
            clampState = .custom(Int(firstVal))
        } else {
            clampState = .mixed(kinds.sorted().joined(separator: "+"))
        }

        let targetVal = targetOverrideTokens ?? unclampedMarker
        var edits: [AntigravityBinaryEdit] = []
        var editIdx = 0

        for cand in selected {
            let (newMovz, newMovk) = encodeMovzMovk(reg: cand.reg, is64Bit: cand.is64Bit, val: targetVal)
            let p1 = base + cand.pos1
            let p2 = base + cand.pos2

            var mzLE = newMovz.littleEndian
            var mkLE = newMovk.littleEndian
            let newBytes1 = Data(bytes: &mzLE, count: 4)
            let newBytes2 = Data(bytes: &mkLE, count: 4)

            let oldBytes1 = data.subdata(in: (data.startIndex + p1) ..< (data.startIndex + p1 + 4))
            let oldBytes2 = data.subdata(in: (data.startIndex + p2) ..< (data.startIndex + p2 + 4))

            edits.append(AntigravityBinaryEdit(id: editIdx, fileOffset: p1, originalBytes: oldBytes1, replacementBytes: newBytes1))
            editIdx += 1
            edits.append(AntigravityBinaryEdit(id: editIdx, fileOffset: p2, originalBytes: oldBytes2, replacementBytes: newBytes2))
            editIdx += 1
        }

        return AntigravityAnalysisReport(
            targetPath: targetPath,
            sliceOffset: slice.sliceOffset,
            textFileOffset: slice.textFileOffset,
            textVirtualSize: slice.textVirtualSize,
            pclnOffset: pcln.sliceRelOffset,
            pclnVersion: pcln.versionLabel,
            functionCount: pcln.nfunc,
            symbolOffset: symRelOff,
            symbolSize: symSize,
            clampState: clampState,
            binarySHA256: sha256Hex(of: data),
            edits: edits
        )
    }

    public static func apply(edits: [AntigravityBinaryEdit], to data: inout Data) throws {
        for edit in edits {
            guard edit.fileOffset >= 0,
                  edit.fileOffset + edit.replacementBytes.count <= data.count else {
                throw AntigravityPatchError.verificationFailed("修改偏移越界: 0x\(String(edit.fileOffset, radix: 16))")
            }
            let start = data.startIndex + edit.fileOffset
            data.replaceSubrange(start ..< (start + edit.replacementBytes.count), with: edit.replacementBytes)
            let verifySlice = data.subdata(in: start ..< (start + edit.replacementBytes.count))
            guard verifySlice == edit.replacementBytes else {
                throw AntigravityPatchError.verificationFailed("内存写入校验失败: 0x\(String(edit.fileOffset, radix: 16))")
            }
        }
    }
}

// MARK: - Antigravity 上下文扩容管理器

@Observable
@MainActor
public final class AntigravityContextManager {
    public static let shared = AntigravityContextManager()

    // 配置与目标
    public var selectedPreset: AntigravityContextPreset = .unclamped
    public var customTokensText: String = "900K"
    public var autoCheckOnEntry: Bool = true

    public var discoveredTargets: [AntigravityTargetCandidate] = []
    public var selectedTargetPath: String = ""

    // 环境检查
    public var environmentItems: [EnvironmentCheckItem] = []
    public var isAppleSilicon: Bool = false
    public var isCodesignReady: Bool = false
    public var isCLTInstalled: Bool = false
    public var hasDirectWritePermission: Bool = false
    public var isInstallingCLT: Bool = false

    // 实时状态
    public var currentAppVersion: String? = nil
    public var currentAppBundlePath: String? = nil
    public var isAntigravityRunning: Bool = false
    public var isLanguageServerRunning: Bool = false

    public var latestReport: AntigravityAnalysisReport? = nil
    public var lastError: String? = nil
    public var statusMessage: String? = nil
    public var isAnalyzing: Bool = false
    public var isApplying: Bool = false

    // 记忆记录 & 历史备份
    public var memory: AntigravityMemoryRecord = AntigravityMemoryRecord()
    public var versionWatchState: AntigravityVersionWatchState = .idle
    public var legacyBackupPaths: [String] = []

    private var cltPollTask: Task<Void, Never>? = nil

    private static let defaultsMemoryKey = "SP_AntigravityContext_MemoryJSON"
    private static let defaultsPresetKey = "SP_AntigravityContext_Preset"
    private static let defaultsCustomKey = "SP_AntigravityContext_CustomTokens"

    private init() {
        loadPersistence()
    }

    // MARK: - 持久化路径

    private nonisolated static var appSupportBaseDir: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SysPulse", isDirectory: true)
    }

    private nonisolated static var stateDir: URL {
        let dir = appSupportBaseDir.appendingPathComponent("AntigravityContext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static var memoryFileURL: URL {
        stateDir.appendingPathComponent("memory.json")
    }

    public nonisolated static var backupDir: URL {
        let dir = appSupportBaseDir
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Antigravity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadPersistence() {
        let d = UserDefaults.standard
        if let rawPreset = d.string(forKey: Self.defaultsPresetKey),
           let preset = AntigravityContextPreset(rawValue: rawPreset) {
            selectedPreset = preset
        }
        if let custom = d.string(forKey: Self.defaultsCustomKey), !custom.isEmpty {
            customTokensText = custom
        }
        if let data = try? Data(contentsOf: Self.memoryFileURL),
           let decoded = try? JSONDecoder().decode(AntigravityMemoryRecord.self, from: data) {
            memory = decoded
        } else if let jsonStr = d.string(forKey: Self.defaultsMemoryKey),
                  let data = jsonStr.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(AntigravityMemoryRecord.self, from: data) {
            memory = decoded
        }
    }

    private func savePersistence() {
        let d = UserDefaults.standard
        d.set(selectedPreset.rawValue, forKey: Self.defaultsPresetKey)
        d.set(customTokensText, forKey: Self.defaultsCustomKey)
        if let encoded = try? JSONEncoder().encode(memory) {
            try? encoded.write(to: Self.memoryFileURL, options: .atomic)
            if let str = String(data: encoded, encoding: .utf8) {
                d.set(str, forKey: Self.defaultsMemoryKey)
            }
        }
    }

    // MARK: - 进入插件/模块中心自动复检

    public func checkOnEntry() {
        guard !isApplying else { return }
        refreshAllStatus()
    }

    public func refreshAllStatus() {
        isAnalyzing = true
        lastError = nil

        let chosenPath = selectedTargetPath
        let rememberedTarget = memory.lastPatchedTargetPath
        let overrideTokens = resolveRequestedTokens()

        DispatchQueue.global(qos: .userInitiated).async {
            let envSnapshot = Self.collectEnvironmentSnapshot()
            let targets = Self.discoverTargets()
            let activePath: String
            if !chosenPath.isEmpty && FileManager.default.fileExists(atPath: chosenPath) {
                activePath = chosenPath
            } else if let remembered = rememberedTarget,
                      targets.contains(where: { $0.path == remembered }) {
                activePath = remembered
            } else {
                activePath = targets.first?.path ?? ""
            }

            let activeTarget = targets.first(where: { $0.path == activePath }) ?? Self.inspectExplicitCandidate(path: activePath)
            let legacyBaks = Self.findLegacyBackups(forTargetPath: activePath)

            var report: AntigravityAnalysisReport? = nil
            var analysisErr: String? = nil
            var writable = false

            if !activePath.isEmpty && FileManager.default.fileExists(atPath: activePath) {
                let url = URL(fileURLWithPath: activePath)
                let parentWritable = FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
                let fileWritable = FileManager.default.isWritableFile(atPath: activePath)
                writable = parentWritable && fileWritable

                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    report = try AntigravityBinaryPatcher.analyze(
                        data: data,
                        targetPath: activePath,
                        targetOverrideTokens: overrideTokens
                    )
                } catch {
                    analysisErr = error.localizedDescription
                }
            }

            DispatchQueue.main.async {
                self.isAppleSilicon = envSnapshot.isAppleSilicon
                self.isCodesignReady = envSnapshot.isCodesignReady
                self.isCLTInstalled = envSnapshot.isCLTInstalled
                self.discoveredTargets = targets
                self.selectedTargetPath = activePath
                self.currentAppVersion = activeTarget?.appVersion
                self.currentAppBundlePath = activeTarget?.appBundlePath
                self.isAntigravityRunning = envSnapshot.isAntigravityAppRunning
                self.isLanguageServerRunning = activeTarget?.isRunning ?? envSnapshot.runningLanguageServerPaths.contains(activePath)
                self.hasDirectWritePermission = writable
                self.legacyBackupPaths = legacyBaks
                self.latestReport = report
                if let analysisErr {
                    self.lastError = analysisErr
                }

                self.rebuildEnvironmentItems(env: envSnapshot, targetPath: activePath, writable: writable)
                self.evaluateVersionWatchState(targetPath: activePath, report: report, analysisError: analysisErr)
                self.isAnalyzing = false
            }
        }
    }

    private func resolveRequestedTokens() -> UInt32? {
        switch selectedPreset {
        case .unclamped: return nil
        case .k900, .k512: return selectedPreset.fixedTokenValue
        case .custom: return try? AntigravityBinaryPatcher.parseTokenInput(customTokensText)
        }
    }

    private func evaluateVersionWatchState(
        targetPath: String,
        report: AntigravityAnalysisReport?,
        analysisError: String?
    ) {
        if targetPath.isEmpty {
            versionWatchState = .targetNotFound
            return
        }
        if let err = analysisError, report == nil {
            versionWatchState = .analysisFailed(err)
            return
        }
        guard let report else {
            versionWatchState = .targetNotFound
            return
        }

        let currentVer = currentAppVersion
        let rememberedVer = memory.lastKnownVersion

        switch report.clampState {
        case .original256K:
            if let oldV = rememberedVer, let newV = currentVer, oldV != newV {
                versionWatchState = .versionChangedReverted(oldVersion: oldV, newVersion: newV)
            } else if memory.lastPatchedAt != nil {
                versionWatchState = .patchInvalidatedSameVersion(version: currentVer ?? rememberedVer)
            } else {
                versionWatchState = .neverPatchedOriginal(currentVersion: currentVer)
            }
        case .unlocked, .custom, .mixed:
            if let oldV = rememberedVer, let newV = currentVer, oldV != newV {
                versionWatchState = .versionChangedStillActive(oldVersion: oldV, newVersion: newV, clamp: report.clampState)
            } else if memory.lastKnownVersion == nil {
                versionWatchState = .externalPatchedUnrecorded(currentVersion: currentVer, clamp: report.clampState)
            } else {
                versionWatchState = .activeMatched(version: currentVer ?? rememberedVer, clamp: report.clampState)
            }
        }
    }

    // MARK: - 同步记忆当前版本号（适配在工具外部已解锁的场景）

    public func syncCurrentVersionMemory() {
        guard let report = latestReport, report.clampState.isPatched else { return }
        memory.lastKnownVersion = currentAppVersion
        memory.lastPatchedTargetPath = report.targetPath
        memory.lastPatchedBinarySHA256 = report.binarySHA256
        memory.lastPatchedAt = Date()
        switch report.clampState {
        case .unlocked:
            memory.lastAppliedPresetRaw = AntigravityContextPreset.unclamped.rawValue
            memory.lastAppliedCustomTokens = nil
        case .custom(let val):
            memory.lastAppliedPresetRaw = AntigravityContextPreset.custom.rawValue
            memory.lastAppliedCustomTokens = val
        default:
            break
        }
        savePersistence()
        statusMessage = "已记忆当前版本 \(currentAppVersion.map { "v\($0)" } ?? "") 与生效状态"
        evaluateVersionWatchState(targetPath: report.targetPath, report: report, analysisError: nil)
    }

    // MARK: - 环境检查与 Xcode CLT 安装引导

    private struct EnvSnapshot: Sendable {
        let isAppleSilicon: Bool
        let archLabel: String
        let isCodesignReady: Bool
        let isXattrReady: Bool
        let isCLTInstalled: Bool
        let isAntigravityAppRunning: Bool
        let runningLanguageServerPaths: Set<String>
    }

    private nonisolated static func collectEnvironmentSnapshot() -> EnvSnapshot {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let arm64 = machine.lowercased().contains("arm64")

        let fm = FileManager.default
        let codesignOk = fm.isExecutableFile(atPath: "/usr/bin/codesign")
        let xattrOk = fm.isExecutableFile(atPath: "/usr/bin/xattr")

        // 检测 CLT 是否真正就绪（避免直接调用 /usr/bin/python3 等 stub 触发意外弹窗）
        let cltProc = Process()
        cltProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        cltProc.arguments = ["-p"]
        cltProc.standardOutput = FileHandle.nullDevice
        cltProc.standardError = FileHandle.nullDevice
        var cltOk = false
        if (try? cltProc.run()) != nil {
            cltProc.waitUntilExit()
            cltOk = (cltProc.terminationStatus == 0)
        }

        let runningApp = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.google.antigravity"
                || $0.bundleIdentifier == "com.google.gemini"
                || ($0.localizedName?.localizedCaseInsensitiveContains("Antigravity") ?? false)
        }

        var runningLS: Set<String> = []
        let psProc = Process()
        psProc.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProc.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        psProc.standardOutput = pipe
        psProc.standardError = FileHandle.nullDevice
        if (try? psProc.run()) != nil {
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            psProc.waitUntilExit()
            if let text = String(data: outData, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.contains("language_server") {
                        runningLS.insert(trimmed)
                    }
                }
            }
        }

        return EnvSnapshot(
            isAppleSilicon: arm64,
            archLabel: machine,
            isCodesignReady: codesignOk,
            isXattrReady: xattrOk,
            isCLTInstalled: cltOk,
            isAntigravityAppRunning: runningApp,
            runningLanguageServerPaths: runningLS
        )
    }

    private func rebuildEnvironmentItems(env: EnvSnapshot, targetPath: String, writable: Bool) {
        var items: [EnvironmentCheckItem] = []

        items.append(EnvironmentCheckItem(
            id: "arch",
            title: "硬件架构",
            detail: env.isAppleSilicon ? "Apple Silicon (\(env.archLabel))" : "非 ARM64 (\(env.archLabel)) · 仅支持 Apple Silicon",
            level: env.isAppleSilicon ? .ready : .blocked
        ))

        items.append(EnvironmentCheckItem(
            id: "engine",
            title: "解析引擎",
            detail: "纯 Swift 原生 Mach-O 引擎（免 Python）",
            level: .ready
        ))

        if env.isCodesignReady && env.isXattrReady {
            items.append(EnvironmentCheckItem(
                id: "codesign",
                title: "签名工具链",
                detail: env.isCLTInstalled ? "codesign & CLT 就绪" : "codesign 可用（CLT 未安装）",
                level: .ready,
                actionTitle: env.isCLTInstalled ? nil : "安装 CLT"
            ))
        } else {
            items.append(EnvironmentCheckItem(
                id: "codesign",
                title: "签名工具链",
                detail: "缺少 codesign / Xcode 命令行工具",
                level: .blocked,
                actionTitle: "一键安装 CLT"
            ))
        }

        if targetPath.isEmpty {
            items.append(EnvironmentCheckItem(
                id: "perm",
                title: "目标权限",
                detail: "未找到 language_server 目标",
                level: .warning,
                actionTitle: "手动选择"
            ))
        } else if writable {
            items.append(EnvironmentCheckItem(
                id: "perm",
                title: "写入权限",
                detail: "当前用户可直接写入与重签",
                level: .ready
            ))
        } else {
            items.append(EnvironmentCheckItem(
                id: "perm",
                title: "写入权限",
                detail: "系统目录受保护（执行时将弹出管理员授权）",
                level: .warning
            ))
        }

        if isAntigravityRunning || isLanguageServerRunning {
            items.append(EnvironmentCheckItem(
                id: "proc",
                title: "进程状态",
                detail: "Antigravity 运行中（执行时自动平滑重启）",
                level: .warning,
                actionTitle: "关闭 Antigravity"
            ))
        } else {
            items.append(EnvironmentCheckItem(
                id: "proc",
                title: "进程状态",
                detail: "无占用进程 · 可安全原地写入",
                level: .ready
            ))
        }

        environmentItems = items
    }

    public func installCommandLineTools() {
        guard !isInstallingCLT else { return }
        isInstallingCLT = true
        statusMessage = "已唤起 macOS 命令行开发者工具安装向导，请按系统弹窗完成安装..."
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            proc.arguments = ["--install"]
            try? proc.run()
            proc.waitUntilExit()
        }

        cltPollTask?.cancel()
        cltPollTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 60 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                let snap = Self.collectEnvironmentSnapshot()
                if snap.isCodesignReady && snap.isCLTInstalled {
                    self.isInstallingCLT = false
                    self.statusMessage = "命令行工具与 codesign 已就绪"
                    self.refreshAllStatus()
                    self.cltPollTask = nil
                    return
                }
            }
            if let self {
                self.isInstallingCLT = false
                self.cltPollTask = nil
            }
        }
    }

    // MARK: - 多路径发现与版本读取

    private nonisolated static func discoverTargets() -> [AntigravityTargetCandidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. 精确高频路径优先，避免遍历 ~/.antigravity 庞大的日志/缓存子树
        var directCandidates: [URL] = [
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            home.appendingPathComponent("Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            URL(fileURLWithPath: "/Applications/Gemini.app/Contents/Resources/bin/language_server"),
            home.appendingPathComponent("Applications/Gemini.app/Contents/Resources/bin/language_server")
        ]

        // 2. 从活跃进程补充正在运行的 language_server
        let env = collectEnvironmentSnapshot()
        for p in env.runningLanguageServerPaths where p.hasPrefix("/") {
            directCandidates.append(URL(fileURLWithPath: p))
        }

        // 3. 有限深度扫描扩展目录
        let shallowRoots: [URL] = [
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources"),
            home.appendingPathComponent("Applications/Antigravity.app/Contents/Resources"),
            home.appendingPathComponent(".antigravity/bin"),
            home.appendingPathComponent(".antigravity/extensions")
        ]

        for root in shallowRoots where fm.fileExists(atPath: root.path) {
            if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let item = enumerator.nextObject() as? URL {
                    let relDepth = item.pathComponents.count - root.pathComponents.count
                    if relDepth > 4 {
                        enumerator.skipDescendants()
                        continue
                    }
                    let name = item.lastPathComponent
                    if name == "node_modules" || name == "logs" || name == "brain" {
                        enumerator.skipDescendants()
                        continue
                    }
                    if name.contains("language_server"),
                       !name.hasSuffix(".bak"),
                       !name.hasSuffix(".patched"),
                       !name.hasSuffix(".dSYM"),
                       !name.contains(".bak-"),
                       AntigravityBinaryPatcher.isMachOFile(item) {
                        directCandidates.append(item)
                    }
                }
            }
        }

        var seen: Set<String> = []
        var results: [AntigravityTargetCandidate] = []
        for url in directCandidates {
            let resolved = url.resolvingSymlinksInPath().path
            guard !seen.contains(resolved),
                  fm.fileExists(atPath: resolved),
                  AntigravityBinaryPatcher.isMachOFile(URL(fileURLWithPath: resolved)) else { continue }
            seen.insert(resolved)
            if let cand = inspectExplicitCandidate(path: resolved, runningPaths: env.runningLanguageServerPaths) {
                results.append(cand)
            }
        }
        return results
    }

    private nonisolated static func inspectExplicitCandidate(
        path: String,
        runningPaths: Set<String>? = nil
    ) -> AntigravityTargetCandidate? {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        var appBundleURL: URL? = nil
        var cursor = url.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" {
                appBundleURL = cursor
                break
            }
            cursor.deleteLastPathComponent()
        }

        var appName = url.lastPathComponent
        var appVersion: String? = nil
        if let appURL = appBundleURL {
            appName = appURL.deletingPathExtension().lastPathComponent
            let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
            if let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] {
                let shortVer = dict["CFBundleShortVersionString"] as? String
                let buildVer = dict["CFBundleVersion"] as? String
                if let shortVer, !shortVer.isEmpty {
                    appVersion = shortVer
                } else if let buildVer, !buildVer.isEmpty {
                    appVersion = buildVer
                }
            }
        }

        let activePaths = runningPaths ?? collectEnvironmentSnapshot().runningLanguageServerPaths
        return AntigravityTargetCandidate(
            path: path,
            appName: appName,
            appBundlePath: appBundleURL?.path,
            appVersion: appVersion,
            isRunning: activePaths.contains(path)
        )
    }

    private nonisolated static func findLegacyBackups(forTargetPath path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        let url = URL(fileURLWithPath: path)
        let prefix = url.lastPathComponent + ".bak-"
        let dir = url.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
            .map(\.path)
    }

    public func selectCustomTargetViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Antigravity language_server 二进制文件"
        panel.message = "通常位于 /Applications/Antigravity.app/Contents/Resources/bin/language_server"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            selectedTargetPath = url.path
            refreshAllStatus()
        }
    }

    // MARK: - 退出 Antigravity 进程（手动或联动调用）

    public func quitAntigravityOnly() {
        let targetPath = selectedTargetPath
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.terminateAntigravityAndLanguageServer(targetPath: targetPath)
            DispatchQueue.main.async {
                self.statusMessage = "已通知 Antigravity 退出"
                self.refreshAllStatus()
            }
        }
    }

    private nonisolated static func terminateAntigravityAndLanguageServer(targetPath: String) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.google.antigravity"
                || $0.bundleIdentifier == "com.google.gemini"
                || ($0.localizedName?.localizedCaseInsensitiveContains("Antigravity") ?? false)
        }
        let wasRunning = !runningApps.isEmpty
        for app in runningApps {
            _ = app.terminate()
        }

        let deadline = Date().addingTimeInterval(4.5)
        while Date() < deadline {
            let stillAlive = NSWorkspace.shared.runningApplications.contains {
                ($0.bundleIdentifier == "com.google.antigravity" || $0.bundleIdentifier == "com.google.gemini") && !$0.isTerminated
            }
            if !stillAlive { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        for app in runningApps where !app.isTerminated {
            _ = app.forceTerminate()
        }

        if !targetPath.isEmpty {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", targetPath]
            pkill.standardOutput = FileHandle.nullDevice
            pkill.standardError = FileHandle.nullDevice
            try? pkill.run()
            pkill.waitUntilExit()
        }
        return wasRunning
    }

    // MARK: - 执行解锁 / 应用预设（包含自动退出、备份、原子替换、重签与重启）

    public func applySelectedPatch(autoRestartIfRunning: Bool = true) {
        guard !isApplying else { return }
        let targetPath = selectedTargetPath
        guard !targetPath.isEmpty else {
            lastError = "未检测到可操作的 language_server 目标文件"
            return
        }

        let requestedTokens: UInt32?
        do {
            switch selectedPreset {
            case .unclamped:
                requestedTokens = nil
            case .k900, .k512:
                requestedTokens = selectedPreset.fixedTokenValue
            case .custom:
                requestedTokens = try AntigravityBinaryPatcher.parseTokenInput(customTokensText)
            }
        } catch {
            lastError = error.localizedDescription
            return
        }

        isApplying = true
        lastError = nil
        statusMessage = "正在分析并执行上下文扩容..."

        let capturedVersion = currentAppVersion
        let capturedBundlePath = currentAppBundlePath
        let capturedPreset = selectedPreset
        let capturedMemory = memory

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let targetURL = URL(fileURLWithPath: targetPath)
                var data = try Data(contentsOf: targetURL)
                let report = try AntigravityBinaryPatcher.analyze(
                    data: data,
                    targetPath: targetPath,
                    targetOverrideTokens: requestedTokens
                )

                if report.alreadyMatchesTarget {
                    DispatchQueue.main.async {
                        self.isApplying = false
                        self.latestReport = report
                        self.syncCurrentVersionMemory()
                        self.statusMessage = "当前已处于目标上下文配置，并已同步版本记忆"
                    }
                    return
                }

                // 若原文件当前处于 256K 原版状态，保存一份不可变原始备份到 Application Support
                var backupPathToSave = capturedMemory.managedBackupPath
                var backupSHA256ToSave = capturedMemory.managedBackupSHA256
                let origSHA = report.binarySHA256
                if case .original256K = report.clampState {
                    let bakURL = Self.backupDir.appendingPathComponent("language_server.orig-\(origSHA.prefix(12))")
                    if !FileManager.default.fileExists(atPath: bakURL.path) {
                        try data.write(to: bakURL, options: .atomic)
                    }
                    backupPathToSave = bakURL.path
                    backupSHA256ToSave = origSHA
                }

                try AntigravityBinaryPatcher.apply(edits: report.edits, to: &data)
                let expectedPatchedSHA = AntigravityBinaryPatcher.sha256Hex(of: data)

                let shouldRestart = autoRestartIfRunning
                    ? Self.terminateAntigravityAndLanguageServer(targetPath: targetPath)
                    : false

                try Self.writeAndResign(patchedData: data, targetURL: targetURL, edits: report.edits)

                // 如果需要重启 Antigravity
                if shouldRestart, let appPath = capturedBundlePath {
                    DispatchQueue.main.async {
                        let appURL = URL(fileURLWithPath: appPath)
                        let cfg = NSWorkspace.OpenConfiguration()
                        cfg.activates = false
                        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, _ in }
                    }
                }

                DispatchQueue.main.async {
                    self.memory.lastKnownVersion = capturedVersion
                    self.memory.lastPatchedTargetPath = targetPath
                    self.memory.lastPatchedBinarySHA256 = expectedPatchedSHA
                    self.memory.lastAppliedPresetRaw = capturedPreset.rawValue
                    self.memory.lastAppliedCustomTokens = requestedTokens.map(Int.init)
                    self.memory.lastPatchedAt = Date()
                    self.memory.managedBackupPath = backupPathToSave
                    self.memory.managedBackupSHA256 = backupSHA256ToSave
                    self.savePersistence()

                    self.isApplying = false
                    self.statusMessage = shouldRestart
                        ? "已完成扩容与代码重签，正在重新启动 Antigravity"
                        : "已完成扩容与代码重签，重启 Antigravity 后立即生效"
                    self.refreshAllStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isApplying = false
                    self.lastError = error.localizedDescription
                    self.statusMessage = nil
                    self.refreshAllStatus()
                }
            }
        }
    }

    // MARK: - 还原原版备份

    public func restoreFromBackup(customBackupPath: String? = nil) {
        guard !isApplying else { return }
        let targetPath = selectedTargetPath
        guard !targetPath.isEmpty else { return }

        let bakPath = customBackupPath
            ?? memory.managedBackupPath
            ?? legacyBackupPaths.first
        guard let bakPath, FileManager.default.fileExists(atPath: bakPath) else {
            lastError = "未找到可用的原版备份文件"
            return
        }

        isApplying = true
        lastError = nil
        statusMessage = "正在还原原版备份并校验签名..."
        let capturedBundlePath = currentAppBundlePath

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bakData = try Data(contentsOf: URL(fileURLWithPath: bakPath))
                let targetURL = URL(fileURLWithPath: targetPath)
                let shouldRestart = Self.terminateAntigravityAndLanguageServer(targetPath: targetPath)
                try Self.writeAndResign(patchedData: bakData, targetURL: targetURL, edits: [])

                if shouldRestart, let appPath = capturedBundlePath {
                    DispatchQueue.main.async {
                        let cfg = NSWorkspace.OpenConfiguration()
                        cfg.activates = false
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: cfg) { _, _ in }
                    }
                }

                DispatchQueue.main.async {
                    self.memory.lastKnownVersion = nil
                    self.memory.lastPatchedBinarySHA256 = nil
                    self.memory.lastPatchedAt = nil
                    self.savePersistence()

                    self.isApplying = false
                    self.statusMessage = shouldRestart
                        ? "已还原为原版 256K 上限并重签，正在重启 Antigravity"
                        : "已还原为原版 256K 上限并校验签名"
                    self.refreshAllStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isApplying = false
                    self.lastError = error.localizedDescription
                    self.refreshAllStatus()
                }
            }
        }
    }

    // MARK: - 原子写盘、降权/提权适配与 codesign 验证

    private nonisolated static func writeAndResign(
        patchedData: Data,
        targetURL: URL,
        edits: [AntigravityBinaryEdit]
    ) throws {
        let fm = FileManager.default
        let parentWritable = fm.isWritableFile(atPath: targetURL.deletingLastPathComponent().path)
        let targetWritable = fm.isWritableFile(atPath: targetURL.path)

        if parentWritable && targetWritable {
            let tmpURL = targetURL.deletingLastPathComponent().appendingPathComponent(".\(targetURL.lastPathComponent).syspulse.tmp")
            let rollbackData = try Data(contentsOf: targetURL)
            do {
                try patchedData.write(to: tmpURL, options: .atomic)
                let attrs = try fm.attributesOfItem(atPath: targetURL.path)
                if let posix = attrs[.posixPermissions] {
                    try? fm.setAttributes([.posixPermissions: posix], ofItemAtPath: tmpURL.path)
                }
                _ = try fm.replaceItemAt(targetURL, withItemAt: tmpURL, backupItemName: nil, options: [])
                try codesignAndVerify(targetURL: targetURL)
            } catch {
                try? fm.removeItem(at: tmpURL)
                try? rollbackData.write(to: targetURL, options: .atomic)
                _ = try? codesignAndVerify(targetURL: targetURL)
                throw error
            }
        } else {
            // 系统受保护目录：通过 macOS 原生管理员授权窗口完成原子替换与重签
            let stageURL = fm.temporaryDirectory.appendingPathComponent("syspulse_ag_patch_\(UUID().uuidString)")
            try patchedData.write(to: stageURL, options: .atomic)
            defer { try? fm.removeItem(at: stageURL) }

            let escStage = shellSingleQuote(stageURL.path)
            let escTarget = shellSingleQuote(targetURL.path)
            let scriptCmd = "cp -f \(escStage) \(escTarget) && chmod 755 \(escTarget) && (xattr -d com.apple.quarantine \(escTarget) 2>/dev/null || true) && codesign --force --preserve-metadata=entitlements,flags --sign - \(escTarget) && codesign --verify --strict \(escTarget)"
            let escapedForAppleScript = scriptCmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScriptSource = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"

            var errDict: NSDictionary? = nil
            guard let script = NSAppleScript(source: appleScriptSource) else {
                throw AntigravityPatchError.permissionOrWriteFailed("无法初始化管理员授权脚本")
            }
            _ = script.executeAndReturnError(&errDict)
            if let errDict {
                let msg = (errDict[NSAppleScript.errorMessage] as? String) ?? "管理员授权取消或失败"
                throw AntigravityPatchError.permissionOrWriteFailed(msg)
            }
        }

        // 最终磁盘字节一致性校验
        let diskData = try Data(contentsOf: targetURL, options: .mappedIfSafe)
        for edit in edits {
            let start = diskData.startIndex + edit.fileOffset
            let end = start + edit.replacementBytes.count
            guard end <= diskData.endIndex,
                  diskData.subdata(in: start ..< end) == edit.replacementBytes else {
                throw AntigravityPatchError.verificationFailed("磁盘最终字节回读校验未通过")
            }
        }
    }

    private nonisolated static func codesignAndVerify(targetURL: URL) throws {
        let xattrProc = Process()
        xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProc.arguments = ["-d", "com.apple.quarantine", targetURL.path]
        xattrProc.standardOutput = FileHandle.nullDevice
        xattrProc.standardError = FileHandle.nullDevice
        try? xattrProc.run()
        xattrProc.waitUntilExit()

        let signProc = Process()
        signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProc.arguments = [
            "--force",
            "--preserve-metadata=entitlements,flags",
            "--sign", "-",
            targetURL.path
        ]
        let signErr = Pipe()
        signProc.standardOutput = FileHandle.nullDevice
        signProc.standardError = signErr
        try signProc.run()
        signProc.waitUntilExit()
        if signProc.terminationStatus != 0 {
            let errText = String(data: signErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AntigravityPatchError.signingFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let verifyProc = Process()
        verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProc.arguments = ["--verify", "--strict", targetURL.path]
        let verErr = Pipe()
        verifyProc.standardOutput = FileHandle.nullDevice
        verifyProc.standardError = verErr
        try verifyProc.run()
        verifyProc.waitUntilExit()
        if verifyProc.terminationStatus != 0 {
            let errText = String(data: verErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AntigravityPatchError.signingFailed("verify 失败: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private nonisolated static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
