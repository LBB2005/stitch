import AppKit
import SwiftUI

/// The document window's content: the sidebar (rail + panel) and the PDF. Folding collapses the sidebar
/// item; the rail then floats over the PDF (`DocumentView`). Narrow windows fold on their own.
@MainActor
final class DocumentSplitController: NSSplitViewController {
    let sidebarItem: NSSplitViewItem
    let contentItem: NSSplitViewItem
    private weak var controller: DocumentWindowController?
    /// The person folded it themselves: auto-unfold leaves it folded.
    private var foldedByHand = false
    private var foldedByWidth = false
    private var placedDivider = false
    /// Auto-fold waits until the window is on screen (building it resizes it a few times).
    private var autoFoldReady = false
    /// Opened from the empty Stitch window: the sidebar unfolds and the page fades in once it's on screen.
    var animateIn = false
    private var animatingIn = false

    static let defaultWidth: CGFloat = 278
    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 520
    private static let widthKey = "StitchSidebarWidth"
    /// The width the person last dragged the sidebar to; every window and tab uses it.
    static var preferredWidth: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: widthKey)
            return saved > 0 ? min(max(saved, minWidth), maxWidth) : defaultWidth
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: widthKey) }
    }
    /// How far either side of the 1-pt divider still grabs it.
    private static let grabSlop: CGFloat = 5
    private var keyObserver: NSObjectProtocol?
    /// The toolbar needs about 580 pt beside the sidebar.
    static var foldBelow: CGFloat { preferredWidth + 582 }
    static var unfoldAbove: CGFloat { foldBelow + 60 }

    init(controller: DocumentWindowController) {
        self.controller = controller
        let sidebar = NSHostingController(rootView: SidebarView(controller: controller)
            .environment(controller.ui).environment(SignatureStore.shared))
        sidebar.sizingOptions = []
        let content = NSHostingController(rootView: DocumentView(controller: controller)
            .environment(controller.ui).environment(SignatureStore.shared))
        content.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.minWidth
        sidebarItem.maximumThickness = Self.maxWidth
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .none
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !placedDivider, view.bounds.width >= Self.preferredWidth + contentItem.minimumThickness {
            placedDivider = true
            splitView.setPosition(Self.preferredWidth, ofDividerAt: 0)
        } else {
            matchSavedWidth()
        }
        // Switching to another tab picks up the width set in the one before.
        if keyObserver == nil, let window = view.window {
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.matchSavedWidth() }
            }
        }
        autoFoldReady = true
        if let width = view.window?.frame.width { autoFold(width: width) }
        if animateIn {
            animateIn = false
            if !sidebarItem.isCollapsed { playAnimateIn() }
        }
    }

    /// Collapses at once (before anything is drawn), then unfolds to the width it had, with the page
    /// fading in: the empty window turning into the document.
    private func playAnimateIn() {
        animatingIn = true
        sidebarItem.isCollapsed = true
        let page = contentItem.viewController.view
        page.alphaValue = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.sidebarItem.animator().isCollapsed = false
                page.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    page.alphaValue = 1
                    self?.animatingIn = false
                    self?.sync()
                }
            }
        }
    }

    var isFolded: Bool { sidebarItem.isCollapsed }

    /// Folds or unfolds, animated, as the person asked (rail button, ⌃⌘S, the toolbar's sidebar button).
    func setFolded(_ folded: Bool, byHand: Bool = true) {
        if byHand {
            foldedByHand = folded
            foldedByWidth = false
        }
        guard sidebarItem.isCollapsed != folded else { return sync() }
        // Folding for the window's width happens while it's being resized: no animation then.
        guard byHand, view.window?.isVisible == true else {
            sidebarItem.isCollapsed = folded
            return sync()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed = folded
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync(folded)
    }

    override func toggleSidebar(_ sender: Any?) {
        setFolded(!sidebarItem.isCollapsed)
    }

    /// Fold when the toolbar would no longer fit beside the sidebar (860 pt at the default width), unfold again 60 pt wider, unless the person folded it themselves.
    func autoFold(width: CGFloat) {
        guard autoFoldReady else { return }
        if width < Self.foldBelow, !sidebarItem.isCollapsed {
            foldedByWidth = true
            setFolded(true, byHand: false)
        } else if width > Self.unfoldAbove, sidebarItem.isCollapsed, foldedByWidth, !foldedByHand {
            foldedByWidth = false
            setFolded(false, byHand: false)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    private var sidebarWidth: CGFloat { sidebarItem.viewController.view.frame.width }

    private func matchSavedWidth() {
        guard placedDivider, !sidebarItem.isCollapsed, !animatingIn else { return }
        let want = Self.preferredWidth
        guard abs(sidebarWidth - want) > 0.5, view.bounds.width >= want + contentItem.minimumThickness else { return }
        splitView.setPosition(want, ofDividerAt: 0)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // Only a drag of the divider itself is remembered (not window resizing, folding or animations).
        if NSApp.currentEvent?.type == .leftMouseDragged, view.window?.inLiveResize == false,
           !animatingIn, !sidebarItem.isCollapsed, sidebarWidth >= Self.minWidth {
            Self.preferredWidth = sidebarWidth
        }
        sync()
    }

    /// A wider grab area than the hairline divider, so it's easy to catch.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect,
                                   ofDividerAt: dividerIndex)
        guard !sidebarItem.isCollapsed else { return rect }
        return rect.insetBy(dx: -Self.grabSlop, dy: 0)
    }

    private func sync(_ folded: Bool? = nil) {
        // Mid animate-in the sidebar is briefly collapsed; the floating rail shouldn't flash up.
        guard !animatingIn else { return }
        let value = folded ?? sidebarItem.isCollapsed
        if controller?.ui.isFolded != value { controller?.ui.isFolded = value }
    }
}
