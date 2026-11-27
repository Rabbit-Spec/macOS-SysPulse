import AppKit
import CoreLocation
import CryptoKit
import Darwin
import Foundation
import IOBluetooth
import MapKit
import Observation
import Security
import SwiftUI
import _Concurrency

// MARK: - Models & Enums

public enum AccessoryTransportMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bluetooth = "bluetooth"
    case usb = "usb"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bluetooth: return "蓝牙 RFCOMM"
        case .usb: return "USB 数据线"
        }
    }

    public var subtitle: String {
        switch self {
        case .bluetooth: return "无线配对后直连 CarKit iAP2"
        case .usb: return "usbmuxd 直连 CarKit（低延迟）"
        }
    }
}

public enum AccessorySessionDuration: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fiveMinutes = 300
    case thirtyMinutes = 1800
    case oneHour = 3600
    case indefinite = 0

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .fiveMinutes: return "5 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .indefinite: return "持续保持"
        }
    }
}

public enum AccessoryProtocolStage: Int, CaseIterable, Identifiable, Sendable {
    case idle = 0
    case linking = 1
    case identifying = 2
    case authenticating = 3
    case streaming = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .idle: return "待命"
        case .linking: return "iAP2 链路同步"
        case .identifying: return "配件身份声明"
        case .authenticating: return "MFi-v3 鉴权"
        case .streaming: return "NMEA 定位注入"
        }
    }

    public var shortTitle: String {
        switch self {
        case .idle: return "未连接"
        case .linking: return "链路 SYN"
        case .identifying: return "身份认证"
        case .authenticating: return "MFi 验签"
        case .streaming: return "位置注入中"
        }
    }
}

public struct DiscoveredAccessoryDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let transport: AccessoryTransportMode
    public let bluetoothAddress: String?
    public let usbDeviceID: Int?
    public let usbUDID: String?

    public var badgeText: String {
        switch transport {
        case .bluetooth:
            return bluetoothAddress ?? "已配对"
        case .usb:
            return usbDeviceID.map { "USB #\($0)" } ?? "USB"
        }
    }
}

public struct SavedLocationBookmark: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double
    public var isGCJ02: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double = 15.0,
        isGCJ02: Bool = false
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.isGCJ02 = isGCJ02
    }
}

public struct PlaceSearchSuggestion: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let subtitle: String
    public let latitude: Double
    public let longitude: Double

    public init(id: UUID = UUID(), title: String, subtitle: String, latitude: Double, longitude: Double) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct MFiIdentityStatus: Equatable, Sendable {
    public let isConfigured: Bool
    public let certificateBytes: Int
    public let keyBytes: Int
    public let sourceLabel: String

    public static let empty = MFiIdentityStatus(
        isConfigured: false,
        certificateBytes: 0,
        keyBytes: 0,
        sourceLabel: "未配置 MFi 凭据"
    )
}

public struct AccessoryLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: String
    public let level: String
    public let message: String
}

// MARK: - Geo Coordinate Converter (GCJ-02 <-> WGS-84)

public enum GeoCoordinateConverter {
    private static let earthAxis = 6378245.0
    private static let eccentricitySq = 0.00669342162296594323

    public static func isOutsideChina(latitude: Double, longitude: Double) -> Bool {
        longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
    }

    public static func wgs84ToGcj02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        if isOutsideChina(latitude: latitude, longitude: longitude) {
            return (latitude, longitude)
        }
        let (dLat, dLon) = delta(latitude: latitude, longitude: longitude)
        return (latitude + dLat, longitude + dLon)
    }

    public static func gcj02ToWgs84(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        if isOutsideChina(latitude: latitude, longitude: longitude) {
            return (latitude, longitude)
        }
        var wgsLat = latitude
        var wgsLon = longitude
        for _ in 0..<8 {
            let gcj = wgs84ToGcj02(latitude: wgsLat, longitude: wgsLon)
            let dLat = latitude - gcj.latitude
            let dLon = longitude - gcj.longitude
            wgsLat += dLat
            wgsLon += dLon
            if abs(dLat) < 1e-9 && abs(dLon) < 1e-9 {
                break
            }
        }
        return (wgsLat, wgsLon)
    }

    private static func delta(latitude: Double, longitude: Double) -> (Double, Double) {
        let x = longitude - 105.0
        let y = latitude - 35.0
        var dLat = transformLat(x: x, y: y)
        var dLon = transformLon(x: x, y: y)
        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1.0 - eccentricitySq * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((earthAxis * (1.0 - eccentricitySq)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (earthAxis / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLon)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}

// MARK: - NMEA 0183 Formatter

public enum NMEA0183Formatter {
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return cal
    }()

    public static func checksum(_ body: String) -> String {
        let xorValue = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
        return String(format: "%02X", xorValue)
    }

    public static func formatCoordinate(_ value: Double, isLatitude: Bool) -> (formatted: String, hemisphere: String) {
        let hemi = isLatitude ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W")
        let absVal = abs(value)
        var degrees = Int(floor(absVal))
        let minutes = (absVal - Double(degrees)) * 60.0
        var scaledMinutes = Int((minutes * 10000.0).rounded())
        if scaledMinutes >= 600000 {
            degrees += 1
            scaledMinutes -= 600000
        }
        let wholeMinutes = scaledMinutes / 10000
        let fracMinutes = scaledMinutes % 10000
        let degFormat = isLatitude
            ? String(format: "%02d%02d.%04d", degrees, wholeMinutes, fracMinutes)
            : String(format: "%03d%02d.%04d", degrees, wholeMinutes, fracMinutes)
        return (degFormat, hemi)
    }

    public static func formatUTCDateAndTime(_ date: Date) -> (time: String, date: String) {
        let comps = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let s = comps.second ?? 0
        let d = comps.day ?? 1
        let mo = comps.month ?? 1
        let y = (comps.year ?? 2026) % 100
        return (
            String(format: "%02d%02d%02d.00", h, m, s),
            String(format: "%02d%02d%02d", d, mo, y)
        )
    }

    public static func makeGPGGA(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double = 15.0,
        date: Date = Date()
    ) -> String {
        let (utcTime, _) = formatUTCDateAndTime(date)
        let (latStr, latHemi) = formatCoordinate(latitude, isLatitude: true)
        let (lonStr, lonHemi) = formatCoordinate(longitude, isLatitude: false)
        let altStr = String(format: "%.1f", altitudeMeters)
        let body = "GPGGA,\(utcTime),\(latStr),\(latHemi),\(lonStr),\(lonHemi),1,08,0.9,\(altStr),M,0.0,M,,"
        return "$\(body)*\(checksum(body))\r\n"
    }

    public static func makeGPRMC(
        latitude: Double,
        longitude: Double,
        speedKnots: Double = 0.0,
        courseDegrees: Double = 0.0,
        date: Date = Date()
    ) -> String {
        let (utcTime, utcDate) = formatUTCDateAndTime(date)
        let (latStr, latHemi) = formatCoordinate(latitude, isLatitude: true)
        let (lonStr, lonHemi) = formatCoordinate(longitude, isLatitude: false)
        let normalizedSpeed = max(0.0, speedKnots)
        let modCourse = courseDegrees.truncatingRemainder(dividingBy: 360.0)
        let normalizedCourse = modCourse < 0 ? modCourse + 360.0 : modCourse
        let body = String(
            format: "GPRMC,%@,A,%@,%@,%@,%@,%.1f,%.1f,%@,,,A",
            utcTime, latStr, latHemi, lonStr, lonHemi, normalizedSpeed, normalizedCourse, utcDate
        )
        return "$\(body)*\(checksum(body))\r\n"
    }
}

// MARK: - MFi-v3 Pure Swift Validator & P-256 Signer

public enum MFiIdentityError: LocalizedError, Sendable {
    case invalidSize(String)
    case invalidDERStructure(String)
    case invalidP256Key(String)
    case certificateKeyMismatch
    case invalidChallengeLength(Int)
    case apkVerificationFailed(String)
    case apkExtractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSize(let msg),
             .invalidDERStructure(let msg),
             .invalidP256Key(let msg),
             .apkVerificationFailed(let msg),
             .apkExtractionFailed(let msg):
            return msg
        case .certificateKeyMismatch:
            return "MFi 证书公钥与私钥不匹配"
        case .invalidChallengeLength(let count):
            return "MFi 质询长度异常（预期 32 字节，实际 \(count) 字节）"
        }
    }
}

private struct PrehashedSHA256Digest: Digest, @unchecked Sendable {
    static var byteCount: Int { 32 }
    private let bytes: Data

    init?(rawBytes: Data) {
        guard rawBytes.count == Self.byteCount else { return nil }
        self.bytes = rawBytes
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    static func == (lhs: PrehashedSHA256Digest, rhs: PrehashedSHA256Digest) -> Bool {
        lhs.bytes == rhs.bytes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }
}

public enum MFiIdentityEngine {
    public static let maxCredentialBytes = 16384
    public static let maxAPKBytes = 64 * 1024 * 1024
    public static let diplayV027URL = URL(string: "https://github.com/shihabal3amri/DiPlay/releases/download/v0.2.7/DiPlay-0.2.7.apk")!
    public static let diplayV027SHA256 = "27b434462da7e78b1ff0987d129ed0a4b0a0e56beceaf8ec221d47150d4675bd"

    // OID 1.2.840.10045.2.1 + OID 1.2.840.10045.3.1.7 + BIT STRING 0x03 0x42 0x00 + 0x04
    private static let p256SPKIUncompressedPrefix: [UInt8] = [
        0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00, 0x04
    ]

    public static func isPKCS8DER(_ rawData: Data) -> Bool {
        let data = rawData.startIndex == 0 ? rawData : Data(rawData)
        guard let (_, rootRange) = parseDERElement(data, at: 0, expectedTag: 0x30),
              rootRange.upperBound == data.count else {
            return false
        }
        var cursor = rootRange.lowerBound
        guard let (next1, verRange) = parseDERElement(data, at: cursor, expectedTag: 0x02),
              verRange.count == 1 else {
            return false
        }
        cursor = next1
        guard let (next2, _) = parseDERElement(data, at: cursor, expectedTag: 0x30) else {
            return false
        }
        cursor = next2
        guard let (_, keyRange) = parseDERElement(data, at: cursor, expectedTag: 0x04),
              !keyRange.isEmpty else {
            return false
        }
        return true
    }

