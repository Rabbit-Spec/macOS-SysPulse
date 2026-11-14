import Foundation

/// IEEE OUI 查询结果
public struct LanOuiMatch: Sendable, Equatable {
    public let prefix: String
    public let shortVendor: String
    public let displayName: String
    public let fullOrg: String
    public let suggestedIcon: String
    public let isLocallyAdministered: Bool
    public let isPrivateOUI: Bool
}

private struct RawOuiEntry: Sendable {
    let shortName: String
    let fullOrg: String
}

/// 离线 IEEE OUI (MA-L / MA-M / MA-S) 查询库
/// 支持 36-bit -> 28-bit -> 24-bit 最长前缀匹配与本地随机私有 MAC 识别
public final class LanOuiDatabase: @unchecked Sendable {
    public static let shared = LanOuiDatabase()

    private let oui36: [String: RawOuiEntry]
    private let oui28: [String: RawOuiEntry]
    private let oui24: [String: RawOuiEntry]

    public var totalEntryCount: Int {
        oui36.count + oui28.count + oui24.count
    }

    private init() {
        var map36: [String: RawOuiEntry] = [:]
        var map28: [String: RawOuiEntry] = [:]
        var map24: [String: RawOuiEntry] = [:]

        if let url = Self.locateDatabaseFile(),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            map36.reserveCapacity(8000)
            map28.reserveCapacity(7000)
            map24.reserveCapacity(42000)

            content.enumerateLines { line, _ in
                guard !line.isEmpty else { return }
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 2 else { return }
                let prefix = String(parts[0]).lowercased()
                let shortName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                let fullOrg = parts.count >= 3
                    ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                    : shortName

                // Skip IEEE container rows (actual owners are in MA-M / MA-S sub-blocks)
                if fullOrg.caseInsensitiveCompare("IEEE Registration Authority") == .orderedSame {
                    return
                }
                guard !shortName.isEmpty || !fullOrg.isEmpty else { return }

                let entry = RawOuiEntry(
                    shortName: shortName.isEmpty ? fullOrg : shortName,
                    fullOrg: fullOrg.isEmpty ? shortName : fullOrg
                )

                switch prefix.count {
                case 13: // xx:xx:xx:xx:x (36-bit MA-S)
                    map36[prefix] = entry
                case 10: // xx:xx:xx:x (28-bit MA-M)
                    map28[prefix] = entry
                case 8:  // xx:xx:xx (24-bit MA-L)
                    map24[prefix] = entry
                default:
                    break
                }
            }
        }

        // Built-in critical fallback entries in case resource loading fails in unusual launch contexts
        let builtIn24: [String: RawOuiEntry] = [
            "48:9e:9d": RawOuiEntry(shortName: "Gaoshengda", fullOrg: "Hui Zhou Gaoshengda Technology Co.,LTD"),
            "b4:60:ed": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "64:9e:31": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "c8:5c:cc": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "cc:b5:d1": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "dc:ed:83": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "ec:4d:3e": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "24:64:77": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "b8:50:d8": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "e4:fe:43": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "e8:4a:54": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "cc:4d:75": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "7c:c2:94": RawOuiEntry(shortName: "Xiaomi", fullOrg: "Beijing Xiaomi Mobile Software Co., Ltd"),
            "40:31:3c": RawOuiEntry(shortName: "Xiaomi", fullOrg: "XIAOMI Electronics,CO.,LTD"),
            "78:df:72": RawOuiEntry(shortName: "Imilab", fullOrg: "Shanghai Imilab Technology Co.Ltd"),
            "54:ef:44": RawOuiEntry(shortName: "Aqara", fullOrg: "Lumi United Technology Co., Ltd"),
            "6c:80:ab": RawOuiEntry(shortName: "ifanr", fullOrg: "ifanr Inc"),
            "20:37:f0": RawOuiEntry(shortName: "Arcadyan", fullOrg: "Arcadyan Corporation"),
            "48:bc:0e": RawOuiEntry(shortName: "AI-Link", fullOrg: "Sichuan AI-Link Technology Co., Ltd."),
            "84:fc:14": RawOuiEntry(shortName: "Bilian", fullOrg: "SHENZHEN BILIAN ELECTRONIC CO.，LTD"),
            "14:0a:02": RawOuiEntry(shortName: "Bilian", fullOrg: "SHENZHEN BILIAN ELECTRONIC CO.，LTD"),
            "c8:48:05": RawOuiEntry(shortName: "Nintendo", fullOrg: "Nintendo Co.,Ltd"),
            "dc:b4:d9": RawOuiEntry(shortName: "Espressif", fullOrg: "Espressif Inc."),
            "bc:89:c1": RawOuiEntry(shortName: "Apple", fullOrg: "Apple, Inc."),
            "c0:95:6d": RawOuiEntry(shortName: "Apple", fullOrg: "Apple, Inc.")
        ]
        for (prefix, entry) in builtIn24 where map24[prefix] == nil {
            map24[prefix] = entry
        }

