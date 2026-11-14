import AppKit
import QuartzCore
import SwiftUI

// MARK: - 菜单栏健康度白兔动画视图

public struct MenuBarHealthRabbitView: View {
    public let rating: HealthRating
    public var size: CGFloat = 72

    @Environment(\.colorScheme) private var colorScheme

    public init(rating: HealthRating, size: CGFloat = 72) {
        self.rating = rating
        self.size = size
    }

    public var body: some View {
        MenuBarHealthRabbitCAView(rating: rating, isDark: colorScheme == .dark)
            .frame(width: size, height: size)
            .accessibilityLabel("系统健康小兔：\(rating.rawValue)")
    }
}

private struct MenuBarHealthRabbitCAView: NSViewRepresentable, Equatable {
    let rating: HealthRating
    let isDark: Bool

    nonisolated static func == (lhs: MenuBarHealthRabbitCAView, rhs: MenuBarHealthRabbitCAView) -> Bool {
        lhs.rating == rhs.rating && lhs.isDark == rhs.isDark
    }

    func makeNSView(context: Context) -> MenuBarHealthRabbitNSView {
        let view = MenuBarHealthRabbitNSView()
        view.configure(rating: rating, isDark: isDark)
        return view
    }

    func updateNSView(_ nsView: MenuBarHealthRabbitNSView, context: Context) {
        nsView.configure(rating: rating, isDark: isDark)
    }
}

/// 基于 CoreAnimation 预渲染位图的健康度白兔动画视图（30fps 合成，无 SwiftUI Canvas 重绘）
private final class MenuBarHealthRabbitNSView: NSView {
    private static let designWidth: CGFloat = 464.0
    private static let designHeight: CGFloat = 484.0
    private static let bitmapScale: CGFloat = 0.5 // 232x242 px over ~72pt widget (>1.6x Retina supersampling)

    private struct SpriteSet {
        let aura: CGImage?
        let ripple1: CGImage?
        let ripple2: CGImage?
        let orbit: CGImage?
        let particles: [(cx: CGFloat, cy: CGFloat, rect: CGRect, image: CGImage?)]
        let backEar: CGImage?
        let torso: CGImage?
        let tail: CGImage?
        let eye: CGImage?
        let frontEar: CGImage?
        let paw: CGImage?
    }

    private static var spriteCache: [String: SpriteSet] = [:]

    private let sceneLayer = CALayer()
    private var currentRating: HealthRating?
    private var currentIsDark: Bool?

    // Animated Layer References (all bitmap-backed CALayers or zero-backing pivot containers)
    private var auraLayer = CALayer()
    private var ripple1Layer = CALayer()
    private var ripple2Layer = CALayer()
    private var orbitLayer = CALayer()
    private var particleLayers: [CALayer] = []

