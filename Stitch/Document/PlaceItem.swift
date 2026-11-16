import AppKit
import UniformTypeIdentifiers

/// Something the Sign and My Info panels can put on a page, by dragging it there or by clicking it and
/// then the page: one entry point (`DocumentWindowController.place`) for drops, clicks, menus and shortcuts.
enum PlaceItem: Codable, Hashable, Sendable {
    case signature, initials, date, textBox
    /// One of your details; address items use the address at that index.
    case profile(ProfileItem, address: Int?)

    static let pasteboardType = NSPasteboard.PasteboardType("com.stitch.place-item")

    var label: String {
        switch self {
        case .signature: "Signature"
        case .initials: "Initials"
        case .date: "Date"
        case .textBox: "Text Box"
        case .profile(let item, _): item.label
        }
    }

    /// What's being dragged right now (also on the pasteboard, as JSON).
    @MainActor static var dragging: PlaceItem?

    @MainActor func itemProvider() -> NSItemProvider {
        Self.dragging = self
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: Self.pasteboardType.rawValue, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    @MainActor static func from(_ pasteboard: NSPasteboard) -> PlaceItem? {
        guard pasteboard.types?.contains(pasteboardType) == true else { return nil }
        if let data = pasteboard.data(forType: pasteboardType), let item = try? JSONDecoder().decode(PlaceItem.self, from: data) {
            return item
        }
        return dragging
    }
}

extension ProfileItem: Codable {}
