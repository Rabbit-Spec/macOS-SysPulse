import SwiftUI
import AppKit

// MARK: - 废纸篓残留提醒浮动面板

@MainActor
public final class TrashRemnantFloatingPanelController {
    public static let shared = TrashRemnantFloatingPanelController()

    private var panel: NSPanel?

    private init() {}

    public func present() {
        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 396, height: 156),
                styleMask: [.nonactivatingPanel, .borderless, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.hidesOnDeactivate = false
            newPanel.isMovableByWindowBackground = true

            let hosting = NSHostingView(rootView: TrashRemnantFloatingCardView(watcher: TrashRemnantWatcher.shared))
            hosting.sizingOptions = [.intrinsicContentSize]
            newPanel.contentView = hosting
            panel = newPanel
        }

        guard let panel else { return }
        if let screenFrame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame {
            panel.layoutIfNeeded()
            let size = panel.contentView?.fittingSize ?? NSSize(width: 396, height: 164)
            let origin = NSPoint(
                x: screenFrame.maxX - size.width - 20,
                y: screenFrame.maxY - size.height - 16
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
    }

    public func dismiss() {
        panel?.orderOut(nil)
    }
}

private struct TrashRemnantFloatingCardView: View {
    @Bindable var watcher: TrashRemnantWatcher
    @Environment(\.colorScheme) private var colorScheme

    private var theme: LiquidGlassTheme {
        LiquidGlassTheme(colorScheme: colorScheme)
    }

    var body: some View {
        if let app = watcher.detectedApp {
            VStack(alignment: .leading, spacing: 12) {
                headerRow(for: app)

                if watcher.isExpanded {
                    expandedComponentList(for: app)
                }

                if let msg = watcher.statusMessage {
                    Text(msg)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.green)
                        .lineLimit(2)
                } else {
                    actionButtonsRow
                }
            }
            .padding(16)
            .frame(width: 396)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(colorScheme == .dark ? 0.16 : 0.45),
                                lineWidth: 1
                            )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.16), radius: 18, y: 8)
            .padding(6)
        }
    }

    private func headerRow(for app: InstalledAppInfo) -> some View {
        let totalStr = ByteCountFormatter.string(fromByteCount: watcher.selectedTotalBytes, countStyle: .file)
        return HStack(spacing: 12) {
            Image(nsImage: AppIconLookupCache.shared.icon(forFilePath: app.bundleURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("检测到「\(app.name)」移入废纸篓")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Text("发现 \(app.components.count) 项关联残留 · 已选 \(totalStr)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    watcher.isExpanded.toggle()
                }
            } label: {
                Image(systemName: watcher.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Button {
                watcher.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
    }

    private func expandedComponentList(for app: InstalledAppInfo) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(app.components) { comp in
                    let isSelected = watcher.selectedComponentIDs.contains(comp.id)
                    Button {
                        watcher.toggleComponent(comp.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(isSelected ? Color.accentColor : theme.secondaryText)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(comp.path.lastPathComponent)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(theme.primaryText)
                                    .lineLimit(1)
                                Text(comp.evidenceLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 6)

                            Text(comp.formattedSize)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 196)
    }

    private var actionButtonsRow: some View {
        let selectedBytesStr = ByteCountFormatter.string(fromByteCount: watcher.selectedTotalBytes, countStyle: .file)
        return HStack(spacing: 8) {
            Button {
                watcher.ignoreCurrentApp()
            } label: {
                Text("忽略此应用")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                watcher.cleanSelectedRemnants()
            } label: {
                HStack(spacing: 5) {
                    if watcher.isCleaning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(watcher.selectedComponentIDs.isEmpty ? "无选中项" : "移入废纸篓 (\(selectedBytesStr))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    Capsule().fill(watcher.selectedComponentIDs.isEmpty ? Color.gray : Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .disabled(watcher.isCleaning || watcher.selectedComponentIDs.isEmpty)
        }
    }
}