    private var rabbitRootLayer = CALayer()
    private var backEarLayer = CALayer()
    private var tailLayer = CALayer()
    private var frontEarLayer = CALayer()
    private var pawLayer = CALayer()
    private var eyeLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupScene()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScene()
    }

    private func setupScene() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Standard CoreAnimation bottom-up coordinates (y=0 bottom, y=designHeight top)
        sceneLayer.bounds = CGRect(x: 0, y: 0, width: Self.designWidth, height: Self.designHeight)
        sceneLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(sceneLayer)
    }

    override func layout() {
        super.layout()
        let scale = min(bounds.width / Self.designWidth, bounds.height / Self.designHeight)
        guard scale > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sceneLayer.position = CGPoint(
            x: bounds.width * 0.5 - 24.0 * scale,
            y: bounds.height * 0.5 + 12.0 * scale
        )
        sceneLayer.transform = CATransform3DMakeScale(scale, scale, 1.0)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            attachAnimations()
        } else {
            removeAnimationsRecursively(layer: sceneLayer)
        }
    }

    func configure(rating: HealthRating, isDark: Bool) {
        if currentRating == rating && currentIsDark == isDark {
            return
        }
        currentRating = rating
        currentIsDark = isDark
        rebuildLayers(rating: rating, isDark: isDark)
        if window != nil {
            attachAnimations()
        }
    }

    // MARK: - Layer Construction (Zero CAShapeLayers; Cached Sprite Textures Only)

    private func rebuildLayers(rating: HealthRating, isDark: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        sceneLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        particleLayers.removeAll(keepingCapacity: true)

        let sprites = Self.cachedSprites(for: rating, isDark: isDark)
        let ringCenter = CGPoint(x: 256.0, y: Self.designHeight - 260.0)

        // Layer 1: Pre-rendered Radial Aura
        auraLayer = makeCenteredSpriteLayer(
            size: CGSize(width: 470, height: 470),
            position: ringCenter,
            image: sprites.aura
        )
        sceneLayer.addSublayer(auraLayer)

        // Layer 2: Staggered Dual Sonar Ripples (bitmap rings)
        ripple1Layer = makeCenteredSpriteLayer(
            size: CGSize(width: 360, height: 360),
            position: ringCenter,
            image: sprites.ripple1
        )
        ripple1Layer.opacity = 0.0
        sceneLayer.addSublayer(ripple1Layer)

        ripple2Layer = makeCenteredSpriteLayer(
            size: CGSize(width: 360, height: 360),
            position: ringCenter,
            image: sprites.ripple2
        )
        ripple2Layer.opacity = 0.0
        sceneLayer.addSublayer(ripple2Layer)

        // Layer 3: Rotating 3-Fold Orbital Arc (bitmap ring)
        orbitLayer = makeCenteredSpriteLayer(
            size: CGSize(width: 436, height: 436),
            position: ringCenter,
            image: sprites.orbit
        )
        sceneLayer.addSublayer(orbitLayer)

        // Layer 4: Tier-Specific Particles (tight bitmap sprites)
        for p in sprites.particles {
            let pLayer = makePivotSpriteLayer(srcRect: p.rect, cx: p.cx, cy: p.cy, image: p.image)
            particleLayers.append(pLayer)
            sceneLayer.addSublayer(pLayer)
        }

        // Layer 5: Articulated White Rabbit (zero-backing pivot + tight cropped sprite sublayers)
        let rootPivotY: CGFloat = 472.0
        rabbitRootLayer = CALayer()
        rabbitRootLayer.bounds = CGRect(x: 0, y: 0, width: Self.designWidth, height: Self.designHeight)
        rabbitRootLayer.anchorPoint = CGPoint(
            x: 280.0 / Self.designWidth,
            y: (Self.designHeight - rootPivotY) / Self.designHeight
        )
        rabbitRootLayer.position = CGPoint(x: 280.0, y: Self.designHeight - rootPivotY)

        backEarLayer = makePivotSpriteLayer(
            srcRect: Self.backEarRect, cx: 286, cy: 66, image: sprites.backEar
        )
        rabbitRootLayer.addSublayer(backEarLayer)

        let torsoLayer = makeCenteredSpriteLayer(
            size: Self.torsoRect.size,
            position: CGPoint(x: Self.torsoRect.midX, y: Self.designHeight - Self.torsoRect.midY),
            image: sprites.torso
        )
        rabbitRootLayer.addSublayer(torsoLayer)

        tailLayer = makePivotSpriteLayer(
            srcRect: Self.tailRect, cx: 162, cy: 377, image: sprites.tail
        )
        rabbitRootLayer.addSublayer(tailLayer)

        eyeLayer = makePivotSpriteLayer(
            srcRect: Self.eyeRect, cx: 332, cy: 81, image: sprites.eye
        )
        rabbitRootLayer.addSublayer(eyeLayer)

        frontEarLayer = makePivotSpriteLayer(
            srcRect: Self.frontEarRect, cx: 266, cy: 112, image: sprites.frontEar
        )
        rabbitRootLayer.addSublayer(frontEarLayer)

        pawLayer = makePivotSpriteLayer(
            srcRect: Self.pawRect, cx: 368, cy: 232, image: sprites.paw
        )
        rabbitRootLayer.addSublayer(pawLayer)

        sceneLayer.addSublayer(rabbitRootLayer)
        CATransaction.commit()
    }

    // MARK: - GPU CoreAnimation Schedules (Capped 30fps Ambient Cadence)

    private func attachAnimations() {
        guard let rating = currentRating else { return }
        removeAnimationsRecursively(layer: sceneLayer)

        let bgCycle = Self.backgroundCycleSeconds(for: rating)
        let ambientRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)

        // 1. Aura Breathe
        let auraScale = CABasicAnimation(keyPath: "transform.scale")
        auraScale.fromValue = 0.84
        auraScale.toValue = 1.20
        auraScale.duration = bgCycle * 0.5
        auraScale.autoreverses = true
        auraScale.repeatCount = .infinity
        auraScale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        auraScale.preferredFrameRateRange = ambientRange
        auraLayer.add(auraScale, forKey: "auraBreathe")

        // 2. Dual Sonar Ripples
        ripple1Layer.add(makeRippleAnimation(duration: bgCycle, maxAlpha: 0.90, timeOffset: 0, rateRange: ambientRange), forKey: "sonar1")
        ripple2Layer.add(makeRippleAnimation(duration: bgCycle, maxAlpha: 0.74, timeOffset: bgCycle * 0.5, rateRange: ambientRange), forKey: "sonar2")

        // 3. Orbital Arc Rotation
        let degPerCycle: Double = {
            switch rating {
            case .excellent, .fair: return 240.0
            case .good: return 120.0
            case .needsAttention: return 360.0
            }
        }()
        let orbitRot = CABasicAnimation(keyPath: "transform.rotation.z")
        orbitRot.fromValue = 0.0
        orbitRot.toValue = -CGFloat.pi * 2.0
        orbitRot.duration = bgCycle * (360.0 / degPerCycle)
        orbitRot.repeatCount = .infinity
        orbitRot.preferredFrameRateRange = ambientRange
        orbitLayer.add(orbitRot, forKey: "orbitSpin")

        // 4. Particles Float & Pulse
        for (idx, pLayer) in particleLayers.enumerated() {
            let group = CAAnimationGroup()
            group.duration = bgCycle * (0.9 + Double(idx) * 0.12)
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timeOffset = Double(idx) * 0.35
            group.preferredFrameRateRange = ambientRange

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.72
            scale.toValue = 1.18
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let floatY = CABasicAnimation(keyPath: "transform.translation.y")
            floatY.fromValue = -8.0
            floatY.toValue = 14.0
            floatY.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            group.animations = [scale, floatY]
            pLayer.add(group, forKey: "particlePulse")
        }

        // 5. Rabbit Breathing & Hop
        let breathPeriod: Double = {
            switch rating {
            case .excellent: return 2.6
            case .good: return 3.0
            case .fair: return 2.3
            case .needsAttention: return 1.8
            }
        }()

        let breathe = CABasicAnimation(keyPath: "transform.scale.y")
        breathe.fromValue = 1.0
        breathe.toValue = 1.014
        breathe.duration = breathPeriod * 0.5
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.preferredFrameRateRange = ambientRange
        rabbitRootLayer.add(breathe, forKey: "rabbitBreathe")

        let hopY = CAKeyframeAnimation(keyPath: "position.y")
        let baseY: CGFloat = Self.designHeight - 472.0
        let hopAmp: CGFloat = rating == .excellent ? 8.5 : (rating == .needsAttention ? 4.5 : 3.5)
        hopY.values = [baseY, baseY, baseY - 1.5, baseY + hopAmp, baseY, baseY]
        hopY.keyTimes = [0.0, 0.27, 0.31, 0.42, 0.56, 1.0]
        hopY.duration = 5.6
        hopY.repeatCount = .infinity
        hopY.calculationMode = .cubic
        hopY.preferredFrameRateRange = ambientRange
        rabbitRootLayer.add(hopY, forKey: "rabbitHop")

        // 6. Ear Flicks
        let earRotF = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        earRotF.values = [0.0, 0.12, -0.03, 0.05, 0.0, 0.07, 0.0]
        earRotF.keyTimes = [0.0, 0.09, 0.13, 0.17, 0.24, 0.42, 1.0]
        earRotF.duration = 5.6
        earRotF.repeatCount = .infinity
        earRotF.preferredFrameRateRange = ambientRange
        frontEarLayer.add(earRotF, forKey: "frontEarFlick")

        let earRotB = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        earRotB.values = [0.0, 0.0, 0.08, -0.02, 0.0, -0.09, 0.0]
        earRotB.keyTimes = [0.0, 0.10, 0.15, 0.21, 0.85, 0.90, 1.0]
        earRotB.duration = 5.6
        earRotB.repeatCount = .infinity
        earRotB.preferredFrameRateRange = ambientRange
        backEarLayer.add(earRotB, forKey: "backEarFlick")

        // 7. Paw Wave
        let pawRot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        pawRot.values = [0.0, 0.0, -0.04, 0.20, 0.08, 0.20, 0.0, 0.0]
        pawRot.keyTimes = [0.0, 0.26, 0.30, 0.37, 0.42, 0.47, 0.54, 1.0]
        pawRot.duration = 5.6
        pawRot.repeatCount = .infinity
        pawRot.preferredFrameRateRange = ambientRange
        pawLayer.add(pawRot, forKey: "pawWave")

        // 8. Tail Wag
        let tailRot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        tailRot.values = [0.0, 0.0, -0.08, 0.08, -0.07, 0.0, 0.0]
        tailRot.keyTimes = [0.0, 0.32, 0.37, 0.42, 0.47, 0.54, 1.0]
        tailRot.duration = 5.6
        tailRot.repeatCount = .infinity
        tailRot.preferredFrameRateRange = ambientRange
        tailLayer.add(tailRot, forKey: "tailWag")

        // 9. Eye Blink
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1.0, 1.0, 0.12, 1.0, 1.0, 0.12, 1.0, 1.0]
        blink.keyTimes = [0.0, 0.21, 0.23, 0.25, 0.77, 0.79, 0.81, 1.0]
        blink.duration = 5.6
        blink.repeatCount = .infinity
        blink.preferredFrameRateRange = ambientRange
        eyeLayer.add(blink, forKey: "eyeBlink")
    }

    private func makeRippleAnimation(
        duration: Double,
        maxAlpha: Double,
        timeOffset: Double,
        rateRange: CAFrameRateRange
    ) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.duration = duration
        group.repeatCount = .infinity
        group.timeOffset = timeOffset
        group.preferredFrameRateRange = rateRange

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.72
        scale.toValue = 1.42
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let alpha = CAKeyframeAnimation(keyPath: "opacity")
        alpha.values = [0.0, maxAlpha, maxAlpha * 0.48, 0.0]
        alpha.keyTimes = [0.0, 0.16, 0.56, 1.0]

        group.animations = [scale, alpha]
        return group
    }

    // MARK: - Layer & Sprite Helpers

    private func makeCenteredSpriteLayer(size: CGSize, position: CGPoint, image: CGImage?) -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(origin: .zero, size: size)
        l.position = position
        l.contents = image
        l.contentsGravity = .resize
        return l
    }

    private func makePivotSpriteLayer(srcRect: CGRect, cx: CGFloat, cy: CGFloat, image: CGImage?) -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(origin: .zero, size: srcRect.size)
        l.anchorPoint = CGPoint(
            x: (cx - srcRect.minX) / srcRect.width,
            y: (srcRect.maxY - cy) / srcRect.height
        )
        l.position = CGPoint(x: cx, y: Self.designHeight - cy)
        l.contents = image
        l.contentsGravity = .resize
        return l
    }

    private func removeAnimationsRecursively(layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach { removeAnimationsRecursively(layer: $0) }
    }

    // Tight crop rects in 464x484 design coordinates
    private static let backEarRect = CGRect(x: 114, y: 38, width: 204, height: 94)
    private static let torsoRect = CGRect(x: 114, y: 28, width: 328, height: 456)
    private static let tailRect = CGRect(x: 70, y: 316, width: 122, height: 122)
    private static let eyeRect = CGRect(x: 314, y: 63, width: 36, height: 36)
    private static let frontEarRect = CGRect(x: 100, y: 50, width: 192, height: 162)
    private static let pawRect = CGRect(x: 316, y: 212, width: 108, height: 190)

    // MARK: - Pre-Rendered Bitmap Sprite Cache

    private static func cachedSprites(for rating: HealthRating, isDark: Bool) -> SpriteSet {
        let key = "\(rating.rawValue)_\(isDark)"
        if let existing = spriteCache[key] {
            return existing
        }

        let accent = accentNSColor(for: rating, isDark: isDark)
        let strokeColor = isDark
            ? NSColor(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0, alpha: 1.0).cgColor
            : NSColor(red: 30.0 / 255.0, green: 41.0 / 255.0, blue: 59.0 / 255.0, alpha: 1.0).cgColor
        let pinkEar = NSColor(red: 253.0 / 255.0, green: 164.0 / 255.0, blue: 175.0 / 255.0, alpha: 1.0)
        let backEarFur = NSColor(red: 248.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0, alpha: 1.0).cgColor
        let white = NSColor.white.cgColor

        let aura = renderAuraImage(accent: accent, isDark: isDark)

        let ripple1 = renderDesignBitmap(srcRect: CGRect(x: 0, y: 0, width: 360, height: 360)) { ctx in
            ctx.setStrokeColor(accent.withAlphaComponent(0.90).cgColor)
            ctx.setLineWidth(18.0)
            ctx.strokeEllipse(in: CGRect(x: 15, y: 15, width: 330, height: 330))
        }
        let ripple2 = renderDesignBitmap(srcRect: CGRect(x: 0, y: 0, width: 360, height: 360)) { ctx in
            ctx.setStrokeColor(accent.withAlphaComponent(0.74).cgColor)
            ctx.setLineWidth(14.0)
            ctx.strokeEllipse(in: CGRect(x: 15, y: 15, width: 330, height: 330))
        }
        let orbit = renderDesignBitmap(srcRect: CGRect(x: 0, y: 0, width: 436, height: 436)) { ctx in
            ctx.setStrokeColor(accent.withAlphaComponent(0.78).cgColor)
            ctx.setLineWidth(15.0)
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [172, 255.26])
            ctx.strokeEllipse(in: CGRect(x: 14, y: 14, width: 408, height: 408))
        }

        let particles = buildParticleSprites(for: rating, accent: accent)

        let backEar = renderDesignBitmap(srcRect: backEarRect) { ctx in
            ctx.setFillColor(strokeColor)
            ctx.addPath(RabbitPaths.backEarSolid)
            ctx.fillPath()
            ctx.setFillColor(backEarFur)
            ctx.addPath(RabbitPaths.backEarFill)
            ctx.fillPath()
        }

        let torso = renderDesignBitmap(srcRect: torsoRect) { ctx in
            ctx.setFillColor(strokeColor)
            ctx.addPath(RabbitPaths.bodySolidTorso)
            ctx.fillPath()
            ctx.setFillColor(white)
            ctx.addPath(RabbitPaths.bodyFillTorso)
            ctx.fillPath()
            ctx.setFillColor(strokeColor)
            ctx.addPath(RabbitPaths.noseTip)
            ctx.fillPath()

            ctx.setStrokeColor(strokeColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(6.5)
            ctx.addPath(RabbitPaths.mouthMain)
            ctx.strokePath()

            ctx.setLineJoin(.miter)
            ctx.setLineWidth(5.5)
            ctx.addPath(RabbitPaths.mouthDimple)
            ctx.strokePath()
        }

        let tail = renderDesignBitmap(srcRect: tailRect) { ctx in
            ctx.setFillColor(strokeColor)
            ctx.addPath(RabbitPaths.tailSolid)
            ctx.fillPath()
            ctx.setFillColor(white)
            ctx.addPath(RabbitPaths.tailFill)
            ctx.fillPath()
        }

        let eye = renderDesignBitmap(srcRect: eyeRect) { ctx in
            ctx.setFillColor(strokeColor)
            ctx.fillEllipse(in: CGRect(x: 332 - 12.5, y: 81 - 12.5, width: 25, height: 25))
            ctx.setFillColor(white)
            ctx.fillEllipse(in: CGRect(x: 336 - 4.0, y: 76 - 4.0, width: 8, height: 8))
        }

        let frontEar = renderDesignBitmap(srcRect: frontEarRect) { ctx in
            ctx.setFillColor(white)
            ctx.addPath(RabbitPaths.frontEarInnerBridge)
            ctx.fillPath()
            ctx.setFillColor(pinkEar.withAlphaComponent(0.45).cgColor)
            ctx.addPath(RabbitPaths.frontEarPink)
            ctx.fillPath()
            ctx.setStrokeColor(strokeColor)
            ctx.setLineWidth(17.5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(RabbitPaths.frontEarOpenStroke)
            ctx.strokePath()
        }

        let paw = renderDesignBitmap(srcRect: pawRect) { ctx in
            ctx.setFillColor(white)
            ctx.addPath(RabbitPaths.pawInnerBridge)
            ctx.fillPath()

            ctx.saveGState()
            ctx.translateBy(x: 386, y: 356)
            ctx.rotate(by: -12.0 * .pi / 180.0)
            ctx.setFillColor(pinkEar.withAlphaComponent(0.46).cgColor)
            ctx.fillEllipse(in: CGRect(x: -6.5, y: -10.5, width: 13, height: 21))
            ctx.restoreGState()

            ctx.setStrokeColor(strokeColor)
            ctx.setLineWidth(17.5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(RabbitPaths.pawOpenStroke)
            ctx.strokePath()
        }

        let set = SpriteSet(
            aura: aura,
            ripple1: ripple1,
            ripple2: ripple2,
            orbit: orbit,
            particles: particles,
            backEar: backEar,
            torso: torso,
            tail: tail,
            eye: eye,
            frontEar: frontEar,
            paw: paw
        )
        spriteCache[key] = set
        return set
    }

    private static func buildParticleSprites(
        for rating: HealthRating,
        accent: NSColor
    ) -> [(cx: CGFloat, cy: CGFloat, rect: CGRect, image: CGImage?)] {
        switch rating {
        case .excellent:
            let r1 = CGRect(x: 392, y: 32, width: 92, height: 92)
            let i1 = renderDesignBitmap(srcRect: r1) { ctx in
                ctx.setFillColor(accent.cgColor)
                ctx.addPath(RabbitPaths.star1Outer)
                ctx.fillPath()
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.90).cgColor)
                ctx.addPath(RabbitPaths.star1Inner)
                ctx.fillPath()
            }
            let r2 = CGRect(x: 38, y: 24, width: 76, height: 76)
            let i2 = renderDesignBitmap(srcRect: r2) { ctx in
                ctx.setFillColor(accent.withAlphaComponent(0.92).cgColor)
                ctx.addPath(RabbitPaths.star2Outer)
                ctx.fillPath()
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
                ctx.addPath(RabbitPaths.star2Inner)
                ctx.fillPath()
            }
            let r3 = CGRect(x: 420, y: 216, width: 68, height: 68)
            let i3 = renderDesignBitmap(srcRect: r3) { ctx in
                ctx.setFillColor(accent.withAlphaComponent(0.88).cgColor)
                ctx.addPath(RabbitPaths.star3Outer)
                ctx.fillPath()
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                ctx.addPath(RabbitPaths.star3Inner)
                ctx.fillPath()
            }
            return [(438, 78, r1, i1), (76, 62, r2, i2), (454, 250, r3, i3)]

        case .good:
            let r1 = CGRect(x: 408, y: 67, width: 56, height: 56)
            let i1 = renderDesignBitmap(srcRect: r1) { ctx in
                ctx.setFillColor(accent.withAlphaComponent(0.86).cgColor)
                ctx.fillEllipse(in: CGRect(x: 436 - 24, y: 95 - 24, width: 48, height: 48))
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
                ctx.fillEllipse(in: CGRect(x: 429 - 8, y: 88 - 8, width: 16, height: 16))
            }
            let r2 = CGRect(x: 55, y: 152, width: 46, height: 46)
            let i2 = renderDesignBitmap(srcRect: r2) { ctx in
                ctx.setFillColor(accent.withAlphaComponent(0.82).cgColor)
                ctx.fillEllipse(in: CGRect(x: 78 - 19, y: 175 - 19, width: 38, height: 38))
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                ctx.fillEllipse(in: CGRect(x: 72 - 6.5, y: 169 - 6.5, width: 13, height: 13))
            }
            let r3 = CGRect(x: 425, y: 245, width: 40, height: 40)
            let i3 = renderDesignBitmap(srcRect: r3) { ctx in
                ctx.setFillColor(accent.withAlphaComponent(0.78).cgColor)
                ctx.fillEllipse(in: CGRect(x: 445 - 16, y: 265 - 16, width: 32, height: 32))
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.82).cgColor)
                ctx.fillEllipse(in: CGRect(x: 440 - 5.5, y: 260 - 5.5, width: 11, height: 11))
            }
            return [(436, 95, r1, i1), (78, 175, r2, i2), (445, 265, r3, i3)]

        case .fair:
            let r1 = CGRect(x: 406, y: 50, width: 64, height: 64)
            let i1 = renderDesignBitmap(srcRect: r1) { ctx in
                ctx.setFillColor(accent.withAlphaComponent(0.28).cgColor)
                ctx.fillEllipse(in: CGRect(x: 438 - 28, y: 82 - 28, width: 56, height: 56))
                ctx.setFillColor(accent.withAlphaComponent(0.95).cgColor)
                ctx.fillEllipse(in: CGRect(x: 438 - 20, y: 82 - 20, width: 40, height: 40))
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
                ctx.fillEllipse(in: CGRect(x: 438 - 7, y: 82 - 7, width: 14, height: 14))
            }
            let r2 = CGRect(x: 48, y: 129, width: 52, height: 52)
            let i2 = renderDesignBitmap(srcRect: r2) { ctx in
                ctx.setFillColor(accent.withAlphaComponent(0.28).cgColor)
                ctx.fillEllipse(in: CGRect(x: 74 - 22, y: 155 - 22, width: 44, height: 44))
                ctx.setFillColor(accent.withAlphaComponent(0.92).cgColor)
                ctx.fillEllipse(in: CGRect(x: 74 - 15, y: 155 - 15, width: 30, height: 30))
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.90).cgColor)
                ctx.fillEllipse(in: CGRect(x: 74 - 5.5, y: 155 - 5.5, width: 11, height: 11))
            }
            return [(438, 82, r1, i1), (74, 155, r2, i2)]

        case .needsAttention:
            let r1 = CGRect(x: 400, y: 22, width: 72, height: 130)
            let i1 = renderDesignBitmap(srcRect: r1) { ctx in
                ctx.setFillColor(accent.cgColor)
                ctx.addPath(RabbitPaths.boltOuter)
                ctx.fillPath()
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.58).cgColor)
                ctx.addPath(RabbitPaths.boltInner)
                ctx.fillPath()
            }
            let r2 = CGRect(x: 48, y: 122, width: 56, height: 56)
            let i2 = renderDesignBitmap(srcRect: r2) { ctx in
                ctx.setFillColor(accent.cgColor)
                ctx.fillEllipse(in: CGRect(x: 76 - 24, y: 150 - 24, width: 48, height: 48))
                ctx.setFillColor(NSColor.white.cgColor)
                let barPath = CGPath(roundedRect: CGRect(x: 71.5, y: 135, width: 9, height: 16), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
                ctx.addPath(barPath)
                ctx.fillPath()
                ctx.fillEllipse(in: CGRect(x: 76 - 4.8, y: 160 - 4.8, width: 9.6, height: 9.6))
            }
            return [(436, 86, r1, i1), (76, 150, r2, i2)]
        }
    }

    private static func renderDesignBitmap(srcRect: CGRect, draw: (CGContext) -> Void) -> CGImage? {
        let pxW = max(2, Int(ceil(srcRect.width * bitmapScale)))
        let pxH = max(2, Int(ceil(srcRect.height * bitmapScale)))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: pxW,
                  height: pxH,
                  bitsPerComponent: 8,
                  bytesPerRow: pxW * 4,
                  space: cs,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }

        // Flip Y from bottom-left CGContext coords into flipped top-left design coords
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: bitmapScale, y: -bitmapScale)
        ctx.translateBy(x: -srcRect.minX, y: -srcRect.minY)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        draw(ctx)
        return ctx.makeImage()
    }

    private static func renderAuraImage(accent: NSColor, isDark: Bool) -> CGImage? {
        let dim = 96
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: dim,
                  height: dim,
                  bitsPerComponent: 8,
                  bytesPerRow: dim * 4,
                  space: cs,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }

        let boost0 = min(0.95, 0.78 * (isDark ? 1.0 : 0.85))
        let boost1 = min(0.65, 0.42 * (isDark ? 1.0 : 0.82))
        let c0 = accent.withAlphaComponent(boost0).cgColor
        let c1 = accent.withAlphaComponent(boost1).cgColor
        let c2 = accent.withAlphaComponent(0.0).cgColor
        let locations: [CGFloat] = [0.0, 0.55, 1.0]

        if let grad = CGGradient(colorsSpace: cs, colors: [c0, c1, c2] as CFArray, locations: locations) {
            let center = CGPoint(x: CGFloat(dim) * 0.5, y: CGFloat(dim) * 0.5)
            ctx.drawRadialGradient(
                grad,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: CGFloat(dim) * 0.5,
                options: [.drawsAfterEndLocation]
            )
        }

        return ctx.makeImage()
    }

    private static func backgroundCycleSeconds(for rating: HealthRating) -> Double {
        switch rating {
        case .excellent: return 1.80
        case .good: return 2.60
        case .fair: return 1.60
        case .needsAttention: return 1.15
        }
    }

    private static func accentNSColor(for rating: HealthRating, isDark: Bool) -> NSColor {
        switch (rating, isDark) {
        case (.excellent, true):
            return NSColor(red: 56.0 / 255.0, green: 229.0 / 255.0, blue: 148.0 / 255.0, alpha: 1.0)
        case (.excellent, false):
            return NSColor(red: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0, alpha: 1.0)
        case (.good, true):
            return NSColor(red: 56.0 / 255.0, green: 189.0 / 255.0, blue: 248.0 / 255.0, alpha: 1.0)
        case (.good, false):
            return NSColor(red: 2.0 / 255.0, green: 132.0 / 255.0, blue: 199.0 / 255.0, alpha: 1.0)
        case (.fair, true):
            return NSColor(red: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0, alpha: 1.0)
        case (.fair, false):
            return NSColor(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0, alpha: 1.0)
        case (.needsAttention, true):
            return NSColor(red: 248.0 / 255.0, green: 113.0 / 255.0, blue: 113.0 / 255.0, alpha: 1.0)
        case (.needsAttention, false):
            return NSColor(red: 220.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0, alpha: 1.0)
        }
    }
}

