import AppKit
import Observation

/// A merge or convert started in the Stitch window (dropped on the start canvas, or Merge Files… from
/// ⌘K). It runs the same `Pipeline` as the menu bar panel but keeps its own list, so the panel's queue
/// is never touched. Settings (save folder, shrink, OCR, location) are the shared ones.
@MainActor
@Observable
final class MergeJob {
    enum Output: Hashable {
        case merge, jpeg, pdf
    }

    enum Phase: Equatable {
        case ready, working, done, failed(String)
    }

    private(set) var files: [InputFile] = []
    var output: Output = .merge
    private(set) var phase: Phase = .ready
    private(set) var progress = JobProgress(message: "", fraction: nil)
    private(set) var result: JobResult?
    /// Smart order was found (and applied) for these names.
    private(set) var series: SeriesInfo?
    /// Files that couldn't be added ("Skipped 1 file Stitch can't use").
    private(set) var note: String?

    /// A finished job with exactly one PDF opens it in the window; anything else shows Done.
    @ObservationIgnored var onFinished: ((JobResult) -> Void)?
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var orderEdited = false

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    var isEmpty: Bool { files.isEmpty }
    var isWorking: Bool { phase == .working }
    var imageCount: Int { files.filter(\.kind.isImage).count }
    var canMerge: Bool {
        files.contains { $0.kind.isPDF || $0.kind.isImage || $0.kind == .csv || ($0.kind.isOffice && OfficeConverter.isInstalled) }
    }
    var canConvertToJPEG: Bool { files.contains { $0.kind == .image(jpeg: false) } }
    var canConvertToPDF: Bool { files.contains(where: \.kind.isImage) }
    var allPDFs: Bool { !files.isEmpty && files.allSatisfy(\.kind.isPDF) }
    var pageCount: Int? {
        let counts = files.map(\.pageCount)
        return counts.contains(nil) ? nil : counts.reduce(0) { $0 + ($1 ?? 0) }
    }

    var orderLabel: String {
        if orderEdited { return "Your order" }
        return series?.label ?? "Order added"
    }

    var title: String {
        switch output {
        case .merge: files.count == 1 ? "Make a PDF of 1 file" : "Merge \(files.count) files"
        case .jpeg: "Convert \(imageCount == 1 ? "1 image" : "\(imageCount) images") to JPEG"
        case .pdf: prefs.combineImages ? "Combine \(imageCount == 1 ? "1 image" : "\(imageCount) images") into a PDF"
                                       : "Convert \(imageCount == 1 ? "1 image" : "\(imageCount) images") to PDF"
        }
    }

    var actionTitle: String {
        switch output {
        case .merge: files.count == 1 ? "Make PDF" : "Merge \(files.count) Files"
        case .jpeg: "Convert to JPEG"
        case .pdf: "Convert to PDF"
        }
    }

    var canRun: Bool {
        guard phase != .working else { return false }
        switch output {
        case .merge: return canMerge
        case .jpeg: return canConvertToJPEG
        case .pdf: return canConvertToPDF
        }
    }

    var destinationName: String { FileManager.default.displayName(atPath: prefs.saveFolder.path) }

    /// One line about what Settings will do to the result.
    var settingsSummary: String {
        var parts = ["Saves to \(destinationName)"]
        if output != .jpeg, prefs.shrink { parts.append("shrinks to under \(ByteSize.string(prefs.targetBytes))") }
        if output != .jpeg, prefs.ocr { parts.append("makes scans searchable") }
        if output == .jpeg, prefs.stripLocation { parts.append("removes location") }
        return parts.joined(separator: " · ")
    }

    // MARK: files

