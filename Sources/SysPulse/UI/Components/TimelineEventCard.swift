import SwiftUI

private struct SmoothRevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let fullSize = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let clamped = max(0, min(1, progress))
        return CGSize(width: fullSize.width, height: round(fullSize.height * clamped))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let fullSize = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: fullSize.height)
        )
    }
}

public struct TimelineEventCard: View {
    @Environment(\.colorScheme) private var colorScheme
    public var events: [PowerEvent]
    @Bindable var nav = PanelCoordinator.shared

    private var expandAnimation: Animation {
        .spring(duration: 0.28, bounce: 0.0)
    }

    public var body: some View {
        let pillFill = LiquidTheme.pillBackground(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("供电事件记录", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if !events.isEmpty {
                    if events.count > 1 {
                        Button(action: {
                            withAnimation(expandAnimation) {
                                nav.isEventsExpanded.toggle()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Text(nav.isEventsExpanded ? "收起历史" : "历史事件 (\(events.count - 1))")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(nav.isEventsExpanded ? 180 : 0))
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(pillFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }

                    Button(action: {
                        withAnimation(expandAnimation) {
                            nav.isEventsExpanded = false
                            PowerSourceEngine.shared.clearEvents()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 9, weight: .medium))
                            Text("清空")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(pillFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("清空所有供电事件记录")
                } else {
                    Text("0 条")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }

            if events.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无电网中断或供电事件记录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    Spacer()
                }
            } else if let latest = events.first {
                Divider()

                // 1. Always show ONLY the latest event by default
                eventRow(latest, isLatest: true)

                // 2. Smoothly interpolated historical events drawer + persistent toggle footer
                if events.count > 1 {
                    let historyEvents = Array(events.dropFirst().prefix(10))

                    SmoothRevealLayout(progress: nav.isEventsExpanded ? 1.0 : 0.0) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(historyEvents) { event in
                                Divider()
                                    .opacity(0.5)
                                eventRow(event, isLatest: false)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .clipped()
                    .opacity(nav.isEventsExpanded ? 1.0 : 0.0)
                    .allowsHitTesting(nav.isEventsExpanded)

                    Button(action: {
                        withAnimation(expandAnimation) {
                            nav.isEventsExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Spacer()
                            Text(nav.isEventsExpanded ? "收起历史事件" : "展开查看其余 \(events.count - 1) 条历史事件")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(nav.isEventsExpanded ? 180 : 0))
                            Spacer()
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .padding(.bottom, 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 12)
    }

    @ViewBuilder
    private func eventRow(_ event: PowerEvent, isLatest: Bool) -> some View {
        let emeraldAccent = LiquidTheme.emerald(for: colorScheme)

        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color(for: event.type))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.type.rawValue)
                        .font(.system(size: 11, weight: isLatest ? .semibold : .medium))
                        .foregroundStyle(.primary)

                    if isLatest {
                        Text("最新")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(emeraldAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(emeraldAccent.opacity(colorScheme == .dark ? 0.16 : 0.12), in: Capsule())
                    }

                    Spacer()

                    Text(event.formattedTime)
                        .font(.system(size: 10, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text(event.details)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for type: PowerEventType) -> Color {
        switch type {
        case .powerCut, .voltageSurge, .batteryLow:
            return LiquidTheme.crimson(for: colorScheme)
        case .powerRestored:
            return LiquidTheme.emerald(for: colorScheme)
        case .voltageDip, .diskEjected, .networkNotified:
            return LiquidTheme.amber(for: colorScheme)
        case .selfTest:
            return LiquidTheme.cyan(for: colorScheme)
        }
    }
}
