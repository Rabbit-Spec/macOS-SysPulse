import SwiftUI
import AppKit

// MARK: - 清理设置弹窗视图

public struct CleanerSettingsModalView: View {
    @Bindable var cleaner = SystemCleanerEngine.shared
    @Bindable var uninstaller = AppUninstallerEngine.shared
    @Bindable var store = CleanProtectionStore.shared
    let theme: LiquidGlassTheme
    @Environment(\.colorScheme) private var colorScheme

    public init(theme: LiquidGlassTheme) {
        self.theme = theme
    }

    public var body: some View {
        VStack(spacing: 0) {
            if store.showingProtectionList {
                CleanProtectionListView(
                    store: store,
                    theme: theme,
                    onBack: {
                        withAnimation(.spring(duration: 0.22, bounce: 0.0)) {
                            store.showingProtectionList = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                mainSettingsView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.0), value: store.showingProtectionList)
    }

    // MARK: - 清理设置主视图

    private var mainSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("保护设置")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                cardContainer {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.spring(duration: 0.22, bounce: 0.0)) {
                                store.showingProtectionList = true
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "slider.horizontal.2.square")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("清理保护名单")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))

                                Text("\(store.ruleCount) 条规则")
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.green.opacity(0.12)))
                            }
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.8)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()

                        Text("清理保护名单对所有清理功能生效，包括命令行与 Agent 工具。")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("清理方式")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                cardContainer {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("删除方式")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.primaryText)

                            Spacer()

                            HStack(spacing: 2) {
                                deleteModeButton(title: "直接删除", mode: .permanent)
                                deleteModeButton(title: "移到废纸篓", mode: .moveToTrash)
                            }
                            .padding(3)
                            .background(
                                Capsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                    .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.6))
                            )
                        }

                        Divider()
                            .overlay(theme.dividerColor.opacity(0.4))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("默认直接删除：智能清理和分类清理的「开发者」分类不会经过废纸篓，删除后通常无法恢复。")
                                .font(.system(size: 11.5, weight: .regular))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("文稿、照片等个人文件分类，以及卸载、重复文件、项目瘦身、安装包、iCloud 和空间分析，始终移到废纸篓，不受这里影响。")
                                .font(.system(size: 11.5, weight: .regular))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("扫描行为")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                cardContainer {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("进入清理页时自动扫描")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.primaryText)

                            Spacer()

                            Toggle("", isOn: $cleaner.autoScanOnEnter)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                                .pointingHandOnHover()
                        }

                        Text("开启后，首次切入智能清理页面且当前尚无扫描结果时会自动开始扫描（手动取消后本次会话内不再自动重扫）。")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func deleteModeButton(title: String, mode: CleanDeleteMode) -> some View {
        let isSelected = (cleaner.deleteMode == mode)
        return Button {
            withAnimation(.spring(duration: 0.18, bounce: 0.0)) {
                cleaner.deleteMode = mode
                uninstaller.deleteMode = (mode == .permanent) ? .permanent : .moveToTrash
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? (colorScheme == .dark ? Color.black : Color.white) : theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? (colorScheme == .dark ? Color.white : Color.primary) : Color.clear)
                        .shadow(color: isSelected ? Color.black.opacity(0.15) : Color.clear, radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.studioCardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(theme.studioCardBorder, lineWidth: 0.8)
                    )
            )
    }
}

// MARK: - 清理保护白名单管理视图

