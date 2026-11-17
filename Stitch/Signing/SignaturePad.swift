import AppKit
import SwiftUI

/// Make a signature or initials: draw (drag with the mouse, or Preview-style with a finger on the
/// trackpad) or type in a script font that ships with macOS.
struct SignaturePad: View {
    enum Mode: String, CaseIterable { case draw = "Draw", type = "Type" }

    let initials: Bool
    /// Your name from My Info, to start the Type tab with. Only passed after Touch ID.
    var suggestedName: String? = nil
    let done: (Signature?) -> Void

    @State private var mode: Mode = .draw
    @State private var canvas = SignatureCanvasView()
    @State private var hasInk = false
    @State private var trackpad = false
    @State private var typed = ""
    @State private var font = Signature.scriptFonts[1].name

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(initials ? "Your Initials" : "Your Signature").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch mode {
            case .draw: drawTab
            case .type: typeTab
            }
            HStack {
                Text("Saved only on this Mac, in your Keychain. Touch ID is asked before it's used.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { finishTrackpad(); done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { finishTrackpad(); done(result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            canvas.onChange = { hasInk = $0 }
            canvas.onTrackpadEnded = { trackpad = false }
            if typed.isEmpty, let name = suggestedName {
                typed = initials ? Self.initials(of: name) : name
            }
        }
    }

    private var drawTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignatureCanvas(view: canvas)
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(trackpad ? Color.accentColor : Theme.hairline, lineWidth: trackpad ? 2 : 0.5))
            HStack(spacing: 12) {
                Button(trackpad ? "Press any key when done" : "Sign on Trackpad") {
                    if trackpad { finishTrackpad() } else { trackpad = true; canvas.startTrackpad() }
                }
                .help("Sign with a finger on the trackpad; press any key to finish")
                Button("Clear") { canvas.clear() }.disabled(!hasInk)
                Spacer()
                Text(trackpad ? "Use one finger on the trackpad" : "Drag to sign")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var typeTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(initials ? "Initials" : "Your name", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Signature.scriptFonts, id: \.name) { option in
                        Button { font = option.name } label: {
                            HStack {
                                Text(typed.isEmpty ? option.label : typed)
                                    .font(.custom(option.name, size: 30))
                                    .lineLimit(1)
                                    .foregroundStyle(Color(cgColor: Signature.ink))
                                Spacer()
                                if font == option.name { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 50)
                            .background(font == option.name ? Color.accentColor.opacity(0.1) : Theme.cell,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 170)
        }
    }

    private var result: Signature? {
        switch mode {
        case .draw: hasInk ? Signature.drawn(strokes: canvas.strokes) : nil
        case .type: Signature.typed(typed, fontName: font)
        }
    }

    private func finishTrackpad() {
        canvas.stopTrackpad()
        trackpad = false
    }

    static func initials(of name: String) -> String {
        name.split(whereSeparator: { $0 == " " || $0 == "-" }).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct SignatureCanvas: NSViewRepresentable {
    let view: SignatureCanvasView
    func makeNSView(context: Context) -> SignatureCanvasView { view }
    func updateNSView(_ nsView: SignatureCanvasView, context: Context) {}
}

/// Collects strokes from mouse drags, or from one finger on the trackpad (absolute position on the
/// trackpad maps to the canvas, as in Preview). While signing on the trackpad the pointer stays still.
final class SignatureCanvasView: NSView {
    private(set) var strokes: [[CGPoint]] = []
    var onChange: ((Bool) -> Void)?
    var onTrackpadEnded: (() -> Void)?
    private var trackpadMode = false
    private var activeTouch: NSObjectProtocol?
    private var leaveObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func clear() {
        strokes = []
        needsDisplay = true
        onChange?(false)
    }

    func startTrackpad() {
        trackpadMode = true
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        window?.makeFirstResponder(self)
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        needsDisplay = true
        // Never leave the pointer frozen: switching apps or windows ends trackpad signing.
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            leaveObservers.append(center.addObserver(forName: name, object: name == NSWindow.didResignKeyNotification ? window : nil,
                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopTrackpad() }
            })
        }
    }

    func stopTrackpad() {
        guard trackpadMode else { return }
        trackpadMode = false
        leaveObservers.forEach(NotificationCenter.default.removeObserver)
        leaveObservers = []
        allowedTouchTypes = []
        activeTouch = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        needsDisplay = true
        onTrackpadEnded?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopTrackpad() }
        super.viewWillMove(toWindow: newWindow)
    }

    // Mouse
    override func mouseDown(with event: NSEvent) {
        guard !trackpadMode else { return }
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !trackpadMode, !strokes.isEmpty else { return }
        add(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { onChange?(!strokes.isEmpty) }

    // Trackpad
    override func touchesBegan(with event: NSEvent) {
        guard trackpadMode, activeTouch == nil, let touch = event.touches(matching: .began, in: self).first else { return }
        activeTouch = touch.identity
        strokes.append([point(for: touch)])
        needsDisplay = true
    }

    override func touchesMoved(with event: NSEvent) {
        guard trackpadMode, let id = activeTouch,
              let touch = event.touches(matching: .moved, in: self).first(where: { $0.identity.isEqual(id) }) else { return }
        add(point(for: touch))
    }

    override func touchesEnded(with event: NSEvent) {
        guard trackpadMode, let id = activeTouch,
              event.touches(matching: .ended, in: self).contains(where: { $0.identity.isEqual(id) }) else { return }
        activeTouch = nil
        onChange?(!strokes.isEmpty)
    }

    override func touchesCancelled(with event: NSEvent) { activeTouch = nil }

    override func keyDown(with event: NSEvent) {
        if trackpadMode { stopTrackpad() } else { super.keyDown(with: event) }
    }

    private func point(for touch: NSTouch) -> CGPoint {
        let p = touch.normalizedPosition
        let inset: CGFloat = 12
        return CGPoint(x: inset + p.x * (bounds.width - inset * 2), y: inset + p.y * (bounds.height - inset * 2))
    }

    private func add(_ p: CGPoint) {
        guard var last = strokes.popLast() else { return }
        if let prev = last.last, hypot(prev.x - p.x, prev.y - p.y) < 0.8 { strokes.append(last); return }
        last.append(p)
        strokes.append(last)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Signing line.
        let lineY = bounds.height * 0.28
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 28, y: lineY))
        line.line(to: NSPoint(x: bounds.width - 28, y: lineY))
        line.lineWidth = 1
        line.stroke()
        let x = NSAttributedString(string: "×", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.tertiaryLabelColor])
        x.draw(at: NSPoint(x: 28, y: lineY + 4))
        if strokes.isEmpty {
            let hint = NSAttributedString(string: trackpadMode ? "Sign with one finger on the trackpad" : "Sign here",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
            hint.draw(at: NSPoint(x: (bounds.width - hint.size().width) / 2, y: bounds.height * 0.6))
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor(cgColor: Signature.ink)?.usingColorSpace(.sRGB)?.cgColor ?? Signature.ink)
        if NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            ctx.setStrokeColor(NSColor.labelColor.cgColor)
        }
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes {
            ctx.addPath(Signature.smoothPath(s))
            ctx.strokePath()
        }
    }
}
