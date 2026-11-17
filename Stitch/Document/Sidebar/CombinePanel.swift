import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - the window's side

extension DocumentWindowController {
    /// The Combine panel's merge or convert. Its own list (the menu bar panel's queue is never touched),
    /// the same Pipeline and settings.
    var combine: MergeJob {
        if let combineJob { return combineJob }
        let job = MergeJob(prefs: prefs)
        job.onFinished = { [weak self] result in self?.combineFinished(result) }
        combineJob = job
        return job
    }

    /// What "Add This PDF" adds: the copy this tab saved, or else the original.
    var combineCurrentFile: URL { session.savedCopy ?? session.original }

    func combineAdd(_ urls: [URL]) {
        withAnimation(.snappy(duration: 0.25)) { combine.add(urls) }
    }

    func combineChooseFiles() {
        guard let window else { return }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = FileKind.pickerTypes
        open.prompt = combine.isEmpty ? "Choose" : "Add"
        open.message = "PDFs, photos, Word, PowerPoint, Excel or CSV files to merge or convert. The originals are never changed."
        open.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.combineAdd(open.urls)
            }
        }
    }

    func combineClear() {
        withAnimation(.snappy(duration: 0.25)) { combine.clear() }
    }

    /// One PDF made: it opens in a new tab beside this one, ready to sign. Anything else: a toast.
    private func combineFinished(_ result: JobResult) {
        let folder = result.outputs.first.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path) } ?? ""
        if result.outputs.count == 1, let url = result.outputs.first, url.pathExtension.lowercased() == "pdf",
           result.overLimit == nil {
            let pages = result.pageCount.map { $0 == 1 ? "1 page" : "\($0) pages" }
            let summary = [result.title, pages, "saved in \(folder)"].compactMap { $0 }.joined(separator: " · ")
            documents?.open(url)
            documents?.current?.showToast(summary, reveal: url)
        } else if let first = result.outputs.first {
            showToast("\(result.title) · saved in \(folder)", reveal: first)
        }
    }
}

// MARK: - the panel

/// ⌘6: merge or convert files without leaving the PDF you're in. Drop files (or this PDF) on the list,
/// reorder, Merge. A merged PDF opens in a new tab beside this one.
struct CombinePanel: View {
    let controller: DocumentWindowController
    @Bindable var job: MergeJob
    @State private var targeted = false

