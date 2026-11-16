import AppKit
import PDFKit
import SwiftUI

/// SwiftUI wrapper for the document window's PDF view (owned by `DocumentWindowController`).
struct PDFCanvas: NSViewRepresentable {
    let view: StitchPDFView
    func makeNSView(context: Context) -> StitchPDFView { view }
    func updateNSView(_ nsView: StitchPDFView, context: Context) {}
}

/// PDFKit's view plus Stitch's tools: overlays you can select, drag, resize and delete; text boxes;
/// and click-to-edit for text already in the PDF. PDFKit still does scrolling, zooming, text selection
/// and form fields.
final class StitchPDFView: PDFView {
    enum Tool: Equatable {
        case select, editText, textBox
        /// Armed from the Sign or My Info panel: the next click on a page places it.
        case place(PlaceItem)
    }

    private enum Drag {
        case move(Overlay, start: NSPoint)
        case resize(Overlay, anchor: NSPoint, viewSize: NSSize)
    }

    weak var session: EditSession?
    var tool: Tool = .select {
        didSet {
            if tool != .editText { hoverChrome.isHidden = true }
            onToolChanged?(tool)
            window?.invalidateCursorRects(for: self)
        }
    }

    private(set) var selectedID: UUID? {
        didSet { if oldValue != selectedID { onSelectionChanged?(selectedID); layoutChrome() } }
    }

    var onSelectionChanged: ((UUID?) -> Void)?
    var onToolChanged: ((Tool) -> Void)?
    var onMessage: ((String) -> Void)?
    /// Asks the window to place a new text box at a page point.
    var onPlaceTextBox: ((Int, CGPoint) -> Void)?
    /// Asks the window to place an item (dropped, or the armed `place` tool clicked) at a page point.
    var onPlaceItem: ((PlaceItem, Int, CGPoint) -> Void)?
    /// For the drop preview: the upright size an item would get, and the spot it would fit into there.
    var placeSize: ((PlaceItem) -> CGSize?)?
    var placeTarget: ((PlaceItem, Int, CGPoint) -> CGRect?)?

    /// Where the person last clicked on a page, for placing signatures "where you last clicked".
    private(set) var lastClick: (page: Int, point: CGPoint, time: Date)?

    private var annotationsByID: [UUID: OverlayAnnotation] = [:]
    private var drag: Drag?
    private let selectionChrome = SelectionChrome()
    private let hoverChrome = SelectionChrome()
    private weak var editor: InlineTextEditor?
    private var editingOverlay: UUID?
    private let dropChrome = SelectionChrome()
    private let outlineChrome = SelectionChrome()
    private var outlined: (rect: CGRect, page: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        pageShadowsEnabled = true
        backgroundColor = .underPageBackgroundColor
        displayBox = .cropBox
        hoverChrome.style = .hover
        hoverChrome.isHidden = true
        dropChrome.style = .hover
        dropChrome.isHidden = true
        outlineChrome.style = .hover
        outlineChrome.isHidden = true
        registerForDraggedTypes([PlaceItem.pasteboardType])
        selectionChrome.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: .PDFViewScaleChanged, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: .PDFViewDisplayModeChanged, object: self)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    // MARK: document

    /// Shows a document, keeping the place you were looking at when it's a newer working copy.
    func show(_ doc: PDFDocument, keepPosition: Bool) {
        let destination = keepPosition ? currentDestination : nil
        let scale = scaleFactor
        let auto = autoScales
        annotationsByID = [:]
        document = doc
        if keepPosition {
            if !auto { scaleFactor = scale }
            if let destination, let page = destination.page, let index = destination.page?.document?.index(for: page),
               let same = doc.page(at: index) {
                go(to: PDFDestination(page: same, at: destination.point))
            }
        }
        syncOverlays()
    }

