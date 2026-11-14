import SwiftUI

// MARK: - 菜单栏健康度卡片 · 灵动白兔矢量骨骼动画视图 (Style 1 · Mod 4)

public struct MenuBarHealthRabbitView: View {
    public let rating: HealthRating
    public var size: CGFloat = 72

    @Environment(\.colorScheme) private var colorScheme

    public init(rating: HealthRating, size: CGFloat = 72) {
        self.rating = rating
        self.size = size
    }

    public var body: some View {
        let isDark = (colorScheme == .dark)

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let bgCycle = RabbitMotionEngine.backgroundCycleSeconds(for: rating)
            let p = now.truncatingRemainder(dividingBy: bgCycle) / bgCycle
            let bg = RabbitMotionEngine.sampleBackground(rating: rating, phase: p)
            let live = RabbitMotionEngine.sampleLiving(rating: rating, sec: now)

            Canvas(rendersAsynchronously: false) { context, canvasSize in
                let scale = min(canvasSize.width / 464.0, canvasSize.height / 484.0)
                var base = context
                base.translateBy(x: (canvasSize.width - 464.0 * scale) * 0.5 - 24.0 * scale,
                                 y: (canvasSize.height - 484.0 * scale) * 0.5 - 12.0 * scale)
                base.scaleBy(x: scale, y: scale)

                let accent = accentColor(isDark: isDark)
                let strokeCol = isDark
                    ? Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0)
                    : Color(red: 30.0 / 255.0, green: 41.0 / 255.0, blue: 59.0 / 255.0)

                drawBackgroundEffects(in: &base, bg: bg, accent: accent, isDark: isDark)
                drawWhiteRabbit(in: &base, live: live, strokeColor: strokeCol)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("系统健康小兔：\(rating.rawValue)")
    }

    // MARK: - 配色映射

