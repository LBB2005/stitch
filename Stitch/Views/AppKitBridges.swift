import AppKit
import SwiftUI

/// The filename field: an AppKit text field so it can take focus with just the name (not the extension)
/// selected, like Finder's rename, so typing replaces the name and keeps `.pdf`.
struct FileNameField: NSViewRepresentable {
    let text: String
    let focusToken: Int
    let onChange: (String) -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("File name")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { Self.focus(field) }
        }
    }

    private static func focus(_ field: NSTextField) {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        let name = field.stringValue as NSString
        let ext = name.pathExtension
        let length = ext.isEmpty ? name.length : name.length - ext.count - 1
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: max(length, 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FileNameField
        var focusToken = -1

        init(parent: FileNameField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// Makes whatever it covers draggable as the finished file(s): drop straight into a ChatGPT or Claude
/// tab, an email or Finder. Double-click opens them.
struct FileDragSource: NSViewRepresentable {
    let urls: [URL]
    var preview: NSImage?
    let onDragChanged: (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.urls = urls
        view.preview = preview
        view.onDragChanged = onDragChanged
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.urls = urls
        view.preview = preview
        view.onDragChanged = onDragChanged
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var urls: [URL] = []
        var preview: NSImage?
        var onDragChanged: (Bool) -> Void = { _ in }
        private var dragStarted = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            dragStarted = false
            if event.clickCount == 2 { urls.forEach { NSWorkspace.shared.open($0) } }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragStarted, !urls.isEmpty else { return }
            dragStarted = true
            let point = convert(event.locationInWindow, from: nil)
            let side: CGFloat = 56
            let items = urls.enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let image = (i == 0 ? preview : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
                let offset = CGFloat(min(i, 4)) * 6
                item.setDraggingFrame(NSRect(x: point.x - side / 2 + offset, y: point.y - side / 2 - offset,
                                             width: side, height: side), contents: image)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            onDragChanged(true)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onDragChanged(false)
        }
    }
}
