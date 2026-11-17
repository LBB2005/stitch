import PDFKit
import SwiftUI

/// One match of a search, with a little text either side.
struct FindResult: Identifiable {
    let id: Int
    let page: Int
    let selection: PDFSelection
    let before: String
    let match: String
    let after: String
}

struct FindState {
    var query = ""
    var replacement = ""
    var caseSensitive = false
    var results: [FindResult] = []
    var current: Int?
    /// Bumped to focus the search field (⌘F).
    var focus = 0
    var searched = false
}

/// Find (and replace) text in the PDF. Replace goes through Edit Text, so it's undoable and saved.
struct FindPanel: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var ui = ui
        let results = ui.find.results
        PanelScaffold(title: "Find") {
            if !results.isEmpty {
                Text(ui.find.current.map { "\($0 + 1) of \(results.count)" } ?? "\(results.count) found")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    TextField("Find in PDF", text: $ui.find.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit { controller.findNext() }
                        .onExitCommand { controller.clearFind() }
                    Toggle(isOn: $ui.find.caseSensitive) { Text("Aa").font(.system(size: 11, weight: .semibold)) }
                        .toggleStyle(.button)
                        .help("Match case")
                }
                HStack(spacing: 4) {
                    TextField("Replace with", text: $ui.find.replacement)
                        .textFieldStyle(.roundedBorder)
                    ControlGroup {
                        Button { controller.findPrevious() } label: { Image(systemName: "chevron.up") }
                            .help("Previous (⇧⌘G)")
                        Button { controller.findNext() } label: { Image(systemName: "chevron.down") }
                            .help("Next (⌘G)")
                    }
                    .fixedSize()
                    .disabled(results.isEmpty)
                }
                HStack(spacing: 6) {
                    Button("Replace") { controller.replaceCurrent() }
                        .disabled(ui.find.current == nil)
                    Button("Replace All") { controller.replaceAll() }
                        .disabled(results.isEmpty)
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onChange(of: ui.find.query) { controller.findChanged() }
            .onChange(of: ui.find.caseSensitive) { controller.findChanged() }
            .onChange(of: ui.find.focus) { fieldFocused = true }
            .onAppear { fieldFocused = true }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if results.isEmpty {
                            if ui.find.searched, !ui.find.query.isEmpty {
                                PanelNote(text: "No matches for “\(ui.find.query)”.")
                            } else {
                                PanelNote(text: "Type to search the PDF's text. Scans need “Make scans searchable” first.",
                                          symbol: "magnifyingglass")
                            }
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, result in
                            if i == 0 || results[i - 1].page != result.page {
                                PanelSection(title: "Page \(result.page + 1)",
                                             trailing: "\(results.filter { $0.page == result.page }.count)")
                                    .padding(.horizontal, 6)
                            }
                            FindRow(result: result, current: ui.find.current == i) { controller.selectResult(i) }
                                .id(result.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
                .onChange(of: ui.find.current) { _, i in
                    if let i, results.indices.contains(i) { proxy.scrollTo(results[i].id) }
                }
            }
        }
    }
}

private struct FindRow: View {
    let result: FindResult
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        (Text(result.before).foregroundStyle(.secondary)
            + Text(result.match).bold().foregroundStyle(.primary)
            + Text(result.after).foregroundStyle(.secondary))
            .font(.system(size: 11))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.accentColor.opacity(0.14)
                : hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