    private func accentColor(isDark: Bool) -> Color {
        switch (rating, isDark) {
        case (.excellent, true):
            return Color(red: 56.0 / 255.0, green: 229.0 / 255.0, blue: 148.0 / 255.0)
        case (.excellent, false):
            return Color(red: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0)
        case (.good, true):
            return Color(red: 56.0 / 255.0, green: 189.0 / 255.0, blue: 248.0 / 255.0)
        case (.good, false):
            return Color(red: 2.0 / 255.0, green: 132.0 / 255.0, blue: 199.0 / 255.0)
        case (.fair, true):
            return Color(red: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0)
        case (.fair, false):
            return Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0)
        case (.needsAttention, true):
            return Color(red: 248.0 / 255.0, green: 113.0 / 255.0, blue: 113.0 / 255.0)
        case (.needsAttention, false):
            return Color(red: 220.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0)
        }
    }

    // MARK: - Layer 1~4: 增强背景光晕 / 双涟漪 / 旋转轨道 / 档位粒子

    private func drawBackgroundEffects(
        in base: inout GraphicsContext,
        bg: RabbitBackgroundPose,
        accent: Color,
        isDark: Bool
    ) {
        // Enhanced 1.35x preset parameters
        let haloAlpha = 1.0
        let ringStroke: CGFloat = 18.0
        let ringAlpha = 0.90
        let orbitStroke: CGFloat = 15.0
        let orbitAlpha = 0.78
        let pMul = 1.12

        // Layer 1: Breathing Radial Aura
        let boost0 = min(0.95, 0.78 * haloAlpha * (isDark ? 1.0 : 0.85))
        let boost1 = min(0.65, 0.42 * haloAlpha * (isDark ? 1.0 : 0.82))
        var auraCtx = base
        applyPivotTransform(&auraCtx, cx: 256, cy: 260, sx: bg.auraScale, sy: bg.auraScale)
        let auraCircle = Path(ellipseIn: CGRect(x: 256 - 235, y: 260 - 235, width: 470, height: 470))
        auraCtx.fill(
            auraCircle,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: accent.opacity(boost0), location: 0.0),
                    .init(color: accent.opacity(boost1), location: 0.55),
                    .init(color: accent.opacity(0.0), location: 1.0)
                ]),
                center: CGPoint(x: 256, y: 260),
                startRadius: 0,
                endRadius: 235
            )
        )

        // Layer 2: Staggered Dual Sonar Ripples
        let rippleCircle = Path(ellipseIn: CGRect(x: 256 - 165, y: 260 - 165, width: 330, height: 330))
        let r1 = RabbitMotionEngine.rippleCurve(phase: bg.ringPhase, maxAlpha: ringAlpha)
        var r1Ctx = base
        applyPivotTransform(&r1Ctx, cx: 256, cy: 260, sx: r1.scale, sy: r1.scale)
        r1Ctx.stroke(rippleCircle, with: .color(accent.opacity(r1.alpha)), lineWidth: ringStroke)

        let r2Phase = (bg.ringPhase + 0.5).truncatingRemainder(dividingBy: 1.0)
        let r2 = RabbitMotionEngine.rippleCurve(phase: r2Phase, maxAlpha: ringAlpha * 0.82)
        var r2Ctx = base
        applyPivotTransform(&r2Ctx, cx: 256, cy: 260, sx: r2.scale, sy: r2.scale)
        r2Ctx.stroke(rippleCircle, with: .color(accent.opacity(r2.alpha)), lineWidth: max(8, (ringStroke * 0.78).rounded()))

        // Layer 3: Continuous Rotating 3-Fold Orbital Arc
        var orbitCtx = base
        applyPivotTransform(&orbitCtx, cx: 256, cy: 260, deg: bg.orbitDeg)
        let orbitCircle = Path(ellipseIn: CGRect(x: 256 - 204, y: 260 - 204, width: 408, height: 408))
        orbitCtx.stroke(
            orbitCircle,
            with: .color(accent.opacity(orbitAlpha)),
            style: StrokeStyle(lineWidth: orbitStroke, lineCap: .round, dash: [172, 255.26])
        )

        // Layer 4: Tier-Specific Particles
        switch rating {
        case .excellent:
            var s1 = base
            applyPivotTransform(&s1, cx: 438, cy: 78, ty: bg.pFloat, deg: bg.pRot, sx: bg.pPulse1 * pMul, sy: bg.pPulse1 * pMul)
            s1.fill(RabbitPaths.star1Outer, with: .color(accent))
            s1.fill(RabbitPaths.star1Inner, with: .color(.white.opacity(0.90)))

            var s2 = base
            applyPivotTransform(&s2, cx: 76, cy: 62, ty: -bg.pFloat * 0.7, deg: -bg.pRot, sx: bg.pPulse2 * pMul, sy: bg.pPulse2 * pMul)
            s2.fill(RabbitPaths.star2Outer, with: .color(accent.opacity(0.92)))
            s2.fill(RabbitPaths.star2Inner, with: .color(.white.opacity(0.88)))

            var s3 = base
            applyPivotTransform(&s3, cx: 454, cy: 250, ty: bg.pFloat * 0.8, deg: bg.pRot * 0.8, sx: bg.pPulse3 * pMul, sy: bg.pPulse3 * pMul)
            s3.fill(RabbitPaths.star3Outer, with: .color(accent.opacity(0.88)))
            s3.fill(RabbitPaths.star3Inner, with: .color(.white.opacity(0.85)))

        case .good:
            var o1 = base
            applyPivotTransform(&o1, cx: 436, cy: 95, ty: bg.pFloat, sx: bg.pPulse1 * pMul, sy: bg.pPulse1 * pMul)
            o1.fill(Path(ellipseIn: CGRect(x: 436 - 24, y: 95 - 24, width: 48, height: 48)), with: .color(accent.opacity(0.86)))
            o1.fill(Path(ellipseIn: CGRect(x: 429 - 8, y: 88 - 8, width: 16, height: 16)), with: .color(.white.opacity(0.88)))

            var o2 = base
            applyPivotTransform(&o2, cx: 78, cy: 175, ty: bg.pFloat * 0.85, sx: bg.pPulse2 * pMul, sy: bg.pPulse2 * pMul)
            o2.fill(Path(ellipseIn: CGRect(x: 78 - 19, y: 175 - 19, width: 38, height: 38)), with: .color(accent.opacity(0.82)))
            o2.fill(Path(ellipseIn: CGRect(x: 72 - 6.5, y: 169 - 6.5, width: 13, height: 13)), with: .color(.white.opacity(0.85)))

            var o3 = base
            applyPivotTransform(&o3, cx: 445, cy: 265, ty: bg.pFloat * 0.7, sx: bg.pPulse3 * pMul, sy: bg.pPulse3 * pMul)
            o3.fill(Path(ellipseIn: CGRect(x: 445 - 16, y: 265 - 16, width: 32, height: 32)), with: .color(accent.opacity(0.78)))
            o3.fill(Path(ellipseIn: CGRect(x: 440 - 5.5, y: 260 - 5.5, width: 11, height: 11)), with: .color(.white.opacity(0.82)))

        case .fair:
            var d1 = base
            applyPivotTransform(&d1, cx: 438, cy: 82, ty: bg.pFloat, sx: bg.pPulse1 * pMul, sy: bg.pPulse1 * pMul)
            d1.fill(Path(ellipseIn: CGRect(x: 438 - 28, y: 82 - 28, width: 56, height: 56)), with: .color(accent.opacity(0.28)))
            d1.fill(Path(ellipseIn: CGRect(x: 438 - 20, y: 82 - 20, width: 40, height: 40)), with: .color(accent.opacity(0.95)))
            d1.fill(Path(ellipseIn: CGRect(x: 438 - 7, y: 82 - 7, width: 14, height: 14)), with: .color(.white.opacity(0.92)))

            var d2 = base
            applyPivotTransform(&d2, cx: 74, cy: 155, ty: bg.pFloat * 0.75, sx: bg.pPulse2 * pMul, sy: bg.pPulse2 * pMul)
            d2.fill(Path(ellipseIn: CGRect(x: 74 - 22, y: 155 - 22, width: 44, height: 44)), with: .color(accent.opacity(0.28)))
            d2.fill(Path(ellipseIn: CGRect(x: 74 - 15, y: 155 - 15, width: 30, height: 30)), with: .color(accent.opacity(0.92)))
            d2.fill(Path(ellipseIn: CGRect(x: 74 - 5.5, y: 155 - 5.5, width: 11, height: 11)), with: .color(.white.opacity(0.90)))

        case .needsAttention:
            var b1 = base
            applyPivotTransform(&b1, cx: 436, cy: 86, ty: bg.pFloat * 0.6, deg: bg.pRot, sx: bg.pPulse1 * pMul, sy: bg.pPulse1 * pMul)
            b1.fill(RabbitPaths.boltOuter, with: .color(accent))
            b1.fill(RabbitPaths.boltInner, with: .color(.white.opacity(0.58)))

            var a2 = base
            applyPivotTransform(&a2, cx: 76, cy: 150, ty: -bg.pFloat * 0.5, deg: -bg.pRot, sx: bg.pPulse2 * pMul, sy: bg.pPulse2 * pMul)
            a2.fill(Path(ellipseIn: CGRect(x: 76 - 24, y: 150 - 24, width: 48, height: 48)), with: .color(accent))
            a2.fill(Path(roundedRect: CGRect(x: 71.5, y: 135, width: 9, height: 16), cornerRadius: 4.5), with: .color(.white))
            a2.fill(Path(ellipseIn: CGRect(x: 76 - 4.8, y: 160 - 4.8, width: 9.6, height: 9.6)), with: .color(.white))
        }
    }

    // MARK: - Style 1: 菜单栏白兔分体骨骼 (含鼻嘴微动、无脸颊腮红)

    private func drawWhiteRabbit(
        in base: inout GraphicsContext,
        live: RabbitLivingPose,
        strokeColor: Color
    ) {
        let pinkEar = Color(red: 253.0 / 255.0, green: 164.0 / 255.0, blue: 175.0 / 255.0)
        let backEarFur = Color(red: 248.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0)

        var root = base
        applyPivotTransform(&root, cx: 280, cy: 472, tx: live.x, ty: live.y, deg: live.tilt, sx: live.sx, sy: live.sy)

        // 1. Back Ear
        var backEar = root
        applyPivotTransform(&backEar, cx: 286, cy: 66, deg: live.earB)
        backEar.fill(RabbitPaths.backEarSolid, with: .color(strokeColor))
        backEar.fill(RabbitPaths.backEarFill, with: .color(backEarFur))

        // 2. Torso
        root.fill(RabbitPaths.bodySolidTorso, with: .color(strokeColor))
        root.fill(RabbitPaths.bodyFillTorso, with: .color(.white))

        // 3. Tail
        var tail = root
        applyPivotTransform(&tail, cx: 162, cy: 377, deg: live.tail)
        tail.fill(RabbitPaths.tailSolid, with: .color(strokeColor))
        tail.fill(RabbitPaths.tailFill, with: .color(.white))

        // 4. Nose & 3/4 Profile Mouth (anchored around 398, 106 for sniff burst)
        var snout = root
        applyPivotTransform(&snout, cx: 398, cy: 106, tx: live.cheekX, ty: live.cheekY, sx: live.cheekScale, sy: live.cheekScale)
        snout.fill(RabbitPaths.noseTip, with: .color(strokeColor))
        snout.stroke(
            RabbitPaths.mouthMain,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round)
        )
        snout.stroke(
            RabbitPaths.mouthDimple,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: 5.5, lineCap: .round)
        )

        // 5. Eyes (blink + pupil gaze or happy smile eye)
        if live.smile {
            root.stroke(
                RabbitPaths.eyeSmile,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: 10.5, lineCap: .round)
            )
        } else {
            var eyeCtx = root
            applyPivotTransform(&eyeCtx, cx: 332, cy: 81, sy: live.blink)
            eyeCtx.fill(Path(ellipseIn: CGRect(x: 332 - 12.5, y: 81 - 12.5, width: 25, height: 25)), with: .color(strokeColor))
            var pupilCtx = eyeCtx
            pupilCtx.translateBy(x: live.pupilX, y: live.pupilY)
            pupilCtx.fill(Path(ellipseIn: CGRect(x: 336 - 4, y: 76 - 4, width: 8, height: 8)), with: .color(.white))
        }

        // 6. Front Ear
        var frontEar = root
        applyPivotTransform(&frontEar, cx: 266, cy: 112, deg: live.earF)
        frontEar.fill(RabbitPaths.frontEarInnerBridge, with: .color(.white))
        frontEar.fill(RabbitPaths.frontEarPink, with: .color(pinkEar.opacity(0.45)))
        frontEar.stroke(
            RabbitPaths.frontEarOpenStroke,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: 17.5, lineCap: .round, lineJoin: .round)
        )

        // 7. Articulated Front Paw
        var paw = root
        applyPivotTransform(&paw, cx: 368, cy: 232, deg: live.paw)
        paw.fill(RabbitPaths.pawInnerBridge, with: .color(.white))
        var padCtx = paw
        applyPivotTransform(&padCtx, cx: 386, cy: 356, deg: -12)
        padCtx.fill(Path(ellipseIn: CGRect(x: 386 - 6.5, y: 356 - 10.5, width: 13, height: 21)), with: .color(pinkEar.opacity(0.46)))
        paw.stroke(
            RabbitPaths.pawOpenStroke,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: 17.5, lineCap: .round, lineJoin: .round)
        )
    }

    private func applyPivotTransform(
        _ ctx: inout GraphicsContext,
        cx: CGFloat,
        cy: CGFloat,
        tx: CGFloat = 0,
        ty: CGFloat = 0,
        deg: Double = 0,
        sx: CGFloat = 1,
        sy: CGFloat = 1
    ) {
        ctx.translateBy(x: cx + tx, y: cy + ty)
        if deg != 0 {
            ctx.rotate(by: .degrees(deg))
        }
        if sx != 1 || sy != 1 {
            ctx.scaleBy(x: sx, y: sy)
        }
        ctx.translateBy(x: -cx, y: -cy)
    }
}

