import SwiftUI
import AppKit

public struct AIToolCleanerDetailView: View {
    @Bindable var manager = AIToolCleanerManager.shared
    @Bindable var navState = StudioWindowNavigationState.shared
    @Bindable var store = CleanProtectionStore.shared
    let theme: LiquidGlassTheme
    @Environment(\.colorScheme) private var colorScheme

    public init(theme: LiquidGlassTheme) {
        self.theme = theme
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 12) {
                headerSummaryCard
                bandWorkspaceCard
            }
            .onAppear {
                if manager.items.isEmpty && !manager.isScanning {
                    manager.scanAITools()
                }
            }

            if manager.isQuitConflictModalPresented {
                quitConflictOverlay
            }
        }
    }

    // MARK: - 顶部概览与操作卡片

    private var headerSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                PluginArtworkIconView(
                    kind: .aiToolCleaner,
                    size: 56,
                    forcedColorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("AI 工具清理与维护")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        Text("Shared Whitelist")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.mint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.mint.opacity(0.14)))
                    }

                    Text(manager.scanStatusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        store.showingProtectionList = true
                        navState.openModal(tab: .cleaner)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 11, weight: .bold))
                            Text("保护名单 (\(store.ruleCount))")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Button {
                        manager.scanAITools()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: manager.isScanning ? "hourglass" : "sparkle.magnifyingglass")
                                .font(.system(size: 11.5, weight: .bold))
                            Text(manager.isScanning ? "扫描中…" : "重新扫描 AI 数据")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.pillFill).overlay(Capsule().strokeBorder(theme.studioCardBorder, lineWidth: 0.8)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isScanning || manager.isProcessing)

                    if manager.selectedCount > 0 {
                        Button {
                            manager.executeSelectedClean()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text(manager.selectedBytes > 0
                                     ? "清理 \(formatBytes(manager.selectedBytes))"
                                     : "清理 \(manager.selectedCount) 项")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.mint))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                        .disabled(manager.isProcessing)
                    }
                }
            }

            HStack(spacing: 10) {
                statPill(label: "已识别工具", value: manager.detectedToolNames.isEmpty ? "待扫描" : "\(manager.detectedToolNames.count) 个 (\(manager.detectedToolNames.prefix(3).joined(separator: " / ")))", tint: .cyan)
                statPill(label: "缓存与旧版本", value: formatBytes(manager.totalBytes(in: .safeCaches)), tint: .green)
                statPill(label: "对话与 Worktree", value: formatBytes(manager.totalBytes(in: .reviewSessions)), tint: .orange)
                statPill(label: "白名单保护跳过", value: "\(manager.protectedItemsCount) 项", tint: .purple)
            }

            if let summary = manager.lastSummaryText {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(theme.primaryText)
                        if let rec = manager.lastRecoveryInstructions {
                            Text(rec)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    // MARK: - 三段式工作台主体

    private var bandWorkspaceCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(AICleanBand.allCases) { band in
                        let isSelected = (manager.activeBand == band)
                        let count = manager.items(in: band).count
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                manager.activeBand = band
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(band.accentColor)
                                    .frame(width: 6.5, height: 6.5)
                                Text("\(band.title) (\(count))")
                                    .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isSelected ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(3)
                .background(Capsule().fill(theme.pillFill))

                Spacer()

                if let toast = manager.copiedHintToast {
                    Text(toast)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.cyan.opacity(0.12)))
                }

                if let undo = manager.undoProtectedPattern {
                    HStack(spacing: 6) {
                        Text("已加入清理保护「\(undo.name)」")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Button("撤销") {
                            manager.undoLastProtection()
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.cyan)
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
                }

                let bandEligibleCount = manager.items(in: manager.activeBand).filter { AIToolCleanerManager.isEligibleForSelectAll($0) }.count
                if bandEligibleCount > 0 {
                    let allBandSelected = manager.areDefaultItemsAllSelected(in: manager.activeBand)
                    Button(allBandSelected ? "取消全选" : "全选推荐项") {
                        if allBandSelected {
                            manager.clearSelection(in: manager.activeBand)
                        } else {
                            manager.selectAll(in: manager.activeBand)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.cyan.opacity(0.12)))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                // 对话保留天数选择器
                HStack(spacing: 6) {
                    Text("对话保留:")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.secondaryText)

                    Picker("", selection: $manager.retentionPolicy) {
                        ForEach(AIRetentionPolicy.allCases) { policy in
                            Text(manager.retentionPickerLabel(for: policy)).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 130, maxWidth: 210)
                    .pointingHandOnHover()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)

            Divider().overlay(theme.dividerColor)

            let rows = manager.items(in: manager.activeBand)
            if manager.isScanning && rows.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(manager.scanStatusText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.green.opacity(0.75))
                    Text("「\(manager.activeBand.title)」当前没有需要处理的项目")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(manager.activeBand.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { item in
                            itemRow(item)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.studioCardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.studioCardBorder, lineWidth: 0.8))
        )
    }

    private func itemRow(_ item: AICleanItem) -> some View {
        let isSelected = item.isSelectable && manager.selectedIDs.contains(item.id)

        return HStack(spacing: 12) {
            if item.isSelectable {
                Button {
                    manager.toggleSelection(for: item)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.mint : theme.secondaryText)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            } else {
                Image(systemName: item.kind == .sqliteDatabase ? "cylinder.split.1x2.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.isProtected ? Color.purple : Color.indigo)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.toolName)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(item.band.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(item.band.accentColor.opacity(0.14)))

                    if let kindBadge = itemKindBadge(for: item.kind) {
                        HStack(spacing: 3) {
                            Image(systemName: kindBadge.icon)
                                .font(.system(size: 9, weight: .bold))
                            Text(kindBadge.label)
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(kindBadge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(kindBadge.color.opacity(0.14)))
                    }

                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    if !item.defaultChecked && !isSelected && !item.isProtected {
                        Text("默认不勾选")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(theme.pillFill))
                    }

                    if item.isProtected {
                        Text("保护中")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.purple.opacity(0.14)))
                    }
                }

                Text(item.guardReason ?? item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)

                if let firstPath = item.primaryPath {
                    let extraSuffix = item.paths.count > 1 ? " (+ 其余 \(item.paths.count - 1) 处)" : ""
                    let pathLabel = "\(firstPath.path)\(extraSuffix)"
                    Text(pathLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(item.formattedSize)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .frame(width: 82, alignment: .trailing)

            HStack(spacing: 6) {
                if item.kind == .sqliteDatabase {
                    Button {
                        manager.compactDatabase(item)
                    } label: {
                        Text("VACUUM 压缩")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.indigo))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .disabled(manager.isProcessing)
                }

                if let cli = item.cliHintCommand {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cli, forType: .string)
                        manager.copiedHintToast = "已复制命令: \(cli)"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                            manager.copiedHintToast = nil
                        }
                    } label: {
                        Text("复制 CLI")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(Color.cyan.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }

                if item.isSelectable {
                    Button {
                        manager.protectItem(item)
                    } label: {
                        let protectTint = colorScheme == .dark
                            ? Color(red: 0.30, green: 0.85, blue: 0.92)
                            : Color(red: 0.02, green: 0.50, blue: 0.66)
                        Text("清理保护")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(protectTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(protectTint.opacity(colorScheme == .dark ? 0.16 : 0.12))
                                    .overlay(Capsule().strokeBorder(protectTint.opacity(0.35), lineWidth: 0.8))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("加入清理保护名单 (~/.config/syspulse/whitelist)")
                }

                if let path = item.primaryPath {
                    Button {
                        NSWorkspace.shared.selectFile(path.path, inFileViewerRootedAtPath: path.deletingLastPathComponent().path)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(6)
                            .background(Circle().fill(theme.pillFill))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("在访达中显示")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.studioCardBorder.opacity(0.6), lineWidth: 0.7))
        )
    }

    private func statPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.pillFill.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.studioCardBorder.opacity(0.6), lineWidth: 0.7))
        )
    }

    private var quitConflictOverlay: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.58 : 0.36)
                .ignoresSafeArea()
                .onTapGesture {
                    manager.isQuitConflictModalPresented = false
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "app.badge.checkmark.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("需要先退出正在使用的 AI 客户端")
                            .font(.system(size: 15.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("检测到 \(manager.pendingQuitConflicts.map(\.appName).joined(separator: "、")) 正在运行，退出后再执行清理或数据库压缩更安全。")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button("取消") {
                        manager.resolveQuitConflict(quitApps: false)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.pillFill))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()

                    Button("退出并继续") {
                        manager.resolveQuitConflict(quitApps: true)
                    }
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.mint))
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
            .padding(20)
            .frame(width: 440)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.35), radius: 22, y: 10)
            )
        }
    }

    private func itemKindBadge(for kind: AIItemKind) -> (label: String, icon: String, color: Color)? {
        switch kind {
        case .staleHooksAndMCP:
            return ("失效 Hook / MCP", "wrench.and.screwdriver.fill", Color.orange)
        case .duplicateSessions:
            return ("重复旧对话", "doc.on.doc.fill", Color.yellow)
        case .codexProjectFolder:
            return ("Codex 项目文件夹", "folder.badge.questionmark", Color.teal)
        case .localModel:
            return ("本地模型", "cpu", Color.cyan)
        case .idleTool:
            return ("闲置工具", "clock.badge.exclamationmark", Color.orange)
        default:
            return nil
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
