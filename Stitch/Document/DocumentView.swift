import SwiftUI

/// The PDF, with the Edit Text pill above it and the "Saved …" toast below. Notes about the document
/// live in the To-Do panel, so nothing covers the page. Folded, the rail floats over the leading edge and
/// the selected text box's format bar floats above the page.
struct DocumentView: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        PDFCanvas(view: controller.pdfView)
            .ignoresSafeArea(.container, edges: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    if let pill = pill {
                        ToolPill(text: pill) { controller.pdfView.tool = .select }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if ui.isFolded, let box = ui.selectedTextBox {
                        TextFormatBar(box: box, controller: controller)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, pill == nil && !(ui.isFolded && ui.selectedTextBox != nil) ? 0 : 8)
                .animation(.snappy(duration: 0.2), value: ui.selectedTextBox != nil)
                .animation(.snappy(duration: 0.2), value: pill)
            }
            .overlay(alignment: .topLeading) {
                if ui.isFolded {
                    RailView(controller: controller, floating: true)
                        .padding(.leading, 12)
                        .padding(.top, 10)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: ui.isFolded)
            .overlay(alignment: .bottom) {
                if let toast = ui.toast {
                    ToastView(toast: toast)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .overlay(alignment: .topTrailing) {
                if ui.isSaving {
                    ProgressView().controlSize(.small).padding(10)
                }
            }
            .animation(.snappy(duration: 0.25), value: ui.toast)
    }

    private var pill: String? {
        switch ui.tool {
        case .editText: "Editing text: click any text in the PDF to change it"
        case .textBox: "Click where the text should go"
        case .place(let item): "Click the page to place \(item.label == "Date" ? "the date" : item.label)"
        case .select: nil
        }
    }
}

/// Says which tool is on, with a Done button (Esc does the same).
private struct ToolPill: View {
    let text: String
    let done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12))
            // Esc is handled by the PDF view (it also cancels an inline edit first), not here.
            Button("Done", action: done)
                .controlSize(.small)
                .help("Done (esc)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// Size, bold, color and white background for the selected text box, floating above the page while
/// the sidebar is folded (open, they're in the sidebar's selection card).
private struct TextFormatBar: View {
    let box: TextBox
    let controller: DocumentWindowController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat").foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Button { controller.updateSelectedTextBox { $0.fontSize = max($0.fontSize - 1, 4) } } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Smaller")
                Text("\(Int(box.fontSize.rounded())) pt")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 40)
                Button { controller.updateSelectedTextBox { $0.fontSize = min($0.fontSize + 1, 144) } } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Larger")
            }
            Divider().frame(height: 16)
            Toggle(isOn: Binding(get: { box.bold }, set: { v in controller.updateSelectedTextBox { $0.bold = v } })) {
                Image(systemName: "bold")
            }
            .toggleStyle(.button)
            .help("Bold")
            Picker("Color", selection: Binding(get: { box.ink }, set: { v in controller.updateSelectedTextBox { $0.ink = v } })) {
                ForEach(TextBox.Ink.allCases, id: \.self) { ink in
                    Text(ink.label).tag(ink)
                }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("White background", isOn: Binding(get: { box.whiteBackground },
                                                      set: { v in controller.updateSelectedTextBox { $0.whiteBackground = v } }))
                .toggleStyle(.checkbox)
                .help("Cover what's underneath, e.g. to retype on a scan")
            Divider().frame(height: 16)
            Button(role: .destructive) { controller.deleteSelection() } label: { Image(systemName: "trash") }
                .help("Delete (⌫)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

private struct ToastView: View {
    let toast: DocumentUI.Toast

    var body: some View {
        HStack(spacing: 8) {
            if toast.reveal != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(toast.text).font(.system(size: 12)).lineLimit(2)
            if let url = toast.reveal {
                Text("·").foregroundStyle(.tertiary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