// MARK: - 生物微动 + 增强背景动效引擎

private struct RabbitBackgroundPose: Sendable {
    var auraScale: Double
    var ringPhase: Double
    var orbitDeg: Double
    var pPulse1: Double
    var pPulse2: Double
    var pPulse3: Double
    var pFloat: Double
    var pRot: Double
}

private struct RabbitLivingPose: Sendable {
    var x: Double = 0
    var y: Double = 0
    var sx: Double = 1
    var sy: Double = 1
    var tilt: Double = 0
    var earF: Double = 0
    var earB: Double = 0
    var tail: Double = 0
    var paw: Double = 0
    var blink: Double = 1.0
    var smile: Bool = false
    var pupilX: Double = 0
    var pupilY: Double = 0
    var cheekX: Double = 0
    var cheekY: Double = 0
    var cheekScale: Double = 1.0
}

private enum RabbitMotionEngine {
    static func backgroundCycleSeconds(for rating: HealthRating) -> Double {
        switch rating {
        case .excellent: return 1.80
        case .good: return 2.60
        case .fair: return 1.60
        case .needsAttention: return 1.15
        }
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let k = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
        return k * k * (3.0 - 2.0 * k)
    }

    static func rippleCurve(phase ph: Double, maxAlpha: Double) -> (scale: Double, alpha: Double) {
        (0.72 + 0.70 * ph, maxAlpha * smoothstep(0.0, 0.16, ph) * (1.0 - ph))
    }

