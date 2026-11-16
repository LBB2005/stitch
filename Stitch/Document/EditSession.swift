import AppKit
import Observation
import PDFKit

/// One open PDF and everything changed in it: the single source of truth for its document window.
///
/// - `original` is read, never written. Its name only changes when the person renames it from the
///   title (`moved(to:)`); its contents never do.
/// - The viewer shows a working copy in the document's temp folder: the original plus `textEdits`, applied
///   by MuPDF, so what you see is what gets saved. Overlays are drawn on top of it by the viewer.
/// - Save Copy applies everything to the original afresh and writes a new file (`SaveCopy`).
@MainActor
@Observable
final class EditSession {
    private(set) var original: URL
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
    /// The file that save wrote, so a later save never replaces something else put at `savedCopy`.
    private var savedCopyID: SaveCopy.FileID?
    private(set) var isRebuilding = false
    /// Every change, for the History panel; its cursor follows undo and redo.
    private(set) var history = HistoryLog()

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var savedChangeCount = 0
    @ObservationIgnored private var savedFormValues: [String: String] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rebuild: Task<Void, Never>?
    @ObservationIgnored private var layoutDoc: MuPDFDocument?
    @ObservationIgnored private var blocksCache: [Int: [TextBlock]] = [:]
    @ObservationIgnored private var pageInfoCache: [Int: MuPDFDocument.PageInfo] = [:]
    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []
    /// While set, changes are one History entry (`batch`).
    @ObservationIgnored private var batching: (action: String, summary: String, kind: HistoryEntry.Kind, page: Int?)?
    @ObservationIgnored private var batchChanged = false
    /// Counts `UndoManager`'s top-level groups, so History knows which changes undo together.
    @ObservationIgnored private var undoGroup = 0

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

