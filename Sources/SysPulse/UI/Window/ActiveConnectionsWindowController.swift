import AppKit
import SwiftUI
import Observation

// MARK: - 活动网络连接窗口控制器

@MainActor
public final class ActiveConnectionsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = ActiveConnectionsWindowController()

    private var localEventMonitor: Any?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "活跃连接数详情"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        let rootView = ActiveConnectionsWindowView(onClose: { [weak self] in
            self?.closeWindow()
        })
        window.contentView = NSHostingView(rootView: rootView)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        guard let window = self.window else { return }
        NetworkDetailModel.shared.refreshActiveSockets()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                if event.keyCode == 53 { // ESC key
                    self?.closeWindow()
                    return nil
                }
                return event
            }
        }
    }

    public func closeWindow() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        ActiveConnectionsViewModel.shared.stopAutoRefresh()
        window?.orderOut(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        ActiveConnectionsViewModel.shared.stopAutoRefresh()
    }
}

// MARK: - 活动网络连接视图模型

@Observable
@MainActor
public final class ActiveConnectionsViewModel {
    public static let shared = ActiveConnectionsViewModel()

    public var searchText: String = ""
    public var selectedProtoFilter: String = "全部"   // 全部, TCP, UDP
    public var selectedStateFilter: String = "全部"   // 全部, 已连接, 监听中
    public var isRefreshing: Bool = false
    private var refreshTimer: Timer? = nil

    public func clearSearch() {
        searchText = ""
    }

    public func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in
                NetworkDetailModel.shared.refreshActiveSockets()
            }
        }
    }

    public func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    public func triggerManualRefresh() {
        isRefreshing = true
        NetworkDetailModel.shared.refreshActiveSockets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.isRefreshing = false
        }
    }
}

// MARK: - Active Connections Window View (SwiftUI Root)