    static func asymBreath(_ sec: Double, period: Double) -> Double {
        let ph = (sec.truncatingRemainder(dividingBy: period) + period)
            .truncatingRemainder(dividingBy: period) / period
        if ph < 0.40 { return 0.5 - 0.5 * cos((ph / 0.40) * .pi) }
        if ph < 0.82 { return 0.5 + 0.5 * cos(((ph - 0.40) / 0.42) * .pi) }
        return 0.0
    }

    static func poseWindow(_ u: Double, _ start: Double, _ end: Double, _ rise: Double, _ fall: Double) -> Double {
        smoothstep(start, start + rise, u) * (1.0 - smoothstep(end - fall, end, u))
    }

    static func earFlick(_ u: Double, _ start: Double, _ dur: Double, _ amp: Double) -> Double {
        guard u > start && u < start + dur else { return 0.0 }
        let k = (u - start) / dur
        if k < 0.15 { return amp * smoothstep(0.0, 0.15, k) }
        let k2 = (k - 0.15) / 0.85
        return amp * exp(-3.2 * k2) * cos(k2 * .pi * 2.5) * (1.0 - smoothstep(0.85, 1.0, k))
    }

    static func sniffBurst(_ u: Double, _ start: Double, _ dur: Double, _ count: Double) -> Double {
        guard u > start && u < start + dur else { return 0.0 }
        let k = (u - start) / dur
        return sin(k * .pi) * (0.5 - 0.5 * cos(k * .pi * 2.0 * count))
    }

