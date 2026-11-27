import SwiftUI
import AppKit

// MARK: - Squarified Treemap Layout Algorithm

public struct SquarifiedTreemapLayout {
    public struct InputItem: Sendable {
        public let id: UUID
        public let weight: Double

        public init(id: UUID, weight: Double) {
            self.id = id
            self.weight = weight
        }
    }

    public static func layout(items: [InputItem], in bounds: CGRect) -> [UUID: CGRect] {
        guard bounds.width > 1, bounds.height > 1 else { return [:] }
        let valid = items.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard !valid.isEmpty else { return [:] }

        let totalWeight = valid.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return [:] }

        let totalArea = Double(bounds.width * bounds.height)
        let normalized: [(id: UUID, area: Double)] = valid.map {
            ($0.id, max(0.0001, ($0.weight / totalWeight) * totalArea))
        }

        var result: [UUID: CGRect] = [:]
        var remaining = normalized
        var currentRow: [(id: UUID, area: Double)] = []
        var rect = bounds

        func worstAspect(row: [(id: UUID, area: Double)], shortSide: Double) -> Double {
            guard !row.isEmpty, shortSide > 0 else { return .greatestFiniteMagnitude }
            let sum = row.reduce(0.0) { $0 + $1.area }
            guard sum > 0 else { return .greatestFiniteMagnitude }
            var maxArea = 0.0
            var minArea = Double.greatestFiniteMagnitude
            for item in row {
                maxArea = max(maxArea, item.area)
                minArea = min(minArea, item.area)
            }
            let sideSq = shortSide * shortSide
            let sumSq = sum * sum
            return max((sideSq * maxArea) / sumSq, sumSq / (sideSq * minArea))
        }

        func commitRow(_ row: [(id: UUID, area: Double)], into currentRect: inout CGRect) {
            guard !row.isEmpty, currentRect.width > 0, currentRect.height > 0 else { return }
            let rowArea = row.reduce(0.0) { $0 + $1.area }
            let horizontalSplit = currentRect.width >= currentRect.height

            if horizontalSplit {
                let sliceWidth = min(currentRect.width, CGFloat(rowArea / Double(currentRect.height)))
                var cursorY = currentRect.minY
                for (index, item) in row.enumerated() {
                    let itemHeight: CGFloat
                    if index == row.count - 1 {
                        itemHeight = max(0, currentRect.maxY - cursorY)
                    } else {
                        itemHeight = sliceWidth > 0 ? CGFloat(item.area / Double(sliceWidth)) : 0
                    }
                    result[item.id] = CGRect(x: currentRect.minX, y: cursorY, width: sliceWidth, height: itemHeight)
                    cursorY += itemHeight
                }
                currentRect = CGRect(
                    x: currentRect.minX + sliceWidth,
                    y: currentRect.minY,
                    width: max(0, currentRect.width - sliceWidth),
                    height: currentRect.height
                )
            } else {
                let sliceHeight = min(currentRect.height, CGFloat(rowArea / Double(currentRect.width)))
                var cursorX = currentRect.minX
                for (index, item) in row.enumerated() {
                    let itemWidth: CGFloat
                    if index == row.count - 1 {
                        itemWidth = max(0, currentRect.maxX - cursorX)
                    } else {
                        itemWidth = sliceHeight > 0 ? CGFloat(item.area / Double(sliceHeight)) : 0
                    }
                    result[item.id] = CGRect(x: cursorX, y: currentRect.minY, width: itemWidth, height: sliceHeight)
                    cursorX += itemWidth
                }
                currentRect = CGRect(
                    x: currentRect.minX,
                    y: currentRect.minY + sliceHeight,
                    width: currentRect.width,
                    height: max(0, currentRect.height - sliceHeight)
                )
            }
        }

