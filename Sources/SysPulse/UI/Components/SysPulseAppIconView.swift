import SwiftUI
import AppKit
import QuartzCore

// MARK: - Native macOS App Icon View & Components

public typealias PowerGlassAppIconView = SysPulseAppIconView

public struct SysPulseAppIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var size: CGFloat = 64
    public var forcedColorScheme: ColorScheme? = nil
    public var includeMacOSIconPadding: Bool = false
    public var isCircle: Bool = false

    public init(
        size: CGFloat = 64,
        forcedColorScheme: ColorScheme? = nil,
        includeMacOSIconPadding: Bool = false,
        isCircle: Bool = false
    ) {
        self.size = size
        self.forcedColorScheme = forcedColorScheme
        self.includeMacOSIconPadding = includeMacOSIconPadding
        self.isCircle = isCircle
    }

    private var activeScheme: ColorScheme {
        forcedColorScheme ?? envColorScheme
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let pad: CGFloat = includeMacOSIconPadding ? (size * 0.098) : 0
        let drawSize = size - pad * 2
        let cornerRadius = drawSize * 0.225
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if let image = AppIconManager.loadWatercolorImage(isDark: isDark) {
                if isCircle {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: drawSize, height: drawSize)
                        .clipShape(Circle())
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: drawSize, height: drawSize)
                        .clipShape(squircle)
                        .shadow(
                            color: Color.black.opacity(includeMacOSIconPadding ? (isDark ? 0.65 : 0.22) : 0.0),
                            radius: includeMacOSIconPadding ? drawSize * 0.045 : 0,
                            x: 0,
                            y: includeMacOSIconPadding ? drawSize * 0.025 : 0
                        )
                }
            } else {
                watercolorVectorComposition(drawSize: drawSize, isDark: isDark, squircle: squircle)
            }
        }
        .frame(width: drawSize, height: drawSize)
        .padding(pad)
    }

    // MARK: - Vector Watercolor Monitor Fallback Composition

    private func watercolorVectorComposition(drawSize: CGFloat, isDark: Bool, squircle: RoundedRectangle) -> some View {
        ZStack {
            squircle
                .fill(
                    LinearGradient(
                        colors: isDark
                            ? [Color(red: 0.08, green: 0.10, blue: 0.17), Color(red: 0.04, green: 0.05, blue: 0.10)]
                            : [Color(red: 0.99, green: 0.98, blue: 0.94), Color(red: 0.95, green: 0.93, blue: 0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    squircle
                        .strokeBorder(
                            isDark ? Color.white.opacity(0.16) : Color(red: 0.20, green: 0.18, blue: 0.15).opacity(0.25),
                            lineWidth: max(1.0, drawSize * 0.014)
                        )
                )

            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: drawSize * 0.04, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.96, green: 0.40, blue: 0.65),
                                    Color(red: 0.88, green: 0.22, blue: 0.58),
                                    Color(red: 0.68, green: 0.35, blue: 0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: drawSize * 0.04, style: .continuous)
                                .strokeBorder(Color(red: 0.22, green: 0.18, blue: 0.24), lineWidth: max(1.2, drawSize * 0.016))
                        )

                    Path { p in
                        let w = drawSize * 0.60
                        let h = drawSize * 0.36
                        let cy = h * 0.50
                        p.move(to: CGPoint(x: 0, y: cy))
                        p.addLine(to: CGPoint(x: w * 0.22, y: cy))
                        p.addLine(to: CGPoint(x: w * 0.30, y: cy - h * 0.38))
                        p.addLine(to: CGPoint(x: w * 0.38, y: cy + h * 0.40))
                        p.addLine(to: CGPoint(x: w * 0.50, y: cy - h * 0.42))
                        p.addLine(to: CGPoint(x: w * 0.58, y: cy + h * 0.25))
                        p.addLine(to: CGPoint(x: w * 0.68, y: cy - h * 0.15))
                        p.addLine(to: CGPoint(x: w * 0.76, y: cy))
                        p.addLine(to: CGPoint(x: w, y: cy))
                    }
                    .stroke(
                        Color.white.opacity(0.95),
                        style: StrokeStyle(lineWidth: max(2.0, drawSize * 0.024), lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: drawSize * 0.60, height: drawSize * 0.36)

                    ZStack {
                        Capsule()
                            .fill(Color(red: 0.82, green: 0.82, blue: 0.88))
                            .overlay(Capsule().strokeBorder(Color(red: 0.25, green: 0.22, blue: 0.28), lineWidth: 1))
                            .frame(width: drawSize * 0.35, height: drawSize * 0.038)
                            .rotationEffect(.degrees(32))
                            .offset(x: drawSize * 0.12, y: -drawSize * 0.05)
                    }
                }
                .frame(width: drawSize * 0.68, height: drawSize * 0.42)

                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.65, green: 0.68, blue: 0.78))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(red: 0.25, green: 0.22, blue: 0.28), lineWidth: 1))
                        .frame(width: drawSize * 0.22, height: drawSize * 0.08)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 0.72, green: 0.74, blue: 0.84))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(red: 0.25, green: 0.22, blue: 0.28), lineWidth: 1))
                        .frame(width: drawSize * 0.28, height: drawSize * 0.025)
                        .offset(y: drawSize * 0.04)
                }
            }
        }
    }
}

