import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The Stitch window with nothing open: what launching Stitch shows, and what a document window turns
/// back into when its last PDF closes. The canvas is the start page: drop one PDF to sign it (this same
/// window becomes the document), or several files to merge them right here. ⌘K searches.
@MainActor
final class StartWindowController: NSWindowController, NSWindowDelegate {
    let job: MergeJob
    let state = StartState()
    private weak var documents: DocumentController?
    private var toolbarDelegate: StartToolbar?

    init(documents: DocumentController, window existing: NSWindow? = nil) {
        self.documents = documents
        job = MergeJob(prefs: documents.prefs)
        let window = existing ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
        let keptFrame = existing?.frame
        window.tabbingMode = .preferred
        window.tabbingIdentifier = DocumentWindowController.tabbingID
        window.isRestorable = false
        window.title = "Stitch"
        window.subtitle = ""
        window.representedURL = nil
        window.isDocumentEdited = false
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 600, height: 420)
        super.init(window: window)
        window.delegate = self

        let toolbar = StartToolbar(controller: self)
        toolbarDelegate = toolbar
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unifiedCompact

        let root = StartView(controller: self, documents: documents)
            .environment(job)
            .environment(state)
            .environment(SignatureStore.shared)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        window.contentViewController = host
        if let keptFrame { window.setFrame(keptFrame, display: true) }
        job.onFinished = { [weak self] result in self?.finished(result) }
    }

    required init?(coder: NSCoder) { nil }

    /// Gives the window to a document opening in it; this controller is done after that.
    func relinquishWindow() -> NSWindow? {
        guard let window else { return nil }
        job.cancel()
        window.delegate = nil
        window.toolbar = nil
        window.contentViewController = nil
        self.window = nil
        return window
    }

    // MARK: actions

    /// One PDF on an empty canvas opens it here; anything else goes on the merge list.
    func dropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if job.isEmpty, urls.count == 1, FileKind.classify(urls[0]) == .pdf {
            documents?.open(urls[0], into: self)
        } else {
            add(urls)
        }
    }

    func add(_ urls: [URL]) {
        withAnimation(.snappy(duration: 0.28)) { job.add(urls) }
        toolbarDelegate?.refreshTitle()
    }

    func openPDF() {
        documents?.showOpenPanel()
    }

    func chooseFiles() {
        guard let window else { return }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = FileKind.pickerTypes
        open.prompt = job.isEmpty ? "Choose" : "Add"
        open.message = "Choose PDFs, photos, Word, PowerPoint, Excel or CSV files. They're never changed."
        open.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.dropped(open.urls)
            }
        }
    }

    func run() {
        job.run()
        toolbarDelegate?.refreshTitle()
    }

    func clear() {
        withAnimation(.snappy(duration: 0.28)) { job.clear() }
        toolbarDelegate?.refreshTitle()
    }

    /// All PDFs: open each as a tab instead of merging.
    func openAsTabs() {
        let urls = job.files.map(\.url)
        clear()
        guard let first = urls.first else { return }
        documents?.open(first, into: self)
        urls.dropFirst().forEach { documents?.open($0) }
    }

    func showSearch() {
        documents?.showCommandBar(over: window)
    }

    /// A merge that made one PDF opens it right here, ready to sign; other results stay on the canvas.
    private func finished(_ result: JobResult) {
        toolbarDelegate?.refreshTitle()
        guard result.outputs.count == 1, let url = result.outputs.first, url.pathExtension.lowercased() == "pdf",
              result.overLimit == nil else { return }
        let folder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
        let pages = result.pageCount.map { $0 == 1 ? "1 page" : "\($0) pages" }
        let summary = [result.title, pages, "saved in \(folder)"].compactMap { $0 }.joined(separator: " · ")
        let documents = documents
        documents?.open(url, into: self)
        documents?.current?.showToast(summary, reveal: url)
    }

    var titleDetail: String {
        switch job.phase {
        case .working: return job.progress.message.isEmpty ? "Working…" : job.progress.message
        case .done: return job.result?.title ?? "Done"
        default: return job.isEmpty ? "No document open" : job.title
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        documents?.newTab()
    }

    // MARK: window

    func windowWillClose(_ notification: Notification) {
        job.cancel()
        toolbarDelegate = nil
        window?.toolbar = nil
        window?.contentViewController = nil
        documents?.startClosed(self)
    }
}

