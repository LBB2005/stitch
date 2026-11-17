import AppKit
import SwiftUI

/// Your signature, initials, today's date and a text box, as cards to drag onto the page (or click, then
/// click the page), and the signing items already on this document.
struct SignPanel: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui
    @Environment(SignatureStore.self) private var store

    var body: some View {
        let signing = controller.session.overlays.filter(\.isSigning)
        PanelScaffold(title: "Sign") {
            Menu {
                Button("Change Signature…") { controller.createSignature(initials: false) }
                Button("Change Initials…") { controller.createSignature(initials: true) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change your signature or initials")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    RevealGate(controller: controller, reason: "show your signature") {
                        VStack(spacing: 8) {
                            if let sig = store.signature {
                                PlaceCard(item: .signature, title: "Signature", shortcut: "⌥⌘S", controller: controller) {
                                    SignatureImage(signature: sig, height: 38)
                                }
                            } else {
                                CreateCard(title: "Create Signature…") { controller.createSignature(initials: false) }
                            }
                            HStack(spacing: 8) {
                                if let initials = store.initials {
                                    PlaceCard(item: .initials, title: "Initials", shortcut: "⌥⌘I", controller: controller) {
                                        SignatureImage(signature: initials, height: 26)
                                    }
                                } else {
                                    CreateCard(title: "Create Initials…") { controller.createSignature(initials: true) }
                                }
                                PlaceCard(item: .date, title: "Today", shortcut: "⇧⌘D", controller: controller) {
                                    Text(controller.formattedDate)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(cgColor: TextBox.Ink.black.cgColor))
                                }
                            }
                        }
                    }
                    PlaceCard(item: .textBox, title: "Text Box", shortcut: "⌥⌘T", controller: controller) {
                        Text("Type anything")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(cgColor: TextBox.Ink.black.cgColor).opacity(0.55))
                    }
                    Text("Drag onto the page, or click a card and then the page. Dropped on a signature line, it fits the line.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PanelSection(title: "On this document", trailing: signing.isEmpty ? nil : "\(signing.count)")
                    if signing.isEmpty {
                        Text("Nothing signed yet").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    ForEach(signing) { overlay in
                        Button {
                            controller.selectOverlay(overlay.id)
                        } label: {
                            HStack {
                                Image(systemName: overlay.textBox == nil ? "signature" : "textformat")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(overlay.kindLabel).font(.system(size: 12))
                                Spacer()
                                Text("p. \(overlay.page + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

extension Overlay {
    var kindLabel: String {
        switch kind {
        case .signature: "Signature"
        case .initials: "Initials"
        case .text(let box): box.text.isEmpty ? "Text box" : box.text
        }
    }
}

/// A draggable card: a white "paper" preview of what will be placed.
struct PlaceCard<Preview: View>: View {
    let item: PlaceItem
    let title: String
    let shortcut: String?
    let controller: DocumentWindowController
    @ViewBuilder var preview: () -> Preview
    @Environment(DocumentUI.self) private var ui
    @State private var hovering = false

    var body: some View {
        let armed = ui.tool == .place(item)
        VStack(alignment: .leading, spacing: 4) {
            preview()
                .frame(maxWidth: .infinity, minHeight: 34)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 2)
                if let shortcut { Text(shortcut).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(armed ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(armed ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.arm(item) }
        .onDrag { item.itemProvider() }
        .help("Drag onto the page, or click and then click the page")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.place(item) }
    }
}

private struct CreateCard: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A saved signature drawn as an image.
struct SignatureImage: View {
    let signature: Signature
    let height: CGFloat

    var body: some View {
        var size = signature.size(height: height)
        if size.width > 180 { size = CGSize(width: 180, height: 180 / signature.aspect) }
        let sig = signature
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            sig.draw(in: ctx, size: rect.size)
            return true
        }
        return Image(nsImage: image).frame(width: size.width, height: size.height)
    }
}