// MARK: - 预解析纯矢量 CGPath + 轻量化 SVG Path Parser

@MainActor
private enum RabbitPaths {
    static let backEarSolid = parseSVGPath("M 295.5 45.0 Q 299.0 43.0 303.0 47.0 Q 307.0 51.0 309.0 58.5 Q 311.0 66.0 309.0 73.5 Q 307.0 81.0 300.0 87.5 Q 293.0 94.0 286.5 95.5 Q 280.0 97.0 273.5 95.5 Q 267.0 94.0 264.0 92.0 Q 261.0 90.0 256.0 93.5 Q 251.0 97.0 222.5 101.0 Q 194.0 105.0 179.0 109.5 Q 164.0 114.0 153.0 119.5 Q 142.0 125.0 136.0 124.5 Q 130.0 124.0 127.0 122.5 Q 124.0 121.0 122.0 117.5 Q 120.0 114.0 121.5 102.5 Q 123.0 91.0 125.5 86.0 Q 128.0 81.0 133.0 75.5 Q 138.0 70.0 148.0 64.0 Q 158.0 58.0 166.5 55.0 Q 175.0 52.0 190.5 49.0 Q 206.0 46.0 232.5 45.0 Q 259.0 44.0 275.5 45.5 Q 292.0 47.0 295.5 45.0 Z")
    static let backEarFill = parseSVGPath("M 208.5 62.5 Q 230.0 60.0 249.0 60.5 Q 268.0 61.0 257.0 71.0 Q 246.0 81.0 227.5 83.0 Q 209.0 85.0 188.0 90.0 Q 167.0 95.0 151.5 102.0 Q 136.0 109.0 138.5 100.0 Q 141.0 91.0 149.0 83.5 Q 157.0 76.0 172.0 70.5 Q 187.0 65.0 208.5 62.5 Z")

