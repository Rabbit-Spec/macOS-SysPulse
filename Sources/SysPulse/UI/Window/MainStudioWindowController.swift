import AppKit
import SwiftUI
import Observation

public enum StudioTopTab: String, CaseIterable, Identifiable, Sendable {
    case status = "状态"
    case network = "网络"
    case cleaner = "清理"
    case software = "软件"
    case space = "空间"

    public var id: String { rawValue }
}

public enum StudioModalTab: String, CaseIterable, Identifiable, Sendable {
    case cleaner = "清理设置"
    case settings = "系统设置"
    case ups = "UPS 设置"
    case about = "关于 SysPulse"

    public var id: String { rawValue }
}

public enum StudioWindowSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "overview"
    case smartCleaner = "smartCleaner"
    case appManager = "appManager"
    case spaceAnalysis = "spaceAnalysis"
    case networkMonitor = "networkMonitor"
    case upsCenter = "upsCenter"
    case customization = "customization"
    case about = "about"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "状态"
        case .smartCleaner: return "清理"
        case .appManager: return "软件"
        case .spaceAnalysis: return "空间"
        case .networkMonitor: return "网络"
        case .upsCenter: return "UPS 设置"
        case .customization: return "设置"
        case .about: return "关于 SysPulse"
        }
    }

    public var subtitle: String {
        switch self {
        case .overview: return "实时硬件状态、整机功耗与进程排行"
        case .smartCleaner: return "应用缓存、系统日志、开发产物与废纸篓安全清理"
        case .appManager: return "应用空间占用分析、一键彻底卸载与残留垃圾扫描"
        case .spaceAnalysis: return "目录层级深度钻取、巨量大文件穿透与容易漏掉的空间解读"
        case .networkMonitor: return "实时掌控上下行带宽、链路延迟与应用流量分布，内置硬件级链路遥测与测速诊断"
        case .upsCenter: return "外接 UPS 监控、断电保护与外接盘安全推出"
        case .customization: return "开启或关闭监测模块、菜单栏显示与弹窗项目"
        case .about: return "连接 UPS 与版本信息"
        }
    }

    public var iconName: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .smartCleaner: return "sparkles.rectangle.stack.fill"
        case .appManager: return "app.badge.checkmark.fill"
        case .spaceAnalysis: return "circle.hexagongrid.fill"
        case .networkMonitor: return "network"
        case .upsCenter: return "bolt.shield.fill"
        case .customization: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }
}

public enum ProcessSortField: String, CaseIterable, Sendable {
    case name = "名称"
    case memory = "内存"
    case cpu = "% CPU"
    case energy = "能耗"
    case pid = "PID"
}

public enum ProcessSortOrder: Sendable {
    case ascending
    case descending
}

@Observable
@MainActor
public final class StudioWindowNavigationState {
    public static let shared = StudioWindowNavigationState()
    public var selectedTab: StudioTopTab = .status
    public var isModalPresented: Bool = false
    public var activeModalTab: StudioModalTab = .settings
    public var isIconMenuPresented: Bool = false
    public var fanMode: String = "自动"
    public var isProcessTableHovered: Bool = false
    public var displayedProcesses: [EnergyAppItem] = []
    public var processSortField: ProcessSortField = .energy
    public var processSortOrder: ProcessSortOrder = .descending
    public var cleanerSortField: CleanerSortField = .size
    public var cleanerSortOrder: ProcessSortOrder = .descending
    public var hoveredCleanerItemID: UUID? = nil
    public var cleanerBucketFilter: CleanReviewBucket? = nil
    public var isCleanerOptionsPresented: Bool = false
    public var isNetworkDetailPresented: Bool = false
    public var isDiagnosticsModalPresented: Bool = false
    public var isUpdateModalPresented: Bool = false
    public var hoveredOverviewCardID: String? = nil
    public var hoveredPopoverCardID: String? = nil

    public func toggleSort(field: ProcessSortField) {
        if processSortField == field {
            processSortOrder = (processSortOrder == .ascending) ? .descending : .ascending
        } else {
            processSortField = field
            processSortOrder = (field == .name) ? .ascending : .descending
        }
    }

    public func toggleCleanerSort(field: CleanerSortField) {
        if cleanerSortField == field {
            cleanerSortOrder = (cleanerSortOrder == .ascending) ? .descending : .ascending
        } else {
            cleanerSortField = field
            cleanerSortOrder = (field == .name) ? .ascending : .descending
        }
    }

    public func updateDisplayedProcesses(from apps: [EnergyAppItem]) {
        if displayedProcesses.isEmpty || !isProcessTableHovered {
            displayedProcesses = apps
        } else {
            // In-place metric update: keep row positions steady so user mouse interactions remain steady
            for i in 0..<displayedProcesses.count {
                if let updated = apps.first(where: { $0.pid == displayedProcesses[i].pid }) {
                    displayedProcesses[i] = updated
                }
            }
        }
    }

