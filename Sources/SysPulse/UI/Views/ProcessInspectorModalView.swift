import SwiftUI
import AppKit
import Observation
import Darwin

// MARK: - 进程深度透视弹窗状态模型

@Observable
@MainActor
public final class ProcessInspectorViewModel {
    public var app: EnergyAppItem
    public var snapshot: ProcessInspectionSnapshot?
    public var isLoading: Bool = true
    public var isMembersExpanded: Bool = false
    public var confirmForceKill: Bool = false
    public var didCopySummary: Bool = false

    public init(app: EnergyAppItem) {
        self.app = app
    }

    public func load() {
        isLoading = true
        let target = app
        Task { @MainActor [weak self] in
            let snap = await ProcessInspectorService.inspect(app: target)
            guard let self, self.app.pid == target.pid else { return }
            self.snapshot = snap
            self.isLoading = false
        }
    }

    public func copySummary() {
        guard let snap = snapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snap.exportDiagnosticText(), forType: .string)
        didCopySummary = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.didCopySummary = false
        }
    }

    public func revealInFinder() {
        let pid = app.pid
        if let running = NSRunningApplication(processIdentifier: pid),
           let url = running.bundleURL ?? running.executableURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if let path = snapshot?.executablePath,
           !path.isEmpty,
           path != "未知路径",
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    public func terminate(force: Bool, onDismiss: @escaping () -> Void) {
        let pid = app.pid
        guard !ProcessInspectorService.isProtected(pid: pid, name: app.name) else { return }
        if force && !confirmForceKill {
            confirmForceKill = true
            return
        }
        if let running = NSRunningApplication(processIdentifier: pid) {
            if force {
                _ = running.forceTerminate()
            } else {
                _ = running.terminate()
            }
        } else {
            _ = Darwin.kill(pid, force ? SIGKILL : SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            SystemResourceMonitor.shared.refreshNow()
        }
        onDismiss()
    }
}

// MARK: - 进程深度透视弹窗视图

public struct ProcessInspectorModalView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var vm: ProcessInspectorViewModel
    let theme: LiquidGlassTheme
    let onClose: () -> Void

    public init(vm: ProcessInspectorViewModel, theme: LiquidGlassTheme, onClose: @escaping () -> Void) {
        self.vm = vm
        self.theme = theme
        self.onClose = onClose
    }

    public var body: some View {
        let glassShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(alignment: .leading, spacing: 14) {
            headerSection

            if vm.isLoading && vm.snapshot == nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在采集内核进程遥测与服务链路…")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if let snap = vm.snapshot {
                summarySection(snap)

                Divider().overlay(theme.dividerColor.opacity(0.42))

                metricsGridSection(snap)

                Divider().overlay(theme.dividerColor.opacity(0.35))

                pathsSection(snap)

                Divider().overlay(theme.dividerColor.opacity(0.35))

                membersSection(snap)

                footerActionsSection(snap)
            }
        }
        .padding(20)
        .frame(width: 530)
        .background(
            glassShape
                .fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.26))
        )
        .glassEffect(.regular, in: glassShape)
        .overlay(
            glassShape
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.55),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 24, y: 12)
        .onAppear {
            vm.load()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 11) {
            inspectorAppIcon
                .frame(width: 28, height: 28)

            Text(vm.app.name)
                .font(.system(size: 17.5, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
    }

    @ViewBuilder
    private var inspectorAppIcon: some View {
        if let img = Self.resolveIcon(pid: vm.app.pid, bundleIdentifier: vm.app.bundleIdentifier) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 19))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func summarySection(_ snap: ProcessInspectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snap.formattedSummaryHeader)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(snap.lineageChain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.primaryText.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(snap.lineageChain)
        }
    }

    private func metricsGridSection(_ snap: ProcessInspectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 18) {
                metricCell(label: "线程数", value: "\(snap.threadCount)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                metricCell(label: "打开文件", value: "\(snap.openFileCount)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                metricCell(label: "运行时长", value: snap.uptimeFormatted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 18) {
                metricCell(label: "launchd 触发原因", value: snap.launchdTriggerReason)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metricCell(label: "launchd 服务", value: snap.launchdServiceName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 18) {
                metricCell(label: "磁盘 I/O", value: snap.formattedDiskIO)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("监听端口")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)

                    Text(snap.listeningPortsSummary)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(snap.listeningPortsSummary)

                    if snap.isListeningOnPublicInterface {
                        warningBadge("进程正在监听公开网络接口")
                    }
                    if snap.isPreventingSleep {
                        warningBadge("正在阻止系统休眠")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    private func warningBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.28))
            .lineLimit(1)
    }

    private func pathsSection(_ snap: ProcessInspectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            pathItem(label: "可执行文件", path: snap.executablePath)
            pathItem(label: "工作目录", path: snap.workingDirectory)
        }
    }

    private func pathItem(label: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text(path)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.primaryText.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
        }
    }

    private func membersSection(_ snap: ProcessInspectionSnapshot) -> some View {
        let visibleMembers = vm.isMembersExpanded ? snap.members : Array(snap.members.prefix(5))
        let hiddenMembers = vm.isMembersExpanded ? [] : Array(snap.members.dropFirst(5))
        let hiddenMemSum = hiddenMembers.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }

        return VStack(alignment: .leading, spacing: 7) {
            Text("进程")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)

            ScrollView(.vertical, showsIndicators: vm.isMembersExpanded) {
                VStack(spacing: 7) {
                    ForEach(visibleMembers) { member in
                        HStack(spacing: 10) {
                            Text(member.name)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(member.pid)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 54, alignment: .trailing)
                            Text(String(format: "%.1f%%", member.cpuPercent))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 48, alignment: .trailing)
                            Text(member.formattedMemory)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .frame(width: 68, alignment: .trailing)
                        }
                        .padding(.vertical, 1.5)
                    }

                    if !hiddenMembers.isEmpty {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                vm.isMembersExpanded = true
                            }
                        } label: {
                            HStack {
                                Text("其余 \(hiddenMembers.count) 个进程（点击展开）")
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                                Spacer()
                                Text(ProcessInspectorService.formatBytes(hiddenMemSum))
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                                    .frame(width: 68, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    } else if snap.members.count > 5 && vm.isMembersExpanded {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                vm.isMembersExpanded = false
                            }
                        } label: {
                            HStack {
                                Text("收起其余进程")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.cyan)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
            }
            .frame(maxHeight: vm.isMembersExpanded ? 184 : 136)
        }
    }

    private func footerActionsSection(_ snap: ProcessInspectionSnapshot) -> some View {
        let isProtected = snap.isProtectedSystemProcess

        return HStack(spacing: 10) {
            if isProtected {
                Text("受系统保护进程，禁止强退")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }

            Spacer()

            actionPillButton(
                title: vm.didCopySummary ? "已复制" : "复制摘要",
                tint: theme.primaryText,
                fill: colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.07),
                disabled: false
            ) {
                vm.copySummary()
            }

            actionPillButton(
                title: "在访达中显示",
                tint: theme.primaryText,
                fill: colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.07),
                disabled: false
            ) {
                vm.revealInFinder()
            }

            actionPillButton(
                title: "终止",
                tint: isProtected ? theme.secondaryText.opacity(0.45) : theme.primaryText,
                fill: colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05),
                disabled: isProtected
            ) {
                vm.terminate(force: false, onDismiss: onClose)
            }

            actionPillButton(
                title: vm.confirmForceKill ? "确认强退" : "强制退出",
                tint: isProtected ? Color.red.opacity(0.4) : Color(red: 0.96, green: 0.42, blue: 0.38),
                fill: isProtected
                    ? Color.red.opacity(0.08)
                    : (vm.confirmForceKill ? Color.red.opacity(0.28) : Color(red: 0.96, green: 0.36, blue: 0.32).opacity(0.16)),
                disabled: isProtected
            ) {
                vm.terminate(force: true, onDismiss: onClose)
            }
        }
        .padding(.top, 4)
    }

    private func actionPillButton(
        title: String,
        tint: Color,
        fill: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 13)
                .padding(.vertical, 6.5)
                .background(Capsule(style: .continuous).fill(fill))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .pointingHandOnHover()
    }

    private static func resolveIcon(pid: Int32, bundleIdentifier: String?) -> NSImage? {
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        if let bid = bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
