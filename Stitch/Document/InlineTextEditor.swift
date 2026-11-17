import AppKit

/// The text field that opens over a text box or over text already in the PDF. Return commits,
/// Shift-Return adds a line, Escape cancels; clicking elsewhere commits.
final class InlineTextEditor: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onChange: ((String) -> Void)?
    /// Fixed width (existing text wraps at the block's width) or grows with the text (text boxes).
    var fixedWidth: CGFloat?
    private var finished = false
    /// Typing has its own undo while the editor is open, so it never mixes with the document's.
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }

    static func make(frame: NSRect, text: String, font: NSFont, color: NSColor, opaque: Bool, fixedWidth: CGFloat?) -> InlineTextEditor {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: fixedWidth ?? 100_000, height: 100_000))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let editor = InlineTextEditor(frame: frame, textContainer: container)
        editor.fixedWidth = fixedWidth
        editor.string = text
        editor.font = font
        editor.textColor = color
        editor.insertionPointColor = .controlAccentColor
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = .zero
        editor.drawsBackground = opaque
        editor.backgroundColor = .white
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = fixedWidth == nil
        editor.typingAttributes = [.font: font, .foregroundColor: color]
        editor.focusRingType = .none
        editor.setAccessibilityLabel("Edit text")
        editor.fitToText()
        return editor
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                commit()
            }
        case 53: // Escape
            cancel()
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        fitToText()
        onChange?(string)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, !finished { DispatchQueue.main.async { [weak self] in self?.commit() } }
        return ok
    }

    func commit() {
        guard !finished else { return }
        finished = true
        onCommit?(string)
        removeFromSuperview()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onCancel?()
        removeFromSuperview()
    }

    /// Grows to fit (downward for fixed-width text, sideways and downward for text boxes).
    func fitToText() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let lineHeight = layout.defaultLineHeight(for: font ?? .systemFont(ofSize: 12))
        let width = fixedWidth ?? (max(ceil(used.width) + 4, lineHeight) + textContainerInset.width * 2)
        let height = max(ceil(used.height), lineHeight) + textContainerInset.height * 2
        let top = frame.maxY
        // The superview (PDFKit's document view) may be flipped or not; keep the top edge fixed.
        let flipped = superview?.isFlipped ?? false
        let origin = flipped ? frame.origin : NSPoint(x: frame.minX, y: top - height)
        setFrameSize(NSSize(width: width, height: height))
        setFrameOrigin(origin)
    }
}
