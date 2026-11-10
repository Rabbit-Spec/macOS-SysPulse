import SwiftUI
import AppKit

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
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path,
            "/Volumes/巨无霸/SPEC/v3.0.0/Resources/\(name).png",
            "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/Resources/\(name).png",
            "/tmp/\(name).png",
            isDark
                ? "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/syspulse_rabbit_dark_icon_1793861549186.jpg"
                : "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/.user_uploaded/media_1793861192679_1b4297a8.jpg"
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                if isDark { cachedDarkImage = img } else { cachedLightImage = img }
                return img
            }
        }

        // Also check if .icns is in Bundle
        let icnsName = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        if let icnsURL = Bundle.main.url(forResource: icnsName, withExtension: "icns"),
           let img = NSImage(contentsOf: icnsURL) {
            return img
        }

        return nil
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

// MARK: - Dedicated Cleaner Artwork Icon View (Matches Storybook Watercolor Aesthetic)

public struct CleanerArtworkIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var size: CGFloat = 42
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedLightCleaner: NSImage?
    private static var cachedDarkCleaner: NSImage?

    public init(size: CGFloat = 42, forcedColorScheme: ColorScheme? = nil) {
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
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(squircle)
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
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path,
            "/Volumes/巨无霸/SPEC/v3.0.0/Resources/\(name).png",
            "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/Resources/\(name).png",
            "/tmp/\(name).png",
            isDark
                ? "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/syspulse_cleaner_icon_dark_1793849341374.jpg"
                : "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/syspulse_cleaner_icon_light_1793849308615.jpg"
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                if isDark { cachedDarkCleaner = img } else { cachedLightCleaner = img }
                return img
            }
        }
        return nil
    }
}

// MARK: - Dedicated Uninstaller Artwork Icon View (Matches Storybook Watercolor Aesthetic)

public struct UninstallerArtworkIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var size: CGFloat = 50
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedLightUninstaller: NSImage?
    private static var cachedDarkUninstaller: NSImage?

    public init(size: CGFloat = 50, forcedColorScheme: ColorScheme? = nil) {
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
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(squircle)
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
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path,
            "/Volumes/巨无霸/SPEC/v3.0.0/Resources/\(name).png",
            "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/Resources/\(name).png",
            "/tmp/\(name).png",
            isDark
                ? "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/syspulse_uninstaller_icon_dark.png"
                : "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/syspulse_uninstaller_icon_light.png",
            isDark
                ? "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/syspulse_uninstaller_icon_dark_1793936655170.jpg"
                : "/Users/bunny/.gemini/antigravity/brain/79037a0d-c569-47f3-8e92-c63a306d3e84/syspulse_uninstaller_icon_light_v2_1793936622704.jpg"
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                if isDark { cachedDarkUninstaller = img } else { cachedLightUninstaller = img }
                return img
            }
        }
        return nil
    }
}

// MARK: - Dedicated Space Analysis Artwork Icon View (Matches Storybook Watercolor Aesthetic)

public struct SpaceAnalysisArtworkIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public var size: CGFloat = 50
    public var forcedColorScheme: ColorScheme? = nil

    private static var cachedLightSpace: NSImage?
    private static var cachedDarkSpace: NSImage?

    public init(size: CGFloat = 50, forcedColorScheme: ColorScheme? = nil) {
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
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(squircle)
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
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path,
            "/Volumes/巨无霸/SPEC/v3.0.0/Resources/\(name).png",
            "/Volumes/巨无霸/SPEC/build/SysPulse.app/Contents/Resources/\(name).png",
            "/tmp/\(name).png"
        ]

        for path in fallbackPaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                if isDark { cachedDarkSpace = img } else { cachedLightSpace = img }
                return img
            }
        }
        return nil
    }
}

// MARK: - 实时微动效组件 (Micro-Motion Components)

/// 根据真实风扇 RPM 转速无级旋转的风扇图标视图
public struct SpinningFanIconView: View {
    public var rpm: Int
    public var size: CGFloat = 14
    public var color: Color = .orange

    public init(rpm: Int, size: CGFloat = 14, color: Color = .orange) {
        self.rpm = rpm
        self.size = size
        self.color = color
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let degPerSec = rpm <= 0 ? 0.0 : max(110.0, min(720.0, Double(rpm) / 1000.0 * 145.0))
            let angle = (t * degPerSec).truncatingRemainder(dividingBy: 360.0)

            Image(systemName: "fan.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
                .rotationEffect(.degrees(angle))
        }
    }
}

/// 带有柔和呼吸脉动（及可选慢速旋转）的卡片头部符号视图
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
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 2.4) + 1.0) * 0.5
            let scale = 0.94 + 0.10 * breath
            let angle = isRotating ? (t * 24.0).truncatingRemainder(dividingBy: 360.0) : 0.0

            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
                .scaleEffect(scale)
                .rotationEffect(.degrees(angle))
                .shadow(color: color.opacity(0.25 + 0.30 * breath), radius: 3.5)
        }
    }
}

/// 3D 模块图标悬浮呼吸与扫描声呐波纹容器视图
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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let floatSpeed = isActive ? 3.6 : 2.1
            let floatY = CGFloat(sin(t * floatSpeed)) * (isActive ? 2.6 : 1.8)
            let tilt = sin(t * (floatSpeed * 0.7)) * (isActive ? 2.2 : 1.2)
            let cornerRadius = size * 0.23

            ZStack {
                if isActive {
                    ForEach(0..<2, id: \.self) { idx in
                        let phase = ((t * 0.85) + Double(idx) * 0.5).truncatingRemainder(dividingBy: 1.0)
                        let ringScale = 1.0 + CGFloat(phase) * 0.42
                        let ringAlpha = max(0.0, (1.0 - phase) * 0.65)

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(accentColor.opacity(ringAlpha), lineWidth: 1.5)
                            .frame(width: size, height: size)
                            .scaleEffect(ringScale)
                    }
                }

                content
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .shadow(
                        color: accentColor.opacity(isActive ? 0.38 : 0.16),
                        radius: isActive ? 7 : 4,
                        y: 2 - floatY * 0.3
                    )
                    .offset(y: floatY)
                    .rotationEffect(.degrees(tilt))
            }
            .frame(width: size, height: size)
        }
    }
}


