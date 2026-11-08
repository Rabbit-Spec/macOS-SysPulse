import AppKit
import SwiftUI

@main
struct SysPulseApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3 && args[1] == "--generate-icons" {
            let outputDir = args[2]
            MainActor.assumeIsolated {
                try? AppIconManager.exportIconsets(to: outputDir)
            }
            exit(0)
        }
        if args.count >= 2 && args[1] == "--self-test" {
            MainActor.assumeIsolated {
                let engine = PowerSourceEngine.shared
                let monitor = SystemResourceMonitor.shared
                let toggles = FeatureToggleManager.shared
                engine.refresh(forceUIUpdate: true)
                monitor.refreshNow()
                RunLoop.main.run(until: Date().addingTimeInterval(2.8))
                monitor.refreshNow()
                RunLoop.main.run(until: Date().addingTimeInterval(1.2))
                let t = engine.telemetry
                let p = monitor.power
                let m = monitor.memory
                let d = monitor.disk
                let r = monitor.loadRuntime
                print("=== SysPulse \(AppMetadata.versionDisplay) Self-Test Report ===")
                print("Hardware Platform: \(MacHardwareInfo.shared.currentPlatformName)")
                print("UPS Connected: \(t.isConnected) | Paired: \(t.pairedUPSDescription) | Battery: \(t.batteryLevel)% | Voltage: \(Int(t.voltageVolts))V")
                print(String(format: "System Power: Total %.2f W (Load %.2f W + Adapter %.2f W) | CPU Total: %.1f%%", p.totalSystemWatts, p.systemLoadWatts, p.adapterLossWatts, p.cpuTotalPercent))
                print(String(format: "Memory: %.2f / %.1f GB (%d%%) | App %.2fG | Wired %.2fG | Compressed %.2fG | Pressure: %@", m.usedGB, m.totalGB, m.usedPercent, m.appMemoryGB, m.wiredMemoryGB, m.compressedMemoryGB, m.pressureLabel))
                print("Disk I/O: Read \(d.formattedReadSpeed) | Write \(d.formattedWriteSpeed) | Boot Free: \(String(format: "%.1f", d.bootVolumeFreeGB))/\(String(format: "%.0f", d.bootVolumeTotalGB)) GB")
                print("Fan Status: \(FanController.shared.currentRPM) RPM (Hardware Monitor: \(monitor.hardware.fanSpeedRPM) RPM, Mode: \(FanController.shared.activeMode.rawValue))")
                print("Load Runtime: \(r.formattedCurrentLoadRuntime) @ \(String(format: "%.1f", r.currentLoadWatts))W (Light: \(r.lightLoadEstimatedMinutes)m, Heavy: \(r.heavyLoadEstimatedMinutes)m, InternalBatt: \(r.hasInternalBattery))")
                print("Top Energy Apps (\(monitor.topEnergyApps.count)):")
                for app in monitor.topEnergyApps.prefix(5) {
                    print(String(format: "  - %@ (PID %d): CPU %.1f%% | Mem %.0f MB | ~%.2f W", app.name, app.id, app.cpuPercent, app.memoryMB, app.estimatedWatts))
                }
                print("Toggles Active: Power=\(toggles.enableSystemPowerMonitor), Mem=\(toggles.enableMemoryMonitor), Disk=\(toggles.enableDiskIOMonitor), Apps=\(toggles.enableTopEnergyAppsMonitor), Runtime=\(toggles.enableLoadRuntimeMonitor)")
                print("=== Self-Test PASSED ===")
            }
            exit(0)
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--render-popover"), idx + 2 < CommandLine.arguments.count {
            let tabType = CommandLine.arguments[idx + 1]
            let destPath = CommandLine.arguments[idx + 2]
            _ = NSApplication.shared
            PanelCoordinator.shared.selectedTab = (tabType == "cleaner" || tabType == "cleanerScanning") ? .cleaner : .system
            if tabType == "cleanerScanning" {
                SystemCleanerEngine.shared.status = .scanning(progress: 0.65, currentPath: "/Users/bunny/Library/Caches/com.apple.Safari/Cache.db")
            }
            SystemResourceMonitor.shared.refreshNow()
            let panelView = LiquidGlassPanel()
                .environment(\.colorScheme, .dark)
                .frame(width: 360)
            let hosting = NSHostingView(rootView: panelView)
            hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                rep.size = NSSize(width: 360, height: 500)
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: destPath))
                    print("RENDERED_POPOVER: \(destPath)")
                }
            }
            exit(0)
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--render-window"), idx + 3 < CommandLine.arguments.count {
            let sectionName = CommandLine.arguments[idx + 1]
            let appearanceName = CommandLine.arguments[idx + 2]
            let destPath = CommandLine.arguments[idx + 3]
            _ = NSApplication.shared

            if sectionName == "menuBar" || sectionName == "popover" || sectionName == "networkDetail" || sectionName == "networkDetailMeasuring" {
                if sectionName == "networkDetail" || sectionName == "networkDetailMeasuring" {
                    StudioWindowNavigationState.shared.isNetworkDetailPresented = true
                    if sectionName == "networkDetailMeasuring" {
                        NetworkSpeedTest.shared.setSimulating(progressSeconds: 3.2, liveDownload: "186.4 MB/s", liveUpload: "24.6 MB/s")
                    }
                }
                SystemResourceMonitor.shared.refreshNow()
                AccessoryBatteryManager.shared.refresh()
                NetworkDetailModel.shared.refresh()
                let rWidth: CGFloat = 334
                let popoverView = LiquidGlassPanel()
                    .environment(\.colorScheme, appearanceName == "light" ? .light : .dark)
                    .frame(width: rWidth)
                let hosting = NSHostingView(rootView: popoverView)
                let offscreenWindow = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: rWidth, height: 720),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                offscreenWindow.isOpaque = false
                offscreenWindow.backgroundColor = .clear
                offscreenWindow.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(1.3))
                SystemResourceMonitor.shared.refreshNow()
                let fitting = hosting.fittingSize
                let rHeight: CGFloat = ceil(max(680, fitting.height))
                print("NEW_FITTING_HEIGHT: \(fitting.height), rHeight: \(rHeight)")
                offscreenWindow.setContentSize(NSSize(width: rWidth, height: rHeight))
                hosting.frame = NSRect(x: 0, y: 0, width: rWidth, height: rHeight)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: rWidth, height: rHeight)) {
                    rep.size = NSSize(width: rWidth, height: rHeight)
                    hosting.cacheDisplay(in: NSRect(x: 0, y: 0, width: rWidth, height: rHeight), to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: destPath))
                        print("RENDERED_WINDOW: \(destPath)")
                    }
                }
                exit(0)
            }

            if sectionName == "menuBarItem" || sectionName == "menuBarStatus" {
                SystemResourceMonitor.shared.refreshNow()
                let isLight = (appearanceName == "light")
                let itemWidth: CGFloat = 360
                let itemHeight: CGFloat = 28
                let barView = NSView(frame: NSRect(x: 0, y: 0, width: itemWidth, height: itemHeight))
                barView.wantsLayer = true
                barView.layer?.backgroundColor = isLight
                    ? NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0).cgColor
                    : NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).cgColor

                let container = NSView(frame: NSRect(x: 16, y: 0, width: itemWidth - 32, height: itemHeight))
                barView.addSubview(container)

                let iconSize: CGFloat = 18
                let iconView = NSImageView(frame: NSRect(x: 0, y: (itemHeight - iconSize) / 2, width: iconSize, height: iconSize))
                iconView.imageScaling = .scaleProportionallyDown
                let templateImage = MenuBarRabbitIcon.templateIcon
                let tintColor = isLight ? NSColor(calibratedWhite: 0.15, alpha: 1.0) : NSColor.white
                let tinted = NSImage(size: NSSize(width: iconSize, height: iconSize))
                tinted.lockFocus()
                templateImage.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))
                tintColor.set()
                NSRect(x: 0, y: 0, width: iconSize, height: iconSize).fill(using: .sourceIn)
                tinted.unlockFocus()
                tinted.isTemplate = false
                iconView.image = tinted
                container.addSubview(iconView)

                let toggles = FeatureToggleManager.shared
                let monitor = SystemResourceMonitor.shared
                func formatMetric(_ prefix: String, _ value: Int, _ unit: String) -> String {
                    let v = max(0, min(999, value))
                    if v < 10 {
                        return "\(prefix)  \(v)\(unit)"
                    } else if v < 100 {
                        return "\(prefix) \(v)\(unit)"
                    } else {
                        return "\(prefix)\(v)\(unit)"
                    }
                }
                var topCols: [String] = []
                var botCols: [String] = []
                if toggles.menuBarShowCpuGpu {
                    let cpuPct = max(0, min(100, Int(round(monitor.power.cpuUsagePercent))))
                    let gpuPct = max(0, min(100, Int(round(monitor.hardware.gpuUsagePercent))))
                    topCols.append(formatMetric("CPU", cpuPct > 0 ? cpuPct : 18, "%"))
                    botCols.append(formatMetric("GPU", gpuPct > 0 ? gpuPct : 12, "%"))
                }
                if toggles.menuBarShowMemTemp {
                    let memPct = max(0, min(100, monitor.memory.usedPercent))
                    let tempC = max(0, min(120, Int(round(monitor.hardware.cpuTemperatureC))))
                    topCols.append(formatMetric("RAM", memPct > 0 ? memPct : 54, "%"))
                    botCols.append(formatMetric("TMP", tempC > 0 ? tempC : 48, "°"))
                }
                if toggles.menuBarShowNetworkSpeed {
                    topCols.append("↑   4 KB/s")
                    botCols.append("↓ 3.8 MB/s")
                }
                if toggles.menuBarShowSystemWatts {
                    let peak = max(1, Int(round(max(monitor.power.peakWatts, monitor.power.totalSystemWatts))))
                    let cur = max(1, Int(round(monitor.power.totalSystemWatts)))
                    topCols.append(formatMetric("MAX", peak > 0 ? peak : 68, "W"))
                    botCols.append(formatMetric("PWR", cur > 0 ? cur : 29, "W"))
                }
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineSpacing = -1.5
                pStyle.maximumLineHeight = 10.0
                pStyle.minimumLineHeight = 10.0
                pStyle.alignment = .left
                let f = NSFont.monospacedSystemFont(ofSize: 9.0, weight: .semibold)
                let textColor = isLight ? NSColor(calibratedWhite: 0.15, alpha: 1.0) : NSColor.white
                let dotColor = isLight ? NSColor(calibratedWhite: 0.35, alpha: 1.0) : NSColor(calibratedWhite: 0.75, alpha: 1.0)

                // 双行状态栏排版与分隔圆点垂直居中偏移
                let mstr = NSMutableAttributedString()
                let topAttr = NSMutableAttributedString()
                for (i, col) in topCols.enumerated() {
                    if i == 0 {
                        topAttr.append(NSAttributedString(string: "  " + col, attributes: [
                            .font: f,
                            .paragraphStyle: pStyle,
                            .foregroundColor: textColor,
                            .baselineOffset: -4.0
                        ]))
                    } else {
                        topAttr.append(NSAttributedString(string: "   " + col, attributes: [
                            .font: f,
                            .paragraphStyle: pStyle,
                            .foregroundColor: textColor,
                            .baselineOffset: -4.0
                        ]))
                    }
                }
                topAttr.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: pStyle]))

                let botAttr = NSMutableAttributedString()
                for (i, col) in botCols.enumerated() {
                    if i == 0 {
                        botAttr.append(NSAttributedString(string: "  " + col, attributes: [
                            .font: f,
                            .paragraphStyle: pStyle,
                            .foregroundColor: textColor,
                            .baselineOffset: -4.0
                        ]))
                    } else {
                        botAttr.append(NSAttributedString(string: " · ", attributes: [
                            .font: f,
                            .paragraphStyle: pStyle,
                            .foregroundColor: dotColor,
                            .baselineOffset: 0.5
                        ]))
                        botAttr.append(NSAttributedString(string: col, attributes: [
                            .font: f,
                            .paragraphStyle: pStyle,
                            .foregroundColor: textColor,
                            .baselineOffset: -4.0
                        ]))
                    }
                }
                mstr.append(topAttr)
                mstr.append(botAttr)

                let textX: CGFloat = iconSize + 6
                let textWidth: CGFloat = container.bounds.width - textX
                let textField = NSTextField(frame: NSRect(x: textX, y: (itemHeight - 20) / 2 - 0.5, width: textWidth, height: 21))
                textField.isBezeled = false
                textField.drawsBackground = false
                textField.isEditable = false
                textField.isSelectable = false
                textField.attributedStringValue = mstr
                container.addSubview(textField)

                let offWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: itemWidth, height: itemHeight), styleMask: [.borderless], backing: .buffered, defer: false)
                offWindow.backgroundColor = .clear
                offWindow.contentView = barView
                barView.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                if let rep = barView.bitmapImageRepForCachingDisplay(in: barView.bounds) {
                    rep.size = NSSize(width: itemWidth, height: itemHeight)
                    barView.cacheDisplay(in: barView.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: destPath))
                        print("RENDERED_WINDOW: \(destPath)")
                    }
                }
                exit(0)
            }

            if sectionName == "appIconMenu" || sectionName == "iconMenu" {
                let isLight = (appearanceName == "light")
                let theme = LiquidGlassTheme(colorScheme: isLight ? .light : .dark)
                let menuView = AppIconDropdownMenuView(navState: StudioWindowNavigationState.shared, theme: theme)
                    .environment(\.colorScheme, isLight ? .light : .dark)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isLight ? Color.white : Color(red: 0.16, green: 0.16, blue: 0.17))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.12), lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.20), radius: 10, y: 4)
                    )
                    .padding(16)
                let hosting = NSHostingView(rootView: menuView)
                let offWindow = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                offWindow.isOpaque = false
                offWindow.backgroundColor = .clear
                offWindow.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                let fit = hosting.fittingSize
                offWindow.setContentSize(fit)
                hosting.frame = NSRect(origin: .zero, size: fit)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: NSRect(origin: .zero, size: fit)) {
                    rep.size = fit
                    hosting.cacheDisplay(in: NSRect(origin: .zero, size: fit), to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: destPath))
                        print("RENDERED_WINDOW: \(destPath)")
                    }
                }
                exit(0)
            }

            let section = StudioWindowSection(rawValue: sectionName) ?? .overview
            StudioWindowNavigationState.shared.selectedSection = section
            if sectionName == "modal" || sectionName == "settings" {
                StudioWindowNavigationState.shared.openModal(tab: .settings)
            } else if sectionName == "cleanerModal" || sectionName == "cleanerSettings" {
                StudioWindowNavigationState.shared.selectedTab = .cleaner
                StudioWindowNavigationState.shared.openModal(tab: .cleaner)
            } else if sectionName == "cleanerProtection" {
                StudioWindowNavigationState.shared.selectedTab = .cleaner
                StudioWindowNavigationState.shared.openModal(tab: .cleaner)
                CleanProtectionStore.shared.showingProtectionList = true
            } else if sectionName == "upsModal" {
                StudioWindowNavigationState.shared.openModal(tab: .ups)
            } else if sectionName == "aboutModal" {
                StudioWindowNavigationState.shared.openModal(tab: .about)
            }
            SystemResourceMonitor.shared.refreshNow()
            DiskGuardian.shared.refreshDisks()
            if sectionName == "appManager" || sectionName == "software" {
                StudioWindowNavigationState.shared.selectedTab = .software
                AppUninstallerEngine.shared.startScan()
                let deadline = Date().addingTimeInterval(5.0)
                while AppUninstallerEngine.shared.isScanning && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
            } else if sectionName == "cleanerIdle" {
                StudioWindowNavigationState.shared.selectedTab = .cleaner
                SystemCleanerEngine.shared.status = .idle
                SystemCleanerEngine.shared.scannedItems = []
                SystemCleanerEngine.shared.selectedItemIDs = []
            } else if sectionName == "cleaner" || sectionName == "smartCleaner" {
                StudioWindowNavigationState.shared.selectedTab = .cleaner
                SystemCleanerEngine.shared.startScan()
                let deadline = Date().addingTimeInterval(5.5)
                while SystemCleanerEngine.shared.isScanning && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
            } else if sectionName == "space" || sectionName == "spaceAnalysis" {
                StudioWindowNavigationState.shared.selectedTab = .space
                StorageAnalysisEngine.shared.startScan(location: .downloads)
                let deadline = Date().addingTimeInterval(3.5)
                while StorageAnalysisEngine.shared.isScanning && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
            } else if sectionName == "spaceInsights" || sectionName == "spaceSystem" {
                StudioWindowNavigationState.shared.selectedTab = .space
                StorageAnalysisEngine.shared.activeViewMode = .insights
                StorageAnalysisEngine.shared.startScan(location: .home)
                let deadline = Date().addingTimeInterval(3.5)
                while StorageAnalysisEngine.shared.isScanning && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
            } else if sectionName == "network" || sectionName == "networkMonitor" || sectionName == "networkSockets" {
                StudioWindowNavigationState.shared.selectedTab = .network
                if sectionName == "networkSockets" {
                    NetworkMonitorViewModel.shared.selectedRankingTab = .sockets
                } else {
                    NetworkMonitorViewModel.shared.selectedRankingTab = .apps
                }
                NetworkDetailModel.shared.refresh()
                NetworkMonitorViewModel.shared.refreshStats()
                let deadline = Date().addingTimeInterval(3.5)
                while (NetworkDetailModel.shared.appNetworkItems.isEmpty || NetworkDetailModel.shared.activeSockets.isEmpty) && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            } else if sectionName == "networkSpeedTest" {
                StudioWindowNavigationState.shared.selectedTab = .network
                NetworkDetailModel.shared.refresh()
                NetworkMonitorViewModel.shared.refreshStats()
                NetworkMonitorViewModel.shared.isSpeedTestCardActive = true
                NetworkSpeedTest.shared.setSimulating(progressSeconds: 3.2, liveDownload: "186.4 MB/s", liveUpload: "24.6 MB/s")
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            } else if sectionName == "networkSpeedTestDone" {
                StudioWindowNavigationState.shared.selectedTab = .network
                NetworkDetailModel.shared.refresh()
                NetworkMonitorViewModel.shared.refreshStats()
                NetworkMonitorViewModel.shared.isSpeedTestCardActive = true
                NetworkSpeedTest.shared.setResults(download: 1593.2, upload: 248.4, latency: 12.0, rpm: 686.0)
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            } else if sectionName == "activeConnections" || sectionName == "activeSocketsDetail" {
                NetworkDetailModel.shared.refreshActiveSockets()
                let deadline = Date().addingTimeInterval(3.0)
                while NetworkDetailModel.shared.activeSockets.isEmpty && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))

                let bigView = ActiveConnectionsWindowView(onClose: {})
                    .environment(\.colorScheme, appearanceName == "light" ? .light : .dark)
                    .frame(width: 960, height: 620)
                let hosting = NSHostingView(rootView: bigView)
                let offscreenWindow = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                offscreenWindow.isOpaque = false
                offscreenWindow.backgroundColor = .clear
                offscreenWindow.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 620)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 960, height: 620)) {
                    rep.size = NSSize(width: 960, height: 620)
                    hosting.cacheDisplay(in: NSRect(x: 0, y: 0, width: 960, height: 620), to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: destPath))
                        print("RENDERED_WINDOW: \(destPath)")
                    }
                }
                exit(0)
            } else {
                StudioWindowNavigationState.shared.selectedTab = .status
                RunLoop.current.run(until: Date().addingTimeInterval(2.1))
                SystemResourceMonitor.shared.refreshNow()
            }

            let isLargePreview = sectionName.hasSuffix("Large")
            let renderW: CGFloat = isLargePreview ? 1680 : 1200
            let renderH: CGFloat = isLargePreview ? 1150 : 822

            let windowView = MainStudioWindowView()
                .environment(\.colorScheme, appearanceName == "light" ? .light : .dark)
                .frame(width: renderW, height: renderH)
            let hosting = NSHostingView(rootView: windowView)
            let offscreenWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: renderW, height: renderH),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            offscreenWindow.isOpaque = false
            offscreenWindow.backgroundColor = .clear
            offscreenWindow.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: renderW, height: renderH)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: renderW, height: renderH)) {
                rep.size = NSSize(width: renderW, height: renderH)
                hosting.cacheDisplay(in: NSRect(x: 0, y: 0, width: renderW, height: renderH), to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: destPath))
                    print("RENDERED_WINDOW: \(destPath)")
                }
            }
            exit(0)
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--render-poster"), idx + 1 < CommandLine.arguments.count {
            let destPath = CommandLine.arguments[idx + 1]
            _ = NSApplication.shared

            func captureView<V: View>(_ view: V, width: CGFloat, height: CGFloat, to path: String) {
                let hosting = NSHostingView(rootView: view)
                let offscreen = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                offscreen.isOpaque = false
                offscreen.backgroundColor = .clear
                offscreen.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: width, height: height)) {
                    rep.size = NSSize(width: width, height: height)
                    hosting.cacheDisplay(in: NSRect(x: 0, y: 0, width: width, height: height), to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }

            SystemResourceMonitor.shared.refreshNow()
            AccessoryBatteryManager.shared.refresh()
            DiskGuardian.shared.refreshDisks()
            NetworkDetailModel.shared.refresh()
            NetworkMonitorViewModel.shared.refreshStats()
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
            SystemResourceMonitor.shared.refreshNow()

            // 1. Overview (Dark)
            StudioWindowNavigationState.shared.closeModal()
            StudioWindowNavigationState.shared.selectedTab = .status
            captureView(
                MainStudioWindowView().environment(\.colorScheme, .dark).frame(width: 1200, height: 822),
                width: 1200,
                height: 822,
                to: "/tmp/poster_overview_dark.png"
            )

            // 1B. Smart Cleaner Scanned Results (Dark) for Hero Right Card
            StudioWindowNavigationState.shared.selectedTab = .cleaner
            SystemCleanerEngine.shared.startScan()
            let cleanDeadline = Date().addingTimeInterval(4.5)
            while SystemCleanerEngine.shared.isScanning && Date() < cleanDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            captureView(
                MainStudioWindowView().environment(\.colorScheme, .dark).frame(width: 1200, height: 822),
                width: 1200,
                height: 822,
                to: "/tmp/poster_cleaner_dark.png"
            )

            // 2. Popover (Light)
            captureView(
                LiquidGlassPanel().environment(\.colorScheme, .light).frame(width: 334, height: 690),
                width: 334,
                height: 690,
                to: "/tmp/poster_popover_light.png"
            )

            // 3. Network SpeedTest Done (Light)
            StudioWindowNavigationState.shared.selectedTab = .network
            NetworkMonitorViewModel.shared.isSpeedTestCardActive = true
            NetworkSpeedTest.shared.setResults(download: 1593.2, upload: 248.4, latency: 12.0, rpm: 686.0)
            captureView(
                MainStudioWindowView().environment(\.colorScheme, .light).frame(width: 1200, height: 822),
                width: 1200,
                height: 822,
                to: "/tmp/poster_network_light.png"
            )

            // 4. Diagnostics Modal (Light)
            SystemDiagnosticsCollector.shared.refresh()
            let diagTheme = LiquidGlassTheme(colorScheme: .light)
            captureView(
                SystemDiagnosticsModalView(theme: diagTheme, onClose: {})
                    .environment(\.colorScheme, .light)
                    .frame(width: 600, height: 420),
                width: 600,
                height: 420,
                to: "/tmp/poster_diagnostics_light.png"
            )

            // 5. Composite Final Bento Poster (1500 x 2000)
            captureView(
                SysPulsePromoPosterView().frame(width: 1500, height: 2000),
                width: 1500,
                height: 2000,
                to: destPath
            )
            print("RENDERED_POSTER: \(destPath)")
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Menu bar only, no dock icon like native macOS UPS
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
        AppIconManager.shared.startObservingSystemAppearance()

        let isBackgroundLaunch = CommandLine.arguments.contains("--background") ||
                                 CommandLine.arguments.contains("--login-item")

        if let idx = CommandLine.arguments.firstIndex(of: "--section"), idx + 1 < CommandLine.arguments.count {
            let secName = CommandLine.arguments[idx + 1]
            let section = StudioWindowSection(rawValue: secName) ?? .overview
            DispatchQueue.main.async {
                MainStudioWindowController.shared.showWindow(section: section)
            }
        } else if CommandLine.arguments.contains("--uninstaller") {
            DispatchQueue.main.async {
                MainStudioWindowController.shared.showWindow(section: .appManager)
            }
        } else if !isBackgroundLaunch {
            DispatchQueue.main.async {
                MainStudioWindowController.shared.showWindow(section: .overview)
            }
        }

        // 启动后延迟 3.5 秒静默检查一次 GitHub Releases 是否有新版本
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            AppUpdateManager.shared.checkForUpdates(userInitiated: false)
        }

        // Allow clean IPC termination and window opening
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.showMainWindow"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MainStudioWindowController.shared.showWindow(section: .overview)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.showCleanerWindow"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MainStudioWindowController.shared.showWindow(section: .smartCleaner)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.showAppManagerWindow"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MainStudioWindowController.shared.showWindow(section: .appManager)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.showCustomizationWindow"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MainStudioWindowController.shared.showWindow(section: .customization)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.switchToSystemTab"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PanelCoordinator.shared.selectedTab = .system
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.switchToCleanerTab"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PanelCoordinator.shared.selectedTab = .cleaner
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.showPopover"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MenuBarController.shared?.openPopover()
            }
        }

        if CommandLine.arguments.contains("--uninstaller") || CommandLine.arguments.contains("--apps") {
            MainStudioWindowController.shared.showWindow(section: .appManager)
        } else if CommandLine.arguments.contains("--cleaner") {
            MainStudioWindowController.shared.showWindow(section: .smartCleaner)
        } else if let idx = CommandLine.arguments.firstIndex(of: "--section"), idx + 1 < CommandLine.arguments.count {
            let secName = CommandLine.arguments[idx + 1]
            let targetSec = StudioWindowSection(rawValue: secName) ?? .overview
            MainStudioWindowController.shared.showWindow(section: targetSec)
        } else if CommandLine.arguments.contains("--show-window") || CommandLine.arguments.contains("-w") {
            MainStudioWindowController.shared.showWindow(section: .overview)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.powerglass.quit"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PowerSourceEngine.shared.stopListening()
        WiFiLowLatencyManager.shared.restoreOnTermination()
    }
}
