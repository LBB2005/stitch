import Foundation

/// One page of one prepared source file.
struct PageRef: Hashable, Sendable, Identifiable {
    let fileID: UUID
    let index: Int
    var id: String { "\(fileID.uuidString)-\(index)" }
}

/// The order pages will be merged in, as the Arrange grid shows it: a multi-page file is one tile until
/// it is expanded into its pages, which can then be moved anywhere.
struct Arrangement: Equatable, Sendable {
    enum Item: Equatable, Sendable, Identifiable {
        case file(UUID, [PageRef])
        case page(PageRef)

        var id: String {
            switch self {
            case .file(let id, _): "file-\(id.uuidString)"
            case .page(let ref): ref.id
            }
        }
        var pages: [PageRef] {
            switch self {
            case .file(_, let pages): pages
            case .page(let ref): [ref]
            }
        }
        var fileID: UUID {
            switch self {
            case .file(let id, _): id
            case .page(let ref): ref.fileID
            }
        }
        var isStack: Bool { if case .file = self { true } else { false } }
    }

    /// Up to this many pages in total, every file starts expanded so each page has its own tile.
    static let expandAllLimit = 16

    private(set) var items: [Item]

    init(items: [Item]) { self.items = items }

    /// Builds the default arrangement for files in order. Pages in `removed` are left out.
    init(files: [(id: UUID, pageCount: Int)], removed: Set<PageRef> = []) {
        let total = files.reduce(0) { $0 + $1.pageCount }
        let expand = total <= Self.expandAllLimit
        var items: [Item] = []
        for file in files {
            let pages = (0..<file.pageCount).map { PageRef(fileID: file.id, index: $0) }.filter { !removed.contains($0) }
            if pages.isEmpty { continue }
            if expand || pages.count == 1 {
                items += pages.map(Item.page)
            } else {
                items.append(.file(file.id, pages))
            }
        }
        self.items = items
    }

    var pages: [PageRef] { items.flatMap(\.pages) }
    var pageCount: Int { items.reduce(0) { $0 + $1.pages.count } }
    var hasStacks: Bool { items.contains(where: \.isStack) }
    /// Files that have more than one page somewhere in the grid, so expanding or collapsing changes something.
    var canCollapse: Bool {
        var counts: [UUID: Int] = [:]
        for case .page(let ref) in items { counts[ref.fileID, default: 0] += 1 }
        return counts.values.contains { $0 > 1 }
    }

    /// Moves an item next to another one, before or after it.
    mutating func move(_ id: String, to targetID: String, before: Bool) {
        guard id != targetID, let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        guard var to = items.firstIndex(where: { $0.id == targetID }) else {
            items.insert(item, at: from)
            return
        }
        if !before { to += 1 }
        items.insert(item, at: to)
    }

    /// Removes a page, or a whole file tile.
    mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }

    /// Replaces a file tile with one tile per page, in place.
    mutating func expand(_ fileID: UUID) {
        guard let i = items.firstIndex(where: { $0.isStack && $0.fileID == fileID }) else { return }
        let pages = items[i].pages
        items.replaceSubrange(i...i, with: pages.map(Item.page))
    }

    /// Gathers every page of a file back into one tile, where its first page is now.
    mutating func collapse(_ fileID: UUID) {
        let indices = items.indices.filter { !items[$0].isStack && items[$0].fileID == fileID }
        guard indices.count > 1, let first = indices.first else { return }
        let pages = indices.flatMap { items[$0].pages }
        for i in indices.reversed() { items.remove(at: i) }
        items.insert(.file(fileID, pages), at: first)
    }

    mutating func expandAll() {
        items = items.flatMap { item -> [Item] in
            item.isStack ? item.pages.map(Item.page) : [item]
        }
    }

    mutating func collapseAll() {
        var seen = Set<UUID>()
        for item in items where !seen.contains(item.fileID) {
            seen.insert(item.fileID)
            collapse(item.fileID)
        }
    }
}
