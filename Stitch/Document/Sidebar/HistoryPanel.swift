import SwiftUI

/// Every change, oldest first. Clicking a row undoes or redoes until the document is back there.
struct HistoryPanel: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        let log = controller.session.history
        PanelScaffold(title: "History") {
            Text(ui.isDirty ? "Not saved" : "Saved")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(ui.isDirty ? Color.accentColor : .secondary)
                .background(Capsule().fill(ui.isDirty ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        HistoryRow(symbol: "doc", title: "Opened the original", detail: nil, state: log.cursor == 0 ? .now : .applied,
                                   controller: controller, entry: nil) {
                            controller.goToHistory(0)
                        }
                        ForEach(log.rows()) { row in
                            switch row {
                            case .step(let i):
                                step(log, i)
                            case .group(let range):
                                HistoryGroupRow(range: range, log: log, controller: controller)
                            case .save(let save):
                                Label("Saved copy: \(save.name)", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                                    .lineLimit(1)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                            }
                        }
                        if ui.typedFields > 0 {
                            Label("Typed in \(ui.typedFields) form field\(ui.typedFields == 1 ? "" : "s")", systemImage: "character.cursor.ibeam")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .help("Typing straight into the PDF's fields isn't an undo step; it's saved with the copy.")
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: log.entries.count) { proxy.scrollTo("end") }
            }
            Divider()
            HStack {
                Button("Revert to Original…") { controller.revertToOriginal() }
                    .disabled(!log.canUndo)
                Spacer()
            }
            .controlSize(.small)
            .padding(10)
        }
    }

    private func step(_ log: HistoryLog, _ i: Int) -> some View {
        let entry = log.entries[i]
        let state: HistoryRow.State = i == log.cursor - 1 ? .now : i < log.cursor ? .applied : .undone
        return HistoryRow(symbol: entry.symbol, title: entry.summary,
                          detail: entry.page.map { "p. \($0 + 1)" }, state: state, controller: controller, entry: entry) {
            controller.goToHistory(i + 1)
        }
    }
}

private struct HistoryRow: View {
    enum State { case applied, now, undone }

    let symbol: String
    let title: String
    let detail: String?
    let state: State
    let controller: DocumentWindowController
    let entry: HistoryEntry?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(state == .now ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: state == .now ? .semibold : .regular))
                .foregroundStyle(state == .undone ? .tertiary : .primary)
                .lineLimit(2)
            Spacer(minLength: 2)
            switch state {
            case .now:
                Text("Now").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            case .undone:
                Text("⇧⌘Z").font(.system(size: 9)).foregroundStyle(.tertiary)
            case .applied:
                if let detail { Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(state == .now ? Color.accentColor.opacity(0.1)
            : hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { inside in
            hovering = inside
            controller.outlineHistory(inside ? entry : nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// "5 text edits on p. 2": one row that opens into its steps.
private struct HistoryGroupRow: View {
    let range: Range<Int>
    let log: HistoryLog
    let controller: DocumentWindowController
    @State private var open = false

    var body: some View {
        let entries = Array(log.entries[range])
        let page = entries.first?.page.map { " on p. \($0 + 1)" } ?? ""
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text("\(entries.count) text edits\(page)")
                        .font(.system(size: 12))
                        .foregroundStyle(range.lowerBound >= log.cursor ? .tertiary : .primary)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(range, id: \.self) { i in
                    let entry = log.entries[i]
                    let state: HistoryRow.State = i == log.cursor - 1 ? .now : i < log.cursor ? .applied : .undone
                    HistoryRow(symbol: entry.symbol, title: entry.summary, detail: nil, state: state,
                               controller: controller, entry: entry) { controller.goToHistory(i + 1) }
                        .padding(.leading, 14)
                }
            }
        }
    }
}

extension HistoryEntry {
    var symbol: String {
        switch kind {
        case .signature: "signature"
        case .initials: "character.textbox"
        case .text: "textformat"
        case .textEdit: "character.cursor.ibeam"
        case .delete: "trash"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .format: "bold.italic.underline"
        case .fill: "person.text.rectangle"
        case .other: "circle"
        }
    }
}