    static let bodySolidTorso = parseSVGPath("M 320.5 36.0 Q 336.0 32.0 351.5 33.0 Q 367.0 34.0 383.0 40.5 Q 399.0 47.0 405.0 51.0 Q 411.0 55.0 417.5 61.5 Q 424.0 68.0 429.5 79.5 Q 435.0 91.0 435.5 103.0 Q 436.0 115.0 431.5 130.0 Q 427.0 145.0 417.0 162.0 Q 407.0 179.0 396.0 192.5 Q 385.0 206.0 382.0 250.0 Q 379.0 302.0 366.0 355.0 Q 358.0 388.0 352.0 404.0 Q 346.0 415.0 360.0 418.0 Q 374.0 421.0 378.0 423.0 Q 382.0 425.0 385.5 428.5 Q 389.0 432.0 391.0 438.0 Q 393.0 444.0 391.5 448.5 Q 390.0 453.0 387.0 456.0 Q 384.0 459.0 377.5 462.5 Q 371.0 466.0 361.5 469.0 Q 352.0 472.0 333.0 475.0 Q 314.0 478.0 300.5 478.5 Q 287.0 479.0 264.0 478.0 Q 241.0 477.0 223.5 473.5 Q 206.0 470.0 191.0 464.0 Q 176.0 458.0 166.0 450.0 Q 156.0 442.0 153.0 437.5 Q 150.0 433.0 153.0 431.0 Q 156.0 429.0 156.0 377.0 Q 156.0 325.0 148.0 322.0 Q 140.0 319.0 130.0 319.0 Q 120.0 319.0 120.0 315.0 Q 120.0 311.0 127.5 293.0 Q 135.0 275.0 146.0 259.0 Q 157.0 243.0 165.5 234.5 Q 174.0 226.0 186.5 216.5 Q 199.0 207.0 205.5 206.5 Q 212.0 206.0 231.0 177.5 Q 250.0 149.0 262.0 97.5 Q 274.0 46.0 283.0 46.5 Q 292.0 47.0 298.5 43.5 Q 305.0 40.0 320.5 36.0 Z")
    static let bodyFillTorso = parseSVGPath("M 326.5 51.0 Q 339.0 48.0 352.0 49.0 Q 365.0 50.0 378.0 55.5 Q 391.0 61.0 399.5 67.5 Q 408.0 74.0 411.0 78.0 Q 414.0 82.0 417.0 89.5 Q 420.0 97.0 420.0 106.5 Q 420.0 116.0 417.0 125.5 Q 414.0 135.0 404.5 151.5 Q 395.0 168.0 381.5 185.0 Q 368.0 202.0 368.0 205.0 Q 368.0 208.0 365.0 252.0 Q 362.0 305.0 348.0 355.5 Q 345.0 358.0 344.5 370.0 Q 344.0 382.0 342.0 388.5 Q 340.0 395.0 335.0 402.0 Q 330.0 409.0 322.5 414.0 Q 315.0 419.0 315.0 422.5 Q 315.0 426.0 317.0 428.5 Q 319.0 431.0 330.0 431.0 Q 341.0 431.0 353.5 433.0 Q 366.0 435.0 370.0 437.0 Q 374.0 439.0 375.0 441.5 Q 376.0 444.0 370.0 448.0 Q 364.0 452.0 355.5 454.5 Q 347.0 457.0 324.5 459.5 Q 302.0 462.0 285.5 462.5 Q 269.0 463.0 249.5 461.0 Q 230.0 459.0 214.5 455.0 Q 199.0 451.0 192.0 448.0 Q 185.0 445.0 178.5 440.5 Q 172.0 436.0 167.0 428.0 Q 162.0 420.0 167.0 414.5 Q 172.0 409.0 176.5 401.0 Q 181.0 393.0 183.5 384.0 Q 186.0 375.0 185.5 364.5 Q 185.0 354.0 181.5 347.5 Q 178.0 341.0 172.5 336.0 Q 167.0 331.0 161.5 328.0 Q 156.0 325.0 145.0 322.5 Q 134.0 320.0 142.5 299.5 Q 151.0 279.0 159.0 267.5 Q 167.0 256.0 177.0 246.0 Q 187.0 236.0 206.5 220.5 Q 226.0 205.0 234.0 196.5 Q 242.0 188.0 249.5 177.5 Q 257.0 167.0 261.5 157.5 Q 266.0 148.0 266.0 145.5 Q 266.0 143.0 262.5 140.0 Q 259.0 137.0 255.0 138.5 Q 251.0 140.0 241.5 148.0 Q 232.0 156.0 238.5 140.5 Q 245.0 125.0 245.0 111.5 Q 245.0 98.0 250.0 97.0 Q 255.0 96.0 263.0 88.0 Q 271.0 80.0 283.0 71.5 Q 295.0 63.0 304.5 58.5 Q 314.0 54.0 326.5 51.0 Z")

