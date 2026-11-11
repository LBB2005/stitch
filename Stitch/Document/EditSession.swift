import AppKit
import Observation
import PDFKit

/// One open PDF and everything changed in it: the single source of truth for its document window.
///
/// - `original` is read, never written.
/// - The viewer shows a working copy in the document's temp folder: the original plus `textEdits`, applied
///   by MuPDF, so what you see is what gets saved. Overlays are drawn on top of it by the viewer.
/// - Save Copy applies everything to the original afresh and writes a new file (`SaveCopy`).
@MainActor
@Observable
final class EditSession {
    let original: URL
    let password: String?
    let workDir: URL
    let pageCount: Int
    let flags: MuPDFDocument.Flags

    private(set) var workingCopy: URL
    private(set) var textEdits: [TextEdit] = []
    private(set) var overlays: [Overlay] = []
    /// Form values that differ from the original (field name → value), harvested from the viewer.
    private(set) var formValues: [String: String] = [:]
    /// The copy this tab saved; later saves update it.
    private(set) var savedCopy: URL?
    private(set) var isRebuilding = false

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var savedChangeCount = 0
    @ObservationIgnored private var savedFormValues: [String: String] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rebuild: Task<Void, Never>?
    @ObservationIgnored private var layoutDoc: MuPDFDocument?
    @ObservationIgnored private var blocksCache: [Int: [TextBlock]] = [:]
    @ObservationIgnored private var pageInfoCache: [Int: MuPDFDocument.PageInfo] = [:]

    /// Called after `overlays` change (the viewer redraws them).
    @ObservationIgnored var onOverlaysChanged: (() -> Void)?
    /// Called with a new working copy and the pages that changed.
    @ObservationIgnored var onWorkingCopyChanged: ((URL, Set<Int>) -> Void)?
    /// Called when a rebuild fails.
    @ObservationIgnored var onError: ((String) -> Void)?
    /// Called when an edit's new text had to grow past its box (it may overlap other content).
    @ObservationIgnored var onOverflow: (() -> Void)?

    var name: String { original.lastPathComponent }
    var isSigned: Bool { overlays.contains(where: \.isSigning) }

    /// Opens `url` for editing. Throws `MuPDFDocument.Failure.needsPassword` / `.wrongPassword`.
    init(original: URL, password: String?) throws {
        self.original = original
        self.password = password
        let doc = try MuPDFDocument(url: original, password: password)
        pageCount = doc.pageCount
        flags = doc.flags
        layoutDoc = doc
        workDir = try Workspace.makeJobDir()
        // An APFS clone: instant, and the viewer never holds the original open.
        let copy = workDir.appendingPathComponent("working-0.pdf")
        try FileManager.default.copyItem(at: original, to: copy)
        workingCopy = copy
    }

    func close() {
        rebuild?.cancel()
        layoutDoc = nil
        Workspace.remove(workDir)
    }

    // MARK: unsaved changes

    func hasUnsavedChanges(currentForm: [String: String]) -> Bool {
        changeCount != savedChangeCount || currentForm != savedFormValues
    }

    func setFormValues(_ values: [String: String]) {
        formValues = values
    }

    private func changed() { changeCount += 1 }

    // MARK: overlays

    func overlay(_ id: UUID) -> Overlay? { overlays.first { $0.id == id } }

    func add(_ overlay: Overlay, actionName: String) {
        overlays.append(overlay)
        changed()
        undoManager.registerUndo(withTarget: self) { $0.remove(overlay.id, actionName: actionName) }
        undoManager.setActionName(actionName)
        onOverlaysChanged?()
    }

    /// A new, still-empty text box: not undoable until it gets text (`commitNew`), and dropped without a
    /// trace if it never does.
    func addDraft(_ overlay: Overlay) {
        overlays.append(overlay)
        onOverlaysChanged?()
    }

    func discardDraft(_ id: UUID) {
        overlays.removeAll { $0.id == id }
        onOverlaysChanged?()
    }

    /// The draft got its text: one undoable "Text Box" step.
    func commitDraft(_ overlay: Overlay) {
        overlays.removeAll { $0.id == overlay.id }
        add(overlay, actionName: "Text Box")
    }

    func remove(_ id: UUID, actionName: String = "Delete") {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        let removed = overlays.remove(at: index)
        changed()
        undoManager.registerUndo(withTarget: self) { session in
            session.overlays.insert(removed, at: min(index, session.overlays.count))
            session.changed()
            session.undoManager.registerUndo(withTarget: session) { $0.remove(removed.id, actionName: actionName) }
            session.onOverlaysChanged?()
        }
        undoManager.setActionName(actionName)
        onOverlaysChanged?()
    }