// MARK: - AppIconManager for Dynamic Theme Switching & CLI Rendering

@MainActor
public final class AppIconManager {
    public static let shared = AppIconManager()

    private var appearanceObservation: NSKeyValueObservation?
    private var currentModeIsDark: Bool? = nil

    private static var cachedLightImage: NSImage?
    private static var cachedDarkImage: NSImage?

    private init() {}

    public static var isSystemInDarkMode: Bool {
        if let val = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication as CFString) as? String {
            return val.caseInsensitiveCompare("dark") == .orderedSame
        }
        return false
    }

    public static func loadWatercolorImage(isDark: Bool) -> NSImage? {
        if isDark, let img = cachedDarkImage { return img }
        if !isDark, let img = cachedLightImage { return img }

        let name = isDark ? "AppIcon-Dark-1024" : "AppIcon-Light-1024"
        let fallbackPaths: [String?] = [
            Bundle.main.url(forResource: name, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let rawImg = NSImage(contentsOfFile: path) {
                let img = downsampledUIImage(from: rawImg, maxPixelSize: 128)
                if isDark { cachedDarkImage = img } else { cachedLightImage = img }
                return img
            }
        }

        // Also check if .icns is in Bundle
        let icnsName = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        if let icnsURL = Bundle.main.url(forResource: icnsName, withExtension: "icns"),
           let rawImg = NSImage(contentsOf: icnsURL) {
            let img = downsampledUIImage(from: rawImg, maxPixelSize: 128)
            if isDark { cachedDarkImage = img } else { cachedLightImage = img }
            return img
        }

        return nil
    }

    /// Downsample and pre-decode large artwork or multi-rep icons into an sRGB host-endian
    /// premultiplied BGRA bitmap so CoreGraphics/Metal blit without runtime ColorSync conversion.
    public nonisolated static func downsampledUIImage(
        from source: NSImage,
        maxPixelSize: CGFloat = 256,
        exactPixelTarget: Bool = false
    ) -> NSImage {
        var proposed = NSRect(x: 0, y: 0, width: maxPixelSize, height: maxPixelSize)
        let resolvedCG: CGImage? = exactPixelTarget
            ? source.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            : source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let cgImage = resolvedCG else {
            return source
        }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let scale = max(w, h) > maxPixelSize ? (maxPixelSize / max(w, h)) : 1.0
        let targetW = max(1, Int(round(w * scale)))
        let targetH = max(1, Int(round(h * scale)))

        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgbSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return source
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaledCG = ctx.makeImage() else { return source }
        return NSImage(cgImage: scaledCG, size: NSSize(width: targetW, height: targetH))
    }

    public func startObservingSystemAppearance() {
        applyCurrentAppearanceIcon(force: true)

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyCurrentAppearanceIcon(force: false)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyCurrentAppearanceIcon(force: true)
            }
        }
    }

    public func applyCurrentAppearanceIcon(force: Bool = false) {
        let isDark = Self.isSystemInDarkMode
        if !force, let current = currentModeIsDark, current == isDark {
            return
        }
        currentModeIsDark = isDark

        let iconResourceName = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        if let iconURL = Bundle.main.url(forResource: iconResourceName, withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        } else if let watercolor = Self.loadWatercolorImage(isDark: isDark) {
            NSApp.applicationIconImage = watercolor
        } else {
            let rendered = Self.renderIconImage(size: 512, isDark: isDark, includePadding: true)
            NSApp.applicationIconImage = rendered
        }
        NSApp.dockTile.display()
    }

    public static func renderIconImage(size: CGFloat, isDark: Bool, includePadding: Bool = true) -> NSImage {
        let iconView = SysPulseAppIconView(
            size: size,
            forcedColorScheme: isDark ? .dark : .light,
            includeMacOSIconPadding: includePadding
        )
        let hostingView = NSHostingView(rootView: iconView)
        hostingView.frame = NSRect(x: 0, y: 0, width: size, height: size)

        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)!
        rep.size = NSSize(width: size, height: size)
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    public static func exportIconsets(to path: String) throws {
        try generateIconSets(to: URL(fileURLWithPath: path))
    }

    public static func generateIconSets(to outputDir: URL) throws {
        let fileManager = FileManager.default
        let lightDir = outputDir.appendingPathComponent("AppIcon-Light.iconset")
        let darkDir = outputDir.appendingPathComponent("AppIcon-Dark.iconset")

        try? fileManager.removeItem(at: lightDir)
        try? fileManager.removeItem(at: darkDir)
        try fileManager.createDirectory(at: lightDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: darkDir, withIntermediateDirectories: true)

        let iconSpecs: [(name: String, size: CGFloat, scale: CGFloat)] = [
            ("icon_16x16.png", 16, 1),
            ("icon_16x16@2x.png", 16, 2),
            ("icon_32x32.png", 32, 1),
            ("icon_32x32@2x.png", 32, 2),
            ("icon_128x128.png", 128, 1),
            ("icon_128x128@2x.png", 128, 2),
            ("icon_256x256.png", 256, 1),
            ("icon_256x256@2x.png", 256, 2),
            ("icon_512x512.png", 512, 1),
            ("icon_512x512@2x.png", 512, 2)
        ]

        for spec in iconSpecs {
            let pixelSize = spec.size * spec.scale

            let lightImage = renderIconImage(size: pixelSize, isDark: false, includePadding: true)
            if let tiff = lightImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let fileURL = lightDir.appendingPathComponent(spec.name)
                try png.write(to: fileURL)
            }

            let darkImage = renderIconImage(size: pixelSize, isDark: true, includePadding: true)
            if let tiff = darkImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let fileURL = darkDir.appendingPathComponent(spec.name)
                try png.write(to: fileURL)
            }
        }
    }
}

