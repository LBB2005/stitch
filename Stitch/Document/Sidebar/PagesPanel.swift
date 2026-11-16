import AppKit
import Observation
import PDFKit
import SwiftUI

/// Page thumbnails, drawn from the viewer's own pages (so placed signatures and text boxes show), cached
/// per page and redrawn only when that page changes.
@MainActor
@Observable
final class PageThumbnails {
    private var versions: [Int: Int] = [:]
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private var cache: [Int: NSImage] = [:]

    static let width: CGFloat = 92

    func version(_ page: Int) -> Int { versions[page] ?? 0 }

    func invalidate(_ pages: Set<Int>) {
        for page in pages {
            cache[page] = nil
            versions[page, default: 0] += 1
        }
    }

    func aspect(_ index: Int) -> CGFloat {
        guard let page = pdfView?.document?.page(at: index) else { return 11 / 8.5 }
        let b = page.bounds(for: .cropBox)
        let turned = (page.rotation / 90) % 2 != 0
        let w = turned ? b.height : b.width, h = turned ? b.width : b.height
        return w > 0 ? h / w : 11 / 8.5
    }

    func image(_ index: Int) -> NSImage? {
        _ = version(index)
        if let hit = cache[index] { return hit }
        guard let page = pdfView?.document?.page(at: index) else { return nil }
        let w = Self.width * 2
        let image = page.thumbnail(of: NSSize(width: w, height: w * aspect(index)), for: .cropBox)
        cache[index] = image
        return image
    }
}

struct PagesPanel: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        let count = controller.pdfView.document?.pageCount ?? controller.session.pageCount
        PanelScaffold(title: "Pages") {
            Text(count == 1 ? "1 page" : "\(count) pages").font(.system(size: 11)).foregroundStyle(.secondary)
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<count, id: \.self) { index in
                            PageThumb(controller: controller, index: index).id(index)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: ui.currentPage) { _, page in
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(page) }
                }
                .onAppear { proxy.scrollTo(ui.currentPage) }
            }
        }
    }
}

private struct PageThumb: View {
    let controller: DocumentWindowController
    let index: Int
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        let thumbs = controller.thumbnails
        let current = ui.currentPage == index
        let session = controller.session
        let changes = session.overlays.filter { $0.page == index }.count + session.textEdits.filter { $0.page == index }.count
        let open = ui.todo.filter { $0.page == index && !$0.done }
        Button {
            controller.goToPage(index)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let image = thumbs.image(index) {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Color.white
                    }
                }
                .frame(width: PageThumbnails.width, height: PageThumbnails.width * thumbs.aspect(index))
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(current ? Color.accentColor : .clear, lineWidth: 2.5)
                        .padding(-4)
                )
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: current ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                if let tag = tag(open) {
                    Label(tag, systemImage: "pencil.and.scribble")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                } else if changes > 0 {
                    Text(changes == 1 ? "1 change" : "\(changes) changes")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(index + 1)\(changes > 0 ? ", \(changes) changes" : "")")
    }

    private func tag(_ open: [TodoItem]) -> String? {
        if open.contains(where: { $0.kind == .signature }) { return "Sign here" }
        if open.contains(where: { $0.kind == .initials }) { return "Initials to do" }
        if !open.isEmpty { return "\(open.count) to fill in" }
        return nil
    }
}