    public static func validatePair(certificateData: Data, privateKeyData: Data) throws {
        guard !certificateData.isEmpty && certificateData.count <= maxCredentialBytes else {
            throw MFiIdentityError.invalidSize("证书大小无效（需 1...\(maxCredentialBytes) 字节）")
        }
        guard !privateKeyData.isEmpty && privateKeyData.count <= maxCredentialBytes else {
            throw MFiIdentityError.invalidSize("私钥大小无效（需 1...\(maxCredentialBytes) 字节）")
        }
        guard certificateData.first == 0x30 else {
            throw MFiIdentityError.invalidDERStructure("证书不是有效的 DER PKCS#7 结构")
        }
        guard isPKCS8DER(privateKeyData) else {
            throw MFiIdentityError.invalidDERStructure("私钥不是明文 DER PKCS#8 格式")
        }
        let signingKey: P256.Signing.PrivateKey
        do {
            signingKey = try P256.Signing.PrivateKey(derRepresentation: privateKeyData)
        } catch {
            throw MFiIdentityError.invalidP256Key("无法解析 P-256 PKCS#8 私钥：\(error.localizedDescription)")
        }
        let expectedX963 = signingKey.publicKey.x963Representation
        let embeddedKeys = extractP256PublicKeys(from: certificateData)
        guard !embeddedKeys.isEmpty else {
            throw MFiIdentityError.invalidDERStructure("证书中未包含可识别的 P-256 公钥")
        }
        guard embeddedKeys.contains(expectedX963) else {
            throw MFiIdentityError.certificateKeyMismatch
        }
    }

    public static func extractP256PublicKeys(from data: Data) -> [Data] {
        let prefix = Data(p256SPKIUncompressedPrefix)
        var results: [Data] = []
        var searchStart = data.startIndex
        while let matchRange = data.range(of: prefix, options: [], in: searchStart..<data.endIndex) {
            let pointStart = matchRange.upperBound - 1 // include 0x04
            let pointEnd = pointStart + 65
            if pointEnd <= data.endIndex {
                results.append(data.subdata(in: pointStart..<pointEnd))
            }
            searchStart = matchRange.upperBound
        }
        return results
    }

    public static func signPrehashedChallenge(_ digest32: Data, privateKeyData: Data) throws -> Data {
        guard let prehashed = PrehashedSHA256Digest(rawBytes: digest32) else {
            throw MFiIdentityError.invalidChallengeLength(digest32.count)
        }
        let signingKey = try P256.Signing.PrivateKey(derRepresentation: privateKeyData)
        let signature = try signingKey.signature(for: prehashed)
        return signature.rawRepresentation
    }

    private static func parseDERElement(
        _ data: Data,
        at offset: Int,
        expectedTag: UInt8
    ) -> (nextOffset: Int, contentRange: Range<Int>)? {
        guard offset + 2 <= data.count, data[offset] == expectedTag else {
            return nil
        }
        let lenByte = data[offset + 1]
        var cursor = offset + 2
        let length: Int
        if lenByte & 0x80 == 0 {
            length = Int(lenByte)
        } else {
            let numBytes = Int(lenByte & 0x7F)
            guard numBytes > 0 && numBytes <= 4 && cursor + numBytes <= data.count else {
                return nil
            }
            var accum = 0
            for i in 0..<numBytes {
                accum = (accum << 8) | Int(data[cursor + i])
            }
            cursor += numBytes
            length = accum
        }
        let end = cursor + length
        guard length >= 0 && end <= data.count else {
            return nil
        }
        return (end, cursor..<end)
    }
}

// MARK: - MFi Identity Vault

public enum MFiIdentityVault {
    public static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("SysPulse", isDirectory: true)
            .appendingPathComponent("AccessoryLocation", isDirectory: true)
            .appendingPathComponent("identity", isDirectory: true)
    }

    public static var certificateURL: URL { directoryURL.appendingPathComponent("certificate.p7b") }
    public static var privateKeyURL: URL { directoryURL.appendingPathComponent("identity.pk8") }
    public static var metadataURL: URL { directoryURL.appendingPathComponent("metadata.json") }

    public static func currentStatus() -> MFiIdentityStatus {
        guard FileManager.default.fileExists(atPath: certificateURL.path),
              FileManager.default.fileExists(atPath: privateKeyURL.path),
              let certData = try? Data(contentsOf: certificateURL),
              let keyData = try? Data(contentsOf: privateKeyURL),
              (try? MFiIdentityEngine.validatePair(certificateData: certData, privateKeyData: keyData)) != nil else {
            return .empty
        }
        let source = loadSourceLabel() ?? "本地凭据库"
        return MFiIdentityStatus(
            isConfigured: true,
            certificateBytes: certData.count,
            keyBytes: keyData.count,
            sourceLabel: source
        )
    }

    public static func loadCredentials() throws -> (certificate: Data, privateKey: Data) {
        guard FileManager.default.fileExists(atPath: certificateURL.path),
              FileManager.default.fileExists(atPath: privateKeyURL.path) else {
            throw MFiIdentityError.invalidDERStructure("尚未导入 MFi 凭据，请先在插件详情页提取或导入")
        }
        let certData = try Data(contentsOf: certificateURL)
        let keyData = try Data(contentsOf: privateKeyURL)
        try MFiIdentityEngine.validatePair(certificateData: certData, privateKeyData: keyData)
        return (certData, keyData)
    }

    public static func saveCredentials(certificateData: Data, privateKeyData: Data, sourceLabel: String) throws -> MFiIdentityStatus {
        try MFiIdentityEngine.validatePair(certificateData: certificateData, privateKeyData: privateKeyData)
        let dir = directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        try certificateData.write(to: certificateURL, options: .atomic)
        try privateKeyData.write(to: privateKeyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificateURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)

        let metaData = try JSONEncoder().encode(["source": sourceLabel])
        try metaData.write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)

        return MFiIdentityStatus(
            isConfigured: true,
            certificateBytes: certificateData.count,
            keyBytes: privateKeyData.count,
            sourceLabel: sourceLabel
        )
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: certificateURL)
        try? FileManager.default.removeItem(at: privateKeyURL)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    public static func importFromAPKFile(at apkURL: URL, requireExactSHA256: Bool = true, sourceLabel: String) throws -> MFiIdentityStatus {
        let attrs = try FileManager.default.attributesOfItem(atPath: apkURL.path)
        if let size = attrs[.size] as? NSNumber, size.intValue > MFiIdentityEngine.maxAPKBytes {
            throw MFiIdentityError.invalidSize("APK 体积超出上限（64 MB）")
        }
        let apkData = try Data(contentsOf: apkURL, options: .mappedIfSafe)
        guard apkData.count <= MFiIdentityEngine.maxAPKBytes else {
            throw MFiIdentityError.invalidSize("APK 体积超出上限（64 MB）")
        }
        if requireExactSHA256 {
            let digest = SHA256.hash(data: apkData)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex == MFiIdentityEngine.diplayV027SHA256 else {
                throw MFiIdentityError.apkVerificationFailed("APK SHA-256 校验失败，请确认使用 DiPlay v0.2.7 官方发布包")
            }
        }
        let certData = try extractEntryFromZip(apkURL: apkURL, entryPath: "assets/offline-mfi/certificate.p7b")
        let keyData = try extractEntryFromZip(apkURL: apkURL, entryPath: "assets/offline-mfi/identity.pk8")
        return try saveCredentials(certificateData: certData, privateKeyData: keyData, sourceLabel: sourceLabel)
    }

    private static func extractEntryFromZip(apkURL: URL, entryPath: String) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", apkURL.path, entryPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !outData.isEmpty, outData.count <= MFiIdentityEngine.maxCredentialBytes else {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MFiIdentityError.apkExtractionFailed("无法从 APK 提取 \(entryPath)：\(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return outData
    }

    private static func loadSourceLabel() -> String? {
        guard let data = try? Data(contentsOf: metadataURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict["source"]
    }
}

// MARK: - iAP2 Wire & Control Codec

public struct IAP2LinkPacket: Equatable, Sendable {
    public let flags: UInt8
    public let seq: UInt8
    public let ack: UInt8
    public let session: UInt8
    public let payload: Data

    public init(flags: UInt8, seq: UInt8, ack: UInt8, session: UInt8, payload: Data = Data()) {
        self.flags = flags
        self.seq = seq
        self.ack = ack
        self.session = session
        self.payload = payload
    }
}

public struct IAP2ControlMessage: Equatable, Sendable {
    public let id: UInt16
    public let parameters: [(id: UInt16, value: Data)]

    public static func == (lhs: IAP2ControlMessage, rhs: IAP2ControlMessage) -> Bool {
        guard lhs.id == rhs.id && lhs.parameters.count == rhs.parameters.count else { return false }
        for (l, r) in zip(lhs.parameters, rhs.parameters) {
            if l.id != r.id || l.value != r.value { return false }
        }
        return true
    }
}

public enum IAP2Codec {
    public static let btDetectFrame = Data([0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10])
    public static let flagSYN: UInt8 = 0x80
    public static let flagACK: UInt8 = 0x40
    public static let flagEAK: UInt8 = 0x20
    public static let flagRST: UInt8 = 0x10

    // Version=1, MaxOut=1, MaxLen=4096(0x1000), Retx=2000ms(0x07D0), CumAck=22ms(0x0016), MaxRetx=5, MaxCumAck=1, ControlSession=[1,0,2]
    public static let synOfferPayload = Data([
        0x01, 0x01, 0x10, 0x00, 0x07, 0xD0, 0x00, 0x16, 0x05, 0x01,
        0x01, 0x00, 0x02
    ])