    /// Swaps in rebuilt pages from a new working copy, so the rest of the document doesn't move.
    func replacePages(_ indexes: Set<Int>, from newDoc: PDFDocument, form: [String: String]) {
        guard let doc = document, doc.pageCount == newDoc.pageCount else { return show(newDoc, keepPosition: true) }
        let destination = currentDestination
        let destIndex = destination?.page.map { doc.index(for: $0) }
        let sorted = indexes.sorted().filter { $0 < newDoc.pageCount }
        let fresh = sorted.compactMap { newDoc.page(at: $0) }
        for index in sorted.reversed() { newDoc.removePage(at: index) }
        for (index, page) in zip(sorted, fresh) {
            for (id, a) in annotationsByID where a.page == doc.page(at: index) { annotationsByID[id] = nil }
            doc.removePage(at: index)
            doc.insert(page, at: index)
            FormBridge.apply(form, to: page)
        }
        layoutDocumentView()
        if let destination, let destIndex, let page = doc.page(at: destIndex) {
            go(to: PDFDestination(page: page, at: destination.point))
        }
        syncOverlays()
    }

    // MARK: overlays

    func syncOverlays() {
        guard let doc = document, let session else { return }
        var live = Set<UUID>()
        var touched = Set<PDFPage>()
        for overlay in session.overlays {
            live.insert(overlay.id)
            guard let page = doc.page(at: overlay.page) else { continue }
            if let a = annotationsByID[overlay.id] {
                if a.page !== page {
                    if let old = a.page { old.removeAnnotation(a); touched.insert(old) }
                    page.addAnnotation(a)
                }
                if a.overlay != overlay { a.update(overlay) }
            } else {
                let a = OverlayAnnotation(overlay)
                page.addAnnotation(a)
                annotationsByID[overlay.id] = a
            }
            touched.insert(page)
        }
        for (id, a) in annotationsByID where !live.contains(id) {
            if let page = a.page { page.removeAnnotation(a); touched.insert(page) }
            annotationsByID[id] = nil
        }
        touched.forEach { annotationsChanged(on: $0) }
        if let selectedID, !live.contains(selectedID) { self.selectedID = nil }
        layoutChrome()
    }

    func select(_ id: UUID?) {
        selectedID = id
        if id != nil { window?.makeFirstResponder(self) }
    }

