import AppKit
import Observation
import SwiftUI

/// ⌘K: a Spotlight-style field over the Stitch window. Type part of a file name or an action: recent
/// files, PDFs anywhere in your home folder (Spotlight's index, nothing leaves the Mac), Stitch's
/// actions and, with a PDF open, things to do in it. ↑↓ choose, Return runs, Esc closes.
@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    private let panel: CommandPanel
    private let model: CommandBarModel
    private weak var parent: NSWindow?
    private var closed = false
    var onClose: (() -> Void)?

    static let width: CGFloat = 640
    /// Room around the card for its shadow.
    static let margin: CGFloat = 24

    init(parent: NSWindow, documents: DocumentController) {
        self.parent = parent
        model = CommandBarModel(documents: documents, window: parent)
        panel = CommandPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.margin * 2, height: 120),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        super.init()
        panel.delegate = self
        let host = NSHostingView(rootView: CommandBarView(model: model) { [weak self] height in
            self?.fit(height: height)
        })
        host.sizingOptions = []
        panel.contentView = host
        model.close = { [weak self] in self?.close() }
    }

    func show() {
        guard let parent else { return }
        fit(height: 120)
        parent.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        model.update()
    }

    /// Keeps the card's top edge in place below the toolbar as the results grow and shrink.
    private func fit(height: CGFloat) {
        guard let parent else { return }
        let frame = parent.frame
        let width = Self.width + Self.margin * 2
        let top = frame.maxY - min(120, frame.height * 0.16) + Self.margin
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    func close() {
        guard !closed else { return }
        closed = true
        model.stop()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - what it finds

@MainActor
@Observable
final class CommandBarModel {
    enum Section: String {
        case document = "In This PDF"
        case recent = "Recent"
        case mac = "On This Mac"
        case actions = "Actions"
    }

    struct Item: Identifiable {
        let id: String
        let section: Section
        let title: String
        var subtitle: String?
        var symbol: String?
        var file: URL?
        /// Extra words it answers to ("sign" finds Signature).
        var keywords = ""
        var shortcut: String?
        let run: @MainActor () -> Void
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            update()
            spotlight.search(query)
        }
    }
    private(set) var groups: [(section: Section, items: [Item])] = []
    var selection = 0
    private(set) var searching = false

    @ObservationIgnored var close: (() -> Void)?
    @ObservationIgnored private let documents: DocumentController
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private let spotlight = SpotlightSearch()
    @ObservationIgnored private var spotlightResults: [URL] = []

    init(documents: DocumentController, window: NSWindow) {
        self.documents = documents
        self.window = window
        spotlight.onResults = { [weak self] urls, busy in
            guard let self else { return }
            spotlightResults = urls
            searching = busy
            update()
        }
    }

    var items: [Item] { groups.flatMap(\.items) }

    func stop() { spotlight.stop() }

    func moveSelection(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func runSelected() {
        let all = items
        guard all.indices.contains(selection) else { return }
        run(all[selection])
    }

    /// Closes first, so a sheet or open panel the action shows isn't fighting the bar for key.
    func run(_ item: Item) {
        close?()
        DispatchQueue.main.async { MainActor.assumeIsolated { item.run() } }
    }

    func update() {
        let q = query.trimmingCharacters(in: .whitespaces)
        var found: [(Section, [(Item, Int)])] = []
        func ranked(_ items: [Item]) -> [(Item, Int)] {
            items.compactMap { item in CommandMatch.score(q, item.title + " " + item.keywords).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }
        }
        let doc = documents.document(in: window)
        if let doc {
            let docItems = ranked(documentItems(doc, query: q))
            if !q.isEmpty, !docItems.isEmpty { found.append((.document, docItems)) }
        }
        let open = Set(documents.windows.map(\.session.original.standardizedFileURL))
        let recent = documents.recents.map { url in
            Item(id: "recent:" + url.path, section: .recent, title: url.lastPathComponent,
                 subtitle: (open.contains(url.standardizedFileURL) ? "Open · " : "") + Self.folder(url), file: url) { [documents] in
                documents.open(url)
            }
        }
        let recentRanked = Array(ranked(recent).prefix(q.isEmpty ? 5 : 6))
        if !recentRanked.isEmpty { found.append((.recent, recentRanked)) }
        if !q.isEmpty {
            let known = Set(documents.recents.map(\.standardizedFileURL))
            let mac = spotlightResults.filter { !known.contains($0.standardizedFileURL) }.prefix(8).map { url in
                (Item(id: "mac:" + url.path, section: .mac, title: url.lastPathComponent, subtitle: Self.folder(url), file: url) { [documents] in
                    documents.open(url)
                }, CommandMatch.score(q, url.lastPathComponent) ?? 0)
            }
            if !mac.isEmpty { found.append((.mac, Array(mac))) }
        }
        let actions = ranked(actionItems())
        if !actions.isEmpty { found.append((.actions, q.isEmpty ? Array(actions.prefix(6)) : actions)) }
        if q.isEmpty, let doc {
            // With nothing typed, the document's own actions come last.
            found.append((.document, ranked(documentItems(doc, query: q)).prefix(5).map { $0 }))
        }
        // Typed: the section with the best match comes first.
        if !q.isEmpty {
            found.sort { ($0.1.first?.1 ?? 0) > ($1.1.first?.1 ?? 0) }
        }
        groups = found.map { ($0.0, $0.1.map(\.0)) }
        selection = min(selection, max(items.count - 1, 0))
        if !q.isEmpty { selection = 0 }
    }

    private func actionItems() -> [Item] {
        let documents = documents
        return [
            Item(id: "open", section: .actions, title: "Open PDF…", symbol: "doc", keywords: "file sign fill edit", shortcut: "⌘O") {
                documents.showOpenPanel()
            },
            Item(id: "merge", section: .actions, title: "Merge Files…", symbol: "doc.on.doc",
                 keywords: "combine join convert jpeg images word powerpoint excel csv") {
                documents.chooseFilesToMerge()
            },
            Item(id: "tab", section: .actions, title: "New Tab", symbol: "plus.rectangle.on.rectangle", keywords: "window start", shortcut: "⌘T") {
                documents.newTab()
            },
            Item(id: "signature", section: .actions, title: "Create or Change Signature…", symbol: "signature", keywords: "initials sign") {
                SettingsOpener.open(tab: .signatures)
            },
            Item(id: "info", section: .actions, title: "Your Info…", symbol: "person.text.rectangle", keywords: "my details address phone email") {
                SettingsOpener.open(tab: .yourInfo)
            },
            Item(id: "settings", section: .actions, title: "Settings…", symbol: "gearshape", keywords: "preferences folder shrink ocr", shortcut: "⌘,") {
                SettingsOpener.open(tab: .general)
            },
        ]
    }

    private func documentItems(_ doc: DocumentWindowController, query q: String) -> [Item] {
        let name = doc.session.name
        var items: [Item] = []
        if !q.isEmpty {
            items.append(Item(id: "find", section: .document, title: "Find “\(q)” in \(name)", symbol: "text.magnifyingglass",
                              keywords: q) {
                doc.ui.find.query = q
                doc.showPanel(.find)
                doc.findChanged()
            })
        }
        items += [
            Item(id: "doc-sign", section: .document, title: "Signature", subtitle: "Click the page to place it",
                 symbol: "signature", keywords: "sign", shortcut: "⌥⌘S") { doc.placeSignature(initials: false) },
            Item(id: "doc-initials", section: .document, title: "Initials", symbol: "character.textbox",
                 keywords: "sign initial", shortcut: "⌥⌘I") { doc.placeSignature(initials: true) },
            Item(id: "doc-date", section: .document, title: "Today's Date", symbol: "calendar", keywords: "date today",
                 shortcut: "⇧⌘D") { doc.insertDate() },
            Item(id: "doc-fill", section: .document, title: "Fill My Info", symbol: "person.text.rectangle",
                 keywords: "form fields details", shortcut: "⌥⌘F") { doc.fillMatchingFields(address: nil) },
            Item(id: "doc-todo", section: .document, title: "Show To-Do", symbol: "checklist", keywords: "todo left next") {
                doc.showPanel(.todo)
            },
            Item(id: "doc-rename", section: .document, title: "Rename “\(name)”…", symbol: "pencil", keywords: "name title file") {
                doc.beginRename()
            },
            Item(id: "doc-save", section: .document, title: "Save Copy", symbol: "square.and.arrow.down", keywords: "export",
                 shortcut: "⌘S") { doc.saveCopy() },
        ]
        return items
    }

    private static func folder(_ url: URL) -> String {
        let dir = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }
}

/// PDFs whose names contain every word typed, from Spotlight's index of the home folder. Local only.
@MainActor
final class SpotlightSearch {
    var onResults: (([URL], Bool) -> Void)?
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?

    func search(_ text: String) {
        pending?.cancel()
        stop()
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard text.trimmingCharacters(in: .whitespaces).count >= 2, !words.isEmpty else {
            onResults?([], false)
            return
        }
        onResults?([], true)
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.start(words)
        }
    }

    private func start(_ words: [String]) {
        let q = NSMetadataQuery()
        var parts = [NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "com.adobe.pdf")]
        parts += words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: q, queue: .main) { [weak self] note in
                let finished = note.name == .NSMetadataQueryDidFinishGathering
                MainActor.assumeIsolated { self?.collect(finished: finished) }
            })
        }
        query = q
        if !q.start() { onResults?([], false) }
    }

    private func collect(finished: Bool) {
        guard let q = query else { return }
        q.disableUpdates()
        var urls: [URL] = []
        for i in 0..<min(q.resultCount, 40) {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !path.contains("/.") else { continue }
            urls.append(URL(fileURLWithPath: path))
            if urls.count == 12 { break }
        }
        q.enableUpdates()
        onResults?(urls, !finished && urls.isEmpty)
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

// MARK: - the bar

struct CommandBarView: View {
    @Bindable var model: CommandBarModel
    let onHeight: (CGFloat) -> Void

    private static let rowHeight: CGFloat = 40
    private static let headerHeight: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                CommandField(text: $model.query, placeholder: "Search PDFs, recent files and actions",
                             onMove: model.moveSelection, onSubmit: model.runSelected, onCancel: { model.close?() })
                    .frame(height: 26)
                if model.searching {
                    ProgressView().controlSize(.small)
                }
                Text("esc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            if !model.groups.isEmpty {
                Divider().opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            let flat = model.items
                            ForEach(model.groups, id: \.section) { group in
                                Text(group.section.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .frame(height: Self.headerHeight, alignment: .bottomLeading)
                                ForEach(group.items) { item in
                                    let index = flat.firstIndex { $0.id == item.id } ?? 0
                                    CommandRow(item: item, selected: index == model.selection)
                                        .id(item.id)
                                        .onTapGesture { model.run(item) }
                                        .onHover { if $0 { model.selection = index } }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .frame(height: listHeight)
                    .onChange(of: model.selection) { _, new in
                        let flat = model.items
                        if flat.indices.contains(new) { proxy.scrollTo(flat[new].id) }
                    }
                }
            } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty, !model.searching {
                Divider().opacity(0.6)
                Text("Nothing matches “\(model.query)”")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
        }
        .frame(width: CommandBarController.width)
        .modifier(BarGlass(shape: shape))
        .padding(CommandBarController.margin)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .animation(.snappy(duration: 0.18), value: model.groups.map(\.items.count))
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(model.items.count) * Self.rowHeight + CGFloat(model.groups.count) * Self.headerHeight + 16
        return min(rows, 420)
    }
}

private struct CommandRow: View {
    let item: CommandBarModel.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.2) : Theme.cell)
                if let file = item.file {
                    FileThumbView(url: file, side: 22)
                } else if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 13))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            }
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Liquid Glass on macOS 26; a thick material before.
private struct BarGlass: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(.regularMaterial, in: shape)
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
        } else {
            content
                .background(.thickMaterial, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
        }
    }
}

/// The search field: an AppKit text field so ↑↓, Return and Esc reach the bar.
private struct CommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search")
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField

        init(parent: CommandField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