    static let tailSolid = parseSVGPath("M 117.5 322.0 Q 120.0 320.0 129.5 320.0 Q 139.0 320.0 148.5 322.5 Q 158.0 325.0 163.5 328.0 Q 169.0 331.0 174.5 336.5 Q 180.0 342.0 182.5 347.0 Q 185.0 352.0 185.0 367.5 Q 185.0 383.0 182.0 391.5 Q 179.0 400.0 175.0 406.0 Q 171.0 412.0 165.0 418.0 Q 159.0 424.0 154.0 427.0 Q 149.0 430.0 145.5 430.0 Q 142.0 430.0 137.0 431.5 Q 132.0 433.0 127.5 433.0 Q 123.0 433.0 117.5 431.5 Q 112.0 430.0 106.5 427.0 Q 101.0 424.0 92.5 416.0 Q 84.0 408.0 80.0 398.5 Q 76.0 389.0 75.5 379.5 Q 75.0 370.0 79.0 358.0 Q 83.0 346.0 90.5 338.0 Q 98.0 330.0 103.0 327.5 Q 108.0 325.0 111.5 324.5 Q 115.0 324.0 117.5 322.0 Z")
    static let tailFill = parseSVGPath("M 113.0 341.0 Q 120.0 338.0 129.5 338.0 Q 139.0 338.0 144.5 339.5 Q 150.0 341.0 154.0 343.0 Q 158.0 345.0 162.0 349.0 Q 166.0 353.0 167.5 356.5 Q 169.0 360.0 169.0 366.5 Q 169.0 373.0 166.0 382.5 Q 163.0 392.0 160.0 396.5 Q 157.0 401.0 152.5 405.5 Q 148.0 410.0 144.0 412.0 Q 140.0 414.0 133.0 415.5 Q 126.0 417.0 119.0 414.5 Q 112.0 412.0 105.0 406.0 Q 98.0 400.0 95.0 394.0 Q 92.0 388.0 91.5 378.5 Q 91.0 369.0 94.0 361.5 Q 97.0 354.0 101.5 349.0 Q 106.0 344.0 113.0 341.0 Z")