    /// The original was renamed (by the person, from the title). Later rebuilds and saves read it there.
    func moved(to url: URL) {
        original = url
    }

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
        // History's cursor follows UndoManager itself, so ⌘Z, the toolbar and the menu all keep it right.
        let center = NotificationCenter.default
        undoObservers = [
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.history.undo() }
            },
            center.addObserver(forName: .NSUndoManagerDidRedoChange, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.history.redo() }
            },
            center.addObserver(forName: .NSUndoManagerDidOpenUndoGroup, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.undoManager.groupingLevel == 1 else { return }
                    self.undoGroup += 1
                }
            },
        ]
    }

    func close() {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
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

    /// Every change goes through here: counts it for "unsaved" and adds its History entry (not while
    /// undoing or redoing, which move History's cursor instead).
    private func changed(_ action: String, _ summary: @autoclosure () -> String, kind: HistoryEntry.Kind, page: Int?,
                         overlayID: UUID? = nil, textRect: CGRect? = nil) {
        changeCount += 1
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return }
        if batching != nil { batchChanged = true; return }
        history.record(action, summary: summary(), kind: kind, page: page, overlayID: overlayID, textRect: textRect,
                       group: currentGroup)
    }

    /// The undo group the change being made belongs to. Changes are recorded just before their undo is
    /// registered, and registering opens a new group when none is open.
    private var currentGroup: Int {
        undoManager.groupingLevel == 0 ? undoGroup + 1 : undoGroup
    }

    /// Runs `body` as one undo step and one History entry ("Initial all", "Replace All").
    func batch(_ action: String, summary: String, kind: HistoryEntry.Kind, page: Int? = nil, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        let group = undoGroup
        batching = (action, summary, kind, page)
        batchChanged = false
        body()
        batching = nil
        undoManager.setActionName(action)
        undoManager.endUndoGrouping()
        if batchChanged { history.record(action, summary: summary, kind: kind, page: page, group: group) }
    }

    private static func describe(_ overlay: Overlay) -> String {
        switch overlay.kind {
        case .signature: "signature"
        case .initials: "initials"
        case .text(let box): HistoryLog.quote(box.text)
        }
    }

    private static func kind(of overlay: Overlay) -> HistoryEntry.Kind {
        switch overlay.kind {
        case .signature: .signature
        case .initials: .initials
        case .text: .text
        }
    }

    // MARK: overlays

    func overlay(_ id: UUID) -> Overlay? { overlays.first { $0.id == id } }

    func add(_ overlay: Overlay, actionName: String) {
        overlays.append(overlay)
        let summary: String = switch overlay.kind {
        case .signature: "Signed"
        case .initials: "Initialled"
        case .text(let box): actionName == "Date" ? "Added the date \(HistoryLog.quote(box.text))" : "Added \(HistoryLog.quote(box.text))"
        }
        changed(actionName, summary, kind: Self.kind(of: overlay), page: overlay.page, overlayID: overlay.id)
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
        changed(actionName, actionName == "Delete" ? "Deleted \(Self.describe(removed))" : "Removed \(Self.describe(removed))",
                kind: .delete, page: removed.page)
        undoManager.registerUndo(withTarget: self) { session in
            session.overlays.insert(removed, at: min(index, session.overlays.count))
            session.changed(actionName, "Restored \(Self.describe(removed))", kind: Self.kind(of: removed), page: removed.page,
                            overlayID: removed.id)
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
        let what = Self.describe(overlay)
        let summary: String = switch actionName {
        case "Move": "Moved \(what)"
        case "Resize": "Resized \(what)"
        case "Format Text": "Formatted \(what)"
        case "Typing": HistoryLog.changeSummary(from: before.textBox?.text ?? "", to: overlay.textBox?.text ?? "")
        default: "\(actionName): \(what)"
        }
        let kind: HistoryEntry.Kind = switch actionName {
        case "Move", "Resize": .move
        case "Format Text": .format
        default: Self.kind(of: overlay)
        }
        changed(actionName, summary, kind: kind, page: overlay.page, overlayID: overlay.id)
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
        setTextEdits(edits, pages: [block.page], actionName: "Edit Text",
                     summary: HistoryLog.changeSummary(from: existing?.text ?? block.text, to: trimmed), rect: block.rect)
    }

    /// Several edits at once (Replace All): one undo step and one rebuild.
    func commitTexts(_ changes: [(text: String, block: TextBlock, existing: TextEdit?)], actionName: String, summary: String) {
        var edits = textEdits
        var pages = Set<Int>()
        for change in changes {
            let trimmed = change.text.replacingOccurrences(of: "\r", with: "")
            if let existing = change.existing, let i = edits.firstIndex(where: { $0.id == existing.id }) {
                if trimmed == existing.text { continue }
                if trimmed == change.block.text { edits.remove(at: i) } else { edits[i].text = trimmed }
            } else {
                if trimmed == change.block.text { continue }
                edits.append(TextEdit(block: change.block, text: trimmed))
            }
            pages.insert(change.block.page)
        }
        guard !pages.isEmpty else { return }
        setTextEdits(edits, pages: pages, actionName: actionName, summary: summary, rect: nil)
    }

    private func setTextEdits(_ edits: [TextEdit], pages: Set<Int>, actionName: String, summary: String, rect: CGRect?) {
        let before = textEdits
        textEdits = edits
        changed(actionName, summary, kind: .textEdit, page: pages.count == 1 ? pages.first : nil, textRect: rect)
        undoManager.registerUndo(withTarget: self) {
            $0.setTextEdits(before, pages: pages, actionName: actionName, summary: summary, rect: rect)
        }
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
                         previousCopyID: exactDestination == nil ? savedCopyID : nil,
                         exactDestination: exactDestination, protected: protected, fallbackFolder: fallbackFolder,
                         workDir: workDir)
    }

    func didSave(to url: URL, fileID: SaveCopy.FileID? = nil) {
        savedCopy = url
        savedCopyID = fileID
        savedChangeCount = changeCount
        savedFormValues = formValues
        history.saved(url.lastPathComponent)
    }

    // MARK: changes the viewer makes (form fields)

    /// Records a change the viewer applied itself (Fill My Info, a detail dropped on a field) as one
    /// undoable step: `apply(before)` undoes it, `apply(after)` redoes it.
    func recordFormChange(_ actionName: String, summary: String, page: Int?, before: [String: String],
                          after: [String: String], apply: @escaping @MainActor ([String: String]) -> Void) {
        changed(actionName, summary, kind: .fill, page: page)
        undoManager.registerUndo(withTarget: self) { session in
            apply(before)
            session.recordFormChange(actionName, summary: summary, page: page, before: after, after: before, apply: apply)
        }
        undoManager.setActionName(actionName)
    }
}
