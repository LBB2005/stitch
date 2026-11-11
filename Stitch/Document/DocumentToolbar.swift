import AppKit

/// The document window's one slim toolbar row (`.unifiedCompact`): zoom, Edit Text, Text, Date, Sign ▾,
/// My Info ▾, and Save Copy. Shortcuts are in each tooltip and in the Insert menu.
@MainActor
final class DocumentToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate {
    let toolbar: NSToolbar
    private weak var controller: DocumentWindowController?
    private var editTextButton: NSButton?
    private var saveButton: NSButton?
    private let myInfoMenu = NSMenu()

    private enum ID {
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let editText = NSToolbarItem.Identifier("editText")
        static let text = NSToolbarItem.Identifier("text")
        static let date = NSToolbarItem.Identifier("date")
        static let sign = NSToolbarItem.Identifier("sign")
        static let myInfo = NSToolbarItem.Identifier("myInfo")
        static let save = NSToolbarItem.Identifier("save")
    }

    init(controller: DocumentWindowController) {
        self.controller = controller
        toolbar = NSToolbar(identifier: "StitchDocumentToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        myInfoMenu.delegate = self
    }

    func refresh() {
        editTextButton?.state = controller?.ui.tool == .editText ? .on : .off
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.zoom, .flexibleSpace, ID.editText, ID.text, ID.date, ID.sign, ID.myInfo, .flexibleSpace, ID.save]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
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
        case ID.myInfo:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("person.text.rectangle")
            item.label = "My Info"
            item.toolTip = "Fill in your details (⌥⌘F)"
            item.menu = myInfoMenu
            item.showsIndicator = true
            return item
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

    // MARK: My Info menu (built when opened, from your saved details)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profile = SignatureStore.shared.profile
        let addresses = profile.addresses.filter { !$0.isEmpty }
        if controller?.hasFormFields == true {
            if addresses.count > 1 {
                for (i, a) in addresses.enumerated() {
                    let item = menuItem("Fill Matching Fields (\(a.label))", #selector(fillWithAddress(_:)), key: i == 0 ? "f" : "")
                    item.tag = i
                    menu.addItem(item)
                }
            } else {
                menu.addItem(menuItem("Fill Matching Fields", #selector(fill), key: "f"))
            }
            menu.addItem(.separator())
        }
        if profile.isEmpty {
            menu.addItem(withTitle: "No details saved yet", action: nil, keyEquivalent: "")
        } else {
            let header = NSMenuItem(title: "Insert as Text", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in ProfileItem.allCases where !item.isAddress && !profile.value(item).isEmpty {
                let m = menuItem(item.label, #selector(insertItem(_:)))
                m.representedObject = item.rawValue
                menu.addItem(m)
            }
            for (i, a) in addresses.enumerated() {
                let m = menuItem(addresses.count > 1 ? "\(a.label) Address" : "Address", #selector(insertAddress(_:)))
                m.tag = i
                menu.addItem(m)
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Edit My Info…", #selector(editInfo)))
    }

    // MARK: actions

    @objc private func zoom(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: controller?.zoomOut()
        case 1: controller?.zoomIn()
        default: controller?.fitWidth()
        }
    }

    @objc private func editText() { controller?.toggleEditText() }
    @objc private func text() { controller?.startTextBox() }
    @objc private func date() { controller?.insertDate() }
    @objc private func signature() { controller?.placeSignature(initials: false) }
    @objc private func initials() { controller?.placeSignature(initials: true) }
    @objc private func createSignature() { controller?.createSignature(initials: false) }
    @objc private func createInitials() { controller?.createSignature(initials: true) }
    @objc private func save() { controller?.saveCopy() }
    @objc private func fill() { controller?.fillMatchingFields(address: nil) }

    @objc private func fillWithAddress(_ sender: NSMenuItem) {
        let addresses = SignatureStore.shared.profile.addresses.filter { !$0.isEmpty }
        controller?.fillMatchingFields(address: addresses.indices.contains(sender.tag) ? addresses[sender.tag] : nil)
    }

    @objc private func insertItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let item = ProfileItem(rawValue: raw) else { return }
        controller?.insertProfileItem(item, address: nil)
    }

    @objc private func insertAddress(_ sender: NSMenuItem) {
        let addresses = SignatureStore.shared.profile.addresses.filter { !$0.isEmpty }
        guard addresses.indices.contains(sender.tag) else { return }
        controller?.insertProfileItem(.fullAddress, address: addresses[sender.tag])
    }

    @objc private func editInfo() { SettingsOpener.open(tab: .yourInfo) }

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