    // Control message IDs
    public static let msgStartIdentification: UInt16 = 0x1D00
    public static let msgIdentificationInformation: UInt16 = 0x1D01
    public static let msgIdentificationAccepted: UInt16 = 0x1D02
    public static let msgIdentificationRejected: UInt16 = 0x1D03
    public static let msgRequestCertificate: UInt16 = 0xAA00
    public static let msgAuthenticationCertificate: UInt16 = 0xAA01
    public static let msgRequestChallengeResponse: UInt16 = 0xAA02
    public static let msgAuthenticationResponse: UInt16 = 0xAA03
    public static let msgAuthenticationFailed: UInt16 = 0xAA04
    public static let msgAuthenticationSucceeded: UInt16 = 0xAA05
    public static let msgStartLocationInformation: UInt16 = 0xFFFA
    public static let msgLocationInformation: UInt16 = 0xFFFB
    public static let msgStopLocationInformation: UInt16 = 0xFFFC

    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        let sum = bytes.reduce(0) { ($0 + Int($1)) & 0xFF }
        return UInt8((256 - sum) & 0xFF)
    }

    public static func encodeLinkPacket(_ packet: IAP2LinkPacket) -> Data {
        let hasPayload = !packet.payload.isEmpty
        let totalLength = hasPayload ? (9 + packet.payload.count + 1) : 9
        var out = Data(capacity: totalLength)
        out.append(0xFF)
        out.append(0x5A)
        out.append(UInt8((totalLength >> 8) & 0xFF))
        out.append(UInt8(totalLength & 0xFF))
        out.append(packet.flags)
        out.append(packet.seq)
        out.append(packet.ack)
        out.append(packet.session)
        out.append(checksum(out))
        if hasPayload {
            out.append(packet.payload)
            out.append(checksum(packet.payload))
        }
        return out
    }

    public static func encodeControlMessage(id: UInt16, parameters: [(id: UInt16, value: Data)] = []) -> Data {
        var paramsBuffer = Data()
        for (pid, value) in parameters {
            let pLen = 4 + value.count
            appendUInt16BE(&paramsBuffer, UInt16(pLen))
            appendUInt16BE(&paramsBuffer, pid)
            paramsBuffer.append(value)
        }
        let totalLength = 6 + paramsBuffer.count
        var out = Data(capacity: totalLength)
        out.append(0x40)
        out.append(0x40)
        appendUInt16BE(&out, UInt16(totalLength))
        appendUInt16BE(&out, id)
        out.append(paramsBuffer)
        return out
    }

    public static func decodeControlMessage(_ rawData: Data) -> IAP2ControlMessage? {
        let data = rawData.startIndex == 0 ? rawData : Data(rawData)
        guard data.count >= 6, data[0] == 0x40, data[1] == 0x40 else { return nil }
        let total = Int(readUInt16BE(data, at: 2))
        guard total >= 6, data.count >= total else { return nil }
        let msgID = readUInt16BE(data, at: 4)
        var params: [(id: UInt16, value: Data)] = []
        var cursor = 6
        while cursor + 4 <= total {
            let pLen = Int(readUInt16BE(data, at: cursor))
            let pID = readUInt16BE(data, at: cursor + 2)
            guard pLen >= 4, cursor + pLen <= total else { return nil }
            let val = data.subdata(in: (cursor + 4)..<(cursor + pLen))
            params.append((pID, val))
            cursor += pLen
        }
        return IAP2ControlMessage(id: msgID, parameters: params)
    }

    public static func encodeParametersBlock(_ parameters: [(id: UInt16, value: Data)]) -> Data {
        var buf = Data()
        for (pid, value) in parameters {
            let pLen = 4 + value.count
            appendUInt16BE(&buf, UInt16(pLen))
            appendUInt16BE(&buf, pid)
            buf.append(value)
        }
        return buf
    }

    public static func cStringData(_ value: String) -> Data {
        var d = Data(value.utf8)
        d.append(0x00)
        return d
    }

    public static func buildIdentificationMessage(
        transport: AccessoryTransportMode,
        bluetoothMACBytes: [UInt8]?
    ) -> Data {
        var transportSubparams: [(UInt16, Data)] = [
            (0, Data([0x00, 0x00])),
            (1, cStringData("Location Transport")),
            (2, Data())
        ]
        let transportParamID: UInt16
        if transport == .bluetooth {
            transportParamID = 17
            let mac = (bluetoothMACBytes?.count == 6 ? bluetoothMACBytes! : [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
            transportSubparams.append((3, Data(mac)))
        } else {
            transportParamID = 16
        }

        let locationComponent = encodeParametersBlock([
            (0, Data([0x00, 0x00])),
            (1, cStringData("GPS")),
            (17, Data()),
            (18, Data())
        ])

        let params: [(UInt16, Data)] = [
            (0, cStringData("Accessory Location Lab")),
            (1, cStringData("AL-1")),
            (2, cStringData("Local Research")),
            (3, cStringData("AL-LOCAL-001")),
            (4, cStringData("0.1")),
            (5, cStringData("1")),
            (6, Data([0xFF, 0xFB])),
            (7, Data([0xFF, 0xFA, 0xFF, 0xFC])),
            (8, Data([0x00])),
            (9, Data([0x00, 0x00])),
            (12, cStringData("en")),
            (13, cStringData("en")),
            (transportParamID, encodeParametersBlock(transportSubparams)),
            (22, locationComponent)
        ]
        return encodeControlMessage(id: msgIdentificationInformation, parameters: params)
    }

    public static func parseSessionTripletControlID(from rawPayload: Data) -> UInt8 {
        let synAckPayload = rawPayload.startIndex == 0 ? rawPayload : Data(rawPayload)
        var cursor = 10
        while cursor + 3 <= synAckPayload.count {
            let sid = synAckPayload[cursor]
            let sType = synAckPayload[cursor + 1]
            if sType == 0 {
                return sid
            }
            cursor += 3
        }
        return 1
    }

    public static func appendUInt16BE(_ data: inout Data, _ val: UInt16) {
        data.append(UInt8((val >> 8) & 0xFF))
        data.append(UInt8(val & 0xFF))
    }

    public static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    public static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}

public final class IAP2StreamFramer {
    private var buffer: [UInt8] = []

    public init() {}

    public func feed(_ chunk: Data) -> [IAP2LinkPacket] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(contentsOf: chunk)
        var packets: [IAP2LinkPacket] = []

        while buffer.count >= 9 {
            var foundIdx: Int?
            if buffer.count >= 2 {
                for i in 0..<(buffer.count - 1) {
                    if buffer[i] == 0xFF && buffer[i + 1] == 0x5A {
                        foundIdx = i
                        break
                    }
                }
            }
            guard let syncIdx = foundIdx else {
                if buffer.last == 0xFF {
                    buffer = [0xFF]
                } else {
                    buffer.removeAll(keepingCapacity: true)
                }
                break
            }
            if syncIdx > 0 {
                buffer.removeFirst(syncIdx)
            }
            guard buffer.count >= 9 else { break }

            let totalLength = (Int(buffer[2]) << 8) | Int(buffer[3])
            if totalLength < 9 || totalLength == 10 {
                buffer.removeFirst(2)
                continue
            }

            let hdrSum = (0..<9).reduce(0) { ($0 + Int(buffer[$1])) & 0xFF }
            if hdrSum != 0 {
                buffer.removeFirst(1)
                continue
            }

            guard buffer.count >= totalLength else { break }

            let rawPacket = Array(buffer[0..<totalLength])
            buffer.removeFirst(totalLength)

            var payload = Data()
            if totalLength > 9 {
                let payloadEnd = totalLength - 1
                let payloadBytes = rawPacket[9..<payloadEnd]
                let expectedChk = IAP2Codec.checksum(payloadBytes)
                if rawPacket[payloadEnd] != expectedChk {
                    continue
                }
                payload = Data(payloadBytes)
            }

            let pkt = IAP2LinkPacket(
                flags: rawPacket[4],
                seq: rawPacket[5],
                ack: rawPacket[6],
                session: rawPacket[7],
                payload: payload
            )
            packets.append(pkt)
        }

        return packets
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

public final class IAP2ControlMessageAssembler {
    private var buffer: [UInt8] = []

    public init() {}

    public func feed(_ chunk: Data) -> [IAP2ControlMessage] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(contentsOf: chunk)
        var messages: [IAP2ControlMessage] = []

        while buffer.count >= 6 {
            if buffer[0] != 0x40 || buffer[1] != 0x40 {
                var foundIdx: Int?
                for i in 0..<(buffer.count - 1) {
                    if buffer[i] == 0x40 && buffer[i + 1] == 0x40 {
                        foundIdx = i
                        break
                    }
                }
                if let idx = foundIdx {
                    buffer.removeFirst(idx)
                } else {
                    buffer = buffer.last == 0x40 ? [0x40] : []
                    break
                }
                guard buffer.count >= 6 else { break }
            }

            let size = (Int(buffer[2]) << 8) | Int(buffer[3])
            guard size >= 6 else {
                buffer.removeFirst(2)
                continue
            }
            guard buffer.count >= size else { break }

            let chunkData = Data(buffer[0..<size])
            buffer.removeFirst(size)
            if let msg = IAP2Codec.decodeControlMessage(chunkData) {
                messages.append(msg)
            }
        }
        return messages
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

// MARK: - Pure Swift usbmuxd Device Discovery

private enum USBMuxClient {
    private static let socketPath = "/var/run/usbmuxd"

    static func listUSBDevices() -> [DiscoveredAccessoryDevice] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= maxLen else { return [] }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for i in 0..<pathBytes.count {
                    dst[i] = pathBytes[i]
                }
            }
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRes == 0 else { return [] }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let reqDict: [String: Any] = [
            "MessageType": "ListDevices",
            "ClientVersionString": "SysPulse",
            "ProgName": "SysPulse",
            "kLibUSBMuxVersion": 3
        ]
        guard let plistData = try? PropertyListSerialization.data(fromPropertyList: reqDict, format: .xml, options: 0),
              sendMuxPacket(fd: fd, tag: 1, payload: plistData),
              let respData = readMuxPacket(fd: fd),
              let respDict = (try? PropertyListSerialization.propertyList(from: respData, options: [], format: nil)) as? [String: Any],
              let list = respDict["DeviceList"] as? [[String: Any]] else {
            return []
        }

        var devices: [DiscoveredAccessoryDevice] = []
        for entry in list {
            guard let props = entry["Properties"] as? [String: Any],
                  let connectionType = props["ConnectionType"] as? String,
                  connectionType == "USB",
                  let deviceID = props["DeviceID"] as? Int,
                  let udid = props["SerialNumber"] as? String else {
                continue
            }
            let suffix = String(udid.suffix(4))
            devices.append(
                DiscoveredAccessoryDevice(
                    id: "usb:\(deviceID):\(udid)",
                    name: "iOS 设备 (USB …\(suffix))",
                    transport: .usb,
                    bluetoothAddress: nil,
                    usbDeviceID: deviceID,
                    usbUDID: udid
                )
            )
        }
        return devices
    }

    private static func sendMuxPacket(fd: Int32, tag: UInt32, payload: Data) -> Bool {
        var header = Data(capacity: 16 + payload.count)
        let totalLen = UInt32(16 + payload.count)
        appendLE(&header, totalLen)
        appendLE(&header, UInt32(1)) // version
        appendLE(&header, UInt32(8)) // plist request
        appendLE(&header, tag)
        header.append(payload)

        return header.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            var written = 0
            while written < rawBuf.count {
                let n = Darwin.send(fd, base.advanced(by: written), rawBuf.count - written, 0)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    private static func readMuxPacket(fd: Int32) -> Data? {
        guard let hdr = readExact(fd: fd, count: 16) else { return nil }
        let totalLen = hdr.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.load(as: UInt32.self))
        }
        guard totalLen >= 16, totalLen <= 1_048_576 else { return nil }
        return readExact(fd: fd, count: Int(totalLen - 16))
    }

    private static func readExact(fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let n = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }

    private static func appendLE(_ data: inout Data, _ val: UInt32) {
        var v = val.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

// MARK: - Transport Abstraction & Sandboxed USB Bridge

private protocol AccessoryTransportBridge: AnyObject {
    var onReady: (@Sendable () -> Void)? { get set }
    var onData: (@Sendable (Data) -> Void)? { get set }
    var onLog: (@Sendable (String, String) -> Void)? { get set }
    var onError: (@Sendable (String) -> Void)? { get set }
    var onClosed: (@Sendable (String) -> Void)? { get set }

    func connect()
    func send(_ data: Data)
    func close()
}

private final class USBCarKitRelayBridge: AccessoryTransportBridge, @unchecked Sendable {
    var onReady: (@Sendable () -> Void)?
    var onData: (@Sendable (Data) -> Void)?
    var onLog: (@Sendable (String, String) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onClosed: (@Sendable (String) -> Void)?

    private let deviceID: Int
    private let udid: String
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var isClosed = false
    private var readySignaled = false

    init(deviceID: Int, udid: String) {
        self.deviceID = deviceID
        self.udid = udid
    }

    func connect() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        proc.arguments = [
            "-p", "(version 1)(allow default)(deny network-outbound (remote ip))",
            "/usr/bin/python3", "-c", Self.pythonRelayScript,
            String(deviceID), udid
        ]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.onData?(chunk)
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            for rawLine in text.split(separator: "\n") {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                if line == "READY" {
                    self.lock.lock()
                    let shouldSignal = !self.readySignaled
                    self.readySignaled = true
                    self.lock.unlock()
                    if shouldSignal {
                        self.onReady?()
                    }
                } else if line.hasPrefix("ERR:") {
                    let msg = String(line.dropFirst(4))
                    self.onError?(msg)
                } else if !line.isEmpty {
                    self.onLog?("INFO", line)
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.lock.lock()
            let wasClosed = self.isClosed
            self.process = nil
            self.stdinHandle = nil
            self.lock.unlock()
            if !wasClosed {
                self.onClosed?("USB 中继通道已关闭（退出码 \(p.terminationStatus)）")
            }
        }

        lock.lock()
        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        lock.unlock()

        do {
            try proc.run()
        } catch {
            onError?("无法启动 USB CarKit 中继：\(error.localizedDescription)")
        }
    }

    func send(_ data: Data) {
        lock.lock()
        let handle = stdinHandle
        let closed = isClosed
        lock.unlock()
        guard !closed, let handle, !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            onError?("USB 发送失败：\(error.localizedDescription)")
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let proc = process
        let handle = stdinHandle
        process = nil
        stdinHandle = nil
        lock.unlock()

        try? handle?.close()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    // Stdlib-only Python script executing inside sandbox-exec (remote IP network denied).
    private static let pythonRelayScript = #"""
import os, plistlib, socket, ssl, struct, sys, tempfile, threading

MUX_PATH = "/var/run/usbmuxd"

def mux_rpc(sock, payload):
    raw = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
    sock.sendall(struct.pack("<IIII", 16 + len(raw), 1, 8, 1) + raw)
    hdr = b""
    while len(hdr) < 16:
        chunk = sock.recv(16 - len(hdr))
        if not chunk:
            raise RuntimeError("usbmuxd closed")
        hdr += chunk
    total, _, _, _ = struct.unpack("<IIII", hdr)
    body = b""
    while len(body) < total - 16:
        chunk = sock.recv((total - 16) - len(body))
        if not chunk:
            raise RuntimeError("usbmuxd truncated")
        body += chunk
    return plistlib.loads(body)

def ld_send(sock, obj):
    raw = plistlib.dumps(obj, fmt=plistlib.FMT_XML)
    sock.sendall(struct.pack(">I", len(raw)) + raw)

def ld_recv(sock):
    hdr = b""
    while len(hdr) < 4:
        chunk = sock.recv(4 - len(hdr))
        if not chunk:
            raise RuntimeError("lockdownd closed")
        hdr += chunk
    size = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < size:
        chunk = sock.recv(size - len(body))
        if not chunk:
            raise RuntimeError("lockdownd truncated")
        body += chunk
    return plistlib.loads(body)

def connect_mux(dev_id, port_host):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(MUX_PATH)
    resp = mux_rpc(s, {
        "MessageType": "Connect",
        "ClientVersionString": "SysPulse",
        "ProgName": "SysPulse",
        "kLibUSBMuxVersion": 3,
        "DeviceID": dev_id,
        "PortNumber": socket.htons(port_host),
    })
    if resp.get("MessageType") != "Result" or resp.get("Number", -1) != 0:
        raise RuntimeError(f"usbmuxd Connect({port_host}) 失败: {resp.get('Number')}")
    return s

def main():
    dev_id = int(sys.argv[1])
    udid = sys.argv[2]

    pr_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    pr_sock.connect(MUX_PATH)
    pr_resp = mux_rpc(pr_sock, {
        "MessageType": "ReadPairRecord",
        "ClientVersionString": "SysPulse",
        "ProgName": "SysPulse",
        "kLibUSBMuxVersion": 3,
        "PairRecordID": udid,
    })
    pr_sock.close()
    pr_bytes = pr_resp.get("PairRecordData")
    if not pr_bytes:
        raise RuntimeError("未找到设备配对记录，请先在 iPhone 上点击“信任此电脑”")
    pr = plistlib.loads(pr_bytes)
    host_id = pr["HostID"]
    system_buid = pr["SystemBUID"]
    host_cert = pr["HostCertificate"]
    host_key = pr["HostPrivateKey"]

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.options |= getattr(ssl, "OP_IGNORE_UNEXPECTED_EOF", 0)
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile("wb", delete=False) as tf:
            tf.write(host_cert + b"\n" + host_key)
            tmp_path = tf.name
        os.chmod(tmp_path, 0o600)
        ctx.load_cert_chain(certfile=tmp_path, keyfile=tmp_path)
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    ld_sock = None
    carkit = None
    ss_resp = {}
    try:
        ld_sock = connect_mux(dev_id, 62078)
        ld_send(ld_sock, {"Request": "QueryType"})
        _ = ld_recv(ld_sock)
        ld_send(ld_sock, {"Request": "StartSession", "HostID": host_id, "SystemBUID": system_buid})
        ss_resp = ld_recv(ld_sock)
        if ss_resp.get("Error"):
            raise RuntimeError(f"lockdownd StartSession 失败: {ss_resp.get('Error')}")
        if ss_resp.get("EnableSessionSSL"):
            ld_sock = ctx.wrap_socket(ld_sock, do_handshake_on_connect=True)

        ld_send(ld_sock, {"Request": "StartService", "Service": "com.apple.carkit.service"})
        svc_resp = ld_recv(ld_sock)
        if svc_resp.get("Error") or "Port" not in svc_resp:
            err = svc_resp.get("Error", "Unknown")
            raise RuntimeError(f"无法拉起 com.apple.carkit.service（需确认设备已解锁）: {err}")
        svc_port = int(svc_resp["Port"])
        svc_ssl = bool(svc_resp.get("EnableServiceSSL", False))

        carkit = connect_mux(dev_id, svc_port)
        if svc_ssl:
            carkit = ctx.wrap_socket(carkit, do_handshake_on_connect=True)

        sys.stderr.write("READY\n")
        sys.stderr.flush()

        stdin_fd = sys.stdin.buffer.fileno()
        stdout_fd = sys.stdout.buffer.fileno()

        def cleanup():
            nonlocal carkit, ld_sock
            if carkit is not None:
                try:
                    carkit.close()
                except Exception:
                    pass
                carkit = None
            if ld_sock is not None:
                try:
                    ld_send(ld_sock, {"Request": "StopSession", "SessionID": ss_resp.get("SessionID", "")})
                except Exception:
                    pass
                try:
                    ld_sock.close()
                except Exception:
                    pass
                ld_sock = None

        def pump_sock_to_stdout():
            try:
                while True:
                    sock_ref = carkit
                    if sock_ref is None:
                        break
                    data = sock_ref.recv(16384)
                    if not data:
                        break
                    view = memoryview(data)
                    written = 0
                    while written < len(view):
                        n = os.write(stdout_fd, view[written:])
                        written += n
            except OSError:
                pass
            finally:
                cleanup()
                os._exit(0)

        reader = threading.Thread(target=pump_sock_to_stdout, daemon=True)
        reader.start()

        while True:
            data = os.read(stdin_fd, 16384)
            if not data:
                break
            sock_ref = carkit
            if sock_ref is None:
                break
            sock_ref.sendall(data)
    finally:
        if carkit is not None:
            try:
                carkit.close()
            except Exception:
                pass
        if ld_sock is not None:
            try:
                ld_send(ld_sock, {"Request": "StopSession", "SessionID": ss_resp.get("SessionID", "")})
            except Exception:
                pass
            try:
                ld_sock.close()
            except Exception:
                pass

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        sys.stderr.write(f"ERR:{e}\n")
        sys.stderr.flush()
        sys.exit(1)
"""#
}

// MARK: - Pure Native IOBluetooth RFCOMM Bridge

private final class BluetoothRFCOMMBridge: NSObject, IOBluetoothRFCOMMChannelDelegate, AccessoryTransportBridge, @unchecked Sendable {
    var onReady: (@Sendable () -> Void)?
    var onData: (@Sendable (Data) -> Void)?
    var onLog: (@Sendable (String, String) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onClosed: (@Sendable (String) -> Void)?

    private let address: String
    private let lock = NSLock()
    private var btThread: Thread?
    private var btRunLoop: CFRunLoop?
    private var channel: IOBluetoothRFCOMMChannel?
    private var isClosed = false
    private var openCompleted = false
    private var openStatus: IOReturn = kIOReturnError
    private var detectBuffer = Data()
    private var detectCompleted = false

    // Custom iAP2 CarKit/Accessory UUID: 00000000-deca-fade-deca-deafdecacafe
    private static let iap2UUIDBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0xDE, 0xCA, 0xFA, 0xDE,
        0xDE, 0xCA, 0xDE, 0xAF, 0xDE, 0xCA, 0xCA, 0xFE
    ]

    init(address: String) {
        self.address = address
        super.init()
    }

    func connect() {
        let thread = Thread { [weak self] in
            self?.runBluetoothLifecycle()
        }
        thread.name = "SysPulse.AccessoryLocation.BT"
        lock.lock()
        self.btThread = thread
        lock.unlock()
        thread.start()
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let activeChannel = channel
        let rl = btRunLoop
        let closed = isClosed
        lock.unlock()
        guard !closed, let activeChannel, let rl else { return }

        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            var copy = data
            let status = copy.withUnsafeMutableBytes { rawBuf -> IOReturn in
                guard let ptr = rawBuf.baseAddress else { return kIOReturnBadArgument }
                return activeChannel.writeSync(ptr, length: UInt16(rawBuf.count))
            }
            if status != kIOReturnSuccess {
                self?.onError?("蓝牙 RFCOMM 写入失败（错误码 \(status)）")
            }
        }
        CFRunLoopWakeUp(rl)
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let activeChannel = channel
        let rl = btRunLoop
        channel = nil
        lock.unlock()

        if let rl {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
                activeChannel?.setDelegate(nil)
                _ = activeChannel?.close()
                CFRunLoopStop(rl)
            }
            CFRunLoopWakeUp(rl)
        }
    }

    private func runBluetoothLifecycle() {
        let rl = CFRunLoopGetCurrent()
        lock.lock()
        self.btRunLoop = rl
        lock.unlock()

        guard let device = IOBluetoothDevice(addressString: address) else {
            onError?("无法创建蓝牙设备对象（\(address)）")
            return
        }

        let uuidData = Data(Self.iap2UUIDBytes)
        let sdpUUID = uuidData.withUnsafeBytes { rawBuf in
            IOBluetoothSDPUUID(bytes: rawBuf.baseAddress, length: 16)
        }

        var record = device.getServiceRecord(for: sdpUUID)
        if record == nil {
            onLog?("INFO", "正在向设备发起 SDP 服务查询...")
            let queryStatus = device.performSDPQuery(nil, uuids: [sdpUUID])
            if queryStatus != kIOReturnSuccess {
                onError?("蓝牙 SDP 查询启动失败（请确认 iPhone 已亮屏并开启蓝牙，错误码 \(queryStatus)）")
                return
            }
            let deadline = Date().addingTimeInterval(6.0)
            while record == nil && Date() < deadline {
                if isThreadClosed() { return }
                CFRunLoopRunInMode(.defaultMode, 0.15, false)
                record = device.getServiceRecord(for: sdpUUID)
            }
        }

        guard let serviceRecord = record else {
            onError?("未发现 iAP2 RFCOMM 服务（需与 iPhone 重新蓝牙配对或改用 USB 连接）")
            return
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        let cidStatus = serviceRecord.getRFCOMMChannelID(&channelID)
        guard cidStatus == kIOReturnSuccess else {
            onError?("读取 RFCOMM 频道号失败（错误码 \(cidStatus)）")
            return
        }

        onLog?("INFO", "正在打开蓝牙 RFCOMM 频道 #\(channelID)...")
        var openedChannel: IOBluetoothRFCOMMChannel?
        let openRet = device.openRFCOMMChannelAsync(&openedChannel, withChannelID: channelID, delegate: self)
        guard openRet == kIOReturnSuccess else {
            onError?("蓝牙 RFCOMM 建连失败（错误码 \(openRet)）")
            return
        }

        let openDeadline = Date().addingTimeInterval(10.0)
        while !isOpenCompleted() && Date() < openDeadline {
            if isThreadClosed() {
                _ = openedChannel?.close()
                return
            }
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }

        lock.lock()
        let finalOpenOK = openCompleted && openStatus == kIOReturnSuccess && channel != nil
        let status = openStatus
        let activeChannel = channel
        lock.unlock()

        guard finalOpenOK, let activeChannel else {
            _ = openedChannel?.close()
            onError?("蓝牙 RFCOMM 建连超时或被拒绝（错误码 \(status)）")
            return
        }

        var detect = IAP2Codec.btDetectFrame
        let detectRet = detect.withUnsafeMutableBytes { rawBuf -> IOReturn in
            guard let ptr = rawBuf.baseAddress else { return kIOReturnBadArgument }
            return activeChannel.writeSync(ptr, length: UInt16(rawBuf.count))
        }
        if detectRet != kIOReturnSuccess {
            onError?("发送蓝牙 iAP2 探测帧失败（错误码 \(detectRet)）")
            close()
            return
        }
        onLog?("INFO", "已发送蓝牙 iAP2 链路探测帧，等待 iPhone 回应...")

        while !isThreadClosed() {
            let res = CFRunLoopRunInMode(.defaultMode, 0.5, false)
            if res == .stopped || res == .finished {
                break
            }
        }
    }

    private func isThreadClosed() -> Bool {
        lock.lock()
        let closed = isClosed
        lock.unlock()
        return closed
    }

    private func isOpenCompleted() -> Bool {
        lock.lock()
        let done = openCompleted
        lock.unlock()
        return done
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        lock.lock()
        self.channel = rfcommChannel
        self.openStatus = error
        self.openCompleted = true
        lock.unlock()
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let chunk = Data(bytes: dataPointer, count: dataLength)

        lock.lock()
        let alreadyDetected = detectCompleted
        if !alreadyDetected {
            detectBuffer.append(chunk)
            let expected = IAP2Codec.btDetectFrame
            if let match = detectBuffer.range(of: expected) {
                let trailing = detectBuffer.subdata(in: match.upperBound..<detectBuffer.endIndex)
                detectBuffer.removeAll(keepingCapacity: false)
                detectCompleted = true
                lock.unlock()
                onReady?()
                if !trailing.isEmpty {
                    onData?(trailing)
                }
                return
            } else if detectBuffer.count >= 64 {
                // Unexpected pre-detect payload, pass through as iAP2 ready
                let full = detectBuffer
                detectBuffer.removeAll(keepingCapacity: false)
                detectCompleted = true
                lock.unlock()
                onReady?()
                onData?(full)
                return
            }
            lock.unlock()
            return
        }
        lock.unlock()

        onData?(chunk)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        channel = nil
        let rl = btRunLoop
        lock.unlock()
        if let rl {
            CFRunLoopStop(rl)
        }
        if !wasClosed {
            onClosed?("蓝牙 RFCOMM 连接已断开")
        }
    }

    static func hostBluetoothAddressBytes() -> [UInt8]? {
        guard let addrStr = IOBluetoothHostController.default()?.addressAsString() else { return nil }
        let parts = addrStr
            .replacingOccurrences(of: ":", with: "-")
            .split(separator: "-")
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? bytes : nil
    }

    static func pairedDevices() -> [DiscoveredAccessoryDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { dev in
            guard let addr = dev.addressString, !addr.isEmpty else { return nil }
            let name = dev.nameOrAddress ?? addr
            return DiscoveredAccessoryDevice(
                id: "bt:\(addr.lowercased())",
                name: name,
                transport: .bluetooth,
                bluetoothAddress: addr,
                usbDeviceID: nil,
                usbUDID: nil
            )
        }
    }
}

// MARK: - AccessoryLocationPluginManager

@Observable
@MainActor
public final class AccessoryLocationPluginManager {
    public static let shared = AccessoryLocationPluginManager()

    // MARK: Connection & Session State
    public var transportMode: AccessoryTransportMode = .usb
    public var sessionDuration: AccessorySessionDuration = .indefinite
    public var discoveredDevices: [DiscoveredAccessoryDevice] = []
    public var selectedDeviceID: String = ""
    public var isRefreshingDevices = false

    public var isRunning = false
    public var stage: AccessoryProtocolStage = .idle
    public var statusMessage = "就绪：选择目标坐标与连接方式后即可启动"
    public var lastErrorMessage: String?
    public var remainingSeconds: Int = 0
    public var packetsSentCount: Int = 0
    public var lastSentTimeString: String = "--:--:--"

    // MARK: Map & Coordinate State
    public var pickedLatitude: Double = 22.2819
    public var pickedLongitude: Double = 114.1581
    public var manualLatitudeInput: String = "22.281900"
    public var manualLongitudeInput: String = "114.158100"
    public var altitudeMeters: Double = 8.0
    public var speedKmh: Double = 0.0
    public var courseDegrees: Double = 0.0
    public var gcj02CorrectionEnabled: Bool = false
    public var searchQuery: String = ""
    public var searchResults: [PlaceSearchSuggestion] = []
    public var isSearchingPlace: Bool = false

    public var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 22.2819, longitude: 114.1581),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    )

    public var bookmarks: [SavedLocationBookmark] = []
    public var newBookmarkName: String = ""

    // MARK: MFi Vault State
    public var mfiStatus: MFiIdentityStatus = .empty
    public var isImportingMFi: Bool = false
    public var mfiImportMessage: String?

    // MARK: Diagnostics Log
    public var logs: [AccessoryLogEntry] = []
    public var didCopyLogs: Bool = false

    // MARK: Private Session State
    private var transportBridge: AccessoryTransportBridge?
    private let framer = IAP2StreamFramer()
    private let controlAssembler = IAP2ControlMessageAssembler()
    private var activeCredentials: (certificate: Data, privateKey: Data)?
    private var currentOutgoingSeq: UInt8 = 1
    private var synInitialSeq: UInt8 = 1
    private var lastPeerSeq: UInt8 = 0
    private var controlSessionID: UInt8 = 1
    private var isLinkEstablished = false
    private var isIdentified = false
    private var isAuthenticated = false
    private var activeSendGGA = false
    private var activeSendRMC = false
    private var minIntervalSeconds: TimeInterval = 1.0
    private var synRetryCount: Int = 0
    private var synRetryTimer: Timer?
    private var nmeaTimer: Timer?
    private var countdownTimer: Timer?
    private var lastPushTimestamp: Date = .distantPast
    private var bluetoothHostMAC: [UInt8]?
    private var currentSessionTransport: AccessoryTransportMode = .usb

    private static let defaultsPrefix = "SP_AccessoryLocation_"
    private static let bookmarksKey = "SP_AccessoryLocation_Bookmarks"
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public var effectiveWGS84Coordinate: (latitude: Double, longitude: Double) {
        if gcj02CorrectionEnabled {
            return GeoCoordinateConverter.gcj02ToWgs84(latitude: pickedLatitude, longitude: pickedLongitude)
        } else {
            return (pickedLatitude, pickedLongitude)
        }
    }

    public var pickedCoordinate2D: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: pickedLatitude, longitude: pickedLongitude)
    }

    public var selectedDevice: DiscoveredAccessoryDevice? {
        discoveredDevices.first { $0.id == selectedDeviceID }
    }

    private init() {
        loadPersistedState()
        refreshMFiStatus()
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let ud = UserDefaults.standard
        if let rawTransport = ud.string(forKey: Self.defaultsPrefix + "Transport"),
           let mode = AccessoryTransportMode(rawValue: rawTransport) {
            self.transportMode = mode
        }
        let durVal = ud.integer(forKey: Self.defaultsPrefix + "Duration")
        if ud.object(forKey: Self.defaultsPrefix + "Duration") != nil,
           let dur = AccessorySessionDuration(rawValue: durVal) {
            self.sessionDuration = dur
        }
        if ud.object(forKey: Self.defaultsPrefix + "PickedLat") != nil {
            let savedLat = ud.double(forKey: Self.defaultsPrefix + "PickedLat")
            let savedLon = ud.double(forKey: Self.defaultsPrefix + "PickedLon")
            if abs(savedLat - 39.9087) < 0.0001 && abs(savedLon - 116.3975) < 0.0001 {
                self.pickedLatitude = 22.2819
                self.pickedLongitude = 114.1581
                self.altitudeMeters = 8.0
                self.gcj02CorrectionEnabled = false
                ud.set(self.pickedLatitude, forKey: Self.defaultsPrefix + "PickedLat")
                ud.set(self.pickedLongitude, forKey: Self.defaultsPrefix + "PickedLon")
                ud.set(self.altitudeMeters, forKey: Self.defaultsPrefix + "Altitude")
                ud.set(self.gcj02CorrectionEnabled, forKey: Self.defaultsPrefix + "GCJ02Correction")
            } else {
                self.pickedLatitude = savedLat
                self.pickedLongitude = savedLon
                if ud.object(forKey: Self.defaultsPrefix + "Altitude") != nil {
                    self.altitudeMeters = ud.double(forKey: Self.defaultsPrefix + "Altitude")
                }
                if ud.object(forKey: Self.defaultsPrefix + "GCJ02Correction") != nil {
                    self.gcj02CorrectionEnabled = ud.bool(forKey: Self.defaultsPrefix + "GCJ02Correction")
                }
            }
        }

        manualLatitudeInput = String(format: "%.6f", pickedLatitude)
        manualLongitudeInput = String(format: "%.6f", pickedLongitude)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: pickedLatitude, longitude: pickedLongitude),
                span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
            )
        )

        let defaultBookmarks: [SavedLocationBookmark] = [
            SavedLocationBookmark(name: "香港 · 中环", latitude: 22.2819, longitude: 114.1581, altitudeMeters: 8.0, isGCJ02: false),
            SavedLocationBookmark(name: "美国 · Apple Park", latitude: 37.3346, longitude: -122.0090, altitudeMeters: 72.0, isGCJ02: false),
            SavedLocationBookmark(name: "日本 · 东京涩谷", latitude: 35.6595, longitude: 139.7004, altitudeMeters: 32.0, isGCJ02: false),
            SavedLocationBookmark(name: "韩国 · 首尔光化门", latitude: 37.5759, longitude: 126.9768, altitudeMeters: 38.0, isGCJ02: false)
        ]

        if let data = ud.data(forKey: Self.bookmarksKey),
           var decoded = try? JSONDecoder().decode([SavedLocationBookmark].self, from: data) {
            let legacyDefaultNames: Set<String> = [
                "北京 · 天安门",
                "上海 · 东方明珠",
                "Tokyo · Shibuya",
                "Cupertino · Apple Park"
            ]
            if decoded.contains(where: { legacyDefaultNames.contains($0.name) }) {
                decoded.removeAll { legacyDefaultNames.contains($0.name) }
                let existingNames = Set(decoded.map { $0.name })
                decoded.append(contentsOf: defaultBookmarks.filter { !existingNames.contains($0.name) })
                self.bookmarks = decoded
                persistBookmarks()
            } else {
                self.bookmarks = decoded
            }
        } else {
            self.bookmarks = defaultBookmarks
        }
    }

    public func savePreferences() {
        let ud = UserDefaults.standard
        ud.set(transportMode.rawValue, forKey: Self.defaultsPrefix + "Transport")
        ud.set(sessionDuration.rawValue, forKey: Self.defaultsPrefix + "Duration")
        ud.set(pickedLatitude, forKey: Self.defaultsPrefix + "PickedLat")
        ud.set(pickedLongitude, forKey: Self.defaultsPrefix + "PickedLon")
        ud.set(altitudeMeters, forKey: Self.defaultsPrefix + "Altitude")
        ud.set(gcj02CorrectionEnabled, forKey: Self.defaultsPrefix + "GCJ02Correction")
    }

    private func persistBookmarks() {
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: Self.bookmarksKey)
        }
    }

    // MARK: - Coordinate & Search Actions

    public func updatePickedCoordinate(latitude: Double, longitude: Double, recenterMap: Bool = false) {
        let clampedLat = min(max(latitude, -90.0), 90.0)
        let clampedLon = min(max(longitude, -180.0), 180.0)
        pickedLatitude = clampedLat
        pickedLongitude = clampedLon
        manualLatitudeInput = String(format: "%.6f", clampedLat)
        manualLongitudeInput = String(format: "%.6f", clampedLon)
        savePreferences()
        if recenterMap {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: clampedLat, longitude: clampedLon),
                    span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
                )
            )
        }
        if isRunning && stage == .streaming {
            pushLocationIfNeeded(force: true)
        }
    }

    public func applyManualCoordinateInputs() {
        let latText = manualLatitudeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lonText = manualLongitudeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lat = Double(latText), let lon = Double(lonText) else {
            lastErrorMessage = "经纬度格式无效，请输入十进制数字（例如 39.908700, 116.397500）"
            return
        }
        lastErrorMessage = nil
        updatePickedCoordinate(latitude: lat, longitude: lon, recenterMap: true)
    }

    public func applyBookmark(_ bookmark: SavedLocationBookmark) {
        gcj02CorrectionEnabled = bookmark.isGCJ02
        altitudeMeters = bookmark.altitudeMeters
        updatePickedCoordinate(latitude: bookmark.latitude, longitude: bookmark.longitude, recenterMap: true)
        appendLog(level: "INFO", message: "已切换收藏坐标「\(bookmark.name)」")
    }

    public func addCurrentAsBookmark() {
        let trimmed = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty
            ? String(format: "%.4f, %.4f", pickedLatitude, pickedLongitude)
            : trimmed
        let item = SavedLocationBookmark(
            name: title,
            latitude: pickedLatitude,
            longitude: pickedLongitude,
            altitudeMeters: altitudeMeters,
            isGCJ02: gcj02CorrectionEnabled
        )
        bookmarks.insert(item, at: 0)
        newBookmarkName = ""
        persistBookmarks()
    }

    public func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persistBookmarks()
    }

    public func searchPlace() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        isSearchingPlace = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)
        search.start { [weak self] response, _ in
            let suggestions: [PlaceSearchSuggestion] = (response?.mapItems ?? []).prefix(6).map { item in
                let coord = item.location.coordinate
                return PlaceSearchSuggestion(
                    title: item.name ?? query,
                    subtitle: item.address?.shortAddress ?? item.address?.fullAddress ?? String(format: "%.4f, %.4f", coord.latitude, coord.longitude),
                    latitude: coord.latitude,
                    longitude: coord.longitude
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSearchingPlace = false
                self.searchResults = suggestions
            }
        }
    }

    public func selectSearchSuggestion(_ suggestion: PlaceSearchSuggestion) {
        searchResults = []
        searchQuery = suggestion.title
        updatePickedCoordinate(latitude: suggestion.latitude, longitude: suggestion.longitude, recenterMap: true)
    }

    // MARK: - Device Discovery

    public func refreshDevices() {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        let mode = transportMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found: [DiscoveredAccessoryDevice]
            switch mode {
            case .usb:
                found = USBMuxClient.listUSBDevices()
            case .bluetooth:
                found = BluetoothRFCOMMBridge.pairedDevices()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRefreshingDevices = false
                self.discoveredDevices = found
                if !found.contains(where: { $0.id == self.selectedDeviceID }) {
                    self.selectedDeviceID = found.first?.id ?? ""
                }
            }
        }
    }

    // MARK: - MFi Credential Vault Actions

    public func refreshMFiStatus() {
        mfiStatus = MFiIdentityVault.currentStatus()
    }

    public func downloadAndExtractDiPlayV027() {
        guard !isImportingMFi else { return }
        isImportingMFi = true
        mfiImportMessage = "正在下载 DiPlay v0.2.7 APK 并校验 SHA-256..."
        appendLog(level: "INFO", message: "开始从 DiPlay v0.2.7 下载并提取离线 MFi 凭据...")

        Task.detached { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: MFiIdentityEngine.diplayV027URL)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw MFiIdentityError.apkVerificationFailed("下载失败（HTTP \(http.statusCode)），可改用本地 APK 或手动导入")
                }
                guard !data.isEmpty, data.count <= MFiIdentityEngine.maxAPKBytes else {
                    throw MFiIdentityError.invalidSize("下载的 APK 文件体积异常")
                }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("diplay-\(UUID().uuidString).apk")
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try data.write(to: tempURL, options: .atomic)

                let status = try MFiIdentityVault.importFromAPKFile(
                    at: tempURL,
                    requireExactSHA256: true,
                    sourceLabel: "DiPlay v0.2.7 在线提取"
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isImportingMFi = false
                    self.mfiStatus = status
                    self.mfiImportMessage = "已成功提取并校验 MFi 凭据"
                    self.appendLog(level: "OK", message: "MFi 凭据库已就绪（证书 \(status.certificateBytes)B / 私钥 \(status.keyBytes)B）")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isImportingMFi = false
                    self.mfiImportMessage = error.localizedDescription
                    self.appendLog(level: "ERR", message: "提取 DiPlay MFi 凭据失败：\(error.localizedDescription)")
                }
            }
        }
    }

    public func chooseLocalAPKAndImport() {
        let panel = NSOpenPanel()
        panel.title = "选择 DiPlay-0.2.7.apk 文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImportingMFi = true
        mfiImportMessage = "正在校验并解析本地 APK..."
        Task.detached { [weak self] in
            do {
                let status = try MFiIdentityVault.importFromAPKFile(
                    at: url,
                    requireExactSHA256: true,
                    sourceLabel: "本地 DiPlay v0.2.7 APK"
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isImportingMFi = false
                    self.mfiStatus = status
                    self.mfiImportMessage = "已从本地 APK 成功导入 MFi 凭据"
                    self.appendLog(level: "OK", message: "MFi 凭据库已就绪（证书 \(status.certificateBytes)B / 私钥 \(status.keyBytes)B）")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isImportingMFi = false
                    self.mfiImportMessage = error.localizedDescription
                    self.appendLog(level: "ERR", message: "本地 APK 解析失败：\(error.localizedDescription)")
                }
            }
        }
    }

    public func chooseManualCertificateAndKey() {
        let certPanel = NSOpenPanel()
        certPanel.title = "第 1/2 步：选择 MFi 证书 (.p7b)"
        certPanel.canChooseFiles = true
        certPanel.canChooseDirectories = false
        certPanel.allowsMultipleSelection = false
        guard certPanel.runModal() == .OK, let certURL = certPanel.url else { return }

        let keyPanel = NSOpenPanel()
        keyPanel.title = "第 2/2 步：选择明文 P-256 PKCS#8 私钥 (.pk8)"
        keyPanel.canChooseFiles = true
        keyPanel.canChooseDirectories = false
        keyPanel.allowsMultipleSelection = false
        guard keyPanel.runModal() == .OK, let keyURL = keyPanel.url else { return }

        do {
            let certData = try Data(contentsOf: certURL)
            let keyData = try Data(contentsOf: keyURL)
            let status = try MFiIdentityVault.saveCredentials(
                certificateData: certData,
                privateKeyData: keyData,
                sourceLabel: "手动导入 P7B / PK8"
            )
            self.mfiStatus = status
            self.mfiImportMessage = "手动 MFi 凭据校验通过并已安全存储"
            self.appendLog(level: "OK", message: "已导入并校验自定义 MFi 凭据（\(status.certificateBytes)B / \(status.keyBytes)B）")
        } catch {
            self.mfiImportMessage = error.localizedDescription
            self.appendLog(level: "ERR", message: "导入 MFi 凭据失败：\(error.localizedDescription)")
        }
    }

    public func clearMFiCredentials() {
        if isRunning {
            stopSession(reason: "凭据已清除，终止当前会话")
        }
        MFiIdentityVault.clear()
        refreshMFiStatus()
        mfiImportMessage = "已清除本地 MFi 凭据"
        appendLog(level: "INFO", message: "已从本地安全存储移除 MFi 凭据")
    }

    // MARK: - Session Lifecycle

    public func toggleSession() {
        if isRunning {
            stopSession(reason: "用户手动停止")
        } else {
            startSession()
        }
    }

    public func startSession() {
        guard !isRunning else { return }
        lastErrorMessage = nil

        do {
            activeCredentials = try MFiIdentityVault.loadCredentials()
        } catch {
            lastErrorMessage = error.localizedDescription
            statusMessage = "请先配置有效的 MFi 凭据"
            appendLog(level: "ERR", message: error.localizedDescription)
            return
        }

        guard let device = selectedDevice else {
            lastErrorMessage = transportMode == .usb
                ? "未检测到已信任的 USB iOS 设备，请先解锁并信任此 Mac"
                : "请先在列表中选择已配对的 iOS 蓝牙设备"
            statusMessage = lastErrorMessage ?? "未选择设备"
            appendLog(level: "WARN", message: statusMessage)
            return
        }

        savePreferences()
        synRetryTimer?.invalidate()
        synRetryTimer = nil
        synRetryCount = 0
        framer.reset()
        controlAssembler.reset()
        currentOutgoingSeq = 1
        synInitialSeq = 1
        lastPeerSeq = 0
        controlSessionID = 1
        isLinkEstablished = false
        isIdentified = false
        isAuthenticated = false
        activeSendGGA = false
        activeSendRMC = false
        minIntervalSeconds = 1.0
        packetsSentCount = 0
        lastSentTimeString = "--:--:--"
        lastPushTimestamp = .distantPast
        currentSessionTransport = device.transport

        if device.transport == .bluetooth {
            bluetoothHostMAC = BluetoothRFCOMMBridge.hostBluetoothAddressBytes()
        }

        let bridge: AccessoryTransportBridge
        switch device.transport {
        case .usb:
            guard let devID = device.usbDeviceID, let udid = device.usbUDID else {
                lastErrorMessage = "USB 设备参数缺失，请刷新设备列表后重试"
                return
            }
            bridge = USBCarKitRelayBridge(deviceID: devID, udid: udid)
        case .bluetooth:
            guard let btAddr = device.bluetoothAddress else {
                lastErrorMessage = "蓝牙设备地址缺失"
                return
            }
            bridge = BluetoothRFCOMMBridge(address: btAddr)
        }

        bridge.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleTransportReady()
            }
        }
        bridge.onData = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleIncomingTransportData(data)
            }
        }
        bridge.onLog = { [weak self] lvl, msg in
            Task { @MainActor [weak self] in
                self?.appendLog(level: lvl, message: msg)
            }
        }
        bridge.onError = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.handleTransportError(msg)
            }
        }
        bridge.onClosed = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.stopSession(reason: reason)
            }
        }

        self.transportBridge = bridge
        self.isRunning = true
        self.stage = .linking
        self.statusMessage = "正在建立 \(device.transport.title) iAP2 通道..."
        appendLog(level: "INFO", message: "启动 \(device.transport.title) 虚拟定位配件 -> \(device.name)")

        setupCountdownIfNeeded()
        bridge.connect()
    }

    public func stopSession(reason: String = "会话已结束") {
        synRetryTimer?.invalidate()
        synRetryTimer = nil
        synRetryCount = 0
        nmeaTimer?.invalidate()
        nmeaTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil

        if let bridge = transportBridge {
            if stage.rawValue >= AccessoryProtocolStage.identifying.rawValue {
                sendRST()
            }
            bridge.close()
            transportBridge = nil
        }

        framer.reset()
        controlAssembler.reset()
        activeCredentials = nil
        isLinkEstablished = false
        isIdentified = false
        isAuthenticated = false
        activeSendGGA = false
        activeSendRMC = false
        remainingSeconds = 0

        if isRunning {
            isRunning = false
            stage = .idle
            statusMessage = reason
            appendLog(level: "INFO", message: "定位配件已断开：\(reason)")
        }
    }

    public func stopSessionSynchronouslyForTermination() {
        synRetryTimer?.invalidate()
        synRetryTimer = nil
        nmeaTimer?.invalidate()
        nmeaTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        transportBridge?.close()
        transportBridge = nil
        isLinkEstablished = false
        isRunning = false
        stage = .idle
    }

    private func setupCountdownIfNeeded() {
        countdownTimer?.invalidate()
        if sessionDuration == .indefinite {
            remainingSeconds = 0
            return
        }
        remainingSeconds = sessionDuration.rawValue
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if self.remainingSeconds > 1 {
                    self.remainingSeconds -= 1
                } else {
                    self.remainingSeconds = 0
                    self.stopSession(reason: "预设定时（\(self.sessionDuration.title)）已到期自动停止")
                }
            }
        }
    }

    // MARK: - iAP2 Protocol State Machine

    private func handleTransportReady() {
        guard isRunning else { return }
        stage = .linking
        isLinkEstablished = false
        synRetryCount = 1
        currentOutgoingSeq = 1
        synInitialSeq = 1
        statusMessage = "传输通道就绪，发送 iAP2 SYN 同步..."
        appendLog(level: "INFO", message: "传输层就绪，发起 iAP2 SYN 握手")

        sendSynOffer()
        synRetryTimer?.invalidate()
        synRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.isLinkEstablished else {
                    self?.synRetryTimer?.invalidate()
                    self?.synRetryTimer = nil
                    return
                }
                if self.synRetryCount < 3 {
                    self.synRetryCount += 1
                    self.appendLog(level: "WARN", message: "iAP2 SYN 等待超时，第 \(self.synRetryCount) 次重发握手帧...")
                    self.sendSynOffer()
                } else {
                    self.synRetryTimer?.invalidate()
                    self.synRetryTimer = nil
                    self.handleTransportError("iAP2 SYN 握手超时（未收到 iPhone 响应，请确认设备已解锁）")
                }
            }
        }
    }

    private func sendSynOffer() {
        let synPkt = IAP2LinkPacket(
            flags: IAP2Codec.flagSYN,
            seq: synInitialSeq,
            ack: 0,
            session: 0,
            payload: IAP2Codec.synOfferPayload
        )
        transportBridge?.send(IAP2Codec.encodeLinkPacket(synPkt))
    }

    private func handleTransportError(_ msg: String) {
        lastErrorMessage = msg
        appendLog(level: "ERR", message: msg)
        stopSession(reason: msg)
    }

    private func handleIncomingTransportData(_ data: Data) {
        guard isRunning else { return }
        let packets = framer.feed(data)
        for pkt in packets {
            handleLinkPacket(pkt)
        }
    }

    private func handleLinkPacket(_ pkt: IAP2LinkPacket) {
        if (pkt.flags & IAP2Codec.flagRST) != 0 {
            lastErrorMessage = "iOS 端重置了 iAP2 链路（RST）"
            appendLog(level: "WARN", message: lastErrorMessage!)
            stopSession(reason: "对方重置连接")
            return
        }

        if (pkt.flags & (IAP2Codec.flagSYN | IAP2Codec.flagACK)) == (IAP2Codec.flagSYN | IAP2Codec.flagACK) {
            if pkt.ack == synInitialSeq {
                synRetryTimer?.invalidate()
                synRetryTimer = nil
                lastPeerSeq = pkt.seq
                if !isLinkEstablished {
                    isLinkEstablished = true
                    controlSessionID = IAP2Codec.parseSessionTripletControlID(from: pkt.payload)
                    sendStandaloneACK()
                    stage = .identifying
                    statusMessage = "iAP2 链路同步完成（Session #\(controlSessionID)），等待身份请求..."
                    appendLog(level: "OK", message: "iAP2 SYN-ACK 成功（控制会话 ID: \(controlSessionID)）")
                } else {
                    sendStandaloneACK()
                }
            }
            return
        }

        guard !pkt.payload.isEmpty, (pkt.flags & IAP2Codec.flagEAK) == 0 else { return }
        if pkt.seq == (lastPeerSeq &+ 1) {
            lastPeerSeq = pkt.seq
            sendStandaloneACK()
            for msg in controlAssembler.feed(pkt.payload) {
                handleControlMessage(msg)
            }
        } else {
            // 重复包或乱序包：确认最近连续序号但不重复投递消息
            sendStandaloneACK()
        }
    }

    private func handleControlMessage(_ msg: IAP2ControlMessage) {
        switch msg.id {
        case IAP2Codec.msgStartIdentification:
            stage = .identifying
            statusMessage = "收到 StartIdentification，正在提交配件能力声明..."
            appendLog(level: "INFO", message: "收到 0x1D00 StartIdentification，提交 GPS Location 组件声明")
            let identPayload = IAP2Codec.buildIdentificationMessage(
                transport: currentSessionTransport,
                bluetoothMACBytes: bluetoothHostMAC
            )
            sendControlPayload(identPayload)

        case IAP2Codec.msgIdentificationAccepted:
            isIdentified = true
            statusMessage = "iOS 已接受配件身份（0x1D02），准备 MFi 鉴权..."
            appendLog(level: "OK", message: "配件身份声明已获 iOS 认可（0x1D02）")
            activateStreamingIfReady()

        case IAP2Codec.msgIdentificationRejected:
            lastErrorMessage = "iOS 拒绝了配件身份声明（0x1D03）"
            appendLog(level: "ERR", message: lastErrorMessage!)
            stopSession(reason: "配件身份被拒绝")

        case IAP2Codec.msgRequestCertificate:
            stage = .authenticating
            statusMessage = "收到 MFi 证书请求（0xAA00），正在下发 P7B 证书..."
            guard let creds = activeCredentials else {
                handleTransportError("MFi 凭据未加载")
                return
            }
            appendLog(level: "INFO", message: "收到 0xAA00 请求证书，发送 PKCS#7 证书（\(creds.certificate.count)B）")
            let resp = IAP2Codec.encodeControlMessage(
                id: IAP2Codec.msgAuthenticationCertificate,
                parameters: [(0, creds.certificate)]
            )
            sendControlPayload(resp)

        case IAP2Codec.msgRequestChallengeResponse:
            stage = .authenticating
            statusMessage = "收到 MFi 质询（0xAA02），正在使用 P-256 私钥签名..."
            guard let creds = activeCredentials,
                  let challenge = msg.parameters.first(where: { $0.id == 0 })?.value else {
                handleTransportError("MFi 质询报文缺少参数 0")
                return
            }
            do {
                let rawSig = try MFiIdentityEngine.signPrehashedChallenge(challenge, privateKeyData: creds.privateKey)
                appendLog(level: "INFO", message: "完成 32B 预哈希质询签名（输出 \(rawSig.count)B r||s）")
                let resp = IAP2Codec.encodeControlMessage(
                    id: IAP2Codec.msgAuthenticationResponse,
                    parameters: [(0, rawSig)]
                )
                sendControlPayload(resp)
            } catch {
                handleTransportError("MFi 私钥签名失败：\(error.localizedDescription)")
            }

        case IAP2Codec.msgAuthenticationSucceeded:
            isAuthenticated = true
            statusMessage = "MFi-v3 鉴权通过！等待 iOS 订阅位置流..."
            appendLog(level: "OK", message: "MFi-v3 鉴权通过（0xAA05），等待 0xFFFA 开始定位")
            activateStreamingIfReady()

        case IAP2Codec.msgAuthenticationFailed:
            lastErrorMessage = "MFi 验签被 iOS 拒绝（0xAA04），请确认凭据未失效"
            appendLog(level: "ERR", message: lastErrorMessage!)
            stopSession(reason: "MFi 鉴权失败")

        case IAP2Codec.msgStartLocationInformation:
            var wantGGA = false
            var wantRMC = false
            var minMs: UInt32 = 1000
            for (pid, val) in msg.parameters {
                switch pid {
                case 1: wantGGA = true
                case 2: wantRMC = true
                case 0x8001, 0x8002:
                    if val.count >= 4 {
                        minMs = max(minMs, IAP2Codec.readUInt32BE(val, at: 0))
                    }
                default:
                    break
                }
            }
            if !wantGGA && !wantRMC {
                wantGGA = true
                wantRMC = true
            }
            activeSendGGA = wantGGA
            activeSendRMC = wantRMC
            minIntervalSeconds = max(1.0, Double(minMs) / 1000.0)
            appendLog(
                level: "OK",
                message: "收到 0xFFFA StartLocation（GGA=\(wantGGA ? "Y" : "N"), RMC=\(wantRMC ? "Y" : "N"), 间隔=\(String(format: "%.1fs", minIntervalSeconds))）"
            )
            activateStreamingIfReady()

        case IAP2Codec.msgStopLocationInformation:
            activeSendGGA = false
            activeSendRMC = false
            nmeaTimer?.invalidate()
            nmeaTimer = nil
            statusMessage = "iOS 暂停了位置订阅（0xFFFC）"
            appendLog(level: "INFO", message: "收到 0xFFFC StopLocationInformation")

        default:
            appendLog(level: "INFO", message: String(format: "收到未处理控制消息 0x%04X", msg.id))
        }
    }

    private func activateStreamingIfReady() {
        guard isRunning, isIdentified, isAuthenticated, activeSendGGA || activeSendRMC else { return }
        stage = .streaming
        let formattedInterval = String(format: "%.1f", minIntervalSeconds)
        statusMessage = "定位注入运行中（\(formattedInterval)s/次）"
        startNMEATimer()
        pushLocationIfNeeded(force: true)
    }

    private func startNMEATimer() {
        nmeaTimer?.invalidate()
        nmeaTimer = Timer.scheduledTimer(withTimeInterval: minIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pushLocationIfNeeded(force: false)
            }
        }
    }

    private func pushLocationIfNeeded(force: Bool) {
        guard isRunning, stage == .streaming, activeSendGGA || activeSendRMC else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastPushTimestamp) < minIntervalSeconds * 0.8 {
            return
        }
        lastPushTimestamp = now

        let wgs = effectiveWGS84Coordinate
        let speedKnots = speedKmh / 1.852
        var params: [(UInt16, Data)] = []
        if activeSendGGA {
            let gga = NMEA0183Formatter.makeGPGGA(
                latitude: wgs.latitude,
                longitude: wgs.longitude,
                altitudeMeters: altitudeMeters,
                date: now
            )
            params.append((0, IAP2Codec.cStringData(gga)))
        }
        if activeSendRMC {
            let rmc = NMEA0183Formatter.makeGPRMC(
                latitude: wgs.latitude,
                longitude: wgs.longitude,
                speedKnots: speedKnots,
                courseDegrees: courseDegrees,
                date: now
            )
            params.append((0, IAP2Codec.cStringData(rmc)))
        }
        guard !params.isEmpty else { return }

        let msgData = IAP2Codec.encodeControlMessage(id: IAP2Codec.msgLocationInformation, parameters: params)
        sendControlPayload(msgData)
        packetsSentCount += 1
        lastSentTimeString = Self.timeFormatter.string(from: now)
    }

    private func sendStandaloneACK() {
        let ackPkt = IAP2LinkPacket(
            flags: IAP2Codec.flagACK,
            seq: currentOutgoingSeq,
            ack: lastPeerSeq,
            session: 0
        )
        transportBridge?.send(IAP2Codec.encodeLinkPacket(ackPkt))
    }

    private func sendControlPayload(_ payload: Data) {
        currentOutgoingSeq = currentOutgoingSeq &+ 1
        let pkt = IAP2LinkPacket(
            flags: IAP2Codec.flagACK,
            seq: currentOutgoingSeq,
            ack: lastPeerSeq,
            session: controlSessionID,
            payload: payload
        )
        transportBridge?.send(IAP2Codec.encodeLinkPacket(pkt))
    }

    private func sendRST() {
        currentOutgoingSeq = currentOutgoingSeq &+ 1
        let rstPkt = IAP2LinkPacket(
            flags: IAP2Codec.flagRST,
            seq: currentOutgoingSeq,
            ack: lastPeerSeq,
            session: 0
        )
        transportBridge?.send(IAP2Codec.encodeLinkPacket(rstPkt))
    }

    // MARK: - Logging (Sanitized)

    public func appendLog(level: String, message: String) {
        let entry = AccessoryLogEntry(
            timestamp: Self.timeFormatter.string(from: Date()),
            level: level,
            message: message
        )
        logs.append(entry)
        if logs.count > 120 {
            logs.removeFirst(logs.count - 120)
        }
    }

    public func clearLogs() {
        logs.removeAll()
        didCopyLogs = false
    }

    public func copyLogsToClipboard() {
        let text = logs.map { "\($0.timestamp) [\($0.level)] \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopyLogs = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.didCopyLogs = false
        }
    }
}
