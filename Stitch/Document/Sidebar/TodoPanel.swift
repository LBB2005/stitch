import SwiftUI

/// What's left to sign, initial, date and fill in, with notes about the document at the top.
struct TodoPanel: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        let items = ui.todo
        let done = items.filter(\.done).count
        let next = items.first { !$0.done }
        let openInitials = items.filter { $0.kind == .initials && !$0.done }
        PanelScaffold(title: "To-Do") {
            if !items.isEmpty {
                Text("\(done) of \(items.count) done").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ui.banners, id: \.self) { banner in
                        TodoNote(banner: banner) { controller.dismissBanner(banner) }
                    }
                    if items.isEmpty {
                        PanelNote(text: "Nothing to sign or fill in that Stitch can spot. Use Sign and My Info to add what you need.",
                                  symbol: "checklist")
                    } else {
                        ProgressView(value: Double(done), total: Double(max(items.count, 1)))
                            .tint(done == items.count ? .green : .accentColor)
                            .padding(.bottom, 4)
                        if let next {
                            NextRow(item: next, controller: controller)
                        } else {
                            Label("All done. Save a copy when you're ready (⌘S).", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                                .padding(.vertical, 6)
                        }
                        if openInitials.count >= 2 {
                            Button {
                                controller.initialAll()
                            } label: {
                                Label("Initial All \(openInitials.count) Spots", systemImage: "signature")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.regular)
                            .padding(.top, 2)
                        }
                        let signing = items.filter(\.isSigning)
                        if !signing.isEmpty {
                            PanelSection(title: "Sign", trailing: "\(signing.filter(\.done).count)/\(signing.count)")
                            ForEach(signing) { TodoRow(item: $0, isNext: $0.id == next?.id, controller: controller) }
                        }
                        let fields = items.filter { !$0.isSigning }
                        if !fields.isEmpty {
                            PanelSection(title: "Fill in", trailing: "\(fields.filter(\.done).count)/\(fields.count)")
                            ForEach(fields) { TodoRow(item: $0, isNext: $0.id == next?.id, controller: controller) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

private struct TodoNote: View {
    let banner: DocumentUI.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: banner.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.isWarning ? Color.orange : Color.accentColor)
                .font(.system(size: 12))
            Text(banner.text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill((banner.isWarning ? Color.orange : Color.accentColor).opacity(0.1)))
        .padding(.bottom, 4)
    }
}

private struct NextRow: View {
    let item: TodoItem
    let controller: DocumentWindowController

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Next").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text(item.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("Page \(item.page + 1)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let verb = item.verb {
                Button(verb) { controller.fill(item) }
                    .controlSize(.small)
            }
            Button("Go") { controller.goTo(item) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let isNext: Bool
    let controller: DocumentWindowController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.done ? "checkmark.circle.fill" : item.symbol)
                .foregroundStyle(item.done ? Color.green : isNext ? Color.accentColor : Color.secondary)
                .font(.system(size: 13))
                .frame(width: 16)
            Text(item.label)
                .font(.system(size: 12))
                .foregroundStyle(item.done ? .secondary : .primary)
                .strikethrough(item.done, color: .secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering, !item.done, let verb = item.verb {
                Button(verb) { controller.fill(item) }
                    .controlSize(.mini)
            }
            Text("p. \(item.page + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { controller.goTo(item) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), page \(item.page + 1), \(item.done ? "done" : "to do")")
        .accessibilityAddTraits(.isButton)
    }
}

extension TodoItem {
    var symbol: String {
        switch kind {
        case .signature: "signature"
        case .initials: "character.textbox"
        case .date: "calendar"
        case .field: "character.cursor.ibeam"
        }
    }

    /// The button that fills it in place.
    var verb: String? {
        switch kind {
        case .signature: "Sign"
        case .initials: "Initial"
        case .date: "Date"
        case .field: nil
        }
    }
}