    static func blinkScale(_ u: Double, _ times: [Double]) -> Double {
        var s = 1.0
        for t in times {
            let d = abs(u - t)
            if d < 0.07 {
                s = min(s, 0.10 + 0.90 * smoothstep(0.0, 0.07, d))
            }
        }
        return s
    }

    static func sampleBackground(rating: HealthRating, phase p: Double) -> RabbitBackgroundPose {
        let tau = Double.pi * 2.0
        switch rating {
        case .excellent:
            let breath = 0.5 - 0.5 * cos(p * tau)
            return RabbitBackgroundPose(
                auraScale: 0.84 + 0.36 * breath,
                ringPhase: p,
                orbitDeg: 240.0 * p,
                pPulse1: 0.50 + 0.82 * sin(p * tau) * sin(p * tau),
                pPulse2: 0.50 + 0.78 * cos(p * tau) * cos(p * tau),
                pPulse3: 0.52 + 0.74 * sin(p * tau + 1.1) * sin(p * tau + 1.1),
                pFloat: -24.0 * sin(p * tau),
                pRot: 18.0 * sin(p * tau)
            )
        case .good:
            let rise = 0.5 - 0.5 * cos(p * tau)
            return RabbitBackgroundPose(
                auraScale: 0.84 + 0.32 * rise,
                ringPhase: p,
                orbitDeg: 120.0 * p,
                pPulse1: 0.76 + 0.44 * rise,
                pPulse2: 0.74 + 0.44 * (0.5 - 0.5 * cos(p * tau + 2.0)),
                pPulse3: 0.72 + 0.44 * (0.5 - 0.5 * cos(p * tau + 4.0)),
                pFloat: -32.0 * rise,
                pRot: 0.0
            )
        case .fair:
            let hop = max(0.0, sin(p * tau * 2.0))
            return RabbitBackgroundPose(
                auraScale: 0.86 + 0.36 * hop,
                ringPhase: (p * 2.0).truncatingRemainder(dividingBy: 1.0),
                orbitDeg: 240.0 * p,
                pPulse1: 0.62 + 0.68 * hop,
                pPulse2: 0.62 + 0.68 * (1.0 - hop),
                pPulse3: 1.0,
                pFloat: -22.0 * hop,
                pRot: 0.0
            )
        case .needsAttention:
            let shake = sin(p * tau * 3.0)
            let pulse = 0.5 + 0.5 * sin(p * tau * 2.0)
            return RabbitBackgroundPose(
                auraScale: 0.88 + 0.38 * pulse,
                ringPhase: p,
                orbitDeg: 360.0 * p,
                pPulse1: 0.68 + 0.68 * pulse,
                pPulse2: 0.68 + 0.68 * (1.0 - pulse),
                pPulse3: 1.0,
                pFloat: -16.0 * pulse,
                pRot: 9.0 * shake
            )
        }
    }

