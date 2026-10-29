import SwiftUI

/// While a job runs: what's happening, how far along, Cancel.
struct WorkingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            if let fraction = model.progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            } else {
                ProgressView().controlSize(.regular)
            }
            Text(model.progress.message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: model.progress.message)
            Button("Cancel") { model.cancelJob() }
                .buttonStyle(SecondaryButtonStyle(fullWidth: false))
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 32)
    }
}

/// Screen 4: the result, ready to drag into a chat.
struct DoneView: View {
    let controller: PanelController
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        if let result = model.result {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: appeared)
                VStack(spacing: 3) {
                    Text(result.title).font(.system(size: 15, weight: .semibold))
                    Text(detail(result)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                notes(result)
                ResultTile(urls: result.outputs, controller: controller)
                HStack(spacing: 8) {
                    Button("Start Over") { model.startOver() }
                        .buttonStyle(SecondaryButtonStyle(height: 30))
                    Button("Reveal in Finder") { model.reveal() }
                        .buttonStyle(PrimaryButtonStyle(height: 30))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(EdgeInsets(top: 20, leading: 14, bottom: 14, trailing: 14))
            .onAppear { appeared = true }
        }
    }

    private func detail(_ result: JobResult) -> String {
        var parts: [String] = []
        if let n = result.pageCount { parts.append(n == 1 ? "1 page" : "\(n) pages") }
        parts.append(ByteSize.string(result.bytes))
        if result.searchable { parts.append("searchable") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func notes(_ result: JobResult) -> some View {
        VStack(spacing: 6) {
            if let shrink = result.shrink {
                Label("Shrunk \(ByteSize.string(shrink.before)) → \(ByteSize.string(shrink.after)) · images at \(shrink.dpi) DPI",
                      systemImage: "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(.secondary)
            }
            if let over = result.overLimit {
                VStack(spacing: 8) {
                    Text("Still \(ByteSize.string(over.bestBytes)) with images at 150 DPI — over your \(ByteSize.string(over.target)) limit. Stitch won't lower the quality further.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Split into Parts Under \(ByteSize.string(over.target))") { model.splitIntoParts() }
                        .buttonStyle(SecondaryButtonStyle(fullWidth: false))
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let note = result.note {
                Text(note).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !result.skipped.isEmpty {
                Text("Left out: " + result.skipped.joined(separator: ", "))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
    }
}

/// The finished file(s) as a tile you can drag into ChatGPT, Claude, Mail or Finder.
private struct ResultTile: View {
    let urls: [URL]
    let controller: PanelController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if urls.count > 1, let second = urls.dropFirst().first {
                    FileThumbView(url: second, side: 34).offset(x: 4, y: -3).opacity(0.6)
                }
                if let first = urls.first { FileThumbView(url: first, side: 34) }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(folderName) · drag \(urls.count == 1 ? "me" : "them") into a chat")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "hand.draw")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(hovering ? Theme.hover : Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            FileDragSource(urls: urls) { dragging in controller.isDraggingOut = dragging }
        }
        .onHover { hovering = $0 }
        .help("Drag into ChatGPT, Claude, Mail or Finder · double-click to open")
    }

    private var title: String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    }

    private var folderName: String {
        guard let folder = urls.first?.deletingLastPathComponent() else { return "" }
        return FileManager.default.displayName(atPath: folder.path)
    }
}
