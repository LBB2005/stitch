import AppKit
import Observation
import PDFKit
import SwiftUI

/// What the SwiftUI part of a document window shows on top of the PDF.
@MainActor
@Observable
final class DocumentUI {
    struct Toast: Equatable {
        var text: String
        var reveal: URL?
        var id = UUID()
    }

    enum Banner: Hashable {
        case xfa, digitallySigned, scan, message(String)

        var text: String {
            switch self {
            case .xfa: "This form uses XFA, which Stitch can't fill. You can still add text boxes, dates and signatures."
            case .digitallySigned: "This PDF is digitally signed. Saving a changed copy makes that digital signature invalid."
            case .scan: "This page is a scan, so it has no text to edit. Use a text box with a white background to cover and retype."
            case .message(let s): s
            }
        }

        var isWarning: Bool {
            switch self {
            case .xfa, .digitallySigned: true
            default: false
            }
        }
    }

    /// What's selected on the page, for the sidebar's selection card.
    enum Selection: Equatable {
        case text(TextBox)
        case signing(Overlay)
    }

    var toast: Toast?
    var banners: [Banner] = []
    var selection: Selection?
    var tool: StitchPDFView.Tool = .select
    var isSaving = false
    var isDirty = false

    // The sidebar (one per window).
    var panel: SidebarPanel = .pages
    var isFolded = false
    var currentPage = 0
    var todo: [TodoItem] = []
    /// What Fill My Info would do, for the My Info panel.
    var fieldMatches: [AutoFill.FieldMatch] = []
    var addressIndex = 0
    /// Touch ID passed in this window: the Sign and My Info panels show their contents.
    var revealed = false
    var find = FindState()
    /// Form fields typed into directly (PDFKit's own editing; not undo steps).
    var typedFields = 0
    var hasFormFields = false

    var selectedTextBox: TextBox? {
        if case .text(let box) = selection { return box }
        return nil
    }

    var todoLeft: Int { todo.filter { !$0.done }.count }
    var hasWarning: Bool { banners.contains(where: \.isWarning) }
}