        while !remaining.isEmpty {
            let shortSide = Double(min(rect.width, rect.height))
            let next = remaining[0]
            if currentRow.isEmpty {
                currentRow.append(next)
                remaining.removeFirst()
                continue
            }
            let currentWorst = worstAspect(row: currentRow, shortSide: shortSide)
            let candidateRow = currentRow + [next]
            let candidateWorst = worstAspect(row: candidateRow, shortSide: shortSide)
            if candidateWorst <= currentWorst {
                currentRow = candidateRow
                remaining.removeFirst()
            } else {
                commitRow(currentRow, into: &rect)
                currentRow = []
            }
        }
        commitRow(currentRow, into: &rect)
        return result
    }
}

// MARK: - Treemap Interactive Canvas View

struct StorageTreemapView: View {
    @Bindable var analysis: StorageAnalysisEngine
    let theme: LiquidGlassTheme
    @Environment(\.colorScheme) private var colorScheme

    private struct RenderTile: Identifiable {
        let id: UUID
        let node: AnalysisNode?
        let title: String
        let sizeText: String
        let shareText: String
        let accent: Color
        let isDirectory: Bool
        let tailCount: Int
    }

    private static let tailSyntheticID = UUID(uuidString: "99999999-9999-4999-9999-999999999999")!