    static let frontEarInnerBridge = parseSVGPath("M 280 74 C 256 88 225 90 190 96 C 148 104 122 128 122 156 C 122 182 152 194 188 182 C 224 170 254 148 278 134 Z")
    static let frontEarPink = parseSVGPath("M 140 162 Q 186 130 236 116 Q 210 156 154 176 Q 134 178 140 162 Z")
    static let frontEarOpenStroke = parseSVGPath("M 264 62 C 254 80 245 88 228 89 C 176 92 140 106 125 124 C 112 140 112 166 127 185 C 142 202 172 203 206 184 C 228 172 246 155 256 144")

    static let pawInnerBridge = parseSVGPath("M 320 226 C 344 218 370 220 385 232 C 395 268 408 326 409 348 C 409 374 392 390 374 390 C 360 389 352 373 351 354 C 349 322 350 296 353 274 C 338 258 324 242 320 226 Z")
    static let pawOpenStroke = parseSVGPath("M 385 232 C 395 268 409 326 410 348 C 411 374 392 391 374 390 C 360 389 352 373 351 354 C 349 324 350 296 353 274")

    static let noseTip = parseSVGPath("M 393 94 Q 402 89 410 94 Q 412 100 403 104 Q 394 101 393 94 Z")
    static let mouthMain = parseSVGPath("M 402 102 Q 400 115 389 118 Q 380 120 375 113")
    static let mouthDimple = parseSVGPath("M 398 112 Q 405 117 410 114")