public struct CleanProtectionListView: View {
    @Bindable var store: CleanProtectionStore
    let theme: LiquidGlassTheme
    var onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(store: CleanProtectionStore, theme: LiquidGlassTheme, onBack: @escaping () -> Void) {
        self.store = store
        self.theme = theme
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("返回")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.pillFill))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Text("清理保护名单")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("\(store.ruleCount) 条保护规则")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.12)))

                Spacer()

                Button {
                    store.showResetConfirm = true
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.pillFill))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .confirmationDialog("确定恢复默认保护名单？", isPresented: $store.showResetConfirm) {
                    Button("恢复默认", role: .destructive) {
                        store.resetToDefaults()
                    }
                } message: {
                    Text("自定义添加的保护路径将被清除，恢复至 Cleer / SysPulse 预设安全白名单。")
                }

                Button {
                    chooseFolderAndAdd()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("选择路径…")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            Picker("", selection: $store.protectionViewMode) {
                Text("保护规则列表").tag(0)
                Text("规则配置文本 (~/.config/syspulse/whitelist)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .pointingHandOnHover()

            if store.protectionViewMode == 0 {
                rulesListView
            } else {
                rawTextEditorView
            }
        }
    }

    // MARK: - Mode 0: Rules List View

    private var rulesListView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.cyan)

                TextField("输入需要保护的完整路径或通配符 (如 ~/Data/* 或 com.example.app)…", text: $store.protectionNewPathInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onSubmit {
                        submitNewPath()
                    }

                if !store.protectionNewPathInput.isEmpty {
                    Button("添加") {
                        submitNewPath()
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.cyan))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.6)
                    )
            )

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                TextField("过滤已保护的路径或组件…", text: $store.protectionSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !store.protectionSearchQuery.isEmpty {
                    Button {
                        store.protectionSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.pillFill))

            let filteredPatterns = store.activePatterns.filter {
                store.protectionSearchQuery.isEmpty || $0.localizedCaseInsensitiveContains(store.protectionSearchQuery)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    ForEach(filteredPatterns, id: \.self) { pattern in
                        ruleRow(pattern: pattern)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 290)
        }
    }

    private func ruleRow(pattern: String) -> some View {
        let isCustom = store.customPatterns.contains(pattern)
        let iconName = ruleIcon(for: pattern)

        return HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isCustom ? Color.cyan : Color(red: 0.45, green: 0.70, blue: 0.95))
                .frame(width: 16)

            Text(pattern)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if isCustom {
                Text("用户新增")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.cyan.opacity(0.12)))

                Button {
                    store.removePattern(pattern)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("从保护名单中移除")
            } else {
                Text("预设保护")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.pillFill))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
        )
    }

    private func ruleIcon(for pattern: String) -> String {
        let lower = pattern.lowercased()
        if lower.contains("xcode") || lower.contains("cursor") || lower.contains("code") || lower.contains("jetbrains") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lower.contains("wechat") || lower.contains("qq") || lower.contains("dingtalk") || lower.contains("feishu") || lower.contains("telegram") {
            return "message.fill"
        } else if lower.contains("ollama") || lower.contains("huggingface") || lower.contains("torch") {
            return "brain.head.profile"
        } else if lower.contains("surge") || lower.contains("cloudkit") {
            return "network"
        } else {
            return "folder.fill.badge.shield"
        }
    }

    private func submitNewPath() {
        let p = store.protectionNewPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            store.addPath(p)
            store.protectionNewPathInput = ""
        }
    }

    private func chooseFolderAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加至保护名单"
        panel.message = "选择在任何清理中均禁止删除的受保护文件或目录："

        if panel.runModal() == .OK, let url = panel.url {
            store.addPath(url.path)
        }
    }

    // MARK: - 文本编辑模式

    private var rawTextEditorView: some View {
        VStack(spacing: 8) {
            TextEditor(text: $store.protectionEditorContent)
                .font(.system(size: 11, design: .monospaced))
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.11) : Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.cardBorder, lineWidth: 0.8)
                        )
                )
                .frame(height: 280)

            HStack {
                Button {
                    NSWorkspace.shared.selectFile(store.configFilePath, inFileViewerRootedAtPath: (store.configFilePath as NSString).deletingLastPathComponent)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5))
                        Text("在访达中定位配置文件")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()

                Spacer()

                if let msg = store.saveSuccessMessage {
                    Text(msg)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.green)
                }

                Button {
                    store.save(text: store.protectionEditorContent)
                    store.saveSuccessMessage = "✓ 已保存"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        CleanProtectionStore.shared.saveSuccessMessage = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("保存并生效")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.cyan))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
    }
}