    var body: some View {
        PanelScaffold(title: "Combine") {
            if !job.isEmpty, !job.isWorking, job.phase != .done {
                Button("Clear") { controller.combineClear() }
                    .buttonStyle(LinkButtonStyle())
                    .font(.system(size: 11.5))
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if job.isEmpty {
                    dropWell
                } else {
                    header
                    list
                    status
                }
                addButtons
                Spacer(minLength: 0)
                if !job.isEmpty { footer }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                        _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
                    }) { urls.append(url) }
                }
                if !urls.isEmpty, !job.isWorking { controller.combineAdd(urls) }
            }
            return !job.isWorking
        }
        .overlay {
            if targeted, !job.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.25), value: job.phase)
        .animation(.snappy(duration: 0.25), value: job.files.map(\.id))
    }

    // Empty: a drop well that says what it does.
    private var dropWell: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: 8) {
            Image(systemName: targeted ? "arrow.down.doc" : "arrow.triangle.merge")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(targeted ? "Release to add" : "Drop files to merge")
                .font(.system(size: 13, weight: .semibold))
            Text("PDFs, photos, Word, PowerPoint, Excel or CSV. One PDF comes out and opens in a new tab.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.08) : Theme.cell, in: shape)
        .overlay(shape.strokeBorder(targeted ? Color.accentColor : Theme.hairline,
                                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 0.5, dash: targeted ? [5, 4] : [])))
        .animation(.snappy(duration: 0.2), value: targeted)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if job.imageCount > 0, job.phase != .done {
                Picker("Output", selection: $job.output) {
                    if job.canMerge { Text("Merge into one PDF").tag(MergeJob.Output.merge) }
                    if job.canConvertToJPEG { Text("Convert to JPEG").tag(MergeJob.Output.jpeg) }
                    if job.canConvertToPDF { Text("Convert images to PDF").tag(MergeJob.Output.pdf) }
                }
                .labelsHidden()
                .controlSize(.small)
                .disabled(job.isWorking)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(job.files) { file in
                CombineRow(file: file, working: job.isWorking) {
                    withAnimation(.snappy(duration: 0.2)) { job.remove(file) }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            }
            .onMove { job.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: min(CGFloat(job.files.count) * 40, 40 * 7.5))
        .disabled(job.isWorking || job.phase == .done)
    }

    @ViewBuilder private var status: some View {
        if let note = job.note, job.phase == .ready {
            Label(note, systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if case .failed(let message) = job.phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if job.isWorking {
            VStack(alignment: .leading, spacing: 5) {
                if let fraction = job.progress.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(job.progress.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .transition(.opacity)
        }
        if job.phase == .done, let result = job.result {
            CombineDone(result: result)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var addButtons: some View {
        if !job.isWorking, job.phase != .done {
            let current = controller.combineCurrentFile
            let alreadyIn = job.files.contains { $0.url.standardizedFileURL == current.standardizedFileURL }
            VStack(alignment: .leading, spacing: 6) {
                Button { controller.combineChooseFiles() } label: {
                    Label("Add Files…", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 28, fullWidth: true))
                if !alreadyIn {
                    Button { controller.combineAdd([current]) } label: {
                        Label("Add \(current.lastPathComponent)", systemImage: "doc.badge.plus")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28, fullWidth: true))
                    .help(controller.session.savedCopy == nil && controller.ui.isDirty
                          ? "Adds the original. Save Copy first to merge your changes."
                          : "Adds this PDF to the list")
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if job.phase == .done {
                HStack(spacing: 8) {
                    if let outputs = job.result?.outputs, !outputs.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                            .buttonStyle(SecondaryButtonStyle(height: 30, fullWidth: true))
                    }
                    Button("Done") { controller.combineClear() }
                        .buttonStyle(PrimaryButtonStyle(height: 30, fullWidth: true))
                }
            } else if job.isWorking {
                Button("Cancel") { job.cancel() }
                    .buttonStyle(SecondaryButtonStyle(height: 30, fullWidth: true))
            } else {
                Text(job.settingsSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Change in Settings…") { SettingsOpener.open(tab: .general) }
                    .buttonStyle(LinkButtonStyle())
                    .font(.system(size: 11))
                Button(job.actionTitle) { job.run() }
                    .buttonStyle(PrimaryButtonStyle(height: 32, fullWidth: true))
                    .disabled(!job.canRun)
            }
        }
    }

    private var caption: String {
        if job.output == .merge {
            var parts = [job.orderLabel]
            if let pages = job.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
            return parts.joined(separator: " · ")
        }
        return "\(job.files.count) file\(job.files.count == 1 ? "" : "s")"
    }
}

private struct CombineRow: View {
    let file: InputFile
    let working: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FileThumbView(url: file.url, side: 24)
                .frame(width: 24, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering && !working ? 0.85 : 0)
            .help("Remove from the list (the file isn't touched)")
            .accessibilityLabel("Remove \(file.name)")
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(Theme.cell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var meta: String {
        switch file.kind {
        case .pdf:
            let n = file.pageCount ?? 0
            return "\(n) page\(n == 1 ? "" : "s")"
        case .image: return "\(file.url.pathExtension.uppercased()) image"
        case .csv: return "CSV table"
        case .word: return OfficeConverter.isInstalled ? "Word" : "Word · needs LibreOffice"
        case .powerpoint: return OfficeConverter.isInstalled ? "PowerPoint" : "PowerPoint · needs LibreOffice"
        case .excel: return OfficeConverter.isInstalled ? "Excel" : "Excel · needs LibreOffice"
        }
    }
}

private struct CombineDone: View {
    let result: JobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(result.title, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.green)
            if let first = result.outputs.first {
                Text(result.outputs.count == 1 ? first.lastPathComponent : "\(result.outputs.count) files")
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .onDrag { NSItemProvider(contentsOf: first) ?? NSItemProvider() }
                    .help("Drag the file into a chat or a folder")
                Text("\(ByteSize.string(result.bytes)) · in \(FileManager.default.displayName(atPath: first.deletingLastPathComponent().path))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let over = result.overLimit {
                Text("Still over \(ByteSize.string(over.target)) at the lowest quality. Split it from the menu bar panel if you need parts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !result.skipped.isEmpty {
                Text("Left out: " + result.skipped.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
