import AppKit
import SwiftUI

@MainActor
public final class ScreenCleanerWindowController: NSWindowController {
    public static let shared = ScreenCleanerWindowController()

    private var localEventMonitor: Any?

    private init() {
        let window = NSWindow(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)

        let rootView = ScreenCleanerView(onExit: { [weak self] in
            self?.closeCleaner()
        })
        window.contentView = NSHostingView(rootView: rootView)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func startCleaning() {
        guard let window = self.window else { return }
        if let screen = NSScreen.main {
            window.setFrame(screen.frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let existingMonitor = localEventMonitor {
            NSEvent.removeMonitor(existingMonitor)
            localEventMonitor = nil
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                self?.closeCleaner()
                return nil
            }
            return event
        }
    }

    public func closeCleaner() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        window?.orderOut(nil)
    }
}

public struct ScreenCleanerView: View {
    public var onExit: () -> Void

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.cyan)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 8) {
                    Text("清洁屏幕模式已开启")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)

                    Text("黑屏已锁住键盘，可随意擦拭显示器与键盘表面。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                Button(action: onExit) {
                    HStack(spacing: 6) {
                        Text("按 Esc 退出")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
    }
}
