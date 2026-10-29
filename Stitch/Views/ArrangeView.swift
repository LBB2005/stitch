import SwiftUI
import UniformTypeIdentifiers

/// Screen 3: a 4-column grid of page thumbnails. Drag to reorder (a blue line shows where it will land),
/// hover ✕ to drop a page, then Merge.
struct ArrangeView: View {
    @Environment(AppModel.self) private var model

    static let columns = 4
    static let spacing: CGFloat = 10
    static let wellPadding: CGFloat = 10
    static var tileWidth: CGFloat {
        let inner = PanelController.width - 2 * Theme.padding - 2 * wellPadding
        return ((inner - CGFloat(columns - 1) * spacing) / CGFloat(columns)).rounded(.down)
    }

    var body: some View {
        let arrangement = model.arrangement
        let tiles = numbered(arrangement.items)
        VStack(spacing: 10) {
            PanelHeader(title: "Arrange Pages", detail: pageSummary(arrangement.pageCount)) {
                IconButton(symbol: "chevron.left", label: "Back") { model.back() }
            } trailing: {
                if arrangement.hasStacks || arrangement.canCollapse {
                    IconButton(symbol: arrangement.hasStacks ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                               label: arrangement.hasStacks ? "Show every page" : "Group pages by file") {
                        model.toggleExpandAll()
                    }
                }
            }
            OrderSwitch()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)

            Well(padding: Self.wellPadding) {
                if tiles.isEmpty {
                    Text("No pages left. Go back to add files.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tileWidth), spacing: Self.spacing),
                                                 count: Self.columns),
                                  spacing: Self.spacing) {
                            ForEach(tiles, id: \.item.id) { tile in
                                PageTile(item: tile.item, caption: tile.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: gridHeight(count: tiles.count))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Drag to reorder · hover a page and click ✕ to drop it")
                    .foregroundStyle(.secondary)
                let left = model.orderedFiles.compactMap { model.skipped[$0.id] }
                if !left.isEmpty {
                    Text("Left out: " + left.joined(separator: ", ")).foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)

            Rectangle().fill(Theme.separator).frame(height: 0.5)
            OutputNameBlock()
            HStack(spacing: 8) {
                Text("\(pageSummary(arrangement.pageCount)) → \(model.destinationName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel") { model.back() }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: false))
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { model.merge() }
                    .buttonStyle(PrimaryButtonStyle(height: 28, fullWidth: false))
                    .disabled(arrangement.pageCount == 0)
            }
        }
        .padding(Theme.padding)
    }

    private func pageSummary(_ n: Int) -> String { n == 1 ? "1 page" : "\(n) pages" }

    /// Up to three and a half rows show at once; more scroll.
    private func gridHeight(count: Int) -> CGFloat {
        let rows = (count + Self.columns - 1) / Self.columns
        let rowHeight = Self.tileWidth + 4 + 13 + Self.spacing
        return min(CGFloat(rows), 3.5) * rowHeight + 8 - (rows <= 3 ? Self.spacing : 0)
    }

    /// Captions: the page's number in the merged PDF, or the range a file tile covers.
    private func numbered(_ items: [Arrangement.Item]) -> [(item: Arrangement.Item, caption: String)] {
        var next = 1
        return items.map { item in
            let n = item.pages.count
            defer { next += n }
            return (item, n == 1 ? "\(next)" : "\(next)–\(next + n - 1)")
        }
    }
}

private struct PageTile: View {
    let item: Arrangement.Item
    let caption: String
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @State private var hovering = false
    @State private var image: NSImage?

    private var side: CGFloat { ArrangeView.tileWidth }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.cell)
                if item.isStack {
                    thumbnail.offset(x: 4, y: -4).opacity(0.3)
                    thumbnail.offset(x: 2, y: -2).opacity(0.55)
                }
                thumbnail
            }
            .frame(width: side, height: side)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2).opacity(hovering ? 1 : 0))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { model.removeTile(item.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color(nsColor: .systemGray), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help(item.isStack ? "Leave out this file" : "Leave out this page")
                    .accessibilityLabel(item.isStack ? "Remove file" : "Remove page \(caption)")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if case .file(let fileID, let pages) = item {
                    Button { model.expand(fileID) } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "square.stack")
                            Text("\(pages.count)")
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(.thickMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Show all \(pages.count) pages")
                }
            }
            .overlay(alignment: indicatorBefore ? .leading : .trailing) {
                if model.dropIndicator?.targetID == item.id {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .offset(x: (indicatorBefore ? -1 : 1) * (ArrangeView.spacing / 2 + 1.5))
                }
            }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(height: 13)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag {
            model.beginTileDrag(item.id)
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(of: [.text], delegate: TileDropDelegate(targetID: item.id, width: side, model: model))
        .contextMenu { menu }
        .task(id: thumbnailKey) { await loadThumbnail() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isStack ? "Pages \(caption)" : "Page \(caption)")
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .padding(side * 0.09)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var menu: some View {
        if case .file(let fileID, _) = item {
            Button("Show All Pages") { model.expand(fileID) }
        } else if model.arrangement.items.filter({ !$0.isStack && $0.fileID == item.fileID }).count > 1 {
            Button("Group This File's Pages") { model.collapse(item.fileID) }
        }
        Button(item.isStack ? "Leave Out File" : "Leave Out Page", role: .destructive) { model.removeTile(item.id) }
    }

    private var indicatorBefore: Bool { model.dropIndicator?.before ?? true }

    private var thumbnailKey: String { item.pages.first?.id ?? item.id }

    private func loadThumbnail() async {
        guard let first = item.pages.first, let url = model.prepared[first.fileID]?.pdfURL else { return }
        let maxSide = side * scale
        if let thumb = await ThumbnailStore.shared.page(url, index: first.index, maxSide: maxSide) {
            image = NSImage(cgImage: thumb.cgImage, size: NSSize(width: CGFloat(thumb.cgImage.width) / scale,
                                                                 height: CGFloat(thumb.cgImage.height) / scale))
        }
    }
}

private struct TileDropDelegate: DropDelegate {
    let targetID: String
    let width: CGFloat
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool { model.draggingTileID != nil }
    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.clearDrop(over: targetID) }
    func performDrop(info: DropInfo) -> Bool { model.performDrop() }

    private func update(_ info: DropInfo) {
        model.updateDrop(over: targetID, before: info.location.x < width / 2)
    }
}
