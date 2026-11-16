import AppKit

/// The document window's one slim toolbar row (`.unifiedCompact`), over the PDF beside the sidebar: the
/// file name (click to rename), search (⌘K), zoom, Edit Text, Text, Date, Sign ▾, undo/redo and Save Copy.
/// Shortcuts are in each tooltip and in the menus. Your details are in the sidebar's My Info panel.
@MainActor
final class DocumentToolbar: NSObject, NSToolbarDelegate {
    let toolbar: NSToolbar
    private weak var controller: DocumentWindowController?
    private var editTextButton: NSButton?
    private var saveButton: NSButton?
    private var undoGroup: NSToolbarItemGroup?
    private let titleView = TitleView()
    private var observers: [NSObjectProtocol] = []

    private enum ID {
        static let title = NSToolbarItem.Identifier("title")
        static let search = NSToolbarItem.Identifier("search")
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let editText = NSToolbarItem.Identifier("editText")
        static let text = NSToolbarItem.Identifier("text")
        static let date = NSToolbarItem.Identifier("date")
        static let sign = NSToolbarItem.Identifier("sign")
        static let undo = NSToolbarItem.Identifier("undo")
        static let save = NSToolbarItem.Identifier("save")
    }

    init(controller: DocumentWindowController) {
        self.controller = controller
        toolbar = NSToolbar(identifier: "StitchDocumentToolbar")
        super.init()
        titleView.onRename = { [weak controller] name in controller?.rename(to: name) ?? false }
        refreshTitle()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if let undo = controller.session.undoManager as UndoManager? {
            for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: undo, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }
    }

    func invalidate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// The name and "3 pages · Edited" under it.
    func refreshTitle() {
        guard let controller else { return }
        let pages = controller.session.pageCount == 1 ? "1 page" : "\(controller.session.pageCount) pages"
        titleView.set(name: controller.session.name, detail: controller.ui.isDirty ? pages + " · Edited" : pages)
    }

    func beginRename() {
        titleView.beginEditing()
    }

    func refresh() {
        editTextButton?.state = controller?.ui.tool == .editText ? .on : .off
        let undo = controller?.session.undoManager
        if let items = undoGroup?.subitems, items.count == 2 {
            items[0].isEnabled = undo?.canUndo == true
            items[1].isEnabled = undo?.canRedo == true
            items[0].toolTip = undo?.canUndo == true ? "\(undo?.undoMenuItemTitle ?? "Undo") (⌘Z)" : "Undo (⌘Z)"
            items[1].toolTip = undo?.canRedo == true ? "\(undo?.redoMenuItemTitle ?? "Redo") (⇧⌘Z)" : "Redo (⇧⌘Z)"
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ID.title, .flexibleSpace, ID.search, ID.zoom, ID.editText, ID.text,
         ID.date, ID.sign, ID.undo, ID.save]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.title:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Name"
            item.view = titleView
            // Plain text like a window title, not a glass button.
            item.isBordered = false
            item.visibilityPriority = .high
            return item
        case ID.search:
            return button(id, "magnifyingglass", "Search", "Search files and actions (⌘K)", #selector(search))
        case ID.zoom:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [symbol("minus.magnifyingglass"), symbol("plus.magnifyingglass"),
                                                    symbol("arrow.left.and.right")],
                                           selectionMode: .momentary, labels: ["Zoom Out", "Zoom In", "Fit Width"],
                                           target: self, action: #selector(zoom(_:)))
            group.label = "Zoom"
            group.toolTip = "Zoom out (⌘−) · Zoom in (⌘+) · Fit width"
            group.controlRepresentation = .expanded
            return group
        case ID.editText:
            let button = NSButton(image: symbol("character.cursor.ibeam"), target: self, action: #selector(editText))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .texturedRounded
            editTextButton = button
            return item(id, label: "Edit Text", tip: "Click text in the PDF to change it (⌥⌘E)", view: button)
        case ID.text:
            return button(id, "textformat", "Text", "Add a text box: click where it goes (⌥⌘T)", #selector(text))
        case ID.date:
            return button(id, "calendar", "Date", "Today's date (⇧⌘D)", #selector(date))
        case ID.sign:
            let menu = NSMenu()
            menu.addItem(menuItem("Signature", #selector(signature), key: "s"))
            menu.addItem(menuItem("Initials", #selector(initials), key: "i"))
            menu.addItem(.separator())
            menu.addItem(menuItem("Create or Change Signature…", #selector(createSignature)))
            menu.addItem(menuItem("Create or Change Initials…", #selector(createInitials)))
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("signature")
            item.label = "Sign"
            item.toolTip = "Sign: signature ⌥⌘S, initials ⌥⌘I"
            item.menu = menu
            item.showsIndicator = true
            item.target = self
            item.action = #selector(signature)
            return item
        case ID.undo:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [symbol("arrow.uturn.backward"), symbol("arrow.uturn.forward")],
                                           selectionMode: .momentary, labels: ["Undo", "Redo"],
                                           target: self, action: #selector(undoRedo(_:)))
            group.label = "Undo"
            group.controlRepresentation = .expanded
            group.autovalidates = false
            undoGroup = group
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return group
        case ID.save:
            let button = NSButton(title: "Save Copy", target: self, action: #selector(save))
            button.bezelStyle = .push
            button.controlSize = .regular
            button.keyEquivalent = ""
            saveButton = button
            return item(id, label: "Save Copy", tip: "Save a copy next to the original (⌘S)", view: button)
        default:
            return nil
        }
    }

    // MARK: actions

    @objc private func zoom(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: controller?.zoomOut()
        case 1: controller?.zoomIn()
        default: controller?.fitWidth()
        }
    }

    @objc private func search() { controller?.showSearch() }
    @objc private func editText() { controller?.toggleEditText() }
    @objc private func text() { controller?.startTextBox() }
    @objc private func date() { controller?.insertDate() }
    @objc private func signature() { controller?.placeSignature(initials: false) }
    @objc private func initials() { controller?.placeSignature(initials: true) }
    @objc private func createSignature() { controller?.createSignature(initials: false) }
    @objc private func createInitials() { controller?.createSignature(initials: true) }
    @objc private func save() { controller?.saveCopy() }

    @objc private func undoRedo(_ sender: NSToolbarItemGroup) {
        controller?.pdfView.commitEditing()
        let undo = controller?.session.undoManager
        if sender.selectedIndex == 0 { if undo?.canUndo == true { undo?.undo() } } else if undo?.canRedo == true { undo?.redo() }
        refresh()
    }

    // MARK: helpers

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    private func item(_ id: NSToolbarItem.Identifier, label: String, tip: String, view: NSView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = tip
        item.view = view
        view.toolTip = tip
        view.setAccessibilityLabel(label)
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbolName: String, _ label: String, _ tip: String,
                        _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = symbol(symbolName)
        item.label = label
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    /// Shortcuts live in the menu bar's Insert menu; these menus only show the names.
    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