// MARK: - 图标裁切与缩放辅助配置

private struct StorybookArtworkFraming {
    let scale: CGFloat
    let offsetYFraction: CGFloat

    static func preset(resourceBase: String, isDark: Bool) -> StorybookArtworkFraming {
        switch resourceBase {
        case "CleanerIcon":
            return isDark ? .init(scale: 1.40, offsetYFraction: -0.005) : .init(scale: 1.42, offsetYFraction: -0.008)
        case "UninstallerIcon":
            return isDark ? .init(scale: 1.40, offsetYFraction: -0.020) : .init(scale: 1.44, offsetYFraction: -0.025)
        case "SpaceAnalysisIcon":
            return isDark ? .init(scale: 1.40, offsetYFraction: -0.022) : .init(scale: 1.44, offsetYFraction: -0.028)
        case "PSPortalIcon":
            return isDark ? .init(scale: 1.40, offsetYFraction: -0.022) : .init(scale: 1.44, offsetYFraction: -0.028)
        case "WiFiLatencyIcon":
            return isDark ? .init(scale: 1.38, offsetYFraction: 0.0) : .init(scale: 1.40, offsetYFraction: 0.0)
        case "LanSnifferIcon":
            return isDark ? .init(scale: 1.40, offsetYFraction: -0.022) : .init(scale: 1.44, offsetYFraction: -0.028)
        case "UPSPowerIcon":
            return isDark ? .init(scale: 1.40, offsetYFraction: 0.0) : .init(scale: 1.42, offsetYFraction: 0.0)
        case "AntigravityContextIcon":
            return isDark ? .init(scale: 1.50, offsetYFraction: 0.0) : .init(scale: 1.78, offsetYFraction: 0.020)
        default:
            return .init(scale: 1.40, offsetYFraction: 0.0)
        }
    }
}

