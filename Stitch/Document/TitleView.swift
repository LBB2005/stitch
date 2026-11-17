import AppKit

/// The title at the leading end of a Stitch window's toolbar: the file name over a line of detail
/// ("3 pages · Edited"). When `onRename` is set, clicking the name turns it into a field: Return renames
/// the file, Esc puts the old name back.
@MainActor
final class TitleView: NSView, NSTextFieldDelegate {
    private let nameField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let hoverBackground = NSView()
    private var tracking: NSTrackingArea?
    private var editing = false
    private var cancelled = false
    private var nameBeforeEditing = ""

    /// Return true when the rename worked; false puts the old name back.
    var onRename: ((String) -> Bool)? {
        didSet { toolTip = onRename == nil ? nil : "Click the name to rename the file" }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.layer?.cornerCurve = .continuous
        hoverBackground.isHidden = true
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverBackground)

        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.delegate = self
        nameField.focusRingType = .none
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.font = .systemFont(ofSize: 10.5)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [nameField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = -1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            hoverBackground.leadingAnchor.constraint(equalTo: nameField.leadingAnchor, constant: -5),
            hoverBackground.trailingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 5),
            hoverBackground.topAnchor.constraint(equalTo: nameField.topAnchor, constant: -1),
            hoverBackground.bottomAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    func set(name: String, detail: String) {
        if !editing, nameField.stringValue != name { nameField.stringValue = name }
        if detailField.stringValue != detail { detailField.stringValue = detail }
        detailField.isHidden = detail.isEmpty
        setAccessibilityLabel(detail.isEmpty ? name : "\(name), \(detail)")
    }

    override var mouseDownCanMoveWindow: Bool { onRename == nil }

    /// Clicks land here (not on the labels) until the name is being edited.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard !editing else { return hit }
        return hit == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { showHover(onRename != nil && !editing) }
    override func mouseExited(with event: NSEvent) { showHover(false) }

    private func showHover(_ on: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
        hoverBackground.isHidden = !on
    }

    override func mouseDown(with event: NSEvent) {
        let point = nameField.convert(event.locationInWindow, from: nil)
        guard onRename != nil, !editing, nameField.bounds.insetBy(dx: -6, dy: -3).contains(point) else {
            return super.mouseDown(with: event)
        }
        beginEditing()
    }

    /// Turns the name into a field with the name (not the extension) selected.
    func beginEditing() {
        guard onRename != nil, !editing, let window else { return }
        editing = true
        cancelled = false
        showHover(false)
        nameBeforeEditing = nameField.stringValue
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.drawsBackground = true
        nameField.backgroundColor = .textBackgroundColor
        nameField.focusRingType = .exterior
        nameField.lineBreakMode = .byClipping
        nameField.cell?.isScrollable = true
        window.makeFirstResponder(nameField)
        if let editor = nameField.currentEditor() {
            let base = (nameBeforeEditing as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelled = true
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard editing else { return }
        editing = false
        let typed = nameField.stringValue
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.lineBreakMode = .byTruncatingMiddle
        if cancelled || typed == nameBeforeEditing || typed.trimmingCharacters(in: .whitespaces).isEmpty {
            nameField.stringValue = nameBeforeEditing
            return
        }
        if onRename?(typed) != true { nameField.stringValue = nameBeforeEditing }
    }
}