/// What the start canvas shows while files are dragged over it.
@MainActor
@Observable
final class StartState {
    /// Files over the window right now (nil when nothing is being dragged).
    var dropCount: Int?
}

/// The start window's toolbar: "Stitch" (or what the merge is doing) and search.
@MainActor
final class StartToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "StitchStartToolbar")
    private weak var controller: StartWindowController?
    private let titleView = TitleView()

    private enum ID {
        static let title = NSToolbarItem.Identifier("title")
        static let search = NSToolbarItem.Identifier("search")
    }

    init(controller: StartWindowController) {
        self.controller = controller
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        refreshTitle()
        observeJob()
    }

    func refreshTitle() {
        guard let controller else { return }
        titleView.set(name: "Stitch", detail: controller.titleDetail)
    }

    /// Follows the job (progress messages, done) without polling.
    private func observeJob() {
        guard let job = controller?.job else { return }
        withObservationTracking {
            _ = job.phase
            _ = job.progress
            _ = job.files.count
            _ = job.output
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshTitle()
                    self?.observeJob()
                }
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.title, .flexibleSpace, ID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.title:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Stitch"
            item.view = titleView
            // Plain text like a window title, not a glass button.
            item.isBordered = false
            return item
        case ID.search:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            item.label = "Search"
            item.toolTip = "Search files and actions (⌘K)"
            item.target = self
            item.action = #selector(search)
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    @objc private func search() { controller?.showSearch() }
}

// MARK: - the canvas

struct StartView: View {
    let controller: StartWindowController
    let documents: DocumentController
    @Environment(MergeJob.self) private var job
    @Environment(StartState.self) private var state

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                Group {
                    if job.isEmpty {
                        EmptyCanvas(controller: controller, documents: documents)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        MergeCard(controller: controller)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: geo.size.height - 44)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StartFooter() }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .topLeading) {
            DimRail()
                .padding(.leading, 12)
                .padding(.top, 10)
        }
        .onDrop(of: [.fileURL], delegate: CanvasDrop(state: state) { controller.dropped($0) })
        .animation(.snappy(duration: 0.28), value: job.isEmpty)
    }
}

/// Drop card, search, and Recent.
private struct EmptyCanvas: View {
    let controller: StartWindowController
    let documents: DocumentController
    @Environment(StartState.self) private var state

    var body: some View {
        VStack(spacing: 26) {
            Button { controller.showSearch() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search PDFs, recent files and actions").foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘K")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.cell, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .modifier(FloatingGlass(enabled: true))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search (⌘K)")

            DropCard(controller: controller)

            RecentRow(documents: documents)
        }
        .frame(maxWidth: 580)
    }
}

private struct DropCard: View {
    let controller: StartWindowController
    @Environment(StartState.self) private var state

    var body: some View {
        let hot = state.dropCount != nil
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(hot ? Color.accentColor : .secondary)
                .offset(y: hot ? -3 : 0)
                .frame(height: 44)
            Text(headline)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.opacity)
            Text("PDFs, photos, Word, PowerPoint, Excel and CSV")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Open PDF…") { controller.openPDF() }
                    .buttonStyle(PrimaryButtonStyle(height: 30, fullWidth: false))
                    .help("Open a PDF to sign, fill or edit (⌘O)")
                Button("Choose Files…") { controller.chooseFiles() }
                    .buttonStyle(SecondaryButtonStyle(height: 30, fullWidth: false))
                    .help("Choose files to merge into one PDF, or images to convert")
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(hot ? Color.accentColor.opacity(0.08) : Theme.cell, in: shape)
        .overlay(shape.strokeBorder(hot ? Color.accentColor : Color.secondary.opacity(0.35),
                                    style: StrokeStyle(lineWidth: hot ? 2 : 1.5, dash: hot ? [] : [6, 5])))
        .scaleEffect(hot ? 1.015 : 1)
        .animation(.snappy(duration: 0.2), value: state.dropCount)
    }

    private var headline: String {
        switch state.dropCount {
        case nil: "Drop a PDF to sign, or several files to merge"
        case 1: "Release to open"
        case let n?: "Release to merge \(n) files"
        }
    }
}