private extension Image {
    func storybookFramed(resourceBase: String, isDark: Bool, size: CGFloat, squircle: RoundedRectangle) -> some View {
        let framing = StorybookArtworkFraming.preset(resourceBase: resourceBase, isDark: isDark)
        return self
            .resizable()
            .aspectRatio(contentMode: .fill)
            .scaleEffect(framing.scale)
            .offset(y: size * framing.offsetYFraction)
            .frame(width: size, height: size)
            .clipShape(squircle)
    }
}

// MARK: - 清理模块图标视图

public struct CleanerArtworkIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var size: CGFloat = 58
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedLightCleaner: NSImage?
    private static var cachedDarkCleaner: NSImage?

    public init(size: CGFloat = 58, forcedColorScheme: ColorScheme? = nil) {
        self.size = size
        self.forcedColorScheme = forcedColorScheme
    }

    private var activeScheme: ColorScheme {
        forcedColorScheme ?? envColorScheme
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let cornerRadius = size * 0.225
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if let image = Self.loadCleanerImage(isDark: isDark) {
                Image(nsImage: image)
                    .storybookFramed(resourceBase: "CleanerIcon", isDark: isDark, size: size, squircle: squircle)
            } else {
                ZStack {
                    squircle.fill(isDark ? Color.purple.opacity(0.3) : Color.cyan.opacity(0.2))
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(isDark ? Color.cyan : Color.blue)
                }
            }
        }
        .frame(width: size, height: size)
    }

    public static func loadCleanerImage(isDark: Bool) -> NSImage? {
        if isDark, let img = cachedDarkCleaner { return img }
        if !isDark, let img = cachedLightCleaner { return img }

        let name = isDark ? "CleanerIcon-Dark-1024" : "CleanerIcon-Light-1024"
        let fallbackPaths: [String?] = [
            Bundle.main.url(forResource: name, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let rawImg = NSImage(contentsOfFile: path) {
                let img = AppIconManager.downsampledUIImage(from: rawImg, maxPixelSize: 256)
                if isDark { cachedDarkCleaner = img } else { cachedLightCleaner = img }
                return img
            }
        }
        return nil
    }
}

// MARK: - 卸载模块图标视图