    public func openModal(tab: StudioModalTab) {
        self.isDiagnosticsModalPresented = false
        self.isUpdateModalPresented = false
        self.activeModalTab = tab
        self.isModalPresented = true
    }

    public func openUpdateModal() {
        self.isDiagnosticsModalPresented = false
        self.isUpdateModalPresented = true
        self.isModalPresented = true
    }

    public func closeModal() {
        self.isDiagnosticsModalPresented = false
        self.isUpdateModalPresented = false
        self.isModalPresented = false
    }

    public var selectedSection: StudioWindowSection {
        get {
            if isModalPresented {
                switch activeModalTab {
                case .cleaner: return .smartCleaner
                case .settings: return .customization
                case .ups: return .upsCenter
                case .about: return .about
                }
            }
            switch selectedTab {
            case .status: return .overview
            case .cleaner: return .smartCleaner
            case .software: return .appManager
            case .space: return .spaceAnalysis
            case .network: return .networkMonitor
            }
        }
        set {
            switch newValue {
            case .overview:
                selectedTab = .status
                isModalPresented = false
            case .smartCleaner:
                selectedTab = .cleaner
                isModalPresented = false
            case .appManager:
                selectedTab = .software
                isModalPresented = false
            case .spaceAnalysis:
                selectedTab = .space
                isModalPresented = false
            case .networkMonitor:
                selectedTab = .network
                isModalPresented = false
            case .customization:
                openModal(tab: .settings)
            case .upsCenter:
                openModal(tab: .ups)
            case .about:
                openModal(tab: .about)
            }
        }
    }

    private init() {}
}

@MainActor
public final class MainStudioWindowController: NSObject, NSWindowDelegate {
    public static let shared = MainStudioWindowController()

    private var window: NSWindow?
    public private(set) var isWindowVisible: Bool = false

    private override init() {
        super.init()
    }

    public func showWindow(section: StudioWindowSection? = nil) {
        if let section {
            StudioWindowNavigationState.shared.selectedSection = section
        }

        // Close popover cleanly without deactivating app
        MenuBarController.shared?.closePopover(deactivateApp: false)

        // Refresh telemetry & hardware monitors immediately
        PowerSourceEngine.shared.setPanelVisible(true)
        SystemResourceMonitor.shared.refreshNow()
        DiskGuardian.shared.refreshDisks()

        let defaultWidth: CGFloat = 1200
        let defaultHeight: CGFloat = 822

        let targetScreen: NSScreen = {
            let mouseLoc = NSEvent.mouseLocation
            if let screenUnderMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
                return screenUnderMouse
            }
            return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        }()

        let screenRect = targetScreen.visibleFrame
        let centerX = screenRect.origin.x + max(0, (screenRect.width - defaultWidth) / 2.0)
        let centerY = screenRect.origin.y + max(0, (screenRect.height - defaultHeight) / 2.0)
        let centeredRect = NSRect(x: centerX, y: centerY, width: defaultWidth, height: defaultHeight)

        if window == nil {
            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight))
            containerView.autoresizesSubviews = true

            let hostingView = NSHostingView(rootView: MainStudioWindowView())
            hostingView.sizingOptions = []
            hostingView.translatesAutoresizingMaskIntoConstraints = true
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = containerView.bounds
            containerView.addSubview(hostingView)

            let newWindow = NSWindow(
                contentRect: centeredRect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "SysPulse"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.titlebarSeparatorStyle = .none
            newWindow.isMovableByWindowBackground = true
            newWindow.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.contentView = containerView
            newWindow.minSize = NSSize(width: defaultWidth, height: defaultHeight)
            newWindow.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            newWindow.setFrame(centeredRect, display: true)
            self.window = newWindow
        }

        isWindowVisible = true
        if let win = window {
            win.minSize = NSSize(width: defaultWidth, height: defaultHeight)
            win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            // 若窗口当前不可见或在初次展示时，以默认尺寸 1200 × 822 居中放置
            if !win.isVisible {
                win.setFrame(centeredRect, display: true)
            }
        }
        window?.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]

        // Switch away from any full-screen app Space and jump back to the Desktop Space
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate()
        }

        NSApp.setActivationPolicy(.regular)
        AppIconManager.shared.applyCurrentAppearanceIcon(force: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let win = self.window else { return }
            win.minSize = NSSize(width: defaultWidth, height: defaultHeight)
            win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            win.orderFrontRegardless()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return NSSize(
            width: max(1200, frameSize.width),
            height: max(822, frameSize.height)
        )
    }

    public func windowWillClose(_ notification: Notification) {
        isWindowVisible = false
        PowerSourceEngine.shared.setPanelVisible(false)
        // Return to lightweight menu bar agent mode so Full Screen menu bar auto-hide is never blocked
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }
}
