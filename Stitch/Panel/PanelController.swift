import AppKit
import SwiftUI

/// The menu bar icon and the popover-style panel under it.
///
/// It is an `NSStatusItem` rather than `MenuBarExtra` so the icon itself can take dragged files: the
/// status item's window is registered for file drags and forwards them here as its delegate. The panel
/// is a borderless, non-activating `NSPanel`, so the app you were in stays frontmost, like Control Center.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSDraggingDestination {
    static let width: CGFloat = 340

    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var panel: StitchPanel?
    private var contentHeight: CGFloat = 200
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Set while the finished file is being dragged out, so the panel stays open.
    var isDraggingOut = false
    private var isRunningModal = false

    var isOpen: Bool { panel?.isVisible ?? false }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: status item

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.normal
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.setAccessibilityLabel("Stitch")
        item.button?.toolTip = "Stitch — drop files here"
        statusItem = item

        registerDragTarget()
        DispatchQueue.main.async { [weak self] in self?.registerDragTarget() }
    }

    /// Drag-onto-icon: the button's window forwards dragging messages to its delegate. The window can
    /// appear a moment after the item is created, so this runs again on the next turn of the run loop.
    private func registerDragTarget() {
        guard let window = statusItem?.button?.window, window.delegate !== self else { return }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            showContextMenu()
        } else {
            isOpen ? close() : open()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Stitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        open()
        model.openSettings()
    }

    private func setDropHighlight(_ on: Bool) {
        statusItem?.button?.image = on ? MenuBarIcon.dropTarget : MenuBarIcon.normal
    }

    // MARK: drag onto the icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let count = fileURLs(sender).count
        guard count > 0 else { return [] }
        setDropHighlight(true)
        model.dropHover = count
        open()
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
        model.dropHover = nil
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        setDropHighlight(false)
        model.dropHover = nil
        guard !urls.isEmpty else { return false }
        model.add(urls)
        open()
        return true
    }

    func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: open / close

    /// `takeFocus: false` shows the panel without making it key (debug screenshots), so keystrokes keep
    /// going to whatever app has them.
    func open(takeFocus: Bool = true) {
        guard !isOpen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        computeAnchor()
        panel.contentView?.layoutSubtreeIfNeeded()   // reports the content height before the first frame
        panel.setFrame(frame(), display: false)
        panel.alphaValue = 0
        if takeFocus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        statusItem?.button?.highlight(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        startMonitors()
    }

    func close(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        stopMonitors()
        statusItem?.button?.highlight(false)
        model.dropHover = nil
        guard animated else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    /// Runs a Finder dialog (open, save, choose folder). The panel steps aside while it is up and comes
    /// back afterwards; Stitch activates so the dialog can take the keyboard.
    func runModal<T>(_ body: () -> T) -> T {
        isRunningModal = true
        close(animated: false)
        NSApp.activate(ignoringOtherApps: true)
        let value = body()
        isRunningModal = false
        open()
        return value
    }

    // MARK: sizing

    /// The SwiftUI content reports its height; the panel follows with its top edge pinned under the icon.
    func contentHeightChanged(_ height: CGFloat) {
        let height = height.rounded()
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard let panel else { return }
        guard panel.isVisible else { return panel.setFrame(frame(), display: false) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame(), display: true)
        }
    }

    /// Centered under the icon, kept on screen.
    /// If the icon has no position yet (just after launch), falls back to the top-right of the main screen.
    private func computeAnchor() {
        guard let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        var item = NSRect(x: screen.frame.maxX - 200, y: screen.visibleFrame.maxY, width: 24, height: 0)
        if let button = statusItem?.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if screen.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) { item = rect }
        }
        let margin: CGFloat = 8
        let half = Self.width / 2
        anchorMidX = min(max(item.midX, screen.frame.minX + margin + half), screen.frame.maxX - margin - half)
        anchorTop = min(item.minY, screen.visibleFrame.maxY) - 6
    }

    private func frame() -> NSRect {
        let maxHeight = (panel?.screen ?? NSScreen.main).map { anchorTop - $0.visibleFrame.minY - 12 } ?? 700
        let height = max(min(contentHeight, maxHeight), 120)
        return NSRect(x: anchorMidX - Self.width / 2, y: anchorTop - height, width: Self.width, height: height)
    }

    private func makePanel() -> StitchPanel {
        let panel = StitchPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: contentHeight),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if !model.back() { close() }
        }

        let host = NSHostingView(rootView: PanelRoot(controller: self).environment(model).environment(model.prefs))
        host.sizingOptions = []   // the controller owns the panel's size
        panel.contentView = Self.material(around: host)
        return panel
    }

    /// Liquid Glass on macOS 26, the frosted popover material before that; rounded with a hairline edge.
    private static func material(around content: NSView) -> NSView {
        let radius: CGFloat = 16
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.maskImage = .roundedMask(radius: radius)
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    // MARK: dismissal

    /// Clicks in other apps and switching apps close the panel — except while a result is being dragged
    /// out of it or a Finder dialog is up.
    private func startMonitors() {
        stopMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfIdle() }
        }) { eventMonitors.append(m) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated { if !isSelf { self?.dismissIfIdle() } }
        })
    }

    private func dismissIfIdle() {
        guard !isDraggingOut, !isRunningModal, model.dropHover == nil else { return }
        close()
    }

    private func stopMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }
}

/// A borderless panel that can take keyboard focus (typing a filename, Return, Escape) without
/// activating Stitch, so the app you were in stays frontmost.
final class StitchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private extension NSImage {
    /// A stretchable rounded-rect mask for `NSVisualEffectView`.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
