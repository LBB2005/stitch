import SwiftUI

/// Your saved details as pills to drag onto the page or a field, and which of this PDF's fields Fill My
/// Info would fill, before you press it.
struct MyInfoPanel: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui
    @Environment(SignatureStore.self) private var store

    var body: some View {
        let profile = store.profile
        let addresses = profile.addresses.filter { !$0.isEmpty }
        PanelScaffold(title: "My Info") {
            Button("Edit…") { SettingsOpener.open(tab: .yourInfo) }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Edit My Info in Settings")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if profile.isEmpty {
                        PanelNote(text: "No details saved yet. Add your name, email, phone and addresses in Settings → Your Info.",
                                  symbol: "person.text.rectangle")
                        Button("Edit My Info…") { SettingsOpener.open(tab: .yourInfo) }
                            .frame(maxWidth: .infinity)
                    } else {
                        RevealGate(controller: controller, reason: "show your details") {
                            VStack(alignment: .leading, spacing: 8) {
                                if addresses.count > 1 {
                                    Picker("Address", selection: Binding(get: { min(ui.addressIndex, addresses.count - 1) },
                                                                         set: { controller.chooseAddress($0) })) {
                                        ForEach(addresses.indices, id: \.self) { i in Text(addresses[i].label).tag(i) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                }
                                FlowLayout(spacing: 6) {
                                    ForEach(items(profile), id: \.self) { item in
                                        DetailPill(item: item, address: addresses.isEmpty ? nil : min(ui.addressIndex, addresses.count - 1),
                                                   value: profile.value(item, address: addresses.isEmpty ? nil : addresses[min(ui.addressIndex, addresses.count - 1)]),
                                                   controller: controller)
                                    }
                                }
                                Text("Drag a detail onto a form field to fill it, or anywhere on the page as text.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        matches
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .onAppear { controller.refreshFieldMatches() }
    }

    private func items(_ profile: Profile) -> [ProfileItem] {
        let order: [ProfileItem] = [.fullName, .email, .phone, .studentID, .dateOfBirth, .fullAddress, .street, .city, .zip]
        return order.filter { !profile.value($0, address: nil).isEmpty }
    }

    @ViewBuilder private var matches: some View {
        let toFill = ui.fieldMatches.filter { !$0.alreadyFilled }
        PanelSection(title: "Matching fields here", trailing: ui.fieldMatches.isEmpty ? nil : "\(ui.fieldMatches.count)")
        if !ui.hasFormFields {
            Text("This PDF has no form fields. Drag details onto the page instead.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if ui.fieldMatches.isEmpty {
            Text("None of this PDF's fields match your details.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(ui.fieldMatches) { match in
                MatchRow(match: match, revealed: ui.revealed, controller: controller)
            }
            Button {
                controller.fillMatchingFields(address: controller.chosenAddress)
            } label: {
                Text(toFill.isEmpty ? "All Matching Fields Filled" : "Fill \(toFill.count) Matching Field\(toFill.count == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(toFill.isEmpty)
            .help("Fill My Info (⌥⌘F)")
            .padding(.top, 4)
        }
    }
}

private struct DetailPill: View {
    let item: ProfileItem
    let address: Int?
    let value: String
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        let place = PlaceItem.profile(item, address: item.isAddress ? address : nil)
        let armed = ui.tool == .place(place)
        VStack(alignment: .leading, spacing: 0) {
            Text(item.label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(armed ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(armed ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: armed ? 1.5 : 0.5))
        .contentShape(Capsule())
        .onTapGesture { controller.arm(place) }
        .onDrag { place.itemProvider() }
        .help("Drag onto a field or the page, or click and then click the page")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.place(place) }
    }
}

private struct MatchRow: View {
    let match: AutoFill.FieldMatch
    let revealed: Bool
    let controller: DocumentWindowController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: match.alreadyFilled ? "checkmark.circle" : "arrow.right.circle")
                .foregroundStyle(match.alreadyFilled ? Color.secondary : Color.accentColor)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 0) {
                Text(match.field.toolTip?.isEmpty == false ? match.field.toolTip! : match.field.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(match.alreadyFilled ? "Already filled" : revealed ? match.value : match.item.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Text("p. \(match.field.page + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            controller.pdfView.outline(inside ? match.field.rect : nil, page: match.field.page)
        }
        .onTapGesture { controller.goTo(rect: match.field.rect, page: match.field.page) }
    }
}

/// Wraps its children onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