    static func sampleLiving(rating: HealthRating, sec: Double) -> RabbitLivingPose {
        let tSec = max(0.0, sec)
        var pose = RabbitLivingPose()

        switch rating {
        case .excellent:
            let u = tSec.truncatingRemainder(dividingBy: 5.6)
            let br = asymBreath(tSec, period: 2.6)
            pose.sy += 0.012 * br
            pose.sx -= 0.007 * br
            pose.y -= 2.0 * br

            let wListen = poseWindow(u, 0.35, 1.20, 0.18, 0.25)
            pose.earF += earFlick(u, 0.35, 0.75, -7.5)
            pose.earB += earFlick(u, 0.50, 0.65, -2.5) + earFlick(u, 4.85, 0.55, 5.5)
            pose.pupilX += 1.2 * wListen
            pose.pupilY -= 1.0 * wListen

            let wAnt = poseWindow(u, 1.52, 1.82, 0.10, 0.10)
            pose.y += 1.5 * wAnt
            pose.sy -= 0.015 * wAnt
            pose.sx += 0.010 * wAnt
            pose.paw += 2.5 * wAnt

            let wWave = poseWindow(u, 1.75, 2.95, 0.22, 0.32)
            pose.y -= 9.5 * wWave
            pose.tilt += 1.8 * wWave
            pose.sy += 0.012 * wWave
            pose.sx -= 0.007 * wWave
            pose.smile = poseWindow(u, 1.82, 2.85, 0.12, 0.12) > 0.5
            pose.paw += -10.5 * wWave - 3.8 * wWave * sin((u - 1.85) * .pi * 3.6)
            pose.earF -= 4.5 * wWave
            pose.earB -= 6.0 * wWave
            pose.tail += 5.0 * wWave * sin((u - 1.8) * .pi * 4.0)

            let sn = sniffBurst(u, 3.35, 0.65, 3.0)
            pose.cheekX += 2.6 * sn
            pose.cheekY -= 2.2 * sn
            pose.cheekScale += 0.07 * sn
            pose.tilt += 0.9 * sn
            pose.earF -= 1.8 * sn

            pose.blink = blinkScale(u, [1.25, 4.35, 4.58])

        case .good:
            let u = tSec.truncatingRemainder(dividingBy: 6.0)
            let br = asymBreath(tSec, period: 3.0)
            pose.sy += 0.011 * br
            pose.sx -= 0.006 * br
            pose.y -= 1.8 * br

            let wTilt = poseWindow(u, 0.60, 1.45, 0.25, 0.30)
            pose.tilt += 1.6 * wTilt
            pose.earF -= 6.5 * wTilt
            pose.earB += 1.5 * wTilt
            pose.pupilX += 1.4 * wTilt
            pose.pupilY -= 0.8 * wTilt

            let wGroom = poseWindow(u, 2.00, 3.35, 0.28, 0.32)
            pose.paw += -8.5 * wGroom - 2.8 * wGroom * (0.5 - 0.5 * cos((u - 2.2) * .pi * 3.2))
            pose.tilt -= 1.1 * wGroom
            pose.cheekY -= 1.5 * wGroom

            let sn = sniffBurst(u, 4.10, 0.55, 2.0)
            pose.cheekX += 2.2 * sn
            pose.cheekY -= 1.8 * sn
            pose.cheekScale += 0.06 * sn
            pose.tilt += 0.6 * sn
            pose.earB += earFlick(u, 5.00, 0.60, -5.0)

            pose.blink = blinkScale(u, [1.10, 3.85, 5.30])

        case .fair:
            let u = tSec.truncatingRemainder(dividingBy: 5.2)
            let br = asymBreath(tSec, period: 2.3)
            pose.sy += 0.009 * br
            pose.sx -= 0.005 * br
            pose.y -= 1.5 * br

            let wPeer = poseWindow(u, 0.40, 1.95, 0.26, 0.32)
            pose.x += 2.2 * wPeer
            pose.y -= 4.5 * wPeer
            pose.tilt += 2.6 * wPeer
            pose.earF -= 6.0 * wPeer
            pose.earB -= 4.0 * wPeer
            pose.pupilX += 1.8 * wPeer

            let sn = sniffBurst(u, 0.85, 0.65, 3.0)
            pose.cheekX += 2.4 * sn
            pose.cheekY -= 2.0 * sn
            pose.cheekScale += 0.06 * sn

            let wTap = poseWindow(u, 2.15, 3.45, 0.22, 0.28)
            pose.paw += -9.5 * wTap - 2.5 * wTap * sin((u - 2.3) * .pi * 3.0)
            pose.earB += earFlick(u, 2.60, 0.55, 5.0)
            pose.earF += earFlick(u, 4.55, 0.50, -5.5)

            pose.blink = blinkScale(u, [2.05, 2.28, 4.40])

        case .needsAttention:
            let u = tSec.truncatingRemainder(dividingBy: 4.5)
            let br = asymBreath(tSec, period: 1.8)
            pose.sy += 0.009 * br
            pose.sx -= 0.005 * br
            pose.y -= 1.5 * br

            let wAlert = poseWindow(u, 0.20, 1.35, 0.10, 0.25)
            let trem = (u > 0.20 && u < 0.75) ? exp(-6.5 * (u - 0.20)) * sin((u - 0.20) * .pi * 14.0) : 0.0
            pose.y -= 4.5 * wAlert
            pose.tilt -= 1.6 * wAlert
            pose.earF += -5.8 * wAlert + 3.4 * trem + earFlick(u, 3.75, 0.50, -6.5)
            pose.earB += 5.2 * wAlert - 3.4 * trem
            pose.paw += -5.0 * wAlert
            pose.pupilX += 1.5 * wAlert
            pose.pupilY -= 1.2 * wAlert

            let wCall = poseWindow(u, 1.50, 2.85, 0.16, 0.24)
            pose.paw += -10.5 * wCall - 3.5 * wCall * sin((u - 1.6) * .pi * 5.2)
            pose.y -= 3.5 * wCall * abs(sin((u - 1.6) * .pi * 2.6))
            pose.tail += 5.0 * wCall * sin((u - 1.6) * .pi * 5.2)

            let sn = sniffBurst(u, 3.15, 0.45, 2.0)
            pose.cheekX += 2.4 * sn
            pose.cheekY -= 2.0 * sn
            pose.cheekScale += 0.06 * sn

            pose.blink = blinkScale(u, [1.42, 1.62, 4.10])
        }

        return pose
    }
}