    func update(_ overlay: Overlay, actionName: String) {
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }), overlays[index] != overlay else { return }
        let before = overlays[index]
        overlays[index] = overlay
        changed()
        undoManager.registerUndo(withTarget: self) { $0.update(before, actionName: actionName) }
        undoManager.setActionName(actionName)
        onOverlaysChanged?()
    }

    // MARK: text already in the PDF

    func pageInfo(_ page: Int) -> MuPDFDocument.PageInfo? {
        if let hit = pageInfoCache[page] { return hit }
        let info = try? layoutDoc?.pageInfo(page)
        pageInfoCache[page] = info
        return info
    }

    /// The original's text blocks on a page (cached). Empty for scans.
    func blocks(onPage page: Int) -> [TextBlock] {
        if let hit = blocksCache[page] { return hit }
        let chars = (try? layoutDoc?.chars(onPage: page)) ?? []
        let blocks = TextLayout.blocks(from: chars, page: page)
        blocksCache[page] = blocks
        return blocks
    }

    func edit(_ id: UUID) -> TextEdit? { textEdits.first { $0.id == id } }

    /// The edit, or else the original block, under a display-space point.
    func editTarget(at point: CGPoint, page: Int) -> (edit: TextEdit?, block: TextBlock)? {
        for edit in textEdits.reversed() where edit.page == page {
            if TextLayout.layout(edit).rect.insetBy(dx: -2, dy: -2).contains(point) { return (edit, edit.block) }
        }
        let covered = textEdits.filter { $0.page == page }.map(\.block.rect)
        guard let block = blocks(onPage: page).first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }),
              !covered.contains(block.rect) else { return nil }
        return (nil, block)
    }

    /// Adds or changes an edit. Changing it back to the original text removes it.
    func commitText(_ text: String, for block: TextBlock, editing existing: TextEdit?) {
        let trimmed = text.replacingOccurrences(of: "\r", with: "")
        var edits = textEdits
        if let existing, let i = edits.firstIndex(where: { $0.id == existing.id }) {
            if trimmed == existing.text { return }
            if trimmed == block.text { edits.remove(at: i) } else { edits[i].text = trimmed }
        } else {
            if trimmed == block.text { return }
            edits.append(TextEdit(block: block, text: trimmed))
        }
        setTextEdits(edits, pages: [block.page], actionName: "Edit Text")
    }

    private func setTextEdits(_ edits: [TextEdit], pages: Set<Int>, actionName: String) {
        let before = textEdits
        textEdits = edits
        changed()
        undoManager.registerUndo(withTarget: self) { $0.setTextEdits(before, pages: pages, actionName: actionName) }
        undoManager.setActionName(actionName)
        rebuildWorkingCopy(pages: pages)
        if let last = edits.last, pages.contains(last.page), TextLayout.layout(last).grew,
           overlapsOtherText(last) { onOverflow?() }
    }

    private func overlapsOtherText(_ edit: TextEdit) -> Bool {
        let laid = TextLayout.layout(edit).rect
        return blocks(onPage: edit.page).contains { $0.rect != edit.block.rect && $0.rect.intersects(laid) }
    }

    /// Re-applies every text edit to the original in the background and hands the viewer the result.
    private func rebuildWorkingCopy(pages: Set<Int>) {
        rebuild?.cancel()
        generation += 1
        let gen = generation, edits = textEdits, original = original, password = password, dir = workDir
        isRebuilding = true
        rebuild = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    let out = dir.appendingPathComponent("working-\(gen).pdf")
                    let doc = try MuPDFDocument(url: original, password: password)
                    try StampRenderer.apply(edits, to: doc, workDir: dir)
                    try doc.save(to: out)
                    return out
                }
            }.value
            guard let self, !Task.isCancelled, gen == generation else { return }
            isRebuilding = false
            switch result {
            case .success(let url):
                let old = workingCopy
                workingCopy = url
                onWorkingCopyChanged?(url, pages)
                if old.lastPathComponent != "working-0.pdf" { try? FileManager.default.removeItem(at: old) }
            case .failure(let error):
                onError?(error.localizedDescription)
            }
        }
    }

    // MARK: saving

    func saveRequest(fallbackFolder: URL, exactDestination: URL? = nil, flatten: Bool = false,
                     protected: [URL] = []) -> SaveCopy.Request {
        SaveCopy.Request(original: original, password: password, textEdits: textEdits, formValues: formValues,
                         overlays: overlays, flatten: flatten, previousCopy: exactDestination == nil ? savedCopy : nil,
                         exactDestination: exactDestination, protected: protected, fallbackFolder: fallbackFolder,
                         workDir: workDir)
    }

    func didSave(to url: URL) {
        savedCopy = url
        savedChangeCount = changeCount
        savedFormValues = formValues
    }
}
