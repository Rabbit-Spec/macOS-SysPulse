import SwiftUI
import AppKit

/// Apple Keynote 16:9 横屏 Bento 风格宣传图（支持 Dark Pro 与 Light Silver 双主题）
public struct SysPulseKeynotePosterView: View {
    public let isDark: Bool

    public init(isDark: Bool) {
        self.isDark = isDark
    }

    private var canvasBg: Color {
        isDark ? Color(red: 0.02, green: 0.02, blue: 0.03) : Color(red: 0.824, green: 0.831, blue: 0.847)
    }

    private var tileBg: Color {
        isDark ? Color(red: 0.082, green: 0.086, blue: 0.102) : Color(red: 0.902, green: 0.906, blue: 0.922)
    }

    private var tileBorder: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var primaryText: Color {
        isDark ? Color.white : Color(red: 0.09, green: 0.10, blue: 0.12)
    }

    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.66) : Color(red: 0.34, green: 0.36, blue: 0.42)
    }

    public var body: some View {
        VStack(spacing: 14) {
            // Top Band (1880 x 220)
            HStack(spacing: 14) {
                menuBarTelemetryTile
                    .frame(width: 350, height: 220)

                networkVisualTile
                    .frame(width: 370, height: 220)

                cleanerVisualTile
                    .frame(width: 380, height: 220)

                uninstallerVisualTile
                    .frame(width: 380, height: 220)

                spaceVisualTile
                    .frame(width: 344, height: 220)
            }
            .frame(width: 1880, height: 220)

            // Middle Band (1880 x 556)
            HStack(spacing: 14) {
                VStack(spacing: 14) {
                    popoverTile
                        .frame(width: 350, height: 386)

                    smcSensorTile
                        .frame(width: 350, height: 156)
                }
                .frame(width: 350, height: 556)

                heroCenterTile
                    .frame(width: 1152, height: 556)

                VStack(spacing: 14) {
                    peripheralsTile
                        .frame(width: 350, height: 271)

                    nativeChipTile
                        .frame(width: 350, height: 271)
                }
                .frame(width: 350, height: 556)
            }
            .frame(width: 1880, height: 556)

            // Bottom Band (1880 x 236)
            HStack(spacing: 14) {
                fanControlTile
                    .frame(width: 350, height: 236)

                moduleCenterVisualTile
                    .frame(width: 380, height: 236)

                modulePairTile(
                    firstIcon: "gamecontroller.fill",
                    firstTitle: "PS Portal 串流增强",
                    firstColors: [Color(red: 0.25, green: 0.56, blue: 1.0), Color(red: 0.14, green: 0.36, blue: 0.88)],
                    secondIcon: "wifi",
                    secondTitle: "Wi-Fi 低延迟",
                    secondColors: [Color(red: 0.08, green: 0.78, blue: 0.84), Color(red: 0.06, green: 0.54, blue: 0.78)],
                    caption: "100/200M 串流 · AWDL 帧稳防抖"
                )
                .frame(width: 380, height: 236)

                modulePairTile(
                    firstIcon: "globe",
                    firstTitle: "局域网 ARP 嗅探",
                    firstColors: [Color(red: 0.64, green: 0.36, blue: 0.96), Color(red: 0.44, green: 0.22, blue: 0.82)],
                    secondIcon: "bolt.batteryblock.fill",
                    secondTitle: "UPS 电源管理",
                    secondColors: [Color(red: 0.98, green: 0.62, blue: 0.14), Color(red: 0.86, green: 0.42, blue: 0.08)],
                    caption: "二层拓扑识别 · USB-HID 断电保护"
                )
                .frame(width: 380, height: 236)

                openSourceTile
                    .frame(width: 334, height: 236)
            }
            .frame(width: 1880, height: 236)
        }
        .padding(20)
        .frame(width: 1920, height: 1080)
        .background(canvasBg)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    // MARK: - Center Hero Tile

    private var heroCenterTile: some View {
        ZStack {
            tileBackground(
                glows: [
                    (Color(red: 0.18, green: 0.62, blue: 0.98).opacity(isDark ? 0.26 : 0.14), CGSize(width: -280, height: -150), 460),
                    (Color(red: 0.46, green: 0.34, blue: 0.96).opacity(isDark ? 0.24 : 0.12), CGSize(width: 280, height: -120), 440),
                    (Color(red: 0.10, green: 0.82, blue: 0.62).opacity(isDark ? 0.16 : 0.10), CGSize(width: 0, height: 180), 420)
                ]
            )

            // 巨型金属质感文字（Apple Keynote 标志性视觉）
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("SysPulse")
                        .font(.system(size: 132, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: isDark
                                    ? [Color.white, Color(white: 0.78), Color.white.opacity(0.92)]
                                    : [Color(red: 0.14, green: 0.16, blue: 0.22), Color(red: 0.34, green: 0.38, blue: 0.46), Color(red: 0.10, green: 0.12, blue: 0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: isDark ? Color.cyan.opacity(0.28) : Color.black.opacity(0.10), radius: 22, y: 4)

                    Text("v\(AppMetadata.version)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(isDark ? Color.white : Color(red: 0.12, green: 0.14, blue: 0.18))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                                .overlay(Capsule().strokeBorder(isDark ? Color.white.opacity(0.26) : Color.black.opacity(0.12), lineWidth: 1))
                        )
                        .offset(y: -14)
                }
                .padding(.top, 14)

                Text("轻于颜表，深于内在 · 让系统状态如玻璃般清透，让运行空间如初次开箱")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondaryText)
                    .padding(.top, -6)

                Spacer(minLength: 10)

                if let statusImg = SysPulsePromoPosterView.loadImage(at: "/tmp/poster_user_status.jpg", stripTrafficLights: true) {
                    Image(nsImage: statusImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 575, height: 394)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.14), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.22), radius: 20, y: 8)
                }
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: - Top & Bottom Keynote Visual Feature Tiles

    private var networkVisualTile: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                miniAppIcon(
                    icon: "network",
                    colors: [Color(red: 0.08, green: 0.72, blue: 0.96), Color(red: 0.06, green: 0.44, blue: 0.86)],
                    size: 62
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wi-Fi 7 · 以太网")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondaryText)
                    Text("2,401 Mbps")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.22, green: 0.80, blue: 1.0), Color(red: 0.14, green: 0.56, blue: 0.98)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("实时测速 · 应用流量排行")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryText)
                }
            }

            VStack(spacing: 2) {
                Text("网络监控")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("物理网卡协商速率 · DNS 与网关延迟")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            tileBackground(glows: [
                (Color.cyan.opacity(isDark ? 0.14 : 0.08), CGSize(width: -70, height: -30), 200)
            ])
        )
    }

    private var cleanerVisualTile: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                miniAppIcon(
                    icon: "sparkles",
                    colors: [Color(red: 0.98, green: 0.36, blue: 0.54), Color(red: 0.84, green: 0.20, blue: 0.44)],
                    size: 62
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("安全扫描复核")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondaryText)
                    Text("6 类残留清理")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.46, blue: 0.62), Color(red: 0.94, green: 0.28, blue: 0.52)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("保护名单 · 系统文件自动跳过")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryText)
                }
            }

            VStack(spacing: 2) {
                Text("智能清理")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("用户缓存 · 日志 · 崩溃诊断 · 废纸篓")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            tileBackground(glows: [
                (Color.pink.opacity(isDark ? 0.14 : 0.08), CGSize(width: -70, height: -30), 200)
            ])
        )
    }

    private var uninstallerVisualTile: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                miniAppIcon(
                    icon: "trash.slash.fill",
                    colors: [Color(red: 0.48, green: 0.44, blue: 0.98), Color(red: 0.32, green: 0.26, blue: 0.86)],
                    size: 62
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("深度穿透扫描")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondaryText)
                    Text("12 类关联残留")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.62, green: 0.58, blue: 1.0), Color(red: 0.44, green: 0.38, blue: 0.96)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("沙盒容器 · 群组配置 · 无主残留")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryText)
                }
            }

            VStack(spacing: 2) {
                Text("应用卸载")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("系统应用防误删 · 彻底清除无残留")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            tileBackground(glows: [
                (Color.indigo.opacity(isDark ? 0.16 : 0.08), CGSize(width: -70, height: -30), 200)
            ])
        )
    }

    private var spaceVisualTile: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                miniAppIcon(
                    icon: "chart.pie.fill",
                    colors: [Color(red: 0.16, green: 0.82, blue: 0.56), Color(red: 0.08, green: 0.60, blue: 0.42)],
                    size: 62
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("多层级索引树")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondaryText)
                    Text("APFS 快照")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.24, green: 0.90, blue: 0.64), Color(red: 0.10, green: 0.72, blue: 0.48)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("逐层下钻 · 无需重复扫描")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(secondaryText)
                }
            }

            VStack(spacing: 2) {
                Text("空间分析")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("目录体积分布 · 大文件定位")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            tileBackground(glows: [
                (Color.green.opacity(isDark ? 0.14 : 0.08), CGSize(width: -60, height: -30), 190)
            ])
        )
    }

    private var moduleCenterVisualTile: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                miniAppIcon(icon: "square.grid.2x2.fill", colors: [Color(red: 0.56, green: 0.34, blue: 0.96), Color(red: 0.36, green: 0.20, blue: 0.82)], size: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text("独立扩展生态")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondaryText)
                    Text("模块中心")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(primaryText)
                }

                Spacer()

                Text("4 大模块")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.48, green: 0.30, blue: 0.92)))
            }

            Text("按需启停 · 关闭即释放零后台资源占用")
                .font(.system(size: 14.5, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            tileBackground(glows: [
                (Color.purple.opacity(isDark ? 0.16 : 0.08), CGSize(width: -80, height: -20), 220)
            ])
        )
    }

    // MARK: - Left Column Tiles

    private var popoverTile: some View {
        VStack(spacing: 8) {
            if let popImg = SysPulsePromoPosterView.loadImage(at: "/tmp/poster_user_popover.jpg") {
                Image(nsImage: popImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 142, height: 328)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(isDark ? 0.50 : 0.18), radius: 12, y: 4)
            }

            Text("菜单栏悬浮窗 · 一键掌控")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            tileBackground(glows: [
                (Color.cyan.opacity(isDark ? 0.14 : 0.08), CGSize(width: 0, height: -20), 260)
            ])
        )
    }

    private var smcSensorTile: some View {
        VStack(spacing: 6) {
            Text("AppleSMC 传感器")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(secondaryText)

            Text("原生直读")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.24, green: 0.66, blue: 1.0), Color(red: 0.16, green: 0.84, blue: 0.72)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Text("CPU · GPU · 功耗 · 温度 · 风扇")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tileBackground())
    }

    // MARK: - Top Left Menu Bar Tile

    private var menuBarTelemetryTile: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarRabbitIcon.templateIcon)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU 12%  GPU 8%  RAM 45%")
                    Text("↑ 24 KB/s  ↓ 18.6 MB/s  28W")
                }
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.24, blue: 0.42), Color(red: 0.14, green: 0.16, blue: 0.26)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.9)
                    )
            )

            VStack(spacing: 3) {
                Text("双行等宽实时遥测")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("菜单栏常驻 · 低开销不跳动")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tileBackground())
    }

    // MARK: - Right Column Tiles

    private var peripheralsTile: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                miniAppIcon(icon: "airpods.pro", colors: [Color(red: 0.42, green: 0.78, blue: 0.98), Color(red: 0.20, green: 0.56, blue: 0.90)])
                miniAppIcon(icon: "beats.headphones", colors: [Color(red: 0.92, green: 0.42, blue: 0.18), Color(red: 0.74, green: 0.24, blue: 0.08)])
                miniAppIcon(icon: "keyboard", colors: [Color(red: 0.34, green: 0.36, blue: 0.42), Color(red: 0.18, green: 0.20, blue: 0.24)])
                miniAppIcon(icon: "hand.point.up.left.fill", colors: [Color(red: 0.24, green: 0.56, blue: 0.98), Color(red: 0.16, green: 0.36, blue: 0.88)])
                miniAppIcon(icon: "battery.100percent.bolt", colors: [Color(red: 0.22, green: 0.84, blue: 0.50), Color(red: 0.12, green: 0.66, blue: 0.38)])
            }

            VStack(spacing: 4) {
                Text("外设电量与 UPS 守护")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("AirPods · 妙控键鼠板 · 断电自动保护")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tileBackground())
    }

    private var nativeChipTile: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isDark
                                ? [Color(red: 0.20, green: 0.22, blue: 0.26), Color(red: 0.10, green: 0.11, blue: 0.14)]
                                : [Color(red: 0.76, green: 0.78, blue: 0.82), Color(red: 0.64, green: 0.66, blue: 0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 112, height: 112)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.15), lineWidth: 1.2)
                    )
                    .shadow(color: isDark ? Color.orange.opacity(0.28) : Color.black.opacity(0.14), radius: 18, y: 4)

                VStack(spacing: 2) {
                    Image(systemName: "swift")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.44, blue: 0.20))
                    Text("Swift 6")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(primaryText)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Apple Silicon")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondaryText)
                Text("原生架构")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("AppKit + SwiftUI\n纯血原生零 Electron")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)
                    .lineSpacing(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            tileBackground(glows: [
                (Color.orange.opacity(isDark ? 0.16 : 0.08), CGSize(width: -60, height: 0), 220)
            ])
        )
    }

    // MARK: - Bottom Band Tiles

    private var fanControlTile: some View {
        VStack(spacing: 18) {
            Text("风扇温控")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)

            HStack(spacing: 8) {
                Text("自动")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 48)
                    .background(Capsule().fill(Color(red: 0.12, green: 0.56, blue: 0.98)))

                Text("降温")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
                    .frame(width: 72, height: 48)
                    .background(Capsule().fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))

                Text("强冷")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
                    .frame(width: 72, height: 48)
                    .background(Capsule().fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
            }
            .padding(6)
            .background(Capsule().fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)))

            Text("三档曲线 · 静音与散热兼得")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tileBackground())
    }

    private func modulePairTile(
        firstIcon: String,
        firstTitle: String,
        firstColors: [Color],
        secondIcon: String,
        secondTitle: String,
        secondColors: [Color],
        caption: String
    ) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                VStack(spacing: 8) {
                    miniAppIcon(icon: firstIcon, colors: firstColors, size: 60)
                    Text(firstTitle)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                }
                .frame(width: 150)

                VStack(spacing: 8) {
                    miniAppIcon(icon: secondIcon, colors: secondColors, size: 60)
                    Text(secondTitle)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                }
                .frame(width: 150)
            }

            Text(caption)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tileBackground())
    }

    private var openSourceTile: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.86, blue: 0.56), Color(red: 0.08, green: 0.68, blue: 0.44)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.green.opacity(isDark ? 0.30 : 0.18), radius: 14, y: 4)

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 3) {
                Text("MIT 开源")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("零遥测 · 永久免费")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tileBackground())
    }

    // MARK: - Helpers

    private func miniAppIcon(icon: String, colors: [Color], size: CGFloat = 52) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: colors.first?.opacity(isDark ? 0.30 : 0.18) ?? .clear, radius: 8, y: 3)

            Image(systemName: icon)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func tileBackground(glows: [(Color, CGSize, CGFloat)] = []) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(tileBg)
            .overlay(
                ZStack {
                    ForEach(Array(glows.enumerated()), id: \.offset) { _, glow in
                        RadialGradient(
                            colors: [glow.0, glow.0.opacity(0.35), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: glow.2 * 0.65
                        )
                        .frame(width: glow.2 * 1.3, height: glow.2 * 1.3)
                        .offset(glow.1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tileBorder, lineWidth: 1)
            )
    }
}
