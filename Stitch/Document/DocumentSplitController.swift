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

    static let preferredWidth: CGFloat = 278
    static let foldBelow: CGFloat = 860
    static let unfoldAbove: CGFloat = 920

    init(controller: DocumentWindowController) {
        self.controller = controller
        let sidebar = NSHostingController(rootView: SidebarView(controller: controller)
            .environment(controller.ui).environment(SignatureStore.shared))
        sidebar.sizingOptions = []
        let content = NSHostingController(rootView: DocumentView(controller: controller)
            .environment(controller.ui).environment(SignatureStore.shared))
        content.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 230
        sidebarItem.maximumThickness = 380
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
        }
        autoFoldReady = true
        if let width = view.window?.frame.width { autoFold(width: width) }
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

    /// Fold under 860 pt (the toolbar needs about 600 pt beside the sidebar), unfold again past 920 pt, unless the person folded it themselves.
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

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        sync()
    }

    private func sync(_ folded: Bool? = nil) {
        let value = folded ?? sidebarItem.isCollapsed
        if controller?.ui.isFolded != value { controller?.ui.isFolded = value }
    }
}