    private func overlay(at point: CGPoint, page: Int) -> Overlay? {
        session?.overlays.last { $0.page == page && $0.rect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    // MARK: geometry

    func viewRect(_ rect: CGRect, page: Int) -> NSRect? {
        guard let p = document?.page(at: page) else { return nil }
        return convert(rect, from: p)
    }

    private func docViewRect(_ viewRect: NSRect) -> NSRect? {
        guard let dv = documentView else { return nil }
        return dv.convert(viewRect, from: self)
    }

    /// A user-space rect on `page` for something `upright` big whose top-left (as shown) is at `topLeft`
    /// (view coordinates).
    private func pageRect(topLeft: NSPoint, upright: CGSize, page: Int) -> CGRect? {
        guard let p = document?.page(at: page) else { return nil }
        let size = NSSize(width: upright.width * scaleFactor, height: upright.height * scaleFactor)
        return convert(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), to: p)
    }

    /// Where a new overlay goes: centred on the last click (if recent and on a page), else the middle of
    /// the visible part of the current page. Kept inside the page.
    func placement(upright: CGSize) -> (page: Int, rect: CGRect, rotation: Int)? {
        guard let doc = document else { return nil }
        var pageIndex: Int
        var center: CGPoint
        if let last = lastClick, Date().timeIntervalSince(last.time) < 600, last.page < doc.pageCount {
            pageIndex = last.page
            center = last.point
        } else {
            let mid = NSPoint(x: bounds.midX, y: bounds.midY)
            guard let page = self.page(for: mid, nearest: true) else { return nil }
            pageIndex = doc.index(for: page)
            center = convert(mid, to: page)
        }
        guard let page = doc.page(at: pageIndex) else { return nil }
        let rotation = page.rotation
        let size = PageGeometry.userSize(ofUpright: upright, rotation: rotation)
        let box = page.bounds(for: .cropBox)
        var rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, box.minX), max(box.maxX - rect.width, box.minX))
        rect.origin.y = min(max(rect.minY, box.minY), max(box.maxY - rect.height, box.minY))
        return (pageIndex, rect, rotation)
    }

    @objc private func geometryChanged() {
        editor?.commit()
        layoutChrome()
    }

    func layoutChrome() {
        guard let dv = documentView else { return }
        for chrome in [selectionChrome, hoverChrome, dropChrome, outlineChrome] where chrome.superview !== dv {
            chrome.removeFromSuperview()
            dv.addSubview(chrome)
        }
        if let id = selectedID, editingOverlay != id, let ov = session?.overlay(id) ?? annotationsByID[id]?.overlay,
           let r = viewRect(liveRect(id) ?? ov.rect, page: ov.page), let d = docViewRect(r) {
            selectionChrome.frame = d.insetBy(dx: -SelectionChrome.handle / 2, dy: -SelectionChrome.handle / 2)
            selectionChrome.isHidden = false
            selectionChrome.needsDisplay = true
        } else {
            selectionChrome.isHidden = true
        }
        if let outlined, let r = viewRect(outlined.rect, page: outlined.page), let d = docViewRect(r) {
            outlineChrome.frame = d.insetBy(dx: -6, dy: -6)
            outlineChrome.isHidden = false
        } else {
            outlineChrome.isHidden = true
        }
    }

    /// Outlines a spot (a field, an edited line) while the person hovers its row in a panel.
    func outline(_ rect: CGRect?, page: Int) {
        outlined = rect.map { ($0, page) }
        layoutChrome()
    }

    /// Rings a spot for a moment: a temporary view over the page, never an annotation, so it can't end
    /// up in a saved file.
    func flash(_ rect: CGRect, page: Int) {
        guard let r = viewRect(rect, page: page), let d = docViewRect(r), let dv = documentView else { return }
        let ring = RingView(frame: d.insetBy(dx: -8, dy: -8))
        dv.addSubview(ring)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ring.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; ring.animator().alphaValue = 0 },
                                                     completionHandler: { ring.removeFromSuperview() })
            }
        })
    }

    /// Shows an overlay as it would be, without changing the session (a slider being dragged).
    func previewOverlay(_ overlay: Overlay) { preview(overlay) }

    var currentPageIndex: Int {
        guard let doc = document, let page = currentPage else { return 0 }
        return doc.index(for: page)
    }

    // MARK: dropping items from the sidebar

    private func dropPoint(_ sender: NSDraggingInfo) -> (page: Int, point: CGPoint)? {
        let p = convert(sender.draggingLocation, from: nil)
        guard let doc = document, let page = page(for: p, nearest: true) else { return nil }
        return (doc.index(for: page), convert(p, to: page))
    }

    private func updateDrop(_ sender: NSDraggingInfo, _ item: PlaceItem) {
        guard let (page, point) = dropPoint(sender) else { return dropChrome.isHidden = true }
        layoutChrome()
        let rect: CGRect
        if let target = placeTarget?(item, page, point) {
            rect = target
        } else {
            let upright = placeSize?(item) ?? CGSize(width: 120, height: 30)
            let rotation = document?.page(at: page)?.rotation ?? 0
            let size = PageGeometry.userSize(ofUpright: upright, rotation: rotation)
            rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        }
        guard let r = viewRect(rect, page: page), let d = docViewRect(r) else { return }
        dropChrome.frame = d.insetBy(dx: -4, dy: -4)
        dropChrome.isHidden = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let item = PlaceItem.from(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        updateDrop(sender, item)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let item = PlaceItem.from(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        updateDrop(sender, item)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, PlaceItem.from(sender.draggingPasteboard) == nil { return super.draggingExited(sender) }
        dropChrome.isHidden = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PlaceItem.from(sender.draggingPasteboard) != nil || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let item = PlaceItem.from(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        dropChrome.isHidden = true
        PlaceItem.dragging = nil
        guard let (page, point) = dropPoint(sender) else { return false }
        lastClick = (page, point, Date())
        onPlaceItem?(item, page, point)
        return true
    }

    private func liveRect(_ id: UUID) -> CGRect? { annotationsByID[id]?.overlay.rect }

    private func handle(at point: NSPoint, for overlay: Overlay) -> NSPoint? {
        guard let r = viewRect(overlay.rect, page: overlay.page) else { return nil }
        let corners = SelectionChrome.corners(of: r)
        for (i, c) in corners.enumerated() where hypot(c.x - point.x, c.y - point.y) <= SelectionChrome.handle {
            return corners[3 - i]   // the opposite corner stays put
        }
        return nil
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        if let editor { editor.commit() }
        let p = convert(event.locationInWindow, from: nil)
        guard let session, let doc = document, let page = page(for: p, nearest: false) else {
            select(nil)
            return super.mouseDown(with: event)
        }
        let index = doc.index(for: page)
        let pt = convert(p, to: page)
        lastClick = (index, pt, Date())
        if case .place(let item) = tool {
            select(nil)
            tool = .select
            onPlaceItem?(item, index, pt)
            return
        }

        if let id = selectedID, let ov = session.overlay(id), let anchor = handle(at: p, for: ov),
           let r = viewRect(ov.rect, page: ov.page) {
            drag = .resize(ov, anchor: anchor, viewSize: r.size)
            return
        }
        if let ov = overlay(at: pt, page: index) {
            select(ov.id)
            if event.clickCount >= 2, ov.textBox != nil { return beginEditing(ov) }
            drag = .move(ov, start: p)
            return
        }
        // Form fields keep working with every tool.
        if let hit = page.annotation(at: pt), hit.type == "Widget" || hit.type == PDFAnnotationSubtype.widget.rawValue {
            select(nil)
            return super.mouseDown(with: event)
        }
        switch tool {
        case .textBox:
            select(nil)
            tool = .select
            onPlaceTextBox?(index, pt)
        case .editText:
            select(nil)
            if let info = session.pageInfo(index), let target = session.editTarget(at: pt.applying(info.toDisplay), page: index) {
                beginEditing(target.block, edit: target.edit, page: index, info: info)
            } else if session.blocks(onPage: index).isEmpty {
                onMessage?("This page is a scan, so it has no text to edit. Use a text box with a white background to cover and retype.")
            }
        case .select, .place:
            select(nil)
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let doc = document else { return super.mouseDragged(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move(let ov, let start):
            guard let page = doc.page(at: ov.page) else { return }
            let a = convert(start, to: page), b = convert(p, to: page)
            var rect = ov.rect.offsetBy(dx: b.x - a.x, dy: b.y - a.y)
            let box = page.bounds(for: .cropBox)
            rect.origin.x = min(max(rect.minX, box.minX - rect.width / 2), box.maxX - rect.width / 2)
            rect.origin.y = min(max(rect.minY, box.minY - rect.height / 2), box.maxY - rect.height / 2)
            var moved = ov
            moved.rect = rect
            preview(moved)
        case .resize(let ov, let anchor, let size):
            guard let page = doc.page(at: ov.page) else { return }
            let scale = max(abs(p.x - anchor.x) / max(size.width, 1), abs(p.y - anchor.y) / max(size.height, 1))
            let w = max(size.width * scale, 12), h = max(size.height * scale, 12 * size.height / max(size.width, 1))
            let r = NSRect(x: p.x < anchor.x ? anchor.x - w : anchor.x, y: p.y < anchor.y ? anchor.y - h : anchor.y, width: w, height: h)
            preview(ov.resized(to: convert(r, to: page)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return super.mouseUp(with: event) }
        self.drag = nil
        let (original, name): (Overlay, String) = switch drag {
        case .move(let ov, _): (ov, "Move")
        case .resize(let ov, _, _): (ov, "Resize")
        }
        if let live = annotationsByID[original.id]?.overlay, live != original {
            session?.update(live, actionName: name)
        }
    }

    private func preview(_ overlay: Overlay) {
        guard let a = annotationsByID[overlay.id] else { return }
        a.update(overlay)
        if let page = a.page { annotationsChanged(on: page) }
        layoutChrome()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard tool == .editText, editor == nil, let session, let doc = document else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: false) else { return hoverChrome.isHidden = true }
        let index = doc.index(for: page)
        let pt = convert(p, to: page)
        if overlay(at: pt, page: index) == nil, let info = session.pageInfo(index),
           let target = session.editTarget(at: pt.applying(info.toDisplay), page: index) {
            let display = target.edit.map { TextLayout.layout($0).rect } ?? target.block.rect
            let user = display.applying(info.toUserSpace)
            if let r = viewRect(user, page: index), let d = docViewRect(r) {
                hoverChrome.frame = d.insetBy(dx: -6, dy: -4)
                hoverChrome.isHidden = false
                if hoverChrome.superview !== documentView { layoutChrome() }
            }
            NSCursor.iBeam.set()
        } else {
            hoverChrome.isHidden = true
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if tool == .textBox { addCursorRect(bounds, cursor: .iBeam) }
        if case .place = tool { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard let id = selectedID, let session, let ov = session.overlay(id) else {
            if event.keyCode == 53, tool != .select { tool = .select; return }
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            session.remove(id)
        case 53: // Escape
            select(nil)
        case 36, 76: // Return: edit a text box
            if ov.textBox != nil { beginEditing(ov) }
        case 123, 124, 125, 126: // arrows nudge by 1 pt (10 with Shift), as the page is shown
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            guard let r = viewRect(ov.rect, page: ov.page), let page = document?.page(at: ov.page) else { return }
            let s = step * scaleFactor
            let d: (CGFloat, CGFloat) = switch event.keyCode {
            case 123: (-s, 0)
            case 124: (s, 0)
            case 125: (0, -s)
            default: (0, s)
            }
            var moved = ov
            moved.rect = convert(r.offsetBy(dx: d.0, dy: d.1), to: page)
            session.update(moved, actionName: "Move")
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: inline editing

    /// Types into a text box overlay. A new box (`isNew`) only becomes an undo step once it has text.
    func beginEditing(_ ov: Overlay, isNew: Bool = false) {
        guard let box = ov.textBox, let r = viewRect(ov.rect, page: ov.page), let frame = docViewRect(r),
              let a = annotationsByID[ov.id], let pdfPage = document?.page(at: ov.page) else { return }
        editor?.commit()
        editingOverlay = ov.id
        layoutChrome()
        a.hidesText = true
        if let page = a.page { annotationsChanged(on: page) }
        let font = NSFont(name: box.fontName, size: box.fontSize * scaleFactor) ?? .systemFont(ofSize: box.fontSize * scaleFactor)
        let inset = TextBox.padding * scaleFactor
        let editorFrame = frame.insetBy(dx: inset, dy: inset)
        // In page space: the view may scroll while typing.
        let topLeft = convert(NSPoint(x: r.minX, y: r.maxY), to: pdfPage)
        let ed = InlineTextEditor.make(frame: editorFrame, text: box.text, font: font, color: NSColor(cgColor: box.ink.cgColor) ?? .black,
                                       opaque: false, fixedWidth: nil)
        let id = ov.id
        let finish: (String?) -> Void = { [weak self] text in
            guard let self, let session = self.session, var current = session.overlay(id) else { return }
            self.editingOverlay = nil
            a.hidesText = false
            defer {
                if let page = a.page { self.annotationsChanged(on: page) }
                self.layoutChrome()
                self.window?.makeFirstResponder(self)
            }
            let blank = current.textBox?.whiteBackground == false
            if isNew, (text ?? "").isEmpty, blank { return session.discardDraft(id) }
            guard let text else { return isNew ? session.commitDraft(current) : () }
            if text.isEmpty, blank { return session.remove(id, actionName: "Delete") }
            guard var b = current.textBox else { return }
            b.text = text
            current.kind = .text(b)
            if let page = self.document?.page(at: current.page),
               let rect = self.pageRect(topLeft: self.convert(topLeft, from: page), upright: b.naturalSize, page: current.page) {
                current.rect = rect
            }
            if isNew { session.commitDraft(current) } else if b.text != box.text { session.update(current, actionName: "Typing") }
        }
        ed.onCommit = { finish($0) }
        ed.onCancel = { finish(nil) }
        documentView?.addSubview(ed)
        ed.fitToText()
        editor = ed
        window?.makeFirstResponder(ed)
        ed.selectAll(nil)
    }

    /// Opens the editor over text already in the PDF.
    private func beginEditing(_ block: TextBlock, edit: TextEdit?, page: Int, info: MuPDFDocument.PageInfo) {
        guard let session else { return }
        let laid = edit.map { TextLayout.layout($0) }
        let display = laid?.rect ?? block.rect
        guard let r = viewRect(display.applying(info.toUserSpace), page: page), let frame = docViewRect(r) else { return }
        hoverChrome.isHidden = true
        let size = (laid?.fontSize ?? block.fontSize) * scaleFactor
        let font = NSFont(name: block.fontName, size: size) ?? .systemFont(ofSize: size)
        let pad: CGFloat = 2
        let ed = InlineTextEditor.make(frame: frame.insetBy(dx: -pad, dy: -pad), text: edit?.text ?? block.text, font: font,
                                       color: NSColor(cgColor: block.color) ?? .black, opaque: true,
                                       fixedWidth: max(frame.width, font.pointSize * 3) + pad * 2)
        ed.textContainerInset = NSSize(width: pad, height: pad)
        let paragraph = NSMutableParagraphStyle()
        let pitch = (laid?.lineHeight ?? block.lineHeight) * scaleFactor
        paragraph.minimumLineHeight = pitch
        paragraph.maximumLineHeight = pitch
        ed.defaultParagraphStyle = paragraph
        ed.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: ed.string.utf16.count))
        ed.typingAttributes[.paragraphStyle] = paragraph
        ed.wantsLayer = true
        ed.layer?.borderColor = NSColor.controlAccentColor.cgColor
        ed.layer?.borderWidth = 1.5
        ed.layer?.cornerRadius = 2
        ed.fitToText()
        ed.onCommit = { [weak self, weak session] text in
            session?.commitText(text, for: block, editing: edit)
            self?.window?.makeFirstResponder(self)
        }
        ed.onCancel = { [weak self] in self?.window?.makeFirstResponder(self) }
        documentView?.addSubview(ed)
        ed.fitToText()
        editor = ed
        window?.makeFirstResponder(ed)
    }

    var isEditingText: Bool { editor != nil }

    func commitEditing() { editor?.commit() }
}

/// The ring `flash` draws around a spot.
private final class RingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        path.lineWidth = 2.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

/// Reads and writes form values on PDFKit's widgets (field name → value; checkboxes "Off" or their
/// on-state, radio groups the selected button's on-state).
enum FormBridge {
    static func isWidget(_ a: PDFAnnotation) -> Bool {
        a.type == "Widget" || a.type == PDFAnnotationSubtype.widget.rawValue || a.fieldName != nil && !(a is OverlayAnnotation)
    }

    static func values(in doc: PDFDocument) -> [String: String] {
        var values: [String: String] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where isWidget(a) {
                guard let name = a.fieldName, !name.isEmpty else { continue }
                switch a.widgetFieldType {
                case .text, .choice:
                    // Several widgets can share one field; a filled-in one wins over an empty copy.
                    let v = a.widgetStringValue ?? ""
                    if !v.isEmpty || values[name] == nil { values[name] = v }
                case .button:
                    let on = a.buttonWidgetState == .onState
                    let state = a.buttonWidgetStateString.isEmpty ? "Yes" : a.buttonWidgetStateString
                    switch a.widgetControlType {
                    case .checkBoxControl: values[name] = on ? state : "Off"
                    case .radioButtonControl: if on { values[name] = state } else if values[name] == nil { values[name] = "Off" }
                    default: break
                    }
                default:
                    break
                }
            }
        }
        return values
    }

    static func apply(_ values: [String: String], to page: PDFPage) {
        for a in page.annotations where isWidget(a) {
            guard let name = a.fieldName, let value = values[name] else { continue }
            switch a.widgetFieldType {
            case .text, .choice:
                if a.widgetStringValue != value { a.widgetStringValue = value }
            case .button:
                let state = a.buttonWidgetStateString.isEmpty ? "Yes" : a.buttonWidgetStateString
                let on = a.widgetControlType == .radioButtonControl ? value == state : value != "Off"
                a.buttonWidgetState = on ? .onState : .offState
            default:
                break
            }
        }
    }

    /// Values that differ from `baseline`.
    static func changes(_ current: [String: String], from baseline: [String: String]) -> [String: String] {
        current.filter { baseline[$0.key] != $0.value }
    }
}