public struct ActiveConnectionsWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onClose: () -> Void

    private var model: NetworkDetailModel { NetworkDetailModel.shared }
    private var vm: ActiveConnectionsViewModel { ActiveConnectionsViewModel.shared }

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var theme: LiquidGlassTheme {
        LiquidGlassTheme(colorScheme: colorScheme)
    }

    // Filtered sockets
    private var filteredSockets: [ActiveSocketItem] {
        model.activeSockets.filter { item in
            // Protocol filter
            if vm.selectedProtoFilter != "全部" && item.proto != vm.selectedProtoFilter {
                return false
            }
            // State filter
            if vm.selectedStateFilter == "已连接" && item.state != "ESTABLISHED" {
                return false
            } else if vm.selectedStateFilter == "监听中" && item.state != "LISTEN" {
                return false
            }

            // Search query
            let query = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return true }

            if item.processName.lowercased().contains(query) { return true }
            if String(item.pid).contains(query) { return true }
            if item.localAddress.lowercased().contains(query) { return true }
            if item.remoteAddress.lowercased().contains(query) { return true }
            if item.state.lowercased().contains(query) { return true }
            return false
        }
    }

    private var tcpCount: Int {
        model.activeSockets.filter { $0.proto == "TCP" }.count
    }

    private var udpCount: Int {
        model.activeSockets.filter { $0.proto == "UDP" }.count
    }

    private var establishedCount: Int {
        model.activeSockets.filter { $0.state == "ESTABLISHED" }.count
    }

    private var listenCount: Int {
        model.activeSockets.filter { $0.state == "LISTEN" }.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .overlay(theme.dividerColor.opacity(0.4))

            filterToolbarRow

            Divider()
                .overlay(theme.dividerColor.opacity(0.3))

            tableColumnHeader

            Divider()
                .overlay(theme.dividerColor.opacity(0.3))

            connectionsTable

            Divider()
                .overlay(theme.dividerColor.opacity(0.4))

            bottomStatusBar
        }
        .frame(minWidth: 820, minHeight: 480)
        .background(
            LinearGradient(
                colors: theme.backdropGradientColors(),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .onAppear {
            model.refreshActiveSockets()
            vm.startAutoRefresh()
        }
        .onDisappear {
            vm.stopAutoRefresh()
        }
    }

    // MARK: - 1. Top Header Bar

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .padding(.trailing, 16)
            }
            .frame(height: 28)
            .padding(.top, 4)

            HStack(spacing: 9) {
                Image(systemName: "network")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.cyan)

                Text("活跃连接数详情")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("共 \(model.activeSockets.count) 个活跃连接")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    )

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 2. Filter Toolbar Row

    private var filterToolbarRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                filterPill(label: "全部", count: model.activeSockets.count, isSelected: vm.selectedProtoFilter == "全部") {
                    vm.selectedProtoFilter = "全部"
                }
                filterPill(label: "TCP", count: tcpCount, isSelected: vm.selectedProtoFilter == "TCP") {
                    vm.selectedProtoFilter = "TCP"
                }
                filterPill(label: "UDP", count: udpCount, isSelected: vm.selectedProtoFilter == "UDP") {
                    vm.selectedProtoFilter = "UDP"
                }
            }
            .padding(2.5)
            .background(
                Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )

            HStack(spacing: 3) {
                filterPill(label: "全部状态", isSelected: vm.selectedStateFilter == "全部") {
                    vm.selectedStateFilter = "全部"
                }
                filterPill(label: "已连接 (\(establishedCount))", isSelected: vm.selectedStateFilter == "已连接") {
                    vm.selectedStateFilter = "已连接"
                }
                filterPill(label: "监听中 (\(listenCount))", isSelected: vm.selectedStateFilter == "监听中") {
                    vm.selectedStateFilter = "监听中"
                }
            }
            .padding(2.5)
            .background(
                Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)

                TextField("搜索进程名、PID、IP 或端口…", text: Binding(get: { vm.searchText }, set: { vm.searchText = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 190)

                if !vm.searchText.isEmpty {
                    Button {
                        vm.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.8)
                    )
            )

            Button {
                vm.triggerManualRefresh()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(vm.isRefreshing ? 360 : 0))
                        .animation(vm.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: vm.isRefreshing)
                    Text("刷新")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func filterPill(label: String, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                if let count = count {
                    Text("(\(count))")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                }
            }
            .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    // MARK: - 3. Table Column Header

    private var tableColumnHeader: some View {
        HStack(spacing: 12) {
            Text("协议")
                .frame(width: 55, alignment: .leading)
            Text("应用 / 进程")
                .frame(width: 210, alignment: .leading)
            Text("本地端点 (IP:端口)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 16)
            Text("远端端点 (IP:端口)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("连接状态")
                .frame(width: 95, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))
    }

    // MARK: - 4. Scrollable Connections Table

    private var connectionsTable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 4) {
                if filteredSockets.isEmpty {
                    VStack(spacing: 10) {
                        Spacer().frame(height: 60)
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(theme.secondaryText.opacity(0.5))
                        Text(vm.searchText.isEmpty ? "未发现匹配的活跃网络连接" : "未找到与 \"\(vm.searchText)\" 相关的网络连接")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                        Spacer().frame(height: 60)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(filteredSockets) { socket in
                        connectionRow(socket: socket)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func connectionRow(socket: ActiveSocketItem) -> some View {
        let isTCP = socket.proto == "TCP"
        let stateColor: Color = {
            switch socket.state {
            case "ESTABLISHED": return Color(red: 0.35, green: 0.85, blue: 0.55)
            case "LISTEN": return Color.blue
            case "SYN_SENT": return Color.orange
            default: return theme.secondaryText
            }
        }()

        return HStack(spacing: 12) {
            Text(socket.proto)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isTCP ? Color.blue : Color.purple)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill((isTCP ? Color.blue : Color.purple).opacity(0.15))
                )
                .frame(width: 55, alignment: .leading)

            HStack(spacing: 7) {
                if let icon = socket.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.cyan.opacity(0.15))
                        Image(systemName: "app.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.cyan)
                    }
                    .frame(width: 18, height: 18)
                }

                Text(socket.processName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Text("(PID \(socket.pid))")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: 210, alignment: .leading)

            Text(socket.localAddress)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.primaryText.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: socket.remoteAddress.isEmpty ? "minus" : "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(theme.secondaryText.opacity(0.5))
                .frame(width: 16)

            Text(socket.remoteAddress.isEmpty ? "(监听本地端口)" : socket.remoteAddress)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(socket.remoteAddress.isEmpty ? theme.secondaryText.opacity(0.6) : theme.primaryText.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3.5) {
                Circle().fill(stateColor).frame(width: 5, height: 5)
                Text(socket.state == "ESTABLISHED" ? "已连接" : (socket.state == "LISTEN" ? "监听中" : socket.state))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(stateColor)
            }
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(stateColor.opacity(0.12))
            )
            .frame(width: 95, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025))
        )
    }

    // MARK: - 5. Bottom Status Bar

    private var bottomStatusBar: some View {
        HStack {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("ESTABLISHED: \(establishedCount)")
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.blue).frame(width: 5, height: 5)
                    Text("LISTEN: \(listenCount)")
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.purple).frame(width: 5, height: 5)
                    Text("UDP: \(udpCount)")
                }
                Text("·   显示 \(filteredSockets.count) / 总计 \(model.activeSockets.count)")
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.primaryText.opacity(0.8))

            Spacer()

            Button("关闭") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .pointingHandOnHover()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))
    }
}