    var body: some View {
        let tiles = buildRenderTiles()
        if tiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x2")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.secondaryText.opacity(0.45))
                Text("当前目录无非零占用项")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                GeometryReader { geo in
                    let rects = computeRects(for: tiles, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        ForEach(tiles) { tile in
                            if let rect = rects[tile.id], rect.width >= 3, rect.height >= 3 {
                                treemapTileView(tile: tile, rect: rect)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private func buildRenderTiles() -> [RenderTile] {
        let positiveNodes = analysis.currentFolderChildren.filter { $0.sizeBytes > 0 }
        let totalBytes = max(1, positiveNodes.reduce(Int64(0)) { $0 + $1.sizeBytes })

        var primary: [AnalysisNode] = []
        var tailNodes: [AnalysisNode] = []
        for (idx, node) in positiveNodes.enumerated() {
            let ratio = Double(node.sizeBytes) / Double(totalBytes)
            if idx < 28 && (idx < 8 || ratio >= 0.008) {
                primary.append(node)
            } else {
                tailNodes.append(node)
            }
        }

        var tiles: [RenderTile] = primary.map { node in
            let share = Double(node.sizeBytes) / Double(totalBytes) * 100.0
            let titleText = node.ownerAppName.map { "\(node.name) (\($0))" } ?? node.name
            return RenderTile(
                id: node.id,
                node: node,
                title: titleText,
                sizeText: node.formattedSize,
                shareText: String(format: "%.1f%%", share),
                accent: tileColor(for: node),
                isDirectory: node.isDirectory,
                tailCount: 0
            )
        }

        if tailNodes.count == 1, let onlyTail = tailNodes.first {
            let share = Double(onlyTail.sizeBytes) / Double(totalBytes) * 100.0
            tiles.append(
                RenderTile(
                    id: onlyTail.id,
                    node: onlyTail,
                    title: onlyTail.name,
                    sizeText: onlyTail.formattedSize,
                    shareText: String(format: "%.1f%%", share),
                    accent: tileColor(for: onlyTail),
                    isDirectory: onlyTail.isDirectory,
                    tailCount: 0
                )
            )
        } else if tailNodes.count > 1 {
            let tailBytes = tailNodes.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let share = Double(tailBytes) / Double(totalBytes) * 100.0
            tiles.append(
                RenderTile(
                    id: Self.tailSyntheticID,
                    node: nil,
                    title: "其余 \(tailNodes.count) 项小体积条目",
                    sizeText: ByteCountFormatter.string(fromByteCount: tailBytes, countStyle: .file),
                    shareText: String(format: "%.1f%%", share),
                    accent: Color.gray,
                    isDirectory: false,
                    tailCount: tailNodes.count
                )
            )
        }

        return tiles
    }

    private func computeRects(for tiles: [RenderTile], in size: CGSize) -> [UUID: CGRect] {
        let positiveNodesByID = Dictionary(uniqueKeysWithValues: analysis.currentFolderChildren.map { ($0.id, Double(max(1, $0.sizeBytes))) })
        let inputs: [SquarifiedTreemapLayout.InputItem] = tiles.map { tile in
            if let node = tile.node {
                return SquarifiedTreemapLayout.InputItem(id: tile.id, weight: Double(max(1, node.sizeBytes)))
            } else {
                let tailSum = analysis.currentFolderChildren
                    .filter { positiveNodesByID[$0.id] != nil }
                    .dropFirst(max(0, tiles.count - 1))
                    .reduce(0.0) { $0 + Double(max(1, $1.sizeBytes)) }
                return SquarifiedTreemapLayout.InputItem(id: tile.id, weight: max(1, tailSum))
            }
        }
        return SquarifiedTreemapLayout.layout(
            items: inputs,
            in: CGRect(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height))
        )
    }

    private func treemapTileView(tile: RenderTile, rect: CGRect) -> some View {
        let isHovered = (analysis.hoveredTreemapNodeID == tile.id)
        let tileW = max(2, rect.width - 4)
        let tileH = max(2, rect.height - 4)
        let showTitle = tileW >= 62 && tileH >= 28
        let showSize = tileW >= 78 && tileH >= 44
        let showShare = tileW >= 120 && tileH >= 64

        return Button {
            handleTileClick(tile)
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tile.accent.opacity(isHovered ? (colorScheme == .dark ? 0.56 : 0.42) : (colorScheme == .dark ? 0.36 : 0.25)),
                                tile.accent.opacity(isHovered ? (colorScheme == .dark ? 0.40 : 0.28) : (colorScheme == .dark ? 0.22 : 0.14))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isHovered ? tile.accent.opacity(0.95) : tile.accent.opacity(0.35),
                                lineWidth: isHovered ? 1.5 : 0.8
                            )
                    )

                if showTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: tile.node == nil ? "square.stack.3d.down.right" : (tile.isDirectory ? "folder.fill" : "doc.fill"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tile.accent)
                            Text(tile.title)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                        }

                        if showSize {
                            HStack(spacing: 6) {
                                Text(tile.sizeText)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(theme.primaryText.opacity(0.9))
                                if showShare {
                                    Text(tile.shareText)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                        }
                    }
                    .padding(7)
                }
            }
            .frame(width: tileW, height: tileH)
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .position(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
        .help("\(tile.title) · \(tile.sizeText) (\(tile.shareText))")
        .onHover { hovering in
            if hovering {
                analysis.hoveredTreemapNodeID = tile.id
            } else if analysis.hoveredTreemapNodeID == tile.id {
                analysis.hoveredTreemapNodeID = nil
            }
        }
        .contextMenu {
            if let node = tile.node {
                if node.isDirectory {
                    Button("进入此目录") {
                        analysis.navigateTo(node: node)
                    }
                } else {
                    Button("快速预览 (Quick Look)") {
                        analysis.previewWithQuickLook(url: node.url)
                    }
                }
                Button("在访达中显示") {
                    analysis.revealInFinder(url: node.url)
                }
                Button("复制完整路径") {
                    analysis.copyPath(node.path)
                }
                Divider()
                Button("移入废纸篓", role: .destructive) {
                    analysis.moveToTrash(node: node)
                }
            } else {
                Button("切换列表查看全部小文件") {
                    analysis.isTailExpanded = true
                    analysis.activeViewMode = .browser
                }
            }
        }
    }

    private func handleTileClick(_ tile: RenderTile) {
        if let node = tile.node {
            if node.isDirectory {
                analysis.navigateTo(node: node)
            } else {
                analysis.previewWithQuickLook(url: node.url)
            }
        } else {
            analysis.isTailExpanded = true
            analysis.activeViewMode = .browser
        }
    }

    private func tileColor(for node: AnalysisNode) -> Color {
        if node.isProtectedOrUnreadable { return .orange }
        if node.isDirectory { return .blue }
        let kind = AnalysisFileKind.classify(url: node.url, isPackage: node.isPackage)
        switch kind {
        case .aiModel: return .mint
        case .developer: return .indigo
        case .video: return .orange
        case .diskImage: return .purple
        case .archive: return .blue
        case .application: return .cyan
        case .audio: return .pink
        case .image: return .teal
        case .document, .other: return .gray
        }
    }
}
