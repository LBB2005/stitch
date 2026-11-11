import SwiftUI

/// The document window's content: the PDF, with banners and the text-box format bar above it and the
/// "Saved …" toast below.
struct DocumentView: View {
    let controller: DocumentWindowController
    @Environment(DocumentUI.self) private var ui

    var body: some View {
        PDFCanvas(view: controller.pdfView)
            .ignoresSafeArea(.container, edges: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(ui.banners, id: \.self) { banner in
                        DocumentBanner(banner: banner) { controller.dismissBanner(banner) }
                    }
                    if let box = ui.selectedTextBox {
                        TextFormatBar(box: box, controller: controller)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, ui.banners.isEmpty && ui.selectedTextBox == nil ? 0 : 8)
                .animation(.snappy(duration: 0.2), value: ui.selectedTextBox != nil)
            }
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
}

private struct DocumentBanner: View {
    let banner: DocumentUI.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.isWarning ? Color.orange : Color.accentColor)
            Text(banner.text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Size, bold, color and white background for the selected text box.
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
