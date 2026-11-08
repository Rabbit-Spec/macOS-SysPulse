import AppKit
import SwiftUI

@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    public static weak var shared: MenuBarController?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var lastRenderedTitle: String = ""
    private var lastRenderedIconKey: String = ""
    private weak var previousActiveApp: NSRunningApplication?

    public override init() {
        super.init()
        Self.shared = self
        setupStatusItem()
        observeEngine()
    }

    private func setupStatusItem() {
        // Native Apple variable length menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateButtonContent()
        }
    }

    private func makePopover() -> NSPopover {
        let newPopover = NSPopover()
        newPopover.contentSize = NSSize(width: 334, height: 700)
        newPopover.behavior = .transient
        newPopover.animates = true
        newPopover.appearance = nil
        newPopover.delegate = self

        let panelView = LiquidGlassPanel()
        let hostingController = NSHostingController(rootView: panelView)
        hostingController.sizingOptions = .preferredContentSize
        newPopover.contentViewController = hostingController
        return newPopover
    }

    private func observeEngine() {
        // Connect power state transitions to disk safety (multi-observer safe)
        PowerSourceEngine.shared.addPowerStateObserver(id: "MenuBarController") { [weak self] state in
            if FeatureToggleManager.shared.enableDiskGuardian {
                if state == .batteryPower {
                    DiskGuardian.shared.handlePowerOutageStarted()
                } else if state == .acPower {
                    DiskGuardian.shared.handlePowerRestored()
                }
            }
            self?.updateButtonContent()
        }

        PowerSourceEngine.shared.onTelemetryUpdated = { [weak self] in
            self?.updateButtonContent()
        }

        FeatureToggleManager.shared.onTogglesChanged = { [weak self] in
            SystemResourceMonitor.shared.refreshNow()
            self?.updateButtonContent()
        }

        SystemResourceMonitor.shared.onMetricsUpdated = { [weak self] in
            let t = FeatureToggleManager.shared
            if t.menuBarShowCpuGpu || t.menuBarShowMemTemp || t.menuBarShowNetworkSpeed || t.menuBarShowSystemWatts {
                self?.updateButtonContent()
            }
        }
    }

    /// Pure native AppKit status bar rendering with strict diffing:
    /// Never mutates NSStatusBarButton unless text or icon state actually changed,
    /// preventing NSStatusBarWindow layout invalidations from blocking Full Screen menu bar auto-hide.
    public func updateButtonContent() {
        guard let button = statusItem.button else { return }

        let toggles = FeatureToggleManager.shared
        let monitor = SystemResourceMonitor.shared

        // 1. 状态栏萌兔模板图标
        let rabbitIcon = MenuBarRabbitIcon.templateIcon
        if button.image !== rabbitIcon {
            button.image = rabbitIcon
        }

        // 2. 构建双行状态栏指标文本
        var topColumns: [String] = []
        var bottomColumns: [String] = []

        if toggles.menuBarShowCpuGpu {
            let cpuPct = max(0, min(100, Int(round(monitor.power.cpuUsagePercent))))
            let gpuPct = max(0, min(100, Int(round(monitor.hardware.gpuUsagePercent))))
            topColumns.append(formatMetric(prefix: "CPU", value: cpuPct, unit: "%"))
            bottomColumns.append(formatMetric(prefix: "GPU", value: gpuPct, unit: "%"))
        }

        if toggles.menuBarShowMemTemp {
            let memPct = max(0, min(100, monitor.memory.usedPercent))
            let tempC = max(0, min(120, Int(round(monitor.hardware.cpuTemperatureC))))
            topColumns.append(formatMetric(prefix: "RAM", value: memPct, unit: "%"))
            bottomColumns.append(formatMetric(prefix: "TMP", value: tempC, unit: "°"))
        }

        if toggles.menuBarShowNetworkSpeed {
            let up = formatSpeedDualRow(monitor.hardware.networkUploadBytesPerSec)
            let down = formatSpeedDualRow(monitor.hardware.networkDownloadBytesPerSec)
            topColumns.append("↑ \(up)")
            bottomColumns.append("↓ \(down)")
        }

        if toggles.menuBarShowSystemWatts && toggles.enableSystemPowerMonitor {
            let peak = max(1, Int(round(max(monitor.power.peakWatts, monitor.power.totalSystemWatts))))
            let cur = max(1, Int(round(monitor.power.totalSystemWatts)))
            topColumns.append(formatMetric(prefix: "MAX", value: peak, unit: "W"))
            bottomColumns.append(formatMetric(prefix: "PWR", value: cur, unit: "W"))
        }

        // 3. Fallback to Pure Icon Mode if all modules disabled
        let hasContent = !topColumns.isEmpty && !bottomColumns.isEmpty
        if !hasContent {
            if lastRenderedTitle != "" {
                lastRenderedTitle = ""
                button.attributedTitle = NSAttributedString(string: "")
                button.title = ""
                button.imagePosition = .imageOnly
            }
            return
        }

        // 4. 拼接双行状态栏文本
        let trackingKey = "\(topColumns.joined(separator: "|"))\n\(bottomColumns.joined(separator: "|"))"

        if trackingKey != lastRenderedTitle {
            lastRenderedTitle = trackingKey
            button.imagePosition = .imageLeading

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = -1.5
            paragraphStyle.maximumLineHeight = 10.0
            paragraphStyle.minimumLineHeight = 10.0
            paragraphStyle.alignment = .left

            let font = NSFont.monospacedSystemFont(ofSize: 9.0, weight: .semibold)
            let mstr = NSMutableAttributedString()

            let topAttr = NSMutableAttributedString()
            for (i, col) in topColumns.enumerated() {
                if i == 0 {
                    topAttr.append(NSAttributedString(string: "  " + col, attributes: [
                        .font: font,
                        .paragraphStyle: paragraphStyle,
                        .baselineOffset: -4.0
                    ]))
                } else {
                    topAttr.append(NSAttributedString(string: "   " + col, attributes: [
                        .font: font,
                        .paragraphStyle: paragraphStyle,
                        .baselineOffset: -4.0
                    ]))
                }
            }
            topAttr.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraphStyle]))

            // 下行分隔符通过 baselineOffset 居中对齐于双行之间
            let botAttr = NSMutableAttributedString()
            for (i, col) in bottomColumns.enumerated() {
                if i == 0 {
                    botAttr.append(NSAttributedString(string: "  " + col, attributes: [
                        .font: font,
                        .paragraphStyle: paragraphStyle,
                        .baselineOffset: -4.0
                    ]))
                } else {
                    botAttr.append(NSAttributedString(string: " · ", attributes: [
                        .font: font,
                        .paragraphStyle: paragraphStyle,
                        .baselineOffset: 0.5
                    ]))
                    botAttr.append(NSAttributedString(string: col, attributes: [
                        .font: font,
                        .paragraphStyle: paragraphStyle,
                        .baselineOffset: -4.0
                    ]))
                }
            }

            mstr.append(topAttr)
            mstr.append(botAttr)
            button.attributedTitle = mstr
        }
    }

    private func formatMetric(prefix: String, value: Int, unit: String) -> String {
        let v = max(0, min(999, value))
        if v < 10 {
            return "\(prefix)  \(v)\(unit)"
        } else if v < 100 {
            return "\(prefix) \(v)\(unit)"
        } else {
            return "\(prefix)\(v)\(unit)"
        }
    }

    private func formatSpeedDualRow(_ bytesPerSec: Double) -> String {
        let k: Double = 1024
        let m: Double = 1024 * 1024
        let g: Double = 1024 * 1024 * 1024

        if bytesPerSec < 1000 {
            return "  0 KB/s"
        } else if bytesPerSec < m {
            let kb = bytesPerSec / k
            if kb < 10 {
                return String(format: "  %.0f KB/s", kb)
            } else if kb < 100 {
                return String(format: " %.0f KB/s", kb)
            } else {
                return String(format: "%.0f KB/s", min(999, kb))
            }
        } else if bytesPerSec < g {
            let mb = bytesPerSec / m
            if mb < 10 {
                return String(format: "%.1f MB/s", mb)
            } else if mb < 100 {
                return String(format: " %.0f MB/s", mb)
            } else {
                return String(format: "%.0f MB/s", min(999, mb))
            }
        } else {
            let gb = bytesPerSec / g
            return String(format: "%.1f GB/s", min(9.9, gb))
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            showMainMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    // MARK: - 状态栏右键菜单

    @objc public func showMainMenu(_ sender: AnyObject?) {
        closePopover(deactivateApp: false)
        let menu = NSMenu(title: "SysPulse")

        let openItem = NSMenuItem(title: "打开 SysPulse", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openItem)

        let statusItem = NSMenuItem(title: "显示状态总览", action: #selector(openStatusOverview), keyEquivalent: "1")
        statusItem.target = self
        statusItem.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)
        menu.addItem(statusItem)

        let cleanerItem = NSMenuItem(title: "智能清理", action: #selector(openSmartCleaner), keyEquivalent: "2")
        cleanerItem.target = self
        cleanerItem.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil)
        menu.addItem(cleanerItem)

        let appItem = NSMenuItem(title: "应用管理", action: #selector(openAppManager), keyEquivalent: "3")
        appItem.target = self
        appItem.image = NSImage(systemSymbolName: "app.badge.checkmark", accessibilityDescription: nil)
        menu.addItem(appItem)

        let spaceItem = NSMenuItem(title: "空间分析", action: #selector(openSpaceAnalysis), keyEquivalent: "4")
        spaceItem.target = self
        spaceItem.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        menu.addItem(spaceItem)

        menu.addItem(.separator())

        // 保持常亮子菜单
        let keepAwake = KeepAwakeController.shared
        let keepAwakeItem = NSMenuItem(
            title: keepAwake.isActive ? "常亮已开启 (\(keepAwake.remainingFormattedText))" : "保持常亮",
            action: nil,
            keyEquivalent: ""
        )
        keepAwakeItem.image = NSImage(systemSymbolName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: nil)
        keepAwakeItem.state = keepAwake.isActive ? .on : .off

        let keepAwakeSub = NSMenu(title: "保持常亮")
        if keepAwake.isActive {
            let stopItem = NSMenuItem(title: "停止常亮", action: #selector(stopKeepAwakeAction), keyEquivalent: "")
            stopItem.target = self
            keepAwakeSub.addItem(stopItem)
            keepAwakeSub.addItem(.separator())
        }

        for dur in [KeepAwakeDuration.indefinitely, .minutes15, .minutes30, .oneHour, .twoHours, .fourHours, .eightHours] {
            let item = NSMenuItem(title: dur.rawValue, action: #selector(selectKeepAwakeDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dur
            if keepAwake.isActive && keepAwake.currentDuration == dur {
                item.state = .on
            }
            keepAwakeSub.addItem(item)
        }

        keepAwakeSub.addItem(.separator())

        // 常亮模式选项
        let modeHeader = NSMenuItem(title: "常亮模式：", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        keepAwakeSub.addItem(modeHeader)

        for beh in KeepAwakeBehavior.allCases {
            let item = NSMenuItem(title: "\(beh.rawValue) (\(beh.detailText))", action: #selector(selectKeepAwakeBehavior(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = beh
            if keepAwake.currentBehavior == beh {
                item.state = .on
            }
            keepAwakeSub.addItem(item)
        }

        keepAwakeItem.submenu = keepAwakeSub
        menu.addItem(keepAwakeItem)

        let networkItem = NSMenuItem(title: "网络与测速", action: #selector(openNetworkDetailAction), keyEquivalent: "n")
        networkItem.target = self
        networkItem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
        menu.addItem(networkItem)

        let fanCooling = (FanController.shared.activeMode != .auto)
        let fanItem = NSMenuItem(title: fanCooling ? "风扇正在降温" : "风扇降温", action: #selector(toggleFanCooling), keyEquivalent: "f")
        fanItem.target = self
        fanItem.state = fanCooling ? .on : .off
        fanItem.image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)
        menu.addItem(fanItem)

        let wifiActive = WiFiLowLatencyManager.shared.isLowLatencyActive
        let wifiItem = NSMenuItem(title: wifiActive ? "WiFi 低延迟已开启" : "WiFi 低延迟", action: #selector(toggleWiFiLatency), keyEquivalent: "w")
        wifiItem.target = self
        wifiItem.state = wifiActive ? .on : .off
        wifiItem.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)
        menu.addItem(wifiItem)

        let cleanScreenItem = NSMenuItem(title: "清洁屏幕", action: #selector(cleanScreenAction), keyEquivalent: "k")
        cleanScreenItem.target = self
        cleanScreenItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(cleanScreenItem)

        menu.addItem(.separator())

        let upsItem = NSMenuItem(title: "UPS 关机设置", action: #selector(openUPSSettings), keyEquivalent: "")
        upsItem.target = self
        upsItem.image = NSImage(systemSymbolName: "bolt.shield", accessibilityDescription: nil)
        menu.addItem(upsItem)

        let settingsItem = NSMenuItem(title: "功能与选项设置…", action: #selector(openCustomizationWindow), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "关于 SysPulse", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 SysPulse", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        if let btn = self.statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func openMainWindow() {
        MainStudioWindowController.shared.showWindow(section: .overview)
    }

    @objc private func openStatusOverview() {
        MainStudioWindowController.shared.showWindow(section: .overview)
    }

    @objc private func openSmartCleaner() {
        MainStudioWindowController.shared.showWindow(section: .smartCleaner)
    }

    @objc private func openAppManager() {
        MainStudioWindowController.shared.showWindow(section: .appManager)
    }

    @objc private func openSpaceAnalysis() {
        MainStudioWindowController.shared.showWindow(section: .spaceAnalysis)
    }

    @objc private func openNetworkDetailAction() {
        closePopover(deactivateApp: false)
        StudioWindowNavigationState.shared.isNetworkDetailPresented = true
        openPopover()
    }

    @objc private func stopKeepAwakeAction() {
        KeepAwakeController.shared.deactivate()
    }

    @objc private func selectKeepAwakeDuration(_ sender: NSMenuItem) {
        if let dur = sender.representedObject as? KeepAwakeDuration {
            KeepAwakeController.shared.activate(duration: dur)
        }
    }

    @objc private func selectKeepAwakeBehavior(_ sender: NSMenuItem) {
        if let beh = sender.representedObject as? KeepAwakeBehavior {
            KeepAwakeController.shared.setBehavior(beh)
        }
    }

    @objc private func toggleFanCooling() {
        let fan = FanController.shared
        if fan.activeMode == .auto {
            fan.setMode(.cool)
        } else {
            fan.setMode(.auto)
        }
    }

    @objc private func toggleWiFiLatency() {
        WiFiLowLatencyManager.shared.toggleLowLatency()
    }

    @objc private func cleanScreenAction() {
        ScreenCleanerWindowController.shared.startCleaning()
    }

    @objc private func openUPSSettings() {
        MainStudioWindowController.shared.showWindow(section: .upsCenter)
    }

    @objc private func openCustomizationWindow() {
        MainStudioWindowController.shared.showWindow(section: .customization)
    }

    @objc private func openAbout() {
        MainStudioWindowController.shared.showWindow(section: .about)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    public func closePopover(deactivateApp: Bool = true) {
        if !deactivateApp {
            previousActiveApp = nil
        }
        if let existing = popover, existing.isShown {
            existing.performClose(nil)
        }
    }

    public func openPopover() {
        guard let button = statusItem.button else { return }
        if popover == nil || !(popover?.isShown ?? false) {
            PanelCoordinator.shared.activeScreen = .dashboard
            PowerSourceEngine.shared.setPanelVisible(true)
            SystemResourceMonitor.shared.refreshNow()
            DiskGuardian.shared.refreshDisks()

            let newPopover = makePopover()
            self.popover = newPopover
            NSApp.activate(ignoringOtherApps: true)
            newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if let existing = popover, existing.isShown {
            existing.performClose(sender)
        } else {
            // Remember the frontmost app (e.g., Full Screen app) so we can return focus cleanly on close
            let frontApp = NSWorkspace.shared.frontmostApplication
            if frontApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousActiveApp = frontApp
            }

            // Always reset to Home Dashboard before showing popover
            PanelCoordinator.shared.activeScreen = .dashboard
            PanelCoordinator.shared.isEventsExpanded = false

            // Mark panel visible and refresh latest hardware telemetry
            PowerSourceEngine.shared.setPanelVisible(true)
            SystemResourceMonitor.shared.refreshNow()
            DiskGuardian.shared.refreshDisks()

            // Create popover on-demand and show
            let newPopover = makePopover()
            self.popover = newPopover
            NSApp.activate(ignoringOtherApps: true)
            newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        if !MainStudioWindowController.shared.isWindowVisible {
            PowerSourceEngine.shared.setPanelVisible(false)
        }
        PanelCoordinator.shared.activeScreen = .dashboard
        PanelCoordinator.shared.isEventsExpanded = false

        // Completely detach _NSPopoverWindow from NSStatusBarWindow so Full Screen menu bar is never pinned
        popover?.contentViewController = nil
        popover?.delegate = nil
        popover = nil

        statusItem.button?.highlight(false)
        statusItem.button?.window?.resignKey()

        // Only yield focus back if the user did not just open the standalone MainStudioWindow
        if !MainStudioWindowController.shared.isWindowVisible {
            if let prev = previousActiveApp, !prev.isTerminated {
                prev.activate()
            } else {
                NSApp.deactivate()
            }
        }
        previousActiveApp = nil
    }
}