public struct UninstallerArtworkIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var size: CGFloat = 58
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedLightUninstaller: NSImage?
    private static var cachedDarkUninstaller: NSImage?

    public init(size: CGFloat = 58, forcedColorScheme: ColorScheme? = nil) {
        self.size = size
        self.forcedColorScheme = forcedColorScheme
    }

    private var activeScheme: ColorScheme {
        forcedColorScheme ?? envColorScheme
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let cornerRadius = size * 0.225
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if let image = Self.loadUninstallerImage(isDark: isDark) {
                Image(nsImage: image)
                    .storybookFramed(resourceBase: "UninstallerIcon", isDark: isDark, size: size, squircle: squircle)
            } else {
                ZStack {
                    squircle.fill(isDark ? Color.indigo.opacity(0.3) : Color.blue.opacity(0.15))
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(isDark ? Color.cyan : Color.blue)
                }
            }
        }
        .frame(width: size, height: size)
    }

    public static func loadUninstallerImage(isDark: Bool) -> NSImage? {
        if isDark, let img = cachedDarkUninstaller { return img }
        if !isDark, let img = cachedLightUninstaller { return img }

        let name = isDark ? "UninstallerIcon-Dark-1024" : "UninstallerIcon-Light-1024"
        let fallbackPaths: [String?] = [
            Bundle.main.url(forResource: name, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let rawImg = NSImage(contentsOfFile: path) {
                let img = AppIconManager.downsampledUIImage(from: rawImg, maxPixelSize: 256)
                if isDark { cachedDarkUninstaller = img } else { cachedLightUninstaller = img }
                return img
            }
        }
        return nil
    }
}

// MARK: - 空间分析模块图标视图

public struct SpaceAnalysisArtworkIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var size: CGFloat = 58
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedLightSpace: NSImage?
    private static var cachedDarkSpace: NSImage?

    public init(size: CGFloat = 58, forcedColorScheme: ColorScheme? = nil) {
        self.size = size
        self.forcedColorScheme = forcedColorScheme
    }

    private var activeScheme: ColorScheme {
        forcedColorScheme ?? envColorScheme
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let cornerRadius = size * 0.225
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if let image = Self.loadSpaceImage(isDark: isDark) {
                Image(nsImage: image)
                    .storybookFramed(resourceBase: "SpaceAnalysisIcon", isDark: isDark, size: size, squircle: squircle)
            } else {
                ZStack {
                    squircle.fill(isDark ? Color.purple.opacity(0.3) : Color.teal.opacity(0.15))
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(isDark ? Color.cyan : Color.teal)
                }
            }
        }
        .frame(width: size, height: size)
    }

    public static func loadSpaceImage(isDark: Bool) -> NSImage? {
        if isDark, let img = cachedDarkSpace { return img }
        if !isDark, let img = cachedLightSpace { return img }

        let name = isDark ? "SpaceAnalysisIcon-Dark-1024" : "SpaceAnalysisIcon-Light-1024"
        let fallbackPaths: [String?] = [
            Bundle.main.url(forResource: name, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let rawImg = NSImage(contentsOfFile: path) {
                let img = AppIconManager.downsampledUIImage(from: rawImg, maxPixelSize: 256)
                if isDark { cachedDarkSpace = img } else { cachedLightSpace = img }
                return img
            }
        }
        return nil
    }
}

/// 模块中心插件图标类型
public enum PluginArtworkKind: String, Sendable {
    case psPortal
    case wifiLatency
    case arpSniffer
    case upsManager
    case antigravityContext

    public var resourceBaseName: String {
        switch self {
        case .psPortal: return "PSPortalIcon"
        case .wifiLatency: return "WiFiLatencyIcon"
        case .arpSniffer: return "LanSnifferIcon"
        case .upsManager: return "UPSPowerIcon"
        case .antigravityContext: return "AntigravityContextIcon"
        }
    }

    public var fallbackSymbol: String {
        switch self {
        case .psPortal: return "gamecontroller.fill"
        case .wifiLatency: return "antenna.radiowaves.left.and.right"
        case .arpSniffer: return "network"
        case .upsManager: return "battery.100.bolt"
        case .antigravityContext: return "sparkles"
        }
    }

    public var fallbackAccent: Color {
        switch self {
        case .psPortal: return .blue
        case .wifiLatency: return .teal
        case .arpSniffer: return .purple
        case .upsManager: return .orange
        case .antigravityContext: return .indigo
        }
    }
}

