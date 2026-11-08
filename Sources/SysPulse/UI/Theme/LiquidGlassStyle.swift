import SwiftUI
import AppKit

// MARK: - macOS 27 Adaptive Liquid Glass Theme (Light & Dark Mode)

public enum LiquidTheme {
    public static let mintGreen = Color.green
    public static let cyanVolt = Color.cyan
    public static let amberWarning = Color.orange
    public static let crimsonAlert = Color.red
    public static let purpleMac = Color.purple

    /// High-contrast emerald green for AC power / normal status
    public static func emerald(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.22, green: 0.86, blue: 0.48)
            : Color(red: 0.05, green: 0.58, blue: 0.27)
    }

    /// High-contrast cyan-blue for voltage & power telemetry
    public static func cyan(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.28, green: 0.82, blue: 0.98)
            : Color(red: 0.00, green: 0.48, blue: 0.80)
    }

    /// High-contrast amber-orange for battery / warning status
    public static func amber(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.00, green: 0.65, blue: 0.16)
            : Color(red: 0.84, green: 0.43, blue: 0.00)
    }

    /// High-contrast crimson-red for critical alerts
    public static func crimson(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.00, green: 0.34, blue: 0.34)
            : Color(red: 0.82, green: 0.14, blue: 0.18)
    }

    /// Subtle capsule/pill button fill that stays visible in both Light and Dark mode
    public static func pillBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }
}

/// Always-active AppKit VisualEffectView backdrop that follows the system appearance (Light / Dark)
/// while keeping `state = .active` so the popover is immediately "solid" (实) on first click.
public struct ActiveLiquidGlassBackdrop: NSViewRepresentable {
    public var colorScheme: ColorScheme

    public init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        // Native macOS popover material perfectly aligns with the NSPopover frame & arrow in both Light and Dark mode
        view.appearance = nil
        view.material = .popover
    }
}

/// Native macOS 27 Liquid Glass Card Modifier with Adaptive Light/Dark Optical Depth
public struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 14
    var isInteractive: Bool = false
    var tintColor: Color? = nil

    public func body(content: Content) -> some View {
        let baseGlass: Glass = {
            var g = Glass.regular
            if let tintColor {
                g = g.tint(tintColor)
            }
            if isInteractive {
                g = g.interactive(true)
            }
            return g
        }()

        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(cardFillGradient)
            )
            .glassEffect(baseGlass, in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(cardBorderGradient, lineWidth: colorScheme == .dark ? 0.75 : 0.8)
            )
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.28)
                    : Color(red: 0.08, green: 0.12, blue: 0.20).opacity(0.06),
                radius: colorScheme == .dark ? 6 : 5,
                x: 0,
                y: 2
            )
    }

    private var cardFillGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.20, blue: 0.25).opacity(0.80),
                    Color(red: 0.13, green: 0.14, blue: 0.18).opacity(0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.92),
                    Color(red: 0.98, green: 0.99, blue: 1.00).opacity(0.86)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var cardBorderGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.24),
                    Color.white.opacity(0.11),
                    Color.white.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.black.opacity(0.07),
                    Color.black.opacity(0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// Native macOS System Settings Grouped Inset Container (Adaptive Light & Dark Mode)
public struct NativeGroupedGroupBoxModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 11

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.16, green: 0.18, blue: 0.23).opacity(0.84)
                            : Color.white.opacity(0.90)
                    )
            )
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.16)
                            : Color.black.opacity(0.08),
                        lineWidth: 0.7
                    )
            )
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.22)
                    : Color.black.opacity(0.04),
                radius: 4,
                x: 0,
                y: 1.5
            )
    }
}

/// Adaptive Panel Substrate Modifier: follows macOS Light / Dark mode automatically
private struct ActiveLiquidPanelSubstrateModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    ActiveLiquidGlassBackdrop(colorScheme: colorScheme)

                    if colorScheme == .dark {
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 0.10, green: 0.11, blue: 0.15).opacity(0.10), location: 0.0),
                                .init(color: Color(red: 0.10, green: 0.11, blue: 0.15).opacity(0.55), location: 0.10),
                                .init(color: Color(red: 0.07, green: 0.08, blue: 0.11).opacity(0.80), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        RadialGradient(
                            colors: [
                                Color(red: 0.20, green: 0.55, blue: 0.95).opacity(0.06),
                                Color.clear
                            ],
                            center: .topLeading,
                            startRadius: 20,
                            endRadius: 280
                        )
                    } else {
                        LinearGradient(
                            colors: [
                                Color(red: 0.94, green: 0.95, blue: 0.97).opacity(0.86),
                                Color(red: 0.90, green: 0.92, blue: 0.95).opacity(0.90)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            )
            .environment(\.controlActiveState, .key)
    }
}

public struct LiquidGlassTheme: Sendable {
    public let colorScheme: ColorScheme
    public var isLight: Bool { colorScheme != .dark }

    public init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public var primaryText: Color {
        colorScheme == .dark ? Color.white : Color(red: 0.08, green: 0.10, blue: 0.14)
    }

    public var secondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.65) : Color(red: 0.32, green: 0.36, blue: 0.44)
    }

    public var dividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    public var cardFill: Color {
        colorScheme == .dark
            ? Color(red: 0.15, green: 0.17, blue: 0.22).opacity(0.84)
            : Color.white.opacity(0.90)
    }

    public var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.09)
    }

    public var pillFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05)
    }

    public var gaugeTrack: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    public func backdropGradientColors(isAC: Bool = true) -> [Color] {
        if colorScheme == .dark {
            return [Color(red: 0.07, green: 0.09, blue: 0.13), Color(red: 0.05, green: 0.06, blue: 0.09)]
        } else {
            return [Color(red: 0.94, green: 0.96, blue: 0.98), Color(red: 0.89, green: 0.92, blue: 0.96)]
        }
    }
}

public extension View {
    func liquidGlassCard(cornerRadius: CGFloat = 14, isInteractive: Bool = false, tint: Color? = nil) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, isInteractive: isInteractive, tintColor: tint))
    }

    func nativeSettingsGroup(cornerRadius: CGFloat = 11) -> some View {
        modifier(NativeGroupedGroupBoxModifier(cornerRadius: cornerRadius))
    }

    /// Applies the always-active adaptive Light/Dark Liquid Glass substrate to a panel view.
    func activeLiquidPanelSubstrate() -> some View {
        modifier(ActiveLiquidPanelSubstrateModifier())
    }

    /// 鼠标悬停时切换为手指光标
    func pointingHandOnHover() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

// MARK: - 手指光标视图修饰符

public struct PointingHandCursorModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .pointerStyle(.link)
        } else {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        NSCursor.pointingHand.set()
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
        }
    }
}