    func add(_ urls: [URL]) {
        guard phase != .working else { return }
        if phase == .done { clear() }
        var known = Set(files.map(\.url.standardizedFileURL))
        var unsupported = 0
        for url in urls.flatMap(AppModel.expandingFolders) {
            guard known.insert(url.standardizedFileURL).inserted else { continue }
            guard let file = InputFile.load(url) else {
                unsupported += 1
                continue
            }
            files.append(file)
        }
        note = unsupported == 0 ? nil : unsupported == 1 ? "Skipped 1 file Stitch can't use" : "Skipped \(unsupported) files Stitch can't use"
        if phase != .ready { phase = .ready }
        applySmartOrder()
        pickOutput()
    }

    func remove(_ file: InputFile) {
        guard phase != .working else { return }
        files.removeAll { $0.id == file.id }
        if phase != .ready { phase = .ready }
        pickOutput()
    }

    func move(from source: IndexSet, to destination: Int) {
        guard phase != .working else { return }
        files.move(fromOffsets: source, toOffset: destination)
        orderEdited = true
    }

    func clear() {
        task?.cancel()
        task = nil
        files = []
        result = nil
        series = nil
        note = nil
        orderEdited = false
        output = .merge
        phase = .ready
    }

    /// "Lecture 1…10" in number order, until the person drags something.
    private func applySmartOrder() {
        guard !orderEdited else { return }
        series = SmartOrder.series(in: files.map(\.baseName))
        if let series, series.order.count == files.count {
            files = series.order.map { files[$0] }
        }
    }

    /// Only images: convert by default. Anything else (or a mix): merge.
    private func pickOutput() {
        if files.allSatisfy(\.kind.isImage), files.count > 0 {
            if output == .merge { output = canConvertToJPEG ? .jpeg : .pdf }
        } else {
            output = .merge
        }
    }

    // MARK: running

    func run() {
        guard canRun else { return }
        let files = self.files, options = jobOptions(), output = self.output, combine = prefs.combineImages
        let workDir: URL
        do {
            workDir = try Workspace.makeJobDir()
        } catch {
            phase = .failed("Couldn't create a temporary folder: \(error.localizedDescription)")
            return
        }
        phase = .working
        progress = JobProgress(message: output == .merge ? "Preparing…" : "Converting…", fraction: nil)
        let handler: ProgressHandler = { [weak self] update in
            Task { @MainActor in
                guard let self, self.phase == .working else { return }
                self.progress = update
            }
        }
        task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () throws -> JobResult in
                switch output {
                case .merge:
                    let (prepared, skipped) = try await Pipeline.prepare(files, workDir: workDir, progress: handler)
                    let usable = files.compactMap { f in prepared[f.id].map { (id: f.id, pageCount: $0.pageCount) } }
                    guard !usable.isEmpty else {
                        throw MergeFailure(message: "None of these files could be used: " + skipped.values.sorted().joined(separator: ", "))
                    }
                    let pages = Arrangement(files: usable).pages
                    let skippedNames = files.compactMap { skipped[$0.id] }
                    return try Pipeline.merge(pages: pages, sources: prepared, options: options, workDir: workDir,
                                              skipped: skippedNames, progress: handler)
                case .jpeg:
                    return try Pipeline.convertToJPEG(files, options: options, progress: handler)
                case .pdf:
                    return try Pipeline.convertToPDF(files, combine: combine, options: options, workDir: workDir, progress: handler)
                }
            }
            let outcome = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            Workspace.remove(workDir)
            guard let self else { return }
            switch outcome {
            case .success(let value):
                result = value
                phase = .done
                onFinished?(value)
            case .failure(let error) where error is CancellationError:
                phase = .ready
            case .failure(let error):
                phase = .failed((error as? MergeFailure)?.message ?? error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .working { phase = .ready }
    }

    private func jobOptions() -> JobOptions {
        let suggestion = OutputNaming.suggestion(baseNames: files.map(\.baseName), series: orderEdited ? nil : series)
        return JobOptions(ocr: prefs.ocr, shrink: prefs.shrink, targetBytes: prefs.targetBytes,
                          stripLocation: prefs.stripLocation, folder: prefs.saveFolder,
                          baseName: OutputNaming.baseName(of: suggestion))
    }
}

private struct MergeFailure: Error {
    let message: String
}