// MARK: - 预解析纯矢量路径 + 轻量化 SVG Path Parser

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
    static let eyeSmile = parseSVGPath("M 317 85 Q 332 69 347 85")

    static let star1Outer = parseSVGPath("M 438 36 L 450 66 L 480 78 L 450 90 L 438 120 L 426 90 L 396 78 L 426 66 Z")
    static let star1Inner = parseSVGPath("M 438 60 L 443 73 L 456 78 L 443 83 L 438 96 L 433 83 L 420 78 L 433 73 Z")
    static let star2Outer = parseSVGPath("M 76 28 L 86 52 L 110 62 L 86 72 L 76 96 L 66 72 L 42 62 L 66 52 Z")
    static let star2Inner = parseSVGPath("M 76 48 L 80 58 L 90 62 L 80 66 L 76 76 L 72 66 L 62 62 L 72 58 Z")
    static let star3Outer = parseSVGPath("M 454 220 L 463 241 L 484 250 L 463 259 L 454 280 L 445 259 L 424 250 L 445 241 Z")
    static let star3Inner = parseSVGPath("M 454 238 L 457.5 246.5 L 466 250 L 457.5 253.5 L 454 262 L 450.5 253.5 L 442 250 L 450.5 246.5 Z")

    static let boltOuter = parseSVGPath("M 442 26 L 404 92 H 434 L 418 148 L 468 76 H 436 Z")
    static let boltInner = parseSVGPath("M 440 44 L 417 86 H 438 L 429 122 L 455 82 H 434 Z")

    private static func parseSVGPath(_ d: String) -> Path {
        var path = Path()
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