private struct RecentRow: View {
    let documents: DocumentController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !documents.recents.isEmpty {
                    Button("Clear") { documents.clearRecents() }.buttonStyle(LinkButtonStyle())
                }
            }
            if documents.recents.isEmpty {
                Text("PDFs you open or save in Stitch show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(Theme.cell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(documents.recents.prefix(8), id: \.self) { url in
                            RecentTile(url: url) { documents.open(url) }
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}

private struct RecentTile: View {
    let url: URL
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                FileThumbView(url: url, side: 84)
                    .frame(width: 84, height: 100)
                    .background(Theme.cell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor : Theme.hairline, lineWidth: hovering ? 1.5 : 0.5))
                    .scaleEffect(hovering ? 1.03 : 1)
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 92)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(url.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

/// The rail, folded and dimmed: it wakes up once a PDF is open.
private struct DimRail: View {
    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarPanel.allCases) { panel in
                Image(systemName: panel.symbol)
                    .font(.system(size: 15))
                    .frame(width: 36, height: 34)
            }
            Divider().frame(width: 24).padding(.vertical, 2)
            Image(systemName: "sidebar.left")
                .font(.system(size: 15))
                .frame(width: 36, height: 34)
        }
        .foregroundStyle(Color.primary.opacity(0.28))
        .padding(.vertical, 8)
        .frame(width: 48)
        .modifier(FloatingGlass(enabled: true))
        .help("Open a PDF to use the sidebar")
        .accessibilityHidden(true)
    }
}

private struct StartFooter: View {
    @Environment(SignatureStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            if store.problem != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't read your saved signature or details").foregroundStyle(.secondary)
                Button("Details…") { SettingsOpener.open(tab: .signatures) }
                    .buttonStyle(LinkButtonStyle())
            } else {
                Image(systemName: store.signature == nil ? "signature" : "checkmark.seal")
                    .foregroundStyle(.secondary)
                Text(store.signature == nil ? "No signature saved yet" : "Signature saved on this Mac")
                    .foregroundStyle(.secondary)
                Button(store.signature == nil ? "Create one…" : "Change…") { SettingsOpener.open(tab: .signatures) }
                    .buttonStyle(LinkButtonStyle())
            }
            Spacer()
            Text("The menu bar icon still takes drops, as always.")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

// MARK: - merging on the canvas

private struct MergeCard: View {
    let controller: StartWindowController
    @Environment(MergeJob.self) private var job

