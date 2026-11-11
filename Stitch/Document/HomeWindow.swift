import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Stitch window: what opens when you launch Stitch from the Dock, Applications or Spotlight.
/// Sign & Edit opens PDFs as tabs; Merge & Convert hands files to the menu bar panel, which does that
/// job exactly as it always has.
@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    private let documents: DocumentController

    init(documents: DocumentController, model: AppModel) {
        self.documents = documents
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Stitch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        let root = HomeWindowView(documents: documents, model: model)
            .environment(documents)
            .environment(model)
            .environment(model.prefs)
            .environment(SignatureStore.shared)
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(NSSize(width: 720, height: 560))
        window.center()
        window.setFrameAutosaveName("StitchHomeWindow")
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        documents.refreshRecents()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HomeWindowView: View {
    let documents: DocumentController
    let model: AppModel
    @Environment(SignatureStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stitch").font(.system(size: 26, weight: .bold))
                    Text("Sign, fill and edit PDFs. Merge and convert files.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { SettingsOpener.open(tab: .general) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings (⌘,)")
            }
            HStack(spacing: 14) {
                ActionCard(symbol: "signature", title: "Sign & Edit a PDF",
                           detail: "Sign with Touch ID, fill forms, add text and dates, or fix text in place.",
                           button: "Open PDF…", accepts: { $0.allSatisfy(Self.isPDF) }) {
                    documents.showOpenPanel()
                } onDrop: { urls in
                    documents.open(urls)
                }
                ActionCard(symbol: "doc.on.doc", title: "Merge & Convert",
                           detail: "PDFs, photos, Word, PowerPoint, Excel or CSV into one PDF, or images to JPEG.",
                           button: "Choose Files…", accepts: { !$0.isEmpty }) {
                    chooseForPanel()
                } onDrop: { urls in
                    model.add(urls)
                    model.panel?.open()
                }
            }
            RecentStrip(documents: documents)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: store.signature == nil ? "signature" : "checkmark.seal")
                    .foregroundStyle(.secondary)
                Text(store.signature == nil ? "No signature saved yet" : "Signature saved on this Mac")
                    .foregroundStyle(.secondary)
                Button(store.signature == nil ? "Create one…" : "Change…") { SettingsOpener.open(tab: .signatures) }
                    .buttonStyle(LinkButtonStyle())
                Spacer()
                Text("The menu bar icon still takes drops, as always.")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .frame(width: 720, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }

    private func chooseForPanel() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = FileKind.pickerTypes
        open.prompt = "Add"
        open.message = "Choose PDFs, photos, Word, PowerPoint, Excel or CSV files. They open in the menu bar panel."
        guard let window = NSApp.keyWindow else {
            if open.runModal() == .OK { model.add(open.urls); model.panel?.open() }
            return
        }
        open.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                model.add(open.urls)
                model.panel?.open()
            }
        }
    }
}

private struct ActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let button: String
    let accepts: ([URL]) -> Bool
    let action: () -> Void
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(height: 30)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button(button, action: action)
                    .buttonStyle(PrimaryButtonStyle(height: 30, fullWidth: false))
                Spacer()
                Text(targeted ? "Release to open" : "or drop files here")
                    .font(.system(size: 11))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(targeted ? Color.accentColor.opacity(0.08) : Theme.cell, in: shape)
        .overlay(shape.strokeBorder(targeted ? Color.accentColor : Theme.hairline,
                                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 0.5, dash: targeted ? [5, 4] : [])))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                        _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
                    }) { urls.append(url) }
                }
                if accepts(urls) { onDrop(urls) } else if !urls.isEmpty { NSSound.beep() }
            }
            return true
        }
    }
}

private struct RecentStrip: View {
    let documents: DocumentController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !documents.recents.isEmpty {
                    Button("Clear") { documents.clearRecents() }.buttonStyle(LinkButtonStyle())
                }
            }
            if documents.recents.isEmpty {
                Text("PDFs you open or save in Stitch show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .background(Theme.cell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(documents.recents.prefix(8), id: \.self) { url in
                            RecentTile(url: url) { documents.open(url) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct RecentTile: View {
    let url: URL
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                FileThumbView(url: url, side: 96)
                    .frame(width: 96, height: 112)
                    .background(Theme.cell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor : Theme.hairline, lineWidth: hovering ? 1.5 : 0.5))
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 100)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
