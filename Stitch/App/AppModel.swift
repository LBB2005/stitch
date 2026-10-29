import AppKit
import Observation
import SwiftUI

/// Everything the panel shows, and every action it can take.
@MainActor
@Observable
final class AppModel {
    enum Screen: Hashable { case home, arrange, working, done, settings }
    enum OrderMode { case smart, added }
    enum Banner: Equatable {
        case libreOffice
        case error(String)
    }
    struct DropIndicator: Equatable {
        let targetID: String
        let before: Bool
    }

    let prefs: Preferences
    @ObservationIgnored weak var panel: PanelController?

    private(set) var files: [InputFile] = []
    private(set) var screen: Screen = .home
    /// Direction of the last screen change, for the slide.
    private(set) var forward = true
    /// Files being dragged over the menu bar icon or the panel ("Release to add N files").
    var dropHover: Int?
    private(set) var orderMode: OrderMode = .smart
    private(set) var series: SeriesInfo?
    private(set) var arrangement = Arrangement(items: [])
    private(set) var prepared: [UUID: PreparedFile] = [:]
    private(set) var skipped: [UUID: String] = [:]
    private(set) var outputName = ""
    /// A folder chosen with Save to… for this job only; nil uses the default from Settings.
    private(set) var oneOffFolder: URL?
    private(set) var progress = JobProgress(message: "", fraction: nil)
    private(set) var result: JobResult?
    var banner: Banner?
    private(set) var toast: String?
    /// Bumped when the filename field should take focus with its name selected.
    private(set) var focusToken = 0
    private(set) var draggingTileID: String?
    private(set) var dropIndicator: DropIndicator?

    @ObservationIgnored private var nameEdited = false
    @ObservationIgnored private var returnScreen: Screen = .home
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var workDir: URL?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    // MARK: derived

