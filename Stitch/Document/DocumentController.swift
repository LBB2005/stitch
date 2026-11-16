import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

/// Opens PDFs into document windows (one window, each PDF a tab), keeps the recent list, and switches
/// Stitch between menu-bar-only and a Dock app: `.regular` while any Stitch window is open, `.accessory`
/// when none is. The menu bar icon and panel are untouched by all of this.
///
/// There is no separate home window: the Stitch window with nothing open (`StartWindowController`) is the
/// start page. A PDF opened from it takes over that same window; closing the last document hands the
/// window back to the start canvas.
@MainActor
@Observable
final class DocumentController {
    private(set) var windows: [DocumentWindowController] = []
    /// Stitch windows (or tabs) with nothing open.
    private(set) var starts: [StartWindowController] = []
    private(set) var recents: [URL] = []
    /// The frontmost document tab, for the menus.
    var current: DocumentWindowController? {
        didSet { commandsTick += 1 }
    }
    /// Bumped when anything the menus show changes (enabled state, recents).
    private(set) var commandsTick = 0

    @ObservationIgnored let model: AppModel
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var commandBar: CommandBarController?

    var prefs: Preferences { model.prefs }

    init(model: AppModel) {
        self.model = model
        recents = Self.resolve(model.prefs.recentBookmarks)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // After the window is gone.
                DispatchQueue.main.async { self?.updateActivationPolicy() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                if let c = self.windows.first(where: { $0.window === window }) { self.current = c }
                else if window.isVisible, window.styleMask.contains(.titled) { self.current = nil }
            }
        })
    }

    func objectWillChangeForCommands() { commandsTick += 1 }

    // MARK: opening

    func showOpenPanel() {
        becomeApp()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDFs to sign, fill or edit. The originals are never changed."
        panel.prompt = "Open"
        if panel.runModal() == .OK { open(panel.urls) }
        updateActivationPolicy()
    }

    /// PDFs open as tabs; anything else goes on a Stitch window's merge list.
    func open(_ urls: [URL]) {
        let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
        let others = urls.filter { !pdfs.contains($0) }
        for url in pdfs { open(url) }
        if !others.isEmpty { stageMerge(others) }
    }

    /// Opens a PDF. `into`: the empty Stitch window it was opened from, which becomes the document.
    func open(_ url: URL, into start: StartWindowController? = nil) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = windows.first(where: { $0.session.original.standardizedFileURL.resolvingSymlinksInPath() == target }) {
            becomeApp()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return alert("Couldn't open “\(url.lastPathComponent)”", "The file can't be read.")
        }
        becomeApp()
        var password: String?
        while true {
            do {
                let session = try EditSession(original: url, password: password)
                show(session, into: start)
                noteRecent(url)
                return
            } catch let failure as MuPDFDocument.Failure where failure == .needsPassword || failure == .wrongPassword {
                guard let entered = askPassword(for: url, wrong: failure == .wrongPassword) else {
                    updateActivationPolicy()
                    return
                }
                password = entered
            } catch {
                alert("Couldn't open “\(url.lastPathComponent)”", error.localizedDescription)
                updateActivationPolicy()
                return
            }
        }
    }

    private func show(_ session: EditSession, into start: StartWindowController?) {
        // Opened from an empty Stitch window (or with only that one around): the document takes it over.
        if let start = start ?? adoptableStart(), let window = start.relinquishWindow() {
            starts.removeAll { $0 === start }
            let controller = DocumentWindowController(session: session, prefs: prefs, documents: self, window: window)
            windows.append(controller)
            window.makeKeyAndOrderFront(nil)
            current = controller
            commandsTick += 1
            return
        }
        let controller = DocumentWindowController(session: session, prefs: prefs, documents: self)
        guard let window = controller.window else { return }
        let host = windows.last(where: { $0.window?.isVisible == true })?.window
        windows.append(controller)
        if let host {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            place(window)
        }
        window.makeKeyAndOrderFront(nil)
        current = controller
        commandsTick += 1
    }

    /// The empty window a PDF should open into: the frontmost one, or the only window there is.
    private func adoptableStart() -> StartWindowController? {
        if let key = NSApp.keyWindow, let start = starts.first(where: { $0.window === key }), start.job.isEmpty { return start }
        guard windows.isEmpty else { return nil }
        return starts.first { $0.window?.isVisible == true && $0.job.isEmpty }
    }

    /// A first window: where Stitch windows were last, or a tall window in the middle of the screen.
    private func place(_ window: NSWindow) {
        let name = "StitchDocumentWindow"
        let inUse = (windows.compactMap(\.window) + starts.compactMap(\.window)).contains { $0 !== window && $0.frameAutosaveName == name }
        if !inUse { window.setFrameAutosaveName(name) }
        if inUse || !window.setFrameUsingName(name) {
            if let screen = NSScreen.main?.visibleFrame {
                let h = min(screen.height - 40, 1100), w = min(h * 0.82 + DocumentSplitController.preferredWidth, screen.width - 80)
                window.setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: false)
            }
        }
    }

    func windowClosed(_ controller: DocumentWindowController) {
        windows.removeAll { $0 === controller }
        if current === controller { current = nil }
        commandsTick += 1
    }

    // MARK: the empty Stitch window

    /// Every Stitch window, documents and empty ones.
    private var allWindows: [NSWindow] { windows.compactMap(\.window) + starts.compactMap(\.window) }

    var hasVisibleWindow: Bool { allWindows.contains { $0.isVisible || $0.isMiniaturized } }

    /// Dock icon, Stitch Window (⇧⌘1), the menu bar panel's "open app": bring a Stitch window forward,
    /// or open an empty one.
    func showHome() {
        becomeApp()
        refreshRecents()
        if let start = starts.last(where: { $0.window?.isVisible == true }) {
            start.window?.makeKeyAndOrderFront(nil)
        } else if let window = (current?.window).flatMap({ $0.isVisible ? $0 : nil }) ?? allWindows.last(where: \.isVisible) {
            window.makeKeyAndOrderFront(nil)
        } else {
            let start = StartWindowController(documents: self)
            starts.append(start)
            if let window = start.window {
                place(window)
                window.makeKeyAndOrderFront(nil)
            }
        }
        commandsTick += 1
    }

    /// ⌘T and the tab bar's +: an empty Stitch window as a new tab.
    @discardableResult
    func newTab() -> StartWindowController {
        becomeApp()
        let start = StartWindowController(documents: self)
        starts.append(start)
        if let window = start.window {
            let key = NSApp.keyWindow.flatMap { k in allWindows.contains(k) ? k : nil }
            if let host = key ?? allWindows.last(where: { $0 !== window && $0.isVisible }) {
                host.addTabbedWindow(window, ordered: .above)
            } else {
                place(window)
            }
            window.makeKeyAndOrderFront(nil)
        }
        commandsTick += 1
        return start
    }

    /// The last document closed: its window stays, as an empty Stitch window.
    func returnToStart(_ window: NSWindow) {
        let start = StartWindowController(documents: self, window: window)
        starts.append(start)
        current = nil
        commandsTick += 1
    }

    func startClosed(_ start: StartWindowController) {
        starts.removeAll { $0 === start }
        commandsTick += 1
    }

    /// Files to merge or convert: onto an empty Stitch window's list (a new tab if every window has a PDF).
    func stageMerge(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        becomeApp()
        // A PDF tab in front: they go on its Combine panel, so you never leave the document.
        if let doc = windows.first(where: { $0.window === NSApp.keyWindow }), !doc.combine.isWorking,
           doc.combine.phase != .done {
            doc.showPanel(.combine)
            doc.combineAdd(urls)
            return
        }
        let start = starts.first { $0.window === NSApp.keyWindow && !$0.job.isWorking }
            ?? starts.first { $0.window?.isVisible == true && !$0.job.isWorking }
            ?? newTab()
        start.window?.makeKeyAndOrderFront(nil)
        start.add(urls)
    }

    /// Merge Files… (⌘K): pick files, then merge them in a Stitch window.
    func chooseFilesToMerge() {
        becomeApp()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileKind.pickerTypes
        panel.prompt = "Choose"
        panel.message = "Choose PDFs, photos, Word, PowerPoint, Excel or CSV files to merge. They're never changed."
        if panel.runModal() == .OK { stageMerge(panel.urls) }
    }

    // MARK: search (⌘K)

    func showCommandBar(over window: NSWindow? = nil) {
        becomeApp()
        if !hasVisibleWindow { showHome() }
        let target = window.flatMap { allWindows.contains($0) ? $0 : nil }
            ?? NSApp.keyWindow.flatMap { allWindows.contains($0) ? $0 : nil }
            ?? current?.window ?? allWindows.last(where: \.isVisible)
        guard let target else { return }
        commandBar?.close()
        let bar = CommandBarController(parent: target, documents: self)
        bar.onClose = { [weak self, weak bar] in
            if let self, self.commandBar === bar { self.commandBar = nil }
        }
        commandBar = bar
        bar.show()
    }

    /// The document window showing this window, if it has a PDF.
    func document(in window: NSWindow?) -> DocumentWindowController? {
        windows.first { $0.window === window }
    }

    private func askPassword(for url: URL, wrong: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = wrong ? "That password didn't work" : "“\(url.lastPathComponent)” is password-protected"
        alert.informativeText = "Enter the password to open it."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: recents

    func noteRecent(_ url: URL) {
        let std = url.standardizedFileURL
        var list = recents.filter { $0.standardizedFileURL != std }
        list.insert(std, at: 0)
        recents = Array(list.prefix(10))
        prefs.recentBookmarks = recents.compactMap { try? $0.bookmarkData() }
        NSDocumentController.shared.noteNewRecentDocumentURL(std)
        commandsTick += 1
    }

    func clearRecents() {
        recents = []
        prefs.recentBookmarks = []
        NSDocumentController.shared.clearRecentDocuments(nil)
        commandsTick += 1
    }

    /// Bookmarks follow renames and moves; files that are gone drop off.
    private static func resolve(_ bookmarks: [Data]) -> [URL] {
        bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// A document was renamed from its title: Recent follows it.
    func renamed(from old: URL, to new: URL) {
        let before = old.standardizedFileURL
        recents = recents.map { $0.standardizedFileURL == before ? new.standardizedFileURL : $0 }
        prefs.recentBookmarks = recents.compactMap { try? $0.bookmarkData() }
        NSDocumentController.shared.noteNewRecentDocumentURL(new)
        commandsTick += 1
    }

    func refreshRecents() {
        recents = recents.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Dock icon and menus

    /// Shows the Dock icon and menu bar menus.
    func becomeApp() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    /// Menu-bar-only again once no Stitch window (home, document, Settings) is open.
    func updateActivationPolicy() {
        let anyWindow = NSApp.windows.contains { w in
            (w.isVisible || w.isMiniaturized) && w.styleMask.contains(.titled) && !(w is NSPanel) && w.level == .normal
        }
        if anyWindow {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        } else if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: quitting

    /// Asks once about all unsaved PDFs; returns whether quitting can go ahead now.
    func reviewBeforeQuit(_ reply: @escaping (Bool) -> Void) {
        let dirty = windows.filter(\.needsSaving)
        guard !dirty.isEmpty else { return reply(true) }
        becomeApp()
        let alert = NSAlert()
        alert.messageText = dirty.count == 1 ? "Save a copy of your changes to “\(dirty[0].session.name)” before quitting?"
                                             : "Save copies of your changes to \(dirty.count) PDFs before quitting?"
        alert.informativeText = "The originals stay as they are either way."
        alert.addButton(withTitle: dirty.count == 1 ? "Save Copy" : "Save Copies")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Quit once every copy is written; if any save fails, stay open (its toast says why).
            var remaining = dirty.count
            var allOK = true
            for c in dirty {
                c.saveCopy { ok in
                    allOK = allOK && ok
                    remaining -= 1
                    if remaining == 0 { reply(allOK) }
                }
            }
        case .alertThirdButtonReturn:
            reply(true)
        default:
            reply(false)
        }
    }
}