/// 模块中心插件图标视图（适配浅色 / 深色与启停状态）
public struct PluginArtworkIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public let kind: PluginArtworkKind
    public var size: CGFloat = 58
    public var isEnabled: Bool = true
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedImages: [String: NSImage] = [:]

    public init(
        kind: PluginArtworkKind,
        size: CGFloat = 58,
        isEnabled: Bool = true,
        forcedColorScheme: ColorScheme? = nil
    ) {
        self.kind = kind
        self.size = size
        self.isEnabled = isEnabled
        self.forcedColorScheme = forcedColorScheme
    }

    private var activeScheme: ColorScheme {
        forcedColorScheme ?? envColorScheme
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let cornerRadius = size * 0.225
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if let image = Self.loadImage(kind: kind, isDark: isDark) {
                Image(nsImage: image)
                    .storybookFramed(resourceBase: kind.resourceBaseName, isDark: isDark, size: size, squircle: squircle)
                    .overlay(
                        squircle
                            .strokeBorder(
                                isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.06),
                                lineWidth: 0.8
                            )
                    )
            } else {
                ZStack {
                    squircle.fill(kind.fallbackAccent.opacity(isDark ? 0.28 : 0.16))
                    Image(systemName: kind.fallbackSymbol)
                        .font(.system(size: size * 0.44, weight: .bold))
                        .foregroundStyle(kind.fallbackAccent)
                }
            }
        }
        .frame(width: size, height: size)
        .saturation(isEnabled ? 1.0 : 0.22)
        .opacity(isEnabled ? 1.0 : 0.72)
    }

    public static func loadImage(kind: PluginArtworkKind, isDark: Bool) -> NSImage? {
        let resourceName = "\(kind.resourceBaseName)-\(isDark ? "Dark" : "Light")-1024"
        if let cached = cachedImages[resourceName] {
            return cached
        }

        let fallbackPaths: [String?] = [
            Bundle.main.url(forResource: resourceName, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(resourceName).png").path
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let rawImg = NSImage(contentsOfFile: path) {
                let img = AppIconManager.downsampledUIImage(from: rawImg, maxPixelSize: 256)
                cachedImages[resourceName] = img
                return img
            }
        }
        return nil
    }
}

// MARK: - 实时动画组件

private final class CARotatingSymbolContainerNSView: NSView {
    private let spriteLayer = CALayer()
    private var currentKey: String = ""
    private var currentDuration: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.masksToBounds = false
        layer?.addSublayer(spriteLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        spriteLayer.bounds = bounds
        spriteLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            spriteLayer.removeAnimation(forKey: "syspulse.spin")
        } else if currentDuration > 0.05 && spriteLayer.animation(forKey: "syspulse.spin") == nil {
            addSpinAnimation(duration: currentDuration)
        }
    }

    private func addSpinAnimation(duration: TimeInterval) {
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0.0
        anim.toValue = -Double.pi * 2.0
        anim.duration = duration
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        if #available(macOS 12.0, *) {
            anim.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        }
        spriteLayer.add(anim, forKey: "syspulse.spin")
    }

    func configure(systemName: String, pointSize: CGFloat, nsColor: NSColor, duration: TimeInterval) {
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        spriteLayer.contentsScale = backingScale

        let rgba = nsColor.usingColorSpace(.sRGB) ?? nsColor
        let r = Int(round(rgba.redComponent * 255))
        let g = Int(round(rgba.greenComponent * 255))
        let b = Int(round(rgba.blueComponent * 255))
        let a = Int(round(rgba.alphaComponent * 255))
        let nextKey = "\(systemName)-\(Int(round(pointSize * 10)))-\(r)-\(g)-\(b)-\(a)-\(Int(round(backingScale * 10)))"

        if nextKey != currentKey {
            currentKey = nextKey
            let symConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
                .applying(.init(paletteColors: [rgba]))
            if let sym = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symConfig) {
                var proposed = NSRect(origin: .zero, size: sym.size)
                spriteLayer.contents = sym.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            }
        }

        if abs(currentDuration - duration) > 0.001 || (window != nil && spriteLayer.animation(forKey: "syspulse.spin") == nil) {
            currentDuration = duration
            spriteLayer.removeAnimation(forKey: "syspulse.spin")
            if duration > 0.05 && window != nil {
                addSpinAnimation(duration: duration)
            }
        }
    }
}