/// One PDF in a tab: the window, its toolbar, the viewer and the edit session. Opened from the empty
/// Stitch window, it takes over that same window (`window:`); closing the last document hands the window
/// back to the start canvas instead of closing it.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingID = "StitchDocument"

    let session: EditSession
    let pdfView = StitchPDFView()
    let ui = DocumentUI()
    let prefs: Preferences
    private(set) weak var documents: DocumentController?
    private var baselineForm: [String: String] = [:]
    private var toolbarDelegate: DocumentToolbar?
    private var toastTask: Task<Void, Never>?
    private var closeConfirmed = false
    /// Callers waiting on the save in progress (quit, close).
    private var saveWaiters: [(Bool) -> Void] = []
    private var formObserver: NSObjectProtocol?
    private var pageObserver: NSObjectProtocol?
    private(set) var split: DocumentSplitController?
    let thumbnails = PageThumbnails()
    /// The overlays as the thumbnails last saw them, to redraw only pages that changed.
    var thumbnailOverlays: [Overlay] = []
    var findTask: Task<Void, Never>?
    /// Form fields Fill My Info (or a dropped detail) set, so History doesn't count them as typed.
    var filledFields: Set<String> = []
    /// The Combine panel's merge or convert, made when first used.
    var combineJob: MergeJob?

    init(session: EditSession, prefs: Preferences, documents: DocumentController, window existing: NSWindow? = nil) {
        self.session = session
        self.prefs = prefs
        self.documents = documents
        let window = existing ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
        let keptFrame = existing?.frame
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingID
        window.isRestorable = false
        window.title = session.name
        window.representedURL = session.original
        window.subtitle = session.pageCount == 1 ? "1 page" : "\(session.pageCount) pages"
        // The toolbar shows the name itself (click it to rename); tabs and the Window menu still use `title`.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 600, height: 420)
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)
        window.delegate = self

        pdfView.session = session
        if let doc = PDFDocument(url: session.workingCopy) {
            if doc.isLocked, let pw = session.password { doc.unlock(withPassword: pw) }
            pdfView.document = doc
            baselineForm = FormBridge.values(in: doc)
        }
        pdfView.syncOverlays()
        wireCallbacks()

        let toolbar = DocumentToolbar(controller: self)
        toolbarDelegate = toolbar
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unifiedCompact

        thumbnails.pdfView = pdfView
        thumbnailOverlays = session.overlays
        let split = DocumentSplitController(controller: self)
        split.animateIn = existing != nil
        self.split = split
        window.contentViewController = split
        if let keptFrame {
            window.setFrame(keptFrame, display: false)
        } else {
            window.setContentSize(NSSize(width: 1180, height: 1000))
        }
        // Typing in the PDF's own form fields: keep the edited dot current.
        formObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil,
                                                              queue: .main) { [weak self] note in
            let field = note.object as? NSView
            MainActor.assumeIsolated {
                guard let self, let field, field.window === self.window, field.isDescendant(of: self.pdfView) else { return }
                self.refreshDirty()
                self.refreshTodo()
                self.refreshFieldMatches()
            }
        }
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let page = self.pdfView.currentPageIndex
                if self.ui.currentPage != page { self.ui.currentPage = page }
            }
        }
        if session.flags.contains(.xfa) { ui.banners.append(.xfa) }
        if session.flags.contains(.digitallySigned) { ui.banners.append(.digitallySigned) }
        ui.hasFormFields = hasFormFields
        refreshTodo()
        refreshFieldMatches()
        ui.panel = ui.todoLeft > 0 || !ui.banners.isEmpty ? .todo : .pages
    }

    required init?(coder: NSCoder) { nil }

    private func wireCallbacks() {
        session.onOverlaysChanged = { [weak self] in
            guard let self else { return }
            pdfView.syncOverlays()
            refreshSelection()
            refreshDirty()
            overlaysChangedForSidebar()
        }
        session.onWorkingCopyChanged = { [weak self] url, pages in
            guard let self, let doc = PDFDocument(url: url) else { return }
            let form = currentForm()
            pdfView.replacePages(pages, from: doc, form: form)
            refreshDirty()
            thumbnails.invalidate(pages)
            refreshTodo()
            refreshFind()
        }
        session.onError = { [weak self] in self?.showToast("Couldn't apply the edit: \($0)") }
        session.onOverflow = { [weak self] in self?.showToast("The new text is longer and now overlaps other content") }
        pdfView.onSelectionChanged = { [weak self] _ in self?.refreshSelection() }
        pdfView.onToolChanged = { [weak self] tool in
            self?.ui.tool = tool
            self?.toolbarDelegate?.refresh()
        }
        pdfView.onMessage = { [weak self] message in
            self?.showBanner(.scan)
            self?.showToast(message)
        }
        pdfView.onPlaceTextBox = { [weak self] page, point in self?.placeTextBox(page: page, at: point) }
        pdfView.onPlaceItem = { [weak self] item, page, point in self?.place(item, page: page, at: point) }
        pdfView.placeSize = { [weak self] item in self?.naturalSize(of: item) }
        pdfView.placeTarget = { [weak self] item, page, point in self?.spot(for: item, page: page, at: point) }
    }

    private func refreshSelection() {
        let selection: DocumentUI.Selection? = pdfView.selectedID.flatMap { session.overlay($0) }.map { ov in
            if let box = ov.textBox { return .text(box) }
            return .signing(ov)
        }
        if ui.selection != selection { ui.selection = selection }
    }

    func refreshDirty() {
        let changes = FormBridge.changes(currentForm(), from: baselineForm)
        let dirty = session.hasUnsavedChanges(currentForm: changes)
        let typed = Set(changes.keys).subtracting(filledFields).count
        if ui.typedFields != typed { ui.typedFields = typed }
        let changed = ui.isDirty != dirty
        ui.isDirty = dirty
        window?.isDocumentEdited = dirty
        if changed { toolbarDelegate?.refreshTitle() }
        documents?.objectWillChangeForCommands()
    }

    func currentForm() -> [String: String] {
        pdfView.document.map(FormBridge.values) ?? [:]
    }

    /// Pulls typed form values from the viewer into the session.
    private func captureForm() {
        session.setFormValues(FormBridge.changes(currentForm(), from: baselineForm))
    }

    // MARK: messages

    func showToast(_ text: String, reveal: URL? = nil) {
        ui.toast = DocumentUI.Toast(text: text, reveal: reveal)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(reveal == nil ? 4 : 7))
            guard !Task.isCancelled else { return }
            self?.ui.toast = nil
        }
    }

    func showBanner(_ banner: DocumentUI.Banner) {
        if !ui.banners.contains(banner) { ui.banners.append(banner) }
        refreshTodo()
    }

    func dismissBanner(_ banner: DocumentUI.Banner) {
        ui.banners.removeAll { $0 == banner }
    }

    // MARK: view

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func actualSize() {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }
    func fitWidth() {
        pdfView.autoScales = true
    }

    // MARK: tools

    func toggleEditText() {
        pdfView.commitEditing()
        pdfView.tool = pdfView.tool == .editText ? .select : .editText
    }

    func startTextBox() {
        pdfView.commitEditing()
        pdfView.tool = .textBox
        showToast("Click where the text should go")
    }

    func placeTextBox(page: Int, at point: CGPoint, text: String = "", select edit: Bool = true) {
        guard let pdfPage = pdfView.document?.page(at: page) else { return }
        var box = TextBox(text: text)
        box.fontSize = 12
        let rotation = pdfPage.rotation
        let size = PageGeometry.userSize(ofUpright: box.naturalSize, rotation: rotation)
        // The click is where the first line starts: the box's top-left as the page is shown.
        let rect: CGRect = switch PageGeometry.normalized(rotation) {
        case 90: CGRect(x: point.x - size.width * 0.75, y: point.y, width: size.width, height: size.height)
        case 180: CGRect(x: point.x - size.width, y: point.y - size.height * 0.25, width: size.width, height: size.height)
        case 270: CGRect(x: point.x - size.width * 0.25, y: point.y - size.height, width: size.width, height: size.height)
        default: CGRect(x: point.x, y: point.y - size.height * 0.75, width: size.width, height: size.height)
        }
        let overlay = Overlay(page: page, rect: rect, rotation: rotation, kind: .text(box))
        session.addDraft(overlay)
        pdfView.select(overlay.id)
        if edit { pdfView.beginEditing(overlay, isNew: true) }
    }

    /// Drops a text box with this text where you last clicked (or mid-page) and selects it.
    func insertText(_ text: String, actionName: String) {
        let box = TextBox(text: text)
        guard let spot = pdfView.placement(upright: box.naturalSize) else { return }
        let overlay = Overlay(page: spot.page, rect: spot.rect, rotation: spot.rotation, kind: .text(box))
        session.add(overlay, actionName: actionName)
        pdfView.select(overlay.id)
    }

    func insertDate() {
        place(.date)
    }

    var formattedDate: String { prefs.formattedDate() }

    func updateSelectedTextBox(_ change: (inout TextBox) -> Void) {
        guard let id = pdfView.selectedID, var ov = session.overlay(id), var box = ov.textBox else { return }
        let before = PageGeometry.uprightSize(of: ov.rect, rotation: ov.rotation)
        change(&box)
        ov.kind = .text(box)
        let after = box.naturalSize
        // Keep the top-left corner (as shown) where it is.
        if let r = pdfView.viewRect(ov.rect, page: ov.page), let page = pdfView.document?.page(at: ov.page) {
            let s = pdfView.scaleFactor
            let view = NSRect(x: r.minX, y: r.maxY - after.height * s, width: after.width * s, height: after.height * s)
            ov.rect = pdfView.convert(view, to: page)
        } else {
            ov.rect.size = PageGeometry.userSize(ofUpright: after, rotation: ov.rotation)
            _ = before
        }
        session.update(ov, actionName: "Format Text")
    }

    func deleteSelection() {
        if let id = pdfView.selectedID { session.remove(id) }
    }

    // MARK: signing

    func placeSignature(initials: Bool) {
        place(initials ? .initials : .signature)
    }

    func createSignature(initials: Bool, thenPlace: Bool = false) {
        guard let window else { return }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let pad = SignaturePad(initials: initials) { [weak self, weak window, weak host] result in
            if let sheet = host?.view.window { window?.endSheet(sheet) }
            guard let self, let result else { return }
            do {
                try SignatureStore.shared.setSignature(result, initials: initials)
                self.ui.revealed = true
                if thenPlace { self.placeSignature(initials: initials) }
            } catch {
                self.showToast("Couldn't save it in the Keychain: \(error.localizedDescription)")
            }
        }
        host.rootView = AnyView(pad)
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask = [.titled]
        window.beginSheet(sheet)
    }

    // MARK: my info

    func fillMatchingFields(address: Profile.Address?) {
        Task {
            guard await reveal("fill in your details") else { return }
            let profile = SignatureStore.shared.profile
            guard !profile.isEmpty else {
                showToast("Add your details first: Stitch → Settings → Your Info")
                return
            }
            let plan = AutoFill.plan(fields: textFields(), profile: profile, address: address).filter { !$0.alreadyFilled }
            var values: [String: String] = [:]
            for match in plan where values[match.field.name] == nil { values[match.field.name] = match.value }
            setFields(values, actionName: "Fill My Info",
                      summary: "Filled \(values.count) field\(values.count == 1 ? "" : "s") from My Info",
                      page: plan.count == 1 ? plan.first?.field.page : nil)
            showToast(values.isEmpty ? "No fields matched your info" : "Filled \(values.count) field\(values.count == 1 ? "" : "s") (highlighted)")
        }
    }

    var hasFormFields: Bool {
        guard let doc = pdfView.document else { return false }
        return (0..<doc.pageCount).contains { i in doc.page(at: i)?.annotations.contains(where: FormBridge.isWidget) ?? false }
    }

    func insertProfileItem(_ item: ProfileItem, address: Profile.Address?) {
        let addresses = SignatureStore.shared.profile.addresses.filter { !$0.isEmpty }
        place(.profile(item, address: address.flatMap { a in addresses.firstIndex { $0.id == a.id } }))
    }

    // MARK: saving

    var canSave: Bool { !ui.isSaving }

    /// `done` runs exactly once: true when the copy was written.
    func saveCopy(done: ((Bool) -> Void)? = nil) {
        save(exact: nil, done: done)
    }

    func saveCopyAs() {
        guard let window else { return }
        pdfView.commitEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = session.original.deletingLastPathComponent()
        panel.nameFieldStringValue = SaveCopy.defaultBaseName(for: session.original, signed: session.isSigned) + ".pdf"
        panel.message = "Stitch saves a new file. The original is never changed."
        panel.prompt = "Save Copy"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.save(exact: url, done: nil) }
        }
    }

    private func save(exact: URL?, done: ((Bool) -> Void)?) {
        guard !ui.isSaving else {
            // Already saving: wait for that one, then save again so the newest changes are in.
            saveWaiters.append { [weak self] _ in self?.save(exact: exact, done: done) ?? done?(false) }
            return
        }
        pdfView.commitEditing()
        captureForm()
        ui.isSaving = true
        let others = documents?.windows.filter { $0 !== self }.map(\.session.original) ?? []
        let request = session.saveRequest(fallbackFolder: prefs.saveFolder, exactDestination: exact, protected: others)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try SaveCopy.run(request) } }.value
            ui.isSaving = false
            defer {
                let waiters = saveWaiters
                saveWaiters = []
                let ok = (try? result.get()) != nil
                waiters.forEach { $0(ok) }
            }
            switch result {
            case .success(let outcome):
                session.didSave(to: outcome.url)
                filledFields = []
                baselineAfterSave()
                documents?.noteRecent(outcome.url)
                let name = outcome.url.lastPathComponent
                showToast(outcome.usedFallback ? "Couldn't write next to the original, so saved \(name) in \(FileManager.default.displayName(atPath: outcome.url.deletingLastPathComponent().path))"
                                               : "Saved \(name)", reveal: outcome.url)
                done?(true)
            case .failure(let error):
                showToast(error.localizedDescription)
                done?(false)
            }
        }
    }

    private func baselineAfterSave() {
        refreshDirty()
    }

    // MARK: name, search, tabs

    /// Renames the file itself (from the toolbar title). Its contents are never touched; an existing
    /// file with that name is never replaced. Returns false (and says why) when it didn't happen.
    func rename(to typed: String) -> Bool {
        let old = session.original
        let ext = old.pathExtension
        guard let base = FileRename.baseName(typed, extension: ext) else {
            showToast("A file name needs at least one letter or number")
            return false
        }
        let new = old.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        guard new.lastPathComponent != old.lastPathComponent else { return true }
        let fm = FileManager.default
        let caseOnly = new.lastPathComponent.lowercased() == old.lastPathComponent.lowercased()
        if fm.fileExists(atPath: new.path), !caseOnly {
            showToast("There's already a file named “\(new.lastPathComponent)” in that folder")
            return false
        }
        do {
            if caseOnly {
                // Case-insensitive volumes see the new name as the same file: go through a temporary name.
                let temp = old.deletingLastPathComponent().appendingPathComponent(".stitch-rename-\(UUID().uuidString)")
                try fm.moveItem(at: old, to: temp)
                do { try fm.moveItem(at: temp, to: new) } catch {
                    try? fm.moveItem(at: temp, to: old)
                    throw error
                }
            } else {
                try fm.moveItem(at: old, to: new)
            }
        } catch {
            showToast("Couldn't rename it: \(error.localizedDescription)")
            return false
        }
        session.moved(to: new)
        window?.title = new.lastPathComponent
        window?.representedURL = new
        toolbarDelegate?.refreshTitle()
        documents?.renamed(from: old, to: new)
        showToast("Renamed to \(new.lastPathComponent)", reveal: new)
        return true
    }

    /// Puts the toolbar title into rename mode (⌘K → Rename).
    func beginRename() {
        toolbarDelegate?.beginRename()
    }

    func showSearch() {
        documents?.showCommandBar(over: window)
    }

    /// The tab bar's + (and ⌘T): a new tab on the start canvas.
    override func newWindowForTab(_ sender: Any?) {
        documents?.newTab()
    }

    // MARK: window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        pdfView.commitEditing()
        captureForm()
        refreshDirty()
        guard ui.isDirty, !closeConfirmed else { return !handBackToStart(sender) }
        let alert = NSAlert()
        alert.messageText = "Save a copy of your changes to “\(session.name)”?"
        alert.informativeText = "The original stays as it is either way."
        alert.addButton(withTitle: "Save Copy")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    self.saveCopy { ok in
                        guard ok else { return }
                        self.closeConfirmed = true
                        sender.performClose(nil)
                    }
                case .alertThirdButtonReturn:
                    self.closeConfirmed = true
                    sender.performClose(nil)
                default:
                    break
                }
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    /// The last document closing: the window stays, back on the empty start canvas.
    private func handBackToStart(_ window: NSWindow) -> Bool {
        guard let documents, documents.windows.count == 1, documents.windows.first === self,
              (window.tabbedWindows?.count ?? 1) <= 1 else { return false }
        tearDown()
        window.delegate = nil
        window.isDocumentEdited = false
        self.window = nil
        documents.returnToStart(window)
        return true
    }

    private func tearDown() {
        combineJob?.cancel()
        session.close()
        if let formObserver { NotificationCenter.default.removeObserver(formObserver) }
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        findTask?.cancel()
        // The SwiftUI content and toolbar hold this controller; let go of them so the tab is freed.
        toolbarDelegate?.invalidate()
        window?.toolbar = nil
        window?.contentViewController = nil
        split = nil
        pdfView.document = nil
        documents?.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        documents?.current = self
    }

    func windowDidResignKey(_ notification: Notification) {
        // The Sign and My Info panels hide their contents again until the next Touch ID.
        if BiometricGate.graceSeconds == 0 { ui.revealed = false }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        split?.autoFold(width: window.frame.width)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        session.undoManager
    }

    /// For quitting: true when there's something unsaved.
    var needsSaving: Bool {
        pdfView.commitEditing()
        captureForm()
        refreshDirty()
        return ui.isDirty
    }
}
