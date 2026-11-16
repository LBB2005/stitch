import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

/// Opens PDFs into document windows (one window, each PDF a tab), keeps the recent list, and switches
/// Stitch between menu-bar-only and a Dock app: `.regular` while any Stitch window is open, `.accessory`
/// when none is. The menu bar icon and panel are untouched by all of this.
@MainActor
@Observable
final class DocumentController {
    private(set) var windows: [DocumentWindowController] = []
    private(set) var recents: [URL] = []
    /// The frontmost document tab, for the menus.
    var current: DocumentWindowController? {
        didSet { commandsTick += 1 }
    }
    /// Bumped when anything the menus show changes (enabled state, recents).
    private(set) var commandsTick = 0

    @ObservationIgnored let model: AppModel
    @ObservationIgnored private(set) lazy var home = HomeWindowController(documents: self, model: model)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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

    /// PDFs open as tabs; anything else goes to the menu bar panel for merging and converting.
    func open(_ urls: [URL]) {
        let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
        let others = urls.filter { !pdfs.contains($0) }
        for url in pdfs { open(url) }
        if !others.isEmpty {
            model.add(others)
            model.panel?.open()
        }
    }

    func open(_ url: URL) {
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
                show(session)
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

    private func show(_ session: EditSession) {
        let controller = DocumentWindowController(session: session, prefs: prefs, documents: self)
        guard let window = controller.window else { return }
        let host = windows.last(where: { $0.window?.isVisible == true })?.window
        windows.append(controller)
        if let host {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.setFrameAutosaveName("StitchDocumentWindow")
            if !window.setFrameUsingName("StitchDocumentWindow") {
                if let screen = NSScreen.main?.visibleFrame {
                    let h = min(screen.height - 40, 1100), w = min(h * 0.82 + DocumentSplitController.preferredWidth, screen.width - 80)
                    window.setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: false)
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        current = controller
        commandsTick += 1
    }

    func windowClosed(_ controller: DocumentWindowController) {
        windows.removeAll { $0 === controller }
        if current === controller { current = nil }
        commandsTick += 1
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

    func refreshRecents() {
        recents = recents.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: the app window

    func showHome() {
        becomeApp()
        home.show()
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