    var body: some View {
        @Bindable var job = job
        let working = job.isWorking
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.system(size: 16, weight: .semibold))
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if job.imageCount > 0, job.phase != .done {
                    Picker("Output", selection: $job.output) {
                        if job.canMerge { Text("Merge into one PDF").tag(MergeJob.Output.merge) }
                        if job.canConvertToJPEG { Text("Convert to JPEG").tag(MergeJob.Output.jpeg) }
                        if job.canConvertToPDF { Text("Convert images to PDF").tag(MergeJob.Output.pdf) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(working)
                }
            }

            List {
                ForEach(job.files) { file in
                    MergeRow(file: file, working: working)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                }
                .onMove { job.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(job.files.count) * 46, 46 * 6.5))
            .disabled(working)

            if let note = job.note, job.phase == .ready {
                Label(note, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if case .failed(let message) = job.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if working {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = job.progress.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(job.progress.message).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            if job.phase == .done, let result = job.result {
                DoneBlock(result: result)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                if job.phase == .done {
                    Spacer()
                    Button("Done") { controller.clear() }
                        .buttonStyle(SecondaryButtonStyle(height: 30, fullWidth: false))
                    if let outputs = job.result?.outputs, !outputs.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                            .buttonStyle(PrimaryButtonStyle(height: 30, fullWidth: false))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.settingsSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Button("Change in Settings…") { SettingsOpener.open(tab: .general) }
                            .buttonStyle(LinkButtonStyle())
                            .font(.system(size: 11))
                    }
                    Spacer(minLength: 8)
                    if working {
                        Button("Cancel") { job.cancel() }
                            .buttonStyle(SecondaryButtonStyle(height: 30, fullWidth: false))
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("Clear") { controller.clear() }
                            .buttonStyle(SecondaryButtonStyle(height: 30, fullWidth: false))
                        Button("Add…") { controller.chooseFiles() }
                            .buttonStyle(SecondaryButtonStyle(height: 30, fullWidth: false))
                        Button(job.actionTitle) { controller.run() }
                            .buttonStyle(PrimaryButtonStyle(height: 30, fullWidth: false))
                            .keyboardShortcut(.defaultAction)
                            .disabled(!job.canRun)
                    }
                }
            }
            if job.allPDFs, job.files.count > 1, job.phase == .ready {
                Button("Open them as tabs instead") { controller.openAsTabs() }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: 600)
        .modifier(CardGlass())
        .animation(.snappy(duration: 0.25), value: job.phase)
        .animation(.snappy(duration: 0.25), value: job.files.map(\.id))
    }

    private var caption: String {
        var parts: [String] = []
        if job.output == .merge {
            parts.append(job.orderLabel)
            if let pages = job.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
            parts.append("drag to reorder")
        } else {
            parts.append("\(job.files.count) file\(job.files.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

private struct MergeRow: View {
    let file: InputFile
    let working: Bool
    @Environment(MergeJob.self) private var job
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileThumbView(url: file.url, side: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { withAnimation(.snappy(duration: 0.2)) { job.remove(file) } } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering && !working ? 0.85 : 0)
            .help("Remove from the list (the file isn't touched)")
            .accessibilityLabel("Remove \(file.name)")
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var meta: String {
        let size = ByteSize.string(file.bytes)
        switch file.kind {
        case .pdf:
            let n = file.pageCount ?? 0
            return "\(size) · \(n) page\(n == 1 ? "" : "s")"
        case .image:
            return "\(size) · \(file.url.pathExtension.uppercased()) image"
        case .csv:
            return "\(size) · \(file.url.pathExtension.uppercased()) table"
        case .word, .powerpoint, .excel:
            let app = switch file.kind { case .word: "Word"; case .powerpoint: "PowerPoint"; default: "Excel" }
            return OfficeConverter.isInstalled ? "\(size) · \(app)" : "\(app) · needs LibreOffice"
        }
    }
}

private struct DoneBlock: View {
    let result: JobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(result.title, systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
            let where_ = result.outputs.first.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path) } ?? ""
            Text("\(result.outputs.count == 1 ? result.outputs[0].lastPathComponent : "\(result.outputs.count) files") · \(ByteSize.string(result.bytes)) · in \(where_)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let over = result.overLimit {
                Text("Still over \(ByteSize.string(over.target)) at the lowest quality. Split it from the menu bar panel if you need parts.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            if !result.skipped.isEmpty {
                Text("Left out: " + result.skipped.joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let note = result.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Liquid Glass card on macOS 26; a material card before.
private struct CardGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26, *) {
            content
                .background(.regularMaterial, in: shape)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
    }
}

/// The whole canvas takes file drops; while something is over it, the drop card says what will happen.
private struct CanvasDrop: DropDelegate {
    let state: StartState
    let perform: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        state.dropCount = max(info.itemProviders(for: [.fileURL]).count, 1)
    }

    func dropExited(info: DropInfo) {
        state.dropCount = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        state.dropCount = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                    _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
                }) { urls.append(url) }
            }
            perform(urls)
        }
        return true
    }
}
