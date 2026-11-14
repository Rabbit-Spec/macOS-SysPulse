import SwiftUI
import AppKit

public struct SysPulsePromoPosterView: View {
    public init() {}

    private let cardBg = Color(red: 0.937, green: 0.937, blue: 0.949) // #EFEFF2 (Apple Bento Light Gray)
    private let primaryText = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let secondaryText = Color(red: 0.38, green: 0.40, blue: 0.45)

    public var body: some View {
        VStack(spacing: 24) {
            topBannerCard
                .frame(width: 1452, height: 220)

            heroShowcaseCard
                .frame(width: 1452, height: 716)

            HStack(spacing: 24) {
                leftMenuBarCard
                    .frame(width: 450, height: 856)

                VStack(spacing: 24) {
                    HStack(spacing: 24) {
                        featureScreenshotSubCard(
                            imagePath: "/tmp/poster_user_cleaner.jpg",
                            title: "智能清理",
                            subtitle: "系统缓存 · 日志与废纸篓"
                        )
                        .frame(width: 477, height: 416)

                        featureScreenshotSubCard(
                            imagePath: "/tmp/poster_user_software.jpg",
                            title: "应用卸载",
                            subtitle: "App 本体与 12 类残留清理"
                        )
                        .frame(width: 477, height: 416)
                    }

                    HStack(spacing: 24) {
                        featureScreenshotSubCard(
                            imagePath: "/tmp/poster_user_space.jpg",
                            title: "空间分析",
                            subtitle: "目录体积分布 · 大文件定位"
                        )
                        .frame(width: 477, height: 416)

                        featureScreenshotSubCard(
                            imagePath: "/tmp/poster_user_plugins.jpg",
                            title: "模块中心",
                            subtitle: "串流画质 · Wi-Fi 低延迟 · ARP · UPS"
                        )
                        .frame(width: 477, height: 416)
                    }
                }
                .frame(width: 978, height: 856)
            }
            .frame(width: 1452, height: 856)

            HStack(spacing: 24) {
                bottomPeripheralsCard
                    .frame(width: 560, height: 228)

                bottomFanModeCard
                    .frame(width: 220, height: 228)

                bottomNativeArchCard
                    .frame(width: 416, height: 228)

                bottomOpenSourceCard
                    .frame(width: 184, height: 228)
            }
            .frame(width: 1452, height: 228)
        }
        .padding(24)
        .frame(width: 1500, height: 2140)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    // MARK: - Row 1: Top Gradient Banner

    private var topBannerCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.82, blue: 0.61),
                            Color(red: 0.16, green: 0.66, blue: 0.95),
                            Color(red: 0.37, green: 0.40, blue: 0.93)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RadialGradient(
                        colors: [Color.white.opacity(0.22), Color.clear],
                        center: .top,
                        startRadius: 20,
                        endRadius: 650
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                )

            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    Text("SysPulse")
                        .font(.system(size: 82, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)

                    Text("v\(AppMetadata.version)")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.22))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1.2))
                        )
                        .offset(y: 4)
                }

                Text("轻于颜表，深于内在 · 让系统状态如玻璃般清透，让运行空间如初次开箱")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.97))
                    .shadow(color: Color.black.opacity(0.10), radius: 4, y: 2)
            }
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Row 2: Hero Showcase Card

    private var heroShowcaseCard: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.13, green: 0.27, blue: 0.48),
                            Color(red: 0.18, green: 0.38, blue: 0.62),
                            Color(red: 0.10, green: 0.16, blue: 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.28))
                            .frame(width: 680, height: 680)
                            .blur(radius: 90)
                            .offset(x: -360, y: -180)

                        Circle()
                            .fill(Color(red: 0.42, green: 0.35, blue: 0.95).opacity(0.30))
                            .frame(width: 640, height: 640)
                            .blur(radius: 95)
                            .offset(x: 380, y: -120)

                        Circle()
                            .fill(Color(red: 0.12, green: 0.80, blue: 0.65).opacity(0.22))
                            .frame(width: 520, height: 520)
                            .blur(radius: 80)
                            .offset(x: 0, y: 180)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                )

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 15, weight: .bold))
                        Text("SysPulse")
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        Text("状态")
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.85)
                        Text("网络")
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.75)
                        Text("清理")
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.75)
                        Text("软件")
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.75)
                        Text("空间")
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.75)
                        Text("模块")
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.75)
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    HStack(spacing: 10) {
                        Image(nsImage: MenuBarRabbitIcon.templateIcon)
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)

                        Text("CPU 12% · GPU  8%   |   RAM 45% · TMP 43°   |   ↑ 24 KB/s · ↓ 18.6 MB/s   |   PWR 28W")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8))
                    )

                    HStack(spacing: 10) {
                        Image(systemName: "wifi")
                        Image(systemName: "battery.100.bolt")
                        Text("12:29")
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 28)
                .frame(height: 44)
                .background(Color.black.opacity(0.18))

                Spacer(minLength: 10)

                HStack(alignment: .center, spacing: 20) {
                    if let heroImg = Self.loadImage(at: "/tmp/poster_user_status.jpg", stripTrafficLights: true) {
                        Image(nsImage: heroImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 696, height: 477)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1.2)
                            )
                            .shadow(color: Color.black.opacity(0.45), radius: 22, y: 10)
                    }

                    if let networkImg = Self.loadImage(at: "/tmp/poster_user_network.jpg", stripTrafficLights: true) {
                        Image(nsImage: networkImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 696, height: 477)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 1.2)
                            )
                            .shadow(color: Color.black.opacity(0.45), radius: 22, y: 10)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 14) {
                    heroDockTile(
                        title: "状态总览",
                        subtitle: "硬件遥测与能耗排行",
                        icon: "gauge.with.dots.needle.67percent",
                        colors: [Color(red: 0.16, green: 0.52, blue: 0.92), Color(red: 0.10, green: 0.32, blue: 0.68)]
                    )
                    heroDockTile(
                        title: "网络监控",
                        subtitle: "链路测速与流量去向",
                        icon: "network",
                        colors: [Color(red: 0.08, green: 0.72, blue: 0.82), Color(red: 0.08, green: 0.48, blue: 0.72)]
                    )
                    heroDockTile(
                        title: "智能清理",
                        subtitle: "缓存日志安全清理",
                        icon: "sparkles",
                        colors: [Color(red: 0.96, green: 0.36, blue: 0.52), Color(red: 0.85, green: 0.24, blue: 0.42)]
                    )
                    heroDockTile(
                        title: "应用卸载",
                        subtitle: "应用与关联残留清理",
                        icon: "trash.slash.fill",
                        colors: [Color(red: 0.45, green: 0.42, blue: 0.96), Color(red: 0.30, green: 0.25, blue: 0.85)]
                    )
                    heroDockTile(
                        title: "空间分析",
                        subtitle: "大文件与目录分布",
                        icon: "chart.pie.fill",
                        colors: [Color(red: 0.16, green: 0.78, blue: 0.54), Color(red: 0.08, green: 0.58, blue: 0.40)]
                    )
                    heroDockTile(
                        title: "模块中心",
                        subtitle: "按需启停四大模块",
                        icon: "square.grid.2x2.fill",
                        colors: [Color(red: 0.58, green: 0.34, blue: 0.92), Color(red: 0.38, green: 0.22, blue: 0.76)]
                    )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1.0)
                        )
                )
                .padding(.bottom, 18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func heroDockTile(title: String, subtitle: String, icon: String, colors: [Color]) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
        }
        .frame(width: 214, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.26))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
    }

    // MARK: - Row 3 Left: Menu Bar Popover Card

    private var leftMenuBarCard: some View {
        VStack(spacing: 14) {
            Text("菜单栏悬浮窗")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
                .padding(.top, 22)

            if let popImg = Self.loadImage(at: "/tmp/poster_user_popover.jpg") {
                Image(nsImage: popImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 280, height: 644)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.black.opacity(0.16), radius: 16, y: 6)
            }

            VStack(spacing: 4) {
                Text("双行等宽实时遥测")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("快捷操控与状态查看")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
            }
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardBg)
        )
    }

    // MARK: - Row 3 Right: 2x2 Core Feature Subcards

    private func featureScreenshotSubCard(imagePath: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            if let img = Self.loadImage(at: imagePath, stripTrafficLights: true) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 438, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
                    .padding(.top, 20)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 438, height: 300)
                    .overlay(Text(title).font(.system(size: 24, weight: .bold)))
                    .padding(.top, 20)
            }

            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text(subtitle)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardBg)
        )
    }

    // MARK: - Row 4: Bottom 4-Tile Strip

    private var bottomPeripheralsCard: some View {
        HStack(spacing: 18) {
            peripheralBadge(
                icon: "airpods.pro",
                label: "AirPods",
                colors: [Color(red: 0.56, green: 0.84, blue: 0.96), Color(red: 0.32, green: 0.68, blue: 0.90)]
            )
            peripheralBadge(
                icon: "beats.headphones",
                label: "Beats",
                colors: [Color(red: 0.86, green: 0.44, blue: 0.16), Color(red: 0.62, green: 0.24, blue: 0.06)]
            )
            peripheralBadge(
                icon: "keyboard.fill",
                label: "妙控键鼠",
                colors: [Color(red: 0.24, green: 0.26, blue: 0.29), Color(red: 0.08, green: 0.09, blue: 0.11)]
            )
            peripheralBadge(
                icon: "rectangle.and.hand.point.up.left.fill",
                label: "妙控板",
                colors: [Color(red: 0.18, green: 0.56, blue: 0.96), Color(red: 0.08, green: 0.34, blue: 0.82)]
            )
            peripheralBadge(
                icon: "bolt.batteryblock.fill",
                label: "UPS 守护",
                colors: [Color(red: 0.34, green: 0.88, blue: 0.62), Color(red: 0.14, green: 0.68, blue: 0.44)]
            )
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardBg)
        )
    }

    private func peripheralBadge(icon: String, label: String, colors: [Color]) -> some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .frame(width: 84, height: 84)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2)
                    )
                    .shadow(color: colors.last!.opacity(0.28), radius: 8, y: 4)

                Image(systemName: icon)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(label)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryText)
        }
    }

    private var bottomFanModeCard: some View {
        VStack(spacing: 22) {
            Text("风扇温控")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)

            HStack(spacing: 8) {
                Text("自")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.22, green: 0.62, blue: 0.98))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color(red: 0.10, green: 0.12, blue: 0.16)))

                Text("降")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                    .frame(width: 44, height: 44)

                Text("强")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.06))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardBg)
        )
    }

    private var bottomNativeArchCard: some View {
        VStack(spacing: 8) {
            Text("AppleSMC 传感器")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)

            Text("原生直读")
                .font(.system(size: 54, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.22, green: 0.62, blue: 0.98))

            Text("Swift 6 原生架构")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardBg)
        )
    }

    private var bottomOpenSourceCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.34, green: 0.88, blue: 0.62), Color(red: 0.14, green: 0.68, blue: 0.44)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 54, height: 54)
                    .shadow(color: Color(red: 0.14, green: 0.68, blue: 0.44).opacity(0.3), radius: 6, y: 3)

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 2) {
                Text("MIT 开源")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("零遥测")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardBg)
        )
    }

    // MARK: - Image Loading Helpers

    static func loadImage(at path: String, stripTrafficLights: Bool = false) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path) else { return nil }
        guard stripTrafficLights,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 100, height > 60 else { return image }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let clearW = min(width - 1, Int(Double(width) * 0.08))
        let clearH = min(height, Int(Double(height) * 0.055))
        let sampleX = min(width - 1, Int(Double(width) * 0.085))
        for y in 0..<clearH {
            let sampleOffset = y * bytesPerRow + sampleX * 4
            let r = pixels[sampleOffset]
            let g = pixels[sampleOffset + 1]
            let b = pixels[sampleOffset + 2]
            let a = pixels[sampleOffset + 3]
            for x in 0..<clearW {
                let dst = y * bytesPerRow + x * 4
                pixels[dst] = r
                pixels[dst + 1] = g
                pixels[dst + 2] = b
                pixels[dst + 3] = a
            }
        }
        guard let cleanedCG = ctx.makeImage() else { return image }
        return NSImage(cgImage: cleanedCG, size: image.size)
    }

    private static func loadResourceImage(named name: String) -> NSImage? {
        let candidates: [String?] = [
            Bundle.main.url(forResource: name, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png").path
        ]
        for path in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }
}