    /// Files in merge order: by series number when a series was found (and not switched off), else as added.
    var orderedFiles: [InputFile] {
        guard orderMode == .smart, let series, series.order.count == files.count else { return files }
        return series.order.map { files[$0] }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var destination: URL { oneOffFolder ?? prefs.saveFolder }
    var destinationName: String { FileManager.default.displayName(atPath: destination.path) }

    var canMerge: Bool {
        files.contains { $0.kind.isPDF || $0.kind.isImage || ($0.kind.isOffice && OfficeConverter.isInstalled) }
    }
    var canConvertToJPEG: Bool { files.contains { $0.kind == .image(jpeg: false) } }
    var canConvertToPDF: Bool { files.contains(where: \.kind.isImage) }
    var imageCount: Int { files.filter(\.kind.isImage).count }

    var orderLabel: String {
        guard let series else { return "Order added" }
        return orderMode == .smart ? series.label : "Order added"
    }

    /// Followed in the row by the limit menu: "6.8 MB · already under [30 MB]", "48 MB → under [30 MB]".
    var shrinkCaption: String {
        let total = totalBytes
        return total <= prefs.targetBytes
            ? "\(ByteSize.string(total)) · already under"
            : "\(ByteSize.string(total)) → under"
    }

    // MARK: files

    func add(_ urls: [URL]) {
        guard screen != .working else { return }
        if screen == .done { startOver() }
        var known = Set(files.map(\.url.standardizedFileURL))
        var unsupported = 0
        var added = 0
        for url in urls.flatMap(Self.expandingFolders) {
            guard known.insert(url.standardizedFileURL).inserted else { continue }
            guard let file = InputFile.load(url) else {
                unsupported += 1
                continue
            }
            files.append(file)
            added += 1
        }
        if unsupported > 0 {
            showToast(unsupported == 1 ? "Skipped 1 file Stitch can't use" : "Skipped \(unsupported) files Stitch can't use")
        }
        if files.contains(where: \.kind.isOffice), !OfficeConverter.isInstalled, !prefs.libreOfficeNoticeShown {
            banner = .libreOffice
            prefs.libreOfficeNoticeShown = true
        }
        filesChanged()
        if added > 0 {
            if screen != .home { go(.home, forward: false) }
            focusToken += 1
        }
    }

    func add(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(provider) { urls.append(url) }
            }
            add(urls)
        }
    }

    func remove(_ file: InputFile) {
        files.removeAll { $0.id == file.id }
        filesChanged()
    }

    private func filesChanged() {
        series = SmartOrder.series(in: files.map(\.baseName))
        let ids = Set(files.map(\.id))
        prepared = prepared.filter { ids.contains($0.key) }
        skipped = skipped.filter { ids.contains($0.key) }
        if files.isEmpty {
            nameEdited = false
            outputName = ""
            oneOffFolder = nil
            orderMode = .smart
            if banner == .libreOffice { banner = nil }
        } else if !nameEdited {
            suggestName()
        }
    }

    private func suggestName() {
        outputName = OutputNaming.suggestion(baseNames: orderedFiles.map(\.baseName),
                                             series: orderMode == .smart ? series : nil)
    }

    func setName(_ name: String) {
        guard name != outputName else { return }
        outputName = name
        nameEdited = true
    }

    func setOrderMode(_ mode: OrderMode) {
        guard mode != orderMode else { return }
        orderMode = mode
        if !nameEdited { suggestName() }
        if screen == .arrange { rebuildArrangement(keepingRemovals: true) }
    }

    // MARK: navigation

    func go(_ screen: Screen, forward: Bool = true) {
        guard screen != self.screen else { return }
        self.forward = forward
        self.screen = screen
    }

    @ObservationIgnored private var settingsReturn: Screen = .home

    func openSettings() {
        guard screen != .settings, screen != .working else { return }
        settingsReturn = screen
        go(.settings)
    }

    /// Escape and the back arrows. Returns false when there is nowhere to go back to.
    @discardableResult
    func back() -> Bool {
        switch screen {
        case .arrange: go(.home, forward: false)
        case .settings: go(settingsReturn, forward: false)
        default: return false
        }
        return true
    }

    // MARK: dialogs

    func chooseFiles() {
        let urls: [URL] = panel?.runModal {
            let open = NSOpenPanel()
            open.allowsMultipleSelection = true
            open.canChooseDirectories = false
            open.allowedContentTypes = FileKind.pickerTypes
            open.prompt = "Add"
            open.message = "Choose PDFs, photos, Word or PowerPoint files"
            return open.runModal() == .OK ? open.urls : []
        } ?? []
        add(urls)
    }

    /// Save to…: a Finder save dialog for this one job's name and folder.
    func chooseSaveLocation() {
        panel?.runModal {
            let save = NSSavePanel()
            save.nameFieldStringValue = outputName
            save.directoryURL = destination
            save.canCreateDirectories = true
            save.prompt = "Choose"
            save.message = "Stitch saves here this time and never replaces an existing file."
            if save.runModal() == .OK, let url = save.url {
                oneOffFolder = url.deletingLastPathComponent()
                setName(url.lastPathComponent)
            }
        }
    }

    func useFolder(_ folder: URL?) {
        oneOffFolder = folder.flatMap { $0.standardizedFileURL == prefs.saveFolder.standardizedFileURL ? nil : $0 }
    }

    func chooseFolder(asDefault: Bool) {
        panel?.runModal {
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.directoryURL = asDefault ? prefs.saveFolder : destination
            open.prompt = "Choose"
            if open.runModal() == .OK, let url = open.url {
                if asDefault { prefs.saveFolder = url } else { useFolder(url) }
            }
        }
    }

    // MARK: merge

    func startMerge() {
        guard canMerge, screen == .home else { return }
        let missing = orderedFiles.filter { prepared[$0.id] == nil }
        guard !missing.isEmpty else { return showArrange() }
        guard let work = ensureWorkDir() else { return }
        run(message: "Preparing…") { progress in
            try await Pipeline.prepare(missing, workDir: work, progress: progress)
        } done: { [weak self] value in
            guard let self else { return }
            prepared.merge(value.prepared) { $1 }
            skipped.merge(value.skipped) { $1 }
            if orderedFiles.allSatisfy({ prepared[$0.id] == nil }) {
                fail(message: "None of these files could be used: " + skipped.values.sorted().joined(separator: ", "))
            } else {
                showArrange()
            }
        }
    }

    private func showArrange() {
        rebuildArrangement(keepingRemovals: false)
        go(.arrange)
        focusToken += 1
    }

    private func rebuildArrangement(keepingRemovals: Bool) {
        let usable = orderedFiles.compactMap { file in prepared[file.id].map { (id: file.id, pageCount: $0.pageCount) } }
        var removed = Set<PageRef>()
        if keepingRemovals {
            let kept = Set(arrangement.pages)
            for file in usable { for i in 0..<file.pageCount where !kept.contains(PageRef(fileID: file.id, index: i)) {
                removed.insert(PageRef(fileID: file.id, index: i))
            } }
        }
        arrangement = Arrangement(files: usable, removed: removed)
    }

    func merge() {
        let pages = arrangement.pages
        guard !pages.isEmpty, let work = ensureWorkDir() else { return }
        let sources = prepared, options = jobOptions()
        let skippedNames = orderedFiles.compactMap { skipped[$0.id] }
        run(message: "Merging…") { progress in
            try Pipeline.merge(pages: pages, sources: sources, options: options, workDir: work,
                               skipped: skippedNames, progress: progress)
        } done: { [weak self] in self?.finish($0) }
    }

    // MARK: arrange

    func removeTile(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) { arrangement.remove(id) }
    }

    func expand(_ fileID: UUID) {
        withAnimation(.snappy(duration: 0.25)) { arrangement.expand(fileID) }
    }

    func collapse(_ fileID: UUID) {
        withAnimation(.snappy(duration: 0.25)) { arrangement.collapse(fileID) }
    }

    func toggleExpandAll() {
        withAnimation(.snappy(duration: 0.25)) {
            if arrangement.hasStacks { arrangement.expandAll() } else { arrangement.collapseAll() }
        }
    }

    func beginTileDrag(_ id: String) {
        draggingTileID = id
    }

    func updateDrop(over targetID: String, before: Bool) {
        guard let dragging = draggingTileID, dragging != targetID else {
            dropIndicator = nil
            return
        }
        let indicator = DropIndicator(targetID: targetID, before: before)
        if dropIndicator != indicator { dropIndicator = indicator }
    }

    func clearDrop(over targetID: String) {
        if dropIndicator?.targetID == targetID { dropIndicator = nil }
    }

    func performDrop() -> Bool {
        defer {
            draggingTileID = nil
            dropIndicator = nil
        }
        guard let dragging = draggingTileID, let indicator = dropIndicator else { return false }
        withAnimation(.snappy(duration: 0.25)) {
            arrangement.move(dragging, to: indicator.targetID, before: indicator.before)
        }
        return true
    }

    // MARK: convert

    func convertToJPEG() {
        guard canConvertToJPEG, screen == .home else { return }
        let files = orderedFiles, options = jobOptions()
        run(message: "Converting…") { progress in
            try Pipeline.convertToJPEG(files, options: options, progress: progress)
        } done: { [weak self] in self?.finish($0) }
    }

    func convertToPDF() {
        guard canConvertToPDF, screen == .home, let work = ensureWorkDir() else { return }
        let files = orderedFiles, options = jobOptions(), combine = prefs.combineImages
        run(message: "Converting…") { progress in
            try Pipeline.convertToPDF(files, combine: combine, options: options, workDir: work, progress: progress)
        } done: { [weak self] in self?.finish($0) }
    }

    func splitIntoParts() {
        guard let over = result?.overLimit, let original = result?.outputs.first else { return }
        run(message: "Splitting…") { progress in
            try Pipeline.split(over, progress: progress)
        } done: { [weak self] value in
            var value = value
            value.note = [value.note, "Full-quality copy kept as \(original.lastPathComponent)"].compactMap { $0 }.joined(separator: "\n")
            self?.finish(value)
        }
    }

    // MARK: jobs

    private func jobOptions() -> JobOptions {
        JobOptions(ocr: prefs.ocr, shrink: prefs.shrink, targetBytes: prefs.targetBytes,
                   stripLocation: prefs.stripLocation, folder: destination,
                   baseName: OutputNaming.baseName(of: outputName))
    }

    private func ensureWorkDir() -> URL? {
        if let workDir { return workDir }
        do {
            workDir = try Workspace.makeJobDir()
            return workDir
        } catch {
            fail(message: "Couldn't create a temporary folder: \(error.localizedDescription)")
            return nil
        }
    }

    /// Shows the working screen, runs `work` off the main thread, then calls `done` — or goes back to
    /// where it started, with the error shown, if it fails or is cancelled.
    private func run<T: Sendable>(message: String,
                                  work: @escaping @Sendable (@escaping ProgressHandler) async throws -> T,
                                  done: @escaping @MainActor (T) -> Void) {
        job?.cancel()
        banner = nil
        progress = JobProgress(message: message, fraction: nil)
        returnScreen = screen
        go(.working)
        let handler: ProgressHandler = { [weak self] update in
            Task { @MainActor in
                guard let self, self.screen == .working else { return }
                self.progress = update
            }
        }
        job = Task { [weak self] in
            let task = Task.detached(priority: .userInitiated) { try await work(handler) }
            let outcome = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }
            guard let self else { return }
            if Task.isCancelled {
                go(returnScreen, forward: false)
                return
            }
            switch outcome {
            case .success(let value):
                done(value)
            case .failure(let error) where error is CancellationError:
                go(returnScreen, forward: false)
            case .failure(let error):
                fail(message: error.localizedDescription)
            }
        }
    }

    func cancelJob() {
        job?.cancel()
        job = nil
        go(returnScreen, forward: false)
    }

    private func finish(_ result: JobResult) {
        self.result = result
        go(.done)
        guard panel?.isOpen != true, let first = result.outputs.first else { return }
        let what = result.outputs.count == 1 ? first.lastPathComponent : "\(result.outputs.count) files"
        Notifier.shared.post(title: result.title, body: "\(what) · \(ByteSize.string(result.bytes)) — in \(FileManager.default.displayName(atPath: first.deletingLastPathComponent().path))")
    }

    private func fail(message: String) {
        banner = .error(message)
        go(returnScreen == .working ? .home : returnScreen, forward: false)
    }

    func startOver() {
        job?.cancel()
        job = nil
        files = []
        prepared = [:]
        skipped = [:]
        arrangement = Arrangement(items: [])
        result = nil
        banner = nil
        series = nil
        orderMode = .smart
        nameEdited = false
        outputName = ""
        oneOffFolder = nil
        Workspace.remove(workDir)
        workDir = nil
        Task { await ThumbnailStore.shared.reset() }
        go(.home, forward: false)
    }

    // MARK: done

    func reveal() {
        guard let outputs = result?.outputs, !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
        panel?.close()
    }

    func openOutputs() {
        result?.outputs.forEach { NSWorkspace.shared.open($0) }
    }

    // MARK: helpers

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// A dropped folder adds the supported files directly inside it, in Finder order.
    private static func expandingFolders(_ url: URL) -> [URL] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values?.isDirectory == true, values?.isPackage != true else { return [url] }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? []
        return contents.filter { FileKind.classify($0) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }
}