    static let star1Outer = parseSVGPath("M 438 36 L 450 66 L 480 78 L 450 90 L 438 120 L 426 90 L 396 78 L 426 66 Z")
    static let star1Inner = parseSVGPath("M 438 60 L 443 73 L 456 78 L 443 83 L 438 96 L 433 83 L 420 78 L 433 73 Z")
    static let star2Outer = parseSVGPath("M 76 28 L 86 52 L 110 62 L 86 72 L 76 96 L 66 72 L 42 62 L 66 52 Z")
    static let star2Inner = parseSVGPath("M 76 48 L 80 58 L 90 62 L 80 66 L 76 76 L 72 66 L 62 62 L 72 58 Z")
    static let star3Outer = parseSVGPath("M 454 220 L 463 241 L 484 250 L 463 259 L 454 280 L 445 259 L 424 250 L 445 241 Z")
    static let star3Inner = parseSVGPath("M 454 238 L 457.5 246.5 L 466 250 L 457.5 253.5 L 454 262 L 450.5 253.5 L 442 250 L 450.5 246.5 Z")

    static let boltOuter = parseSVGPath("M 442 26 L 404 92 H 434 L 418 148 L 468 76 H 436 Z")
    static let boltInner = parseSVGPath("M 440 44 L 417 86 H 438 L 429 122 L 455 82 H 434 Z")