private struct CoreAnimationRotatingSymbolView: NSViewRepresentable {
    let systemName: String
    let size: CGFloat
    let color: Color
    let duration: TimeInterval

    func makeNSView(context: Context) -> CARotatingSymbolContainerNSView {
        CARotatingSymbolContainerNSView()
    }

    func updateNSView(_ nsView: CARotatingSymbolContainerNSView, context: Context) {
        nsView.configure(
            systemName: systemName,
            pointSize: size,
            nsColor: NSColor(color),
            duration: duration
        )
    }
}

/// 根据风扇 RPM 转速旋转的风扇图标视图（RPM <= 0 时静止）
public struct SpinningFanIconView: View {
    public var rpm: Int
    public var size: CGFloat = 14
    public var color: Color = .orange

    public init(rpm: Int, size: CGFloat = 14, color: Color = .orange) {
        self.rpm = rpm
        self.size = size
        self.color = color
    }

    private var speedTier: Int {
        guard rpm > 0 else { return 0 }
        if rpm < 1400 { return 1 }
        if rpm < 2400 { return 2 }
        if rpm < 3800 { return 3 }
        return 4
    }

    private var revolutionDuration: TimeInterval {
        switch speedTier {
        case 1: return 2.1
        case 2: return 1.4
        case 3: return 0.9
        default: return 0.55
        }
    }

    public var body: some View {
        if rpm <= 0 {
            Image(systemName: "fan.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
        } else {
            CoreAnimationRotatingSymbolView(
                systemName: "fan.fill",
                size: size,
                color: color,
                duration: revolutionDuration
            )
            .frame(width: size + 4, height: size + 4)
        }
    }
}

/// 支持慢速旋转的卡片头部符号视图
public struct PulsingHeaderSymbolView: View {
    public var systemName: String
    public var size: CGFloat = 13
    public var color: Color
    public var isRotating: Bool = false

    public init(systemName: String, size: CGFloat = 13, color: Color, isRotating: Bool = false) {
        self.systemName = systemName
        self.size = size
        self.color = color
        self.isRotating = isRotating
    }

    public var body: some View {
        if !isRotating {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
        } else {
            CoreAnimationRotatingSymbolView(
                systemName: systemName,
                size: size,
                color: color,
                duration: 15.0
            )
            .frame(width: size + 4, height: size + 4)
        }
    }
}

/// 模块图标呼吸与波纹动画容器（未激活时静止）
public struct AnimatedModuleArtworkBadgeView<Content: View>: View {
    public var size: CGFloat = 50
    public var isActive: Bool = false
    public var accentColor: Color = .cyan
    private let content: Content

    public init(
        size: CGFloat = 50,
        isActive: Bool = false,
        accentColor: Color = .cyan,
        @ViewBuilder content: () -> Content
    ) {
        self.size = size
        self.isActive = isActive
        self.accentColor = accentColor
        self.content = content()
    }

    public var body: some View {
        let cornerRadius = size * 0.23

        if !isActive {
            content
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.55), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .phaseAnimator([false, true]) { ring, phase in
                        ring
                            .scaleEffect(phase ? 1.32 : 1.0)
                            .opacity(phase ? 0.08 : 0.65)
                    } animation: { _ in
                        .easeOut(duration: 1.5)
                    }

                content
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(accentColor.opacity(0.32), lineWidth: 1.0)
                    )
                    .phaseAnimator([false, true]) { badge, phase in
                        badge
                            .offset(y: phase ? -2.0 : 1.5)
                            .rotationEffect(.degrees(phase ? 1.5 : -1.5))
                    } animation: { _ in
                        .easeInOut(duration: 1.8)
                    }
            }
            .frame(width: size, height: size)
        }
    }
}