        self.oui36 = map36
        self.oui28 = map28
        self.oui24 = map24
    }

    private static func locateDatabaseFile() -> URL? {
        if let url = Bundle.main.url(forResource: "ieee_oui", withExtension: "tsv"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("ieee_oui.tsv"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        let bundleSibling = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ieee_oui.tsv")
        if FileManager.default.fileExists(atPath: bundleSibling.path) {
            return bundleSibling
        }
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Plugins
            .deletingLastPathComponent() // SysPulse
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Project Root
            .appendingPathComponent("Resources/ieee_oui.tsv")
        if FileManager.default.fileExists(atPath: sourceRelative.path) {
            return sourceRelative
        }
        return nil
    }

    /// 规范化 MAC 地址为小写零填充 xx:xx:xx:xx:xx:xx；若非合法 6 字节 MAC 返回 nil
    public static func normalizeMAC(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Handle colon/hyphen separated octets that may omit leading zeros (e.g., e:3f:5:1:2:3 from BSD arp)
        if trimmed.contains(":") || trimmed.contains("-") {
            let sep: Character = trimmed.contains(":") ? ":" : "-"
            let parts = trimmed.split(separator: sep, omittingEmptySubsequences: false)
            if parts.count == 6 {
                var bytes: [String] = []
                bytes.reserveCapacity(6)
                for p in parts {
                    guard !p.isEmpty, p.count <= 2, let val = UInt8(p, radix: 16) else {
                        return nil
                    }
                    bytes.append(String(format: "%02x", val))
                }
                return bytes.joined(separator: ":")
            }
        }

        // Fallback for flat hex or dot-notation (e.g. aabb.ccdd.eeff)
        let hex = trimmed.lowercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var octets: [String] = []
        var idx = hex.startIndex
        for _ in 0..<6 {
            let nextIdx = hex.index(idx, offsetBy: 2)
            octets.append(String(hex[idx..<nextIdx]))
            idx = nextIdx
        }
        return octets.joined(separator: ":")
    }

    /// 判断 MAC 是否属于本地管理位 (U/L bit = 1) 的随机/私有 MAC
    public static func isLocallyAdministeredMAC(_ rawMac: String) -> Bool {
        guard let norm = normalizeMAC(rawMac),
              let firstByte = UInt8(norm.prefix(2), radix: 16) else {
            return false
        }
        // Ignore multicast bit (0x01) for unicast check; U/L bit is 0x02
        return (firstByte & 0x02) != 0
    }

    /// 按 36-bit -> 28-bit -> 24-bit 顺序查找 IEEE 厂商信息；未命中且 U/L 位为 1 时标注随机私有 MAC
    public func lookup(_ rawMac: String) -> LanOuiMatch? {
        guard let norm = Self.normalizeMAC(rawMac) else { return nil }
        // Strip colons to easily form 24/28/36-bit keys -> norm format "aa:bb:cc:dd:ee:ff"
        // Length 17 chars:
        // 0..7   = "aa:bb:cc" (8 chars, 24-bit)
        // 0..9   = "aa:bb:cc:d" (10 chars, 28-bit)
        // 0..12  = "aa:bb:cc:dd:e" (13 chars, 36-bit)
        let key36 = String(norm.prefix(13))
        let key28 = String(norm.prefix(10))
        let key24 = String(norm.prefix(8))

        if let entry = oui36[key36] {
            return Self.formatMatch(prefix: key36, entry: entry)
        }
        if let entry = oui28[key28] {
            return Self.formatMatch(prefix: key28, entry: entry)
        }
        if let entry = oui24[key24] {
            return Self.formatMatch(prefix: key24, entry: entry)
        }

        if Self.isLocallyAdministeredMAC(norm) {
            return LanOuiMatch(
                prefix: key24,
                shortVendor: "随机 MAC",
                displayName: "随机私有 MAC",
                fullOrg: "Locally Administered / Randomized MAC",
                suggestedIcon: "shield.lefthalf.filled",
                isLocallyAdministered: true,
                isPrivateOUI: false
            )
        }

        return nil
    }

    private static func formatMatch(prefix: String, entry: RawOuiEntry) -> LanOuiMatch {
        if entry.fullOrg.caseInsensitiveCompare("Private") == .orderedSame {
            return LanOuiMatch(
                prefix: prefix,
                shortVendor: "IEEE 隐私",
                displayName: "隐私注册厂商 (IEEE Private)",
                fullOrg: "Private (IEEE Registered)",
                suggestedIcon: "lock.shield",
                isLocallyAdministered: false,
                isPrivateOUI: true
            )
        }

        let lowFull = entry.fullOrg.lowercased()
        let (brandShort, displayName, icon) = mapLocalizedBrand(
            shortName: entry.shortName,
            fullOrg: entry.fullOrg,
            lowFull: lowFull
        )

        return LanOuiMatch(
            prefix: prefix,
            shortVendor: brandShort,
            displayName: displayName,
            fullOrg: entry.fullOrg,
            suggestedIcon: icon,
            isLocallyAdministered: false,
            isPrivateOUI: false
        )
    }

    private static func mapLocalizedBrand(
        shortName: String,
        fullOrg: String,
        lowFull: String
    ) -> (short: String, display: String, icon: String) {
        if lowFull.contains("xiaomi") || shortName == "Xiaomi" {
            return ("Xiaomi", "Xiaomi (小米)", "sensor.tag.radiowaves.forward")
        }
        if lowFull.contains("zhangyue") || lowFull.contains("ireader") || shortName == "Shenzhen Zhangyue" || shortName == "iReader" {
            return ("iReader", "iReader (掌阅)", "book.fill")
        }
        if lowFull.contains("lumi united") || lowFull.contains("aqara") || shortName == "Aqara" {
            return ("Aqara", "Aqara (绿米)", "lightbulb.led.fill")
        }
        if lowFull.contains("imilab") || shortName.lowercased().contains("imilab") {
            return ("Imilab", "Imilab (创米科技)", "video.fill")
        }
        if lowFull.contains("gaoshengda") || shortName == "Gaoshengda" {
            return ("Gaoshengda", "Gaoshengda (高盛达模组)", "cpu")
        }
        if lowFull.contains("ai-link") || shortName == "AI-Link" {
            return ("AI-Link", "AI-Link (爱联模组)", "cpu")
        }
        if lowFull.contains("bilian") || lowFull.contains("b-link") || shortName == "Bilian" {
            return ("Bilian", "Bilian (必联模组)", "wifi")
        }
        if lowFull.contains("ifanr") || shortName == "ifanr" {
            return ("ifanr", "ifanr (制糖工厂)", "bolt.fill")
        }
        if lowFull.contains("arcadyan") || shortName == "Arcadyan" {
            return ("Arcadyan", "Arcadyan (智易科技)", "tv")
        }
        if lowFull.contains("espressif") || shortName == "Espressif" {
            return ("Espressif", "Espressif (乐鑫模组)", "cpu")
        }
        if lowFull.contains("tuya") || shortName == "Tuya" {
            return ("Tuya", "Tuya (涂鸦智能)", "sensor.tag.radiowaves.forward")
        }
        if lowFull.contains("yeelink") || shortName == "Yeelight" {
            return ("Yeelight", "Yeelight (易来照明)", "lightbulb.fill")
        }
        if lowFull.contains("roborock") || shortName == "Roborock" {
            return ("Roborock", "Roborock (石头科技)", "fan.fill")
        }
        if lowFull.contains("dreame") || shortName == "Dreame" {
            return ("Dreame", "Dreame (追觅)", "fan.fill")
        }
        if lowFull.contains("ecovacs") || shortName == "Ecovacs" {
            return ("Ecovacs", "Ecovacs (科沃斯)", "fan.fill")
        }
        if lowFull.contains("apple") || shortName == "Apple" {
            return ("Apple", "Apple 设备", "apple.logo")
        }
        if lowFull.contains("nintendo") || shortName == "Nintendo" {
            return ("Nintendo", "Nintendo 设备", "gamecontroller.fill")
        }
        if lowFull.contains("sony") || shortName == "Sony" {
            return ("Sony", "Sony 设备", "gamecontroller.fill")
        }
        if lowFull.contains("huawei") || shortName == "Huawei" {
            return ("Huawei", "Huawei (华为)", "iphone")
        }
        if lowFull.contains("honor device") || shortName == "Honor" {
            return ("Honor", "Honor (荣耀)", "iphone")
        }
        if lowFull.contains("asustek") || shortName == "ASUS" {
            return ("ASUS", "ASUS (华硕)", "desktopcomputer")
        }
        if lowFull.contains("tp-link") || shortName == "TP-Link" {
            return ("TP-Link", "TP-Link (普联)", "wifi.router")
        }
        if lowFull.contains("synology") || shortName == "Synology" {
            return ("Synology", "Synology (群晖)", "externaldrive.connected.to.line.below")
        }
        if lowFull.contains("qnap") || shortName == "QNAP" {
            return ("QNAP", "QNAP (威联通)", "externaldrive.connected.to.line.below")
        }
        if lowFull.contains("ubiquiti") || shortName == "Ubiquiti" {
            return ("Ubiquiti", "Ubiquiti 设备", "wifi.router")
        }
        if lowFull.contains("hikvision") || shortName == "Hikvision" {
            return ("Hikvision", "Hikvision (海康威视)", "video.fill")
        }
        if lowFull.contains("ezviz") || shortName == "EZVIZ" {
            return ("EZVIZ", "EZVIZ (萤石)", "video.fill")
        }
        if lowFull.contains("dahua") || shortName == "Dahua" {
            return ("Dahua", "Dahua (大华)", "video.fill")
        }
        if lowFull.contains("sonos") || shortName == "Sonos" {
            return ("Sonos", "Sonos 音响", "hifispeaker.fill")
        }
        if lowFull.contains("lg electronics") || shortName == "LG" {
            return ("LG", "LG Electronics", "tv")
        }
        if lowFull.contains("samsung") || shortName == "Samsung" {
            return ("Samsung", "Samsung (三星)", "display")
        }
        if lowFull.contains("google") || shortName == "Google" {
            return ("Google", "Google 设备", "homepod.mini.fill")
        }
        if lowFull.contains("amazon") || shortName == "Amazon" {
            return ("Amazon", "Amazon 设备", "dot.radiowaves.left.and.right")
        }
        if lowFull.contains("microsoft") || shortName == "Microsoft" {
            return ("Microsoft", "Microsoft 设备", "desktopcomputer")
        }
        if lowFull.contains("intel") || shortName == "Intel" {
            return ("Intel", "Intel 网卡终端", "desktopcomputer")
        }
        if lowFull.contains("realtek") || shortName == "Realtek" {
            return ("Realtek", "Realtek 网卡终端", "desktopcomputer")
        }
        if lowFull.contains("broadcom") || shortName == "Broadcom" {
            return ("Broadcom", "Broadcom 网卡终端", "wifi")
        }
        if lowFull.contains("qualcomm") || shortName == "Qualcomm" {
            return ("Qualcomm", "Qualcomm 无线终端", "wifi")
        }
        if lowFull.contains("mediatek") || shortName == "MediaTek" {
            return ("MediaTek", "MediaTek 无线终端", "wifi")
        }
        if lowFull.contains("lenovo") || shortName == "Lenovo" {
            return ("Lenovo", "Lenovo (联想)", "laptopcomputer")
        }
        if lowFull.contains("dell") || shortName == "Dell" {
            return ("Dell", "Dell (戴尔)", "desktopcomputer")
        }
        if lowFull.contains("hewlett packard") || lowFull.contains("hp inc") || shortName == "HP" {
            return ("HP", "HP (惠普)", "printer.fill")
        }
        if lowFull.contains("raspberry pi") || shortName == "Raspberry Pi" {
            return ("Raspberry Pi", "Raspberry Pi", "cpu")
        }
        if lowFull.contains("gl.inet") || lowFull.contains("gl technologies") || shortName == "GL.iNet" {
            return ("GL.iNet", "GL.iNet 路由器", "wifi.router")
        }
        if lowFull.contains("hisense") {
            return ("Hisense", "Hisense (海信)", "tv")
        }
        if lowFull.contains("midea") {
            return ("Midea", "Midea (美的)", "sensor.tag.radiowaves.forward")
        }
        if lowFull.contains("haier") {
            return ("Haier", "Haier (海尔)", "sensor.tag.radiowaves.forward")
        }
        if lowFull.contains("gree electric") {
            return ("Gree", "Gree (格力)", "sensor.tag.radiowaves.forward")
        }
        if lowFull.contains("vivo mobile") {
            return ("vivo", "vivo 终端", "iphone")
        }
        if lowFull.contains("guangdong oppo") || lowFull.contains("oppo") {
            return ("OPPO", "OPPO 终端", "iphone")
        }
        if lowFull.contains("oneplus") {
            return ("OnePlus", "OnePlus (一加)", "iphone")
        }
        if lowFull.contains("brother industries") {
            return ("Brother", "Brother 打印机", "printer.fill")
        }
        if lowFull.contains("epson") {
            return ("Epson", "Epson 打印机", "printer.fill")
        }
        if lowFull.contains("canon") {
            return ("Canon", "Canon 设备", "printer.fill")
        }
        if lowFull.contains("philips") || lowFull.contains("signify") {
            return ("Signify", "Signify / Hue", "lightbulb.fill")
        }
        if lowFull.contains("mercurys") || lowFull.contains("mercury communication") {
            return ("Mercury", "Mercury (水星网络)", "wifi.router")
        }
        if lowFull.contains("tenda") {
            return ("Tenda", "Tenda (腾达)", "wifi.router")
        }
        if lowFull.contains("h3c") {
            return ("H3C", "H3C (新华三)", "network")
        }
        if lowFull.contains("ruijie") {
            return ("Ruijie", "Ruijie (锐捷)", "wifi.router")
        }
        if lowFull.contains("zte") {
            return ("ZTE", "ZTE (中兴)", "wifi.router")
        }
        if lowFull.contains("netgear") {
            return ("NETGEAR", "NETGEAR (网件)", "wifi.router")
        }
        if lowFull.contains("mikrotik") {
            return ("MikroTik", "MikroTik 路由", "network")
        }
        if lowFull.contains("dyson") {
            return ("Dyson", "Dyson (戴森)", "fan.fill")
        }
        if lowFull.contains("bose") {
            return ("Bose", "Bose 音响", "hifispeaker.fill")
        }

        let display = fullOrg.count <= 32 ? fullOrg : "\(shortName) 终端"
        return (shortName, display, "network")
    }
}