    private static func parseSVGPath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        let chars = Array(d.unicodeScalars)
        var i = 0
        let n = chars.count

        func skipSep() {
            while i < n && (chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" || chars[i] == "\r" || chars[i] == ",") {
                i += 1
            }
        }

        func nextNumber() -> CGFloat {
            skipSep()
            let start = i
            if i < n && (chars[i] == "-" || chars[i] == "+") {
                i += 1
            }
            while i < n && ((chars[i] >= "0" && chars[i] <= "9") || chars[i] == ".") {
                i += 1
            }
            let str = String(String.UnicodeScalarView(chars[start..<i]))
            return CGFloat(Double(str) ?? 0.0)
        }

        var current = CGPoint.zero
        while i < n {
            skipSep()
            if i >= n { break }
            let cmd = Character(chars[i])
            i += 1
            switch cmd {
            case "M":
                current = CGPoint(x: nextNumber(), y: nextNumber())
                path.move(to: current)
            case "L":
                current = CGPoint(x: nextNumber(), y: nextNumber())
                path.addLine(to: current)
            case "H":
                current = CGPoint(x: nextNumber(), y: current.y)
                path.addLine(to: current)
            case "Q":
                let c = CGPoint(x: nextNumber(), y: nextNumber())
                current = CGPoint(x: nextNumber(), y: nextNumber())
                path.addQuadCurve(to: current, control: c)
            case "C":
                let c1 = CGPoint(x: nextNumber(), y: nextNumber())
                let c2 = CGPoint(x: nextNumber(), y: nextNumber())
                current = CGPoint(x: nextNumber(), y: nextNumber())
                path.addCurve(to: current, control1: c1, control2: c2)
            case "Z", "z":
                path.closeSubpath()
            default:
                break
            }
        }
        return path
    }
}
