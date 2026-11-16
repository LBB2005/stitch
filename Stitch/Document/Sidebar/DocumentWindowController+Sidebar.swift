import AppKit
import PDFKit

/// What the sidebar's panels ask of the window. Panels never touch `EditSession` or the PDF view directly;
/// anything that decides something lives in tested engine code (`TodoFinder`, `AutoFill.plan`,
/// `HistoryLog`, `FindReplace`).
extension DocumentWindowController {
    // MARK: rail

    func showPanel(_ panel: SidebarPanel) {
        ui.panel = panel
        if ui.isFolded { split?.setFolded(false) }
        if panel == .find { ui.find.focus += 1 }
    }

    /// The open panel's icon folds the sidebar; any other icon opens its panel.
    func railTapped(_ panel: SidebarPanel) {
        if !ui.isFolded, ui.panel == panel {
            split?.setFolded(true)
        } else {
            showPanel(panel)
        }
    }

    func toggleSidebar() {
        split?.setFolded(!ui.isFolded)
    }

    func goToPage(_ index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func goTo(rect: CGRect, page index: Int, flash: Bool = true) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: rect.insetBy(dx: -40, dy: -80), on: page)
        if flash {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.pdfView.flash(rect, page: index) }
        }
    }

    func selectOverlay(_ id: UUID) {
        guard let ov = session.overlay(id) else { return }
        goTo(rect: ov.rect, page: ov.page, flash: false)
        pdfView.select(id)
    }

    // MARK: thumbnails and to-dos

    func overlaysChangedForSidebar() {
        let old = Dictionary(thumbnailOverlays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(session.overlays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pages = Set<Int>()
        for o in thumbnailOverlays where new[o.id] != o { pages.insert(o.page) }
        for n in session.overlays where old[n.id] != n { pages.insert(n.page) }
        thumbnailOverlays = session.overlays
        thumbnails.invalidate(pages)
        refreshTodo()
    }

    /// Recomputes the To-Do list from the pages' text, their form fields and what's been placed.
    func refreshTodo() {
        guard let doc = pdfView.document else { return }
        var pages: [TodoFinder.Page] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var lines: [TodoFinder.Line] = []
            // Text is read once per page and cached; very long documents only get their fields checked.
            if doc.pageCount <= 200, let info = session.pageInfo(i) {
                for block in session.blocks(onPage: i) {
                    for line in block.lines {
                        lines.append(TodoFinder.Line(text: line.text, rect: line.rect.applying(info.toUserSpace)))
                    }
                }
            }
            let widgets = page.annotations.filter(FormBridge.isWidget).compactMap { a -> TodoFinder.Widget? in
                let kind: TodoFinder.Widget.Kind = switch a.widgetFieldType {
                case .text: .text
                case .signature: .signature
                default: .other
                }
                guard kind != .other else { return nil }
                let name = a.fieldName ?? ""
                return TodoFinder.Widget(name: name, label: Self.fieldLabel(a), rect: a.bounds, kind: kind,
                                         value: a.widgetStringValue ?? "")
            }
            pages.append(TodoFinder.Page(index: i, bounds: page.bounds(for: .cropBox), lines: lines, widgets: widgets))
        }
        let marks = session.overlays.map { ov -> TodoFinder.Mark in
            let kind: TodoFinder.Mark.Kind = switch ov.kind {
            case .signature: .signature
            case .initials: .initials
            case .text: .text
            }
            return TodoFinder.Mark(kind: kind, page: ov.page, rect: ov.rect)
        }
        let todo = TodoFinder.find(pages: pages, marks: marks)
        if ui.todo != todo { ui.todo = todo }
    }

    static func fieldLabel(_ a: PDFAnnotation) -> String {
        if let tip = a.toolTip, !tip.isEmpty { return tip }
        return (a.fieldName ?? "").replacingOccurrences(of: "_", with: " ")
    }

    func goTo(_ item: TodoItem) {
        goTo(rect: item.rect, page: item.page)
    }

    /// Signs, initials or dates a spot in place.
    func fill(_ item: TodoItem) {
        let place: PlaceItem? = switch item.kind {
        case .signature: .signature
        case .initials: .initials
        case .date: .date
        case .field: nil
        }
        guard let place else { return goTo(item) }
        goTo(rect: item.rect, page: item.page, flash: false)
        self.place(place, page: item.page, into: item.rect)
    }

    /// Initials on every open initials spot: one Touch ID, one undo step.
    func initialAll() {
        let spots = ui.todo.filter { $0.kind == .initials && !$0.done }
        guard !spots.isEmpty else { return }
        guard let sig = SignatureStore.shared.initials else { return createSignature(initials: true) }
        Task {
            guard await reveal("use your initials") else { return }
            var placed: [Overlay] = []
            session.batch("Initial All", summary: "Initialled \(spots.count) spots", kind: .initials) {
                for spot in spots {
                    guard let ov = overlay(.initials(sig), natural: Self.signatureSize(sig, initials: true),
                                           page: spot.page, point: nil, spot: spot.rect) else { continue }
                    session.add(ov, actionName: "Initials")
                    placed.append(ov)
                }
            }
            if let last = placed.last { pdfView.select(last.id) }
            showToast("Initialled \(placed.count) spot\(placed.count == 1 ? "" : "s")")
        }
    }

    // MARK: Touch ID for the panels

    /// Asks once; the panels then show their contents while this window is key, or, with the grace
    /// setting on, until the grace period after that Touch ID runs out (wherever the window is).
    func reveal(_ reason: String) async -> Bool {
        if ui.revealed { return true }
        let ok = await BiometricGate.authorize(reason)
        if ok {
            ui.revealed = true
            scheduleRelock()
        }
        return ok
    }

    private func scheduleRelock() {
        ui.relock?.cancel()
        guard let left = BiometricGate.graceRemaining else { return }
        ui.relock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left + 0.5))
            guard !Task.isCancelled, let self, BiometricGate.graceRemaining == nil else { return }
            ui.revealed = false
        }
    }

    func revealSidebar(_ reason: String) {
        Task { _ = await reveal(reason) }
    }

    // MARK: placing items

    /// Click a card, then click the page.
    func arm(_ item: PlaceItem) {
        pdfView.commitEditing()
        if pdfView.tool == .place(item) {
            pdfView.tool = .select
            return
        }
        pdfView.tool = .place(item)
        window?.makeFirstResponder(pdfView)
    }

    static func signatureSize(_ sig: Signature, initials: Bool) -> CGSize {
        var size = sig.size(height: initials ? 28 : 40)
        if size.width > 220 { size = CGSize(width: 220, height: 220 / sig.aspect) }
        return size
    }

    /// The upright size an item would get on the page.
    func naturalSize(of item: PlaceItem) -> CGSize? {
        switch item {
        case .signature:
            return SignatureStore.shared.signature.map { Self.signatureSize($0, initials: false) } ?? CGSize(width: 160, height: 40)
        case .initials:
            return SignatureStore.shared.initials.map { Self.signatureSize($0, initials: true) } ?? CGSize(width: 60, height: 28)
        case .date:
            return TextBox(text: formattedDate).naturalSize
        case .textBox:
            return CGSize(width: 90, height: 18)
        case .profile(let p, let a):
            guard ui.revealed else { return CGSize(width: 120, height: 18) }
            let value = SignatureStore.shared.profile.value(p, address: address(at: a))
            return TextBox(text: value.isEmpty ? p.label : value).naturalSize
        }
    }

    /// Where an item dropped at `point` would go instead of where it was dropped: an open To-Do spot of
    /// its kind, a signature field, or (for details and dates) a text field it would fill.
    func spot(for item: PlaceItem, page: Int, at point: CGPoint) -> CGRect? {
        if let field = textField(at: point, page: page), item.fillsFields { return field.bounds }
        let kind: TodoItem.Kind? = switch item {
        case .signature: .signature
        case .initials: .initials
        case .date: .date
        default: nil
        }
        guard let kind else { return nil }
        return ui.todo.first { $0.kind == kind && $0.page == page && !$0.done
            && $0.rect.insetBy(dx: -TodoFinder.reach, dy: -TodoFinder.reach).contains(point) }?.rect
    }

    private func textField(at point: CGPoint, page: Int) -> PDFAnnotation? {
        pdfView.document?.page(at: page)?.annotations.first {
            FormBridge.isWidget($0) && $0.widgetFieldType == .text && $0.bounds.insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    func address(at index: Int?) -> Profile.Address? {
        let addresses = SignatureStore.shared.profile.addresses.filter { !$0.isEmpty }
        guard let index, addresses.indices.contains(index) else { return nil }
        return addresses[index]
    }

    /// The one way anything gets put on a page: toolbar, menus, shortcuts, To-Do, drops and armed clicks.
    /// With no page, it goes where you last clicked (or mid-page). Dropped on a spot it fits the spot.
    func place(_ item: PlaceItem, page: Int? = nil, at point: CGPoint? = nil, into explicitSpot: CGRect? = nil) {
        pdfView.commitEditing()
        let spot = explicitSpot ?? {
            guard let page, let point else { return nil }
            return self.spot(for: item, page: page, at: point)
        }()
        switch item {
        case .textBox:
            if let page, let point { placeTextBox(page: page, at: point) } else { startTextBox() }
        case .signature, .initials:
            let initials = item == .initials
            if (initials ? SignatureStore.shared.initials : SignatureStore.shared.signature) == nil,
               SignatureStore.shared.problem != nil {
                // It may be saved but unreadable right now (a denied Keychain prompt): ask again before
                // offering to make a new one over it.
                SignatureStore.shared.reload()
                if let problem = SignatureStore.shared.problem { return showToast(problem) }
            }
            guard let sig = initials ? SignatureStore.shared.initials : SignatureStore.shared.signature else {
                return createSignature(initials: initials, thenPlace: page == nil && spot == nil)
            }
            Task {
                guard await reveal(initials ? "use your initials" : "use your signature") else { return }
                guard let ov = overlay(initials ? .initials(sig) : .signature(sig), natural: Self.signatureSize(sig, initials: initials),
                                       page: page, point: point, spot: spot) else { return }
                session.add(ov, actionName: initials ? "Initials" : "Signature")
                pdfView.select(ov.id)
            }
        case .date:
            putText(formattedDate, actionName: "Date", page: page, point: point, spot: spot)
        case .profile(let p, let a):
            Task {
                guard await reveal("use your details") else { return }
                let value = SignatureStore.shared.profile.value(p, address: address(at: a))
                guard !value.isEmpty else { return showToast("\(p.label) is empty in Settings → Your Info") }
                putText(value, actionName: p.label, page: page, point: point, spot: spot)
            }
        }
    }

    /// Text into a form field when dropped on one, else a text box.
    private func putText(_ text: String, actionName: String, page: Int?, point: CGPoint?, spot: CGRect?) {
        if let page, let point, let field = textField(at: point, page: page), let name = field.fieldName {
            setFields([name: text], actionName: actionName, summary: "Filled \(Self.fieldLabel(field)) with \(HistoryLog.quote(text))",
                      page: page)
            return
        }
        let box = TextBox(text: text)
        guard let ov = overlay(.text(box), natural: box.naturalSize, page: page, point: point, spot: spot) else { return }
        session.add(ov, actionName: actionName)
        pdfView.select(ov.id)
    }

    /// An overlay sized and positioned for a spot, a point, or where you last clicked.
    func overlay(_ kind: Overlay.Kind, natural: CGSize, page: Int?, point: CGPoint?, spot: CGRect?) -> Overlay? {
        guard let page, let pdfPage = pdfView.document?.page(at: page) else {
            guard let p = pdfView.placement(upright: natural) else { return nil }
            return Overlay(page: p.page, rect: p.rect, rotation: p.rotation, kind: kind)
        }
        let rotation = pdfPage.rotation
        let box = pdfPage.bounds(for: .cropBox)
        var upright = natural
        let rect: CGRect
        if let spot {
            if case .text = kind {} else {
                // Fit the spot: as big as it allows, within reason.
                let room = PageGeometry.uprightSize(of: spot, rotation: rotation)
                let s = min(max(min(room.height * 0.95 / natural.height, (room.width - 4) / natural.width), 0.4), 1.6)
                upright = CGSize(width: natural.width * s, height: natural.height * s)
            }
            let size = PageGeometry.userSize(ofUpright: upright, rotation: rotation)
            if PageGeometry.normalized(rotation) == 0 {
                // On the line, from its left end.
                rect = CGRect(x: spot.minX + 3, y: spot.minY + 1, width: size.width, height: size.height)
            } else {
                rect = CGRect(x: spot.midX - size.width / 2, y: spot.midY - size.height / 2, width: size.width, height: size.height)
            }
        } else {
            let center = point ?? CGPoint(x: box.midX, y: box.midY)
            let size = PageGeometry.userSize(ofUpright: upright, rotation: rotation)
            var r = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            r.origin.x = min(max(r.minX, box.minX), max(box.maxX - r.width, box.minX))
            r.origin.y = min(max(r.minY, box.minY), max(box.maxY - r.height, box.minY))
            rect = r
        }
        return Overlay(page: page, rect: rect, rotation: rotation, kind: kind)
    }

    // MARK: selection card

    /// The size slider: previews while dragging, one "Resize" undo step when it ends.
    func resize(_ base: Overlay, by scale: Double, commit: Bool) {
        let s = CGFloat(scale)
        var ov = base
        let w = base.rect.width * s, h = base.rect.height * s
        ov.rect = CGRect(x: base.rect.midX - w / 2, y: base.rect.midY - h / 2, width: w, height: h)
        if commit {
            if ov != base { session.update(ov, actionName: "Resize") }
        } else {
            pdfView.previewOverlay(ov)
        }
    }

    // MARK: my info

    /// The text form fields in the viewer, as `AutoFill` sees them.
    func textFields() -> [AutoFill.Field] {
        guard let doc = pdfView.document else { return [] }
        var fields: [AutoFill.Field] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where FormBridge.isWidget(a) && a.widgetFieldType == .text {
                guard let name = a.fieldName, !name.isEmpty else { continue }
                fields.append(AutoFill.Field(name: name, toolTip: a.toolTip, value: a.widgetStringValue ?? "", page: i, rect: a.bounds))
            }
        }
        return fields
    }

    var chosenAddress: Profile.Address? { address(at: ui.addressIndex) }

    func chooseAddress(_ index: Int) {
        ui.addressIndex = index
        refreshFieldMatches()
    }

    func refreshFieldMatches() {
        let matches = AutoFill.plan(fields: textFields(), profile: SignatureStore.shared.profile, address: chosenAddress)
        if ui.fieldMatches != matches { ui.fieldMatches = matches }
    }

    /// Sets form fields by name, as one undo step that puts the old values back.
    func setFields(_ values: [String: String], actionName: String, summary: String, page: Int?) {
        guard !values.isEmpty, let doc = pdfView.document else { return }
        let current = FormBridge.values(in: doc)
        let before = values.mapValues { _ in "" }.merging(current.filter { values[$0.key] != nil }) { _, v in v }
        applyFields(values, highlight: true)
        session.recordFormChange(actionName, summary: summary, page: page, before: before, after: values) { [weak self] v in
            self?.applyFields(v, highlight: false)
        }
    }

    private func applyFields(_ values: [String: String], highlight: Bool) {
        guard let doc = pdfView.document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var touched = false
            for a in page.annotations where FormBridge.isWidget(a) && a.widgetFieldType == .text {
                guard let name = a.fieldName, let value = values[name] else { continue }
                a.widgetStringValue = value
                a.backgroundColor = value.isEmpty ? nil : NSColor.systemYellow.withAlphaComponent(highlight ? 0.25 : 0.15)
                touched = true
            }
            if touched { pdfView.annotationsChanged(on: page); thumbnails.invalidate([i]) }
        }
        filledFields.formUnion(values.keys)
        pdfView.needsDisplay = true
        refreshDirty()
        refreshTodo()
        refreshFieldMatches()
    }

    // MARK: history

    /// Undoes or redoes until `position` changes are applied.
    func goToHistory(_ position: Int) {
        pdfView.commitEditing()
        let undo = session.undoManager
        while session.history.cursor > position, undo.canUndo {
            let before = session.history.cursor
            undo.undo()
            if session.history.cursor == before { break }
        }
        while session.history.cursor < position, undo.canRedo {
            let before = session.history.cursor
            undo.redo()
            if session.history.cursor == before { break }
        }
    }

    func outlineHistory(_ entry: HistoryEntry?) {
        guard let entry, let page = entry.page else { return pdfView.outline(nil, page: 0) }
        if let id = entry.overlayID, let ov = session.overlay(id) {
            pdfView.outline(ov.rect, page: ov.page)
        } else if let rect = entry.textRect, let info = session.pageInfo(page) {
            pdfView.outline(rect.applying(info.toUserSpace), page: page)
        } else {
            pdfView.outline(nil, page: 0)
        }
    }

    func revertToOriginal() {
        guard let window, session.history.canUndo else { return }
        let alert = NSAlert()
        alert.messageText = "Undo every change to “\(session.name)”?"
        alert.informativeText = "You can redo them afterwards (⇧⌘Z). Saved copies stay as they are."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.goToHistory(0)
            }
        }
    }

    // MARK: find

    func startFind() { showPanel(.find) }

    func findChanged() {
        findTask?.cancel()
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.runFind(keep: false)
        }
    }

    func refreshFind() {
        if !ui.find.query.isEmpty { runFind(keep: true) }
    }

    private func runFind(keep: Bool) {
        let query = ui.find.query
        guard let doc = pdfView.document, !query.isEmpty else {
            ui.find.results = []
            ui.find.current = nil
            ui.find.searched = false
            pdfView.highlightedSelections = nil
            return
        }
        let found = doc.findString(query, withOptions: ui.find.caseSensitive ? [] : [.caseInsensitive])
        var results: [FindResult] = []
        for (i, sel) in found.enumerated() {
            guard let page = sel.pages.first else { continue }
            let (before, match, after) = Self.context(sel, query: query, caseSensitive: ui.find.caseSensitive)
            results.append(FindResult(id: i, page: doc.index(for: page), selection: sel, before: before, match: match, after: after))
        }
        let previous = ui.find.current
        ui.find.results = results
        ui.find.searched = true
        for r in results { r.selection.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        pdfView.highlightedSelections = results.map(\.selection)
        if results.isEmpty {
            ui.find.current = nil
        } else if keep, let previous {
            ui.find.current = min(previous, results.count - 1)
            if let i = ui.find.current { pdfView.setCurrentSelection(results[i].selection, animate: false) }
        } else {
            selectResult(0)
        }
    }

    private static func context(_ sel: PDFSelection, query: String, caseSensitive: Bool) -> (String, String, String) {
        let match = sel.string ?? query
        guard let wide = sel.copy() as? PDFSelection else { return ("", match, "") }
        wide.extend(atStart: 24)
        wide.extend(atEnd: 30)
        let text = (wide.string ?? match).replacingOccurrences(of: "\n", with: " ")
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        // The occurrence closest to where the original selection starts (24 characters in).
        var best: Range<String.Index>?
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: match, options: options, range: search) {
            let offset = text.distance(from: text.startIndex, to: r.lowerBound)
            if best == nil || abs(offset - 24) < abs(text.distance(from: text.startIndex, to: best!.lowerBound) - 24) { best = r }
            search = r.upperBound..<text.endIndex
        }
        guard let best else { return ("", match, "") }
        let before = String(text[..<best.lowerBound]), after = String(text[best.upperBound...])
        return ((before.count < 24 ? "" : "…") + before.trimmingCharacters(in: .newlines), String(text[best]),
                after + (after.count < 30 ? "" : "…"))
    }

    func selectResult(_ i: Int) {
        guard ui.find.results.indices.contains(i) else { return }
        ui.find.current = i
        let sel = ui.find.results[i].selection
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    func findNext() {
        if ui.panel != .find || ui.isFolded { showPanel(.find) }
        let n = ui.find.results.count
        guard n > 0 else { return }
        selectResult(((ui.find.current ?? -1) + 1) % n)
    }

    func findPrevious() {
        let n = ui.find.results.count
        guard n > 0 else { return }
        selectResult(((ui.find.current ?? 0) - 1 + n) % n)
    }

    func clearFind() {
        ui.find.query = ""
        ui.find.results = []
        ui.find.current = nil
        ui.find.searched = false
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    /// The text block (and its edit, if it has one) a match is in.
    private func target(of result: FindResult) -> (edit: TextEdit?, block: TextBlock)? {
        guard let page = pdfView.document?.page(at: result.page), let info = session.pageInfo(result.page) else { return nil }
        let b = result.selection.bounds(for: page)
        return session.editTarget(at: CGPoint(x: b.midX, y: b.midY).applying(info.toDisplay), page: result.page)
    }

    func replaceCurrent() {
        let f = ui.find
        guard let i = f.current, f.results.indices.contains(i) else { return }
        pdfView.commitEditing()
        let result = f.results[i]
        guard let t = target(of: result) else {
            return showToast(session.blocks(onPage: result.page).isEmpty
                ? "This page is a scan, so its text can't be replaced. Cover it with a white text box instead."
                : "Couldn't find that text in the PDF to replace it")
        }
        let siblings = f.results.filter { $0.page == result.page && target(of: $0)?.block.rect == t.block.rect }
        let k = siblings.firstIndex { $0.id == result.id } ?? 0
        let text = t.edit?.text ?? t.block.text
        guard let new = FindReplace.replace(f.query, with: f.replacement, in: text, occurrence: k, caseSensitive: f.caseSensitive)
                ?? FindReplace.replace(f.query, with: f.replacement, in: text, occurrence: 0, caseSensitive: f.caseSensitive) else {
            return showToast("Couldn't find that text in the PDF to replace it")
        }
        session.commitText(new, for: t.block, editing: t.edit)
    }

    func replaceAll() {
        let f = ui.find
        guard !f.results.isEmpty else { return }
        pdfView.commitEditing()
        var seen = Set<String>()
        var changes: [(text: String, block: TextBlock, existing: TextEdit?)] = []
        var count = 0, skipped = 0
        for r in f.results {
            guard let t = target(of: r) else { skipped += 1; continue }
            let key = "\(t.block.page)-\(t.block.rect.debugDescription)"
            guard seen.insert(key).inserted else { continue }
            let (text, n) = FindReplace.replaceAll(f.query, with: f.replacement, in: t.edit?.text ?? t.block.text,
                                                   caseSensitive: f.caseSensitive)
            guard n > 0 else { continue }
            count += n
            changes.append((text, t.block, t.edit))
        }
        guard !changes.isEmpty else { return showToast("Couldn't find that text in the PDF to replace it") }
        session.commitTexts(changes, actionName: "Replace All",
                            summary: "Replaced \(count) × \(HistoryLog.quote(f.query, max: 16)) with \(HistoryLog.quote(f.replacement, max: 16))")
        showToast("Replaced \(count) match\(count == 1 ? "" : "es")" + (skipped > 0 ? "; \(skipped) on scanned pages left as they are" : ""))
    }
}

private extension PlaceItem {
    /// Text that can go into a form field instead of a text box.
    var fillsFields: Bool {
        switch self {
        case .date, .profile: true
        default: false
        }
    }
}
