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

    var toast: Toast?
    var banners: [Banner] = []
    var selectedTextBox: TextBox?
    var tool: StitchPDFView.Tool = .select
    var isSaving = false
    var isDirty = false
}

/// One PDF in a tab: the window, its toolbar, the viewer and the edit session.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingID = "StitchDocument"

    let session: EditSession
    let pdfView = StitchPDFView()
    let ui = DocumentUI()
    private let prefs: Preferences
    private weak var documents: DocumentController?
    private var baselineForm: [String: String] = [:]
    private var toolbarDelegate: DocumentToolbar?
    private var toastTask: Task<Void, Never>?
    private var closeConfirmed = false
    /// Callers waiting on the save in progress (quit, close).
    private var saveWaiters: [(Bool) -> Void] = []
    private var formObserver: NSObjectProtocol?

    init(session: EditSession, prefs: Preferences, documents: DocumentController) {
        self.session = session
        self.prefs = prefs
        self.documents = documents
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingID
        window.isRestorable = false
        window.title = session.name
        window.representedURL = session.original
        window.subtitle = session.pageCount == 1 ? "1 page" : "\(session.pageCount) pages"
        window.minSize = NSSize(width: 520, height: 420)
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

        window.contentView = NSHostingView(rootView: DocumentView(controller: self).environment(ui))
        // Typing in the PDF's own form fields: keep the edited dot current.
        formObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil,
                                                              queue: .main) { [weak self] note in
            let field = note.object as? NSView
            MainActor.assumeIsolated {
                guard let self, let field, field.window === self.window, field.isDescendant(of: self.pdfView) else { return }
                self.refreshDirty()
            }
        }
        if session.flags.contains(.xfa) { ui.banners.append(.xfa) }
        if session.flags.contains(.digitallySigned) { ui.banners.append(.digitallySigned) }
    }

    required init?(coder: NSCoder) { nil }

    private func wireCallbacks() {
        session.onOverlaysChanged = { [weak self] in
            guard let self else { return }
            pdfView.syncOverlays()
            refreshSelection()
            refreshDirty()
        }
        session.onWorkingCopyChanged = { [weak self] url, pages in
            guard let self, let doc = PDFDocument(url: url) else { return }
            let form = currentForm()
            pdfView.replacePages(pages, from: doc, form: form)
            refreshDirty()
        }
        session.onError = { [weak self] in self?.showToast("Couldn't apply the edit: \($0)") }
        session.onOverflow = { [weak self] in self?.showToast("The new text is longer and now overlaps other content") }
        pdfView.onSelectionChanged = { [weak self] _ in self?.refreshSelection() }
        pdfView.onToolChanged = { [weak self] tool in
            self?.ui.tool = tool
            self?.toolbarDelegate?.refresh()
        }
        pdfView.onMessage = { [weak self] _ in self?.showBanner(.scan) }
        pdfView.onPlaceTextBox = { [weak self] page, point in self?.placeTextBox(page: page, at: point) }
    }

    private func refreshSelection() {
        ui.selectedTextBox = pdfView.selectedID.flatMap { session.overlay($0)?.textBox }
    }

    func refreshDirty() {
        let dirty = session.hasUnsavedChanges(currentForm: FormBridge.changes(currentForm(), from: baselineForm))
        ui.isDirty = dirty
        window?.isDocumentEdited = dirty
        documents?.objectWillChangeForCommands()
    }

    private func currentForm() -> [String: String] {
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

    private func placeTextBox(page: Int, at point: CGPoint, text: String = "", select edit: Bool = true) {
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
        insertText(prefs.formattedDate(), actionName: "Date")
    }

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
        let store = SignatureStore.shared
        guard let sig = initials ? store.initials : store.signature else {
            return createSignature(initials: initials, thenPlace: true)
        }
        Task {
            guard await BiometricGate.authorize(initials ? "use your initials" : "use your signature") else { return }
            let height: CGFloat = initials ? 28 : 40
            var size = sig.size(height: height)
            if size.width > 220 { size = CGSize(width: 220, height: 220 / sig.aspect) }
            guard let spot = pdfView.placement(upright: size) else { return }
            let overlay = Overlay(page: spot.page, rect: spot.rect, rotation: spot.rotation,
                                  kind: initials ? .initials(sig) : .signature(sig))
            session.add(overlay, actionName: initials ? "Initials" : "Signature")
            pdfView.select(overlay.id)
        }
    }

    func createSignature(initials: Bool, thenPlace: Bool = false) {
        guard let window else { return }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let pad = SignaturePad(initials: initials) { [weak self, weak window, weak host] result in
            if let sheet = host?.view.window { window?.endSheet(sheet) }
            guard let self, let result else { return }
            do {
                try SignatureStore.shared.setSignature(result, initials: initials)
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
            guard await BiometricGate.authorize("fill in your details") else { return }
            let profile = SignatureStore.shared.profile
            guard !profile.isEmpty else {
                showToast("Add your details first: Stitch → Settings → Your Info")
                return
            }
            guard let doc = pdfView.document else { return }
            var filled = 0
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                for a in page.annotations where FormBridge.isWidget(a) && a.widgetFieldType == .text {
                    guard (a.widgetStringValue ?? "").isEmpty,
                          let item = a.fieldName.flatMap(AutoFill.match) ?? a.toolTip.flatMap(AutoFill.match) else { continue }
                    let value = profile.value(item, address: address)
                    guard !value.isEmpty else { continue }
                    a.widgetStringValue = value
                    a.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25)
                    filled += 1
                }
                pdfView.annotationsChanged(on: page)
            }
            pdfView.needsDisplay = true
            refreshDirty()
            showToast(filled == 0 ? "No fields matched your info" : "Filled \(filled) field\(filled == 1 ? "" : "s") (highlighted)")
        }
    }

    var hasFormFields: Bool {
        guard let doc = pdfView.document else { return false }
        return (0..<doc.pageCount).contains { i in doc.page(at: i)?.annotations.contains(where: FormBridge.isWidget) ?? false }
    }

    func insertProfileItem(_ item: ProfileItem, address: Profile.Address?) {
        Task {
            guard await BiometricGate.authorize("use your details") else { return }
            let value = SignatureStore.shared.profile.value(item, address: address)
            guard !value.isEmpty else { return showToast("\(item.label) is empty in Settings → Your Info") }
            insertText(value, actionName: item.label)
        }
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

    // MARK: window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        pdfView.commitEditing()
        captureForm()
        refreshDirty()
        guard ui.isDirty, !closeConfirmed else { return true }
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
        session.close()
        if let formObserver { NotificationCenter.default.removeObserver(formObserver) }
        // The SwiftUI content and toolbar hold this controller; let go of them so the tab is freed.
        window?.toolbar = nil
        window?.contentView = nil
        pdfView.document = nil
        documents?.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        documents?.current = self
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
