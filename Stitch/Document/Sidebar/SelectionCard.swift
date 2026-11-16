import SwiftUI

/// The selected item's settings, pinned at the bottom of the sidebar: text boxes get size, bold, ink and
/// white background; signatures and initials get size. Every change is one undo step.
struct SelectionCard: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch ui.selection {
            case .text(let box):
                header("Text Box", symbol: "textformat")
                TextBoxControls(box: box, controller: controller)
            case .signing(let overlay):
                header(overlay.kindLabel, symbol: "signature")
                SigningControls(overlay: overlay, controller: controller)
            case nil:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ title: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(role: .destructive) { controller.deleteSelection() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete (⌫)")
                .accessibilityLabel("Delete")
        }
    }
}

struct TextBoxControls: View {
    let box: TextBox
    let controller: DocumentWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Button { controller.updateSelectedTextBox { $0.fontSize = max($0.fontSize - 1, 4) } } label: {
                        Image(systemName: "minus").frame(width: 22, height: 20)
                    }
                    .help("Smaller")
                    Text("\(Int(box.fontSize.rounded())) pt")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 42)
                    Button { controller.updateSelectedTextBox { $0.fontSize = min($0.fontSize + 1, 144) } } label: {
                        Image(systemName: "plus").frame(width: 22, height: 20)
                    }
                    .help("Larger")
                }
                .buttonStyle(.borderless)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Toggle(isOn: Binding(get: { box.bold }, set: { v in controller.updateSelectedTextBox { $0.bold = v } })) {
                    Image(systemName: "bold")
                }
                .toggleStyle(.button)
                .help("Bold")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Ink").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(TextBox.Ink.allCases, id: \.self) { ink in
                        Button { controller.updateSelectedTextBox { $0.ink = ink } } label: {
                            Circle()
                                .fill(Color(cgColor: ink.cgColor))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                .padding(2)
                                .overlay(Circle().strokeBorder(box.ink == ink ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(ink.label)
                        .accessibilityLabel("\(ink.label) ink")
                    }
                }
                Spacer(minLength: 0)
            }
            Toggle("White background", isOn: Binding(get: { box.whiteBackground },
                                                      set: { v in controller.updateSelectedTextBox { $0.whiteBackground = v } }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Cover what's underneath, e.g. to retype on a scan")
        }
    }
}

private struct SigningControls: View {
    let overlay: Overlay
    let controller: DocumentWindowController
    @State private var scale: Double = 1
    @State private var base: Overlay?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
            Slider(value: $scale, in: 0.4...2.5) { editing in
                if editing {
                    base = overlay
                } else if let base {
                    controller.resize(base, by: scale, commit: true)
                    self.base = nil
                    scale = 1
                }
            }
            .onChange(of: scale) { _, s in
                if let base { controller.resize(base, by: s, commit: false) }
            }
            .accessibilityLabel("Size")
            Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
        }
        .onChange(of: overlay.id) { scale = 1; base = nil }
    }
}
