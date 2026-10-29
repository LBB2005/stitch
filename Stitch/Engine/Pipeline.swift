import Foundation
import PDFKit

struct JobOptions: Sendable {
    var ocr: Bool
    var shrink: Bool
    var targetBytes: Int64
    var stripLocation: Bool
    var folder: URL
    /// The output name without extension; a folder's name when there are several outputs.
    var baseName: String
}

struct JobProgress: Sendable, Equatable {
    var message: String
    /// nil shows an indeterminate spinner.
    var fraction: Double?
}

typealias ProgressHandler = @Sendable (JobProgress) -> Void

/// What the Done screen shows.
struct JobResult: Sendable {
    struct Shrink: Sendable {
        let before: Int64
        let after: Int64
        let dpi: Int
    }

    /// The output didn't fit even at 150 DPI; it can still be split into parts.
    struct OverLimit: Sendable {
        let best: URL
        let bestBytes: Int64
        let target: Int64
        let baseName: String
        let folder: URL
    }

    var title: String
    var outputs: [URL]
    var pageCount: Int?
    var bytes: Int64
    var searchable = false
    var shrink: Shrink?
    var overLimit: OverLimit?
    var skipped: [String] = []
    var note: String?
}

/// Every job, start to finish. Runs off the main thread; reads inputs, writes new files only.
enum Pipeline {
    // MARK: merge

    /// Turns every file into a PDF Stitch can take pages from: PDFs as they are, images and Office files
    /// converted into the work folder. Files that can't be used are in `skipped`, as "name (reason)".
    static func prepare(_ files: [InputFile], workDir: URL, progress: ProgressHandler) async throws
        -> (prepared: [UUID: PreparedFile], skipped: [UUID: String]) {
        var prepared: [UUID: PreparedFile] = [:]
        var skipped: [UUID: String] = [:]
        for (n, file) in files.enumerated() {
            try Task.checkCancellation()
            progress(JobProgress(message: "Preparing \(file.name)…", fraction: Double(n) / Double(files.count)))
            do {
                let url: URL
                switch file.kind {
                case .pdf:
                    url = file.url
                case .image:
                    url = workDir.appendingPathComponent("image-\(file.id.uuidString).pdf")
                    try ImageConverter.writePDF(images: [file.url], to: url)
                case .word, .powerpoint:
                    guard OfficeConverter.isInstalled else {
                        skipped[file.id] = "\(file.name) (needs LibreOffice)"
                        continue
                    }
                    url = try await OfficeConverter.convert(file.url, workDir: workDir)
                }
                let doc = try PDFTools.open(url, name: file.name)
                guard doc.pageCount > 0 else {
                    skipped[file.id] = "\(file.name) (no pages)"
                    continue
                }
                prepared[file.id] = PreparedFile(fileID: file.id, pdfURL: url, pageCount: doc.pageCount, title: file.baseName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped[file.id] = "\(file.name) (\(reason(error)))"
            }
        }
        return (prepared, skipped)
    }

    static func merge(pages: [PageRef], sources: [UUID: PreparedFile], options: JobOptions, workDir: URL,
                      skipped: [String], progress: @escaping ProgressHandler) throws -> JobResult {
        progress(JobProgress(message: "Merging \(pages.count) pages…", fraction: nil))
        let merged = workDir.appendingPathComponent("merged-\(UUID().uuidString).pdf")
        let outline = try PDFTools.assemble(pages, sources: sources, to: merged)
        let final = try finalizePDF(merged, outline: outline, options: options, workDir: workDir, progress: progress)
        let dest = OutputNaming.uniqueURL(in: options.folder, base: options.baseName, ext: "pdf")
        try FileManager.default.moveItem(at: final.url, to: dest)

        let fileCount = Set(pages.map(\.fileID)).count
        var result = JobResult(title: fileCount == 1 ? "Saved 1 file as PDF" : "Merged \(fileCount) files",
                               outputs: [dest], pageCount: final.pages, bytes: PDFTools.size(dest))
        result.searchable = final.searchable
        result.shrink = final.shrink
        result.overLimit = final.overLimit(options)
        result.skipped = skipped
        return result
    }

    // MARK: convert

    static func convertToJPEG(_ files: [InputFile], options: JobOptions, progress: ProgressHandler) throws -> JobResult {
        let images = files.filter { $0.kind == .image(jpeg: false) }
        let folder = try outputFolder(count: images.count, options: options)
        var outputs: [URL] = []
        for (n, file) in images.enumerated() {
            try Task.checkCancellation()
            progress(JobProgress(message: "Converting \(file.name)…", fraction: Double(n) / Double(images.count)))
            let base = images.count == 1 ? options.baseName : file.baseName
            let dest = OutputNaming.uniqueURL(in: folder, base: base, ext: "jpg")
            try ImageConverter.writeJPEG(from: file.url, to: dest, stripLocation: options.stripLocation)
            outputs.append(dest)
        }
        var result = JobResult(title: images.count == 1 ? "Converted 1 image" : "Converted \(images.count) images",
                               outputs: outputs, bytes: outputs.reduce(0) { $0 + PDFTools.size($1) })
        let jpegs = files.filter { $0.kind == .image(jpeg: true) }.count
        let others = files.count - images.count - jpegs
        result.note = [jpegs > 0 ? "\(jpegs) already JPEG" : nil, others > 0 ? "\(others) not an image" : nil]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty.map { "Left out: \($0)" }
        if options.stripLocation { result.note = [result.note, "Location removed"].compactMap { $0 }.joined(separator: " · ") }
        return result
    }

    static func convertToPDF(_ files: [InputFile], combine: Bool, options: JobOptions, workDir: URL,
                             progress: @escaping ProgressHandler) throws -> JobResult {
        let images = files.filter(\.kind.isImage)
        if combine || images.count == 1 {
            progress(JobProgress(message: "Making a PDF of \(images.count == 1 ? "1 image" : "\(images.count) images")…", fraction: nil))
            let temp = workDir.appendingPathComponent("images-\(UUID().uuidString).pdf")
            try ImageConverter.writePDF(images: images.map(\.url), to: temp)
            let final = try finalizePDF(temp, outline: [], options: options, workDir: workDir, progress: progress)
            let dest = OutputNaming.uniqueURL(in: options.folder, base: options.baseName, ext: "pdf")
            try FileManager.default.moveItem(at: final.url, to: dest)
            var result = JobResult(title: images.count == 1 ? "Converted 1 image" : "Combined \(images.count) images",
                                   outputs: [dest], pageCount: final.pages, bytes: PDFTools.size(dest))
            result.searchable = final.searchable
            result.shrink = final.shrink
            result.overLimit = final.overLimit(options)
            return result
        }

        let folder = try outputFolder(count: images.count, options: options)
        var outputs: [URL] = []
        var searchable = true
        for (n, file) in images.enumerated() {
            try Task.checkCancellation()
            progress(JobProgress(message: "Converting \(file.name)…", fraction: Double(n) / Double(images.count)))
            let temp = workDir.appendingPathComponent("image-\(UUID().uuidString).pdf")
            try ImageConverter.writePDF(images: [file.url], to: temp)
            let final = try finalizePDF(temp, outline: [], options: options, workDir: workDir) { _ in }
            searchable = searchable && final.searchable
            let dest = OutputNaming.uniqueURL(in: folder, base: file.baseName, ext: "pdf")
            try FileManager.default.moveItem(at: final.url, to: dest)
            outputs.append(dest)
        }
        var result = JobResult(title: "Converted \(images.count) images", outputs: outputs, pageCount: images.count,
                               bytes: outputs.reduce(0) { $0 + PDFTools.size($1) })
        result.searchable = options.ocr && searchable
        return result
    }

    // MARK: split

    static func split(_ over: JobResult.OverLimit, progress: ProgressHandler) throws -> JobResult {
        progress(JobProgress(message: "Splitting into parts under \(ByteSize.string(over.target))…", fraction: nil))
        let parts = try PDFShrinker.split(over.best, target: over.target, folder: over.folder, base: over.baseName)
        var result = JobResult(title: "Split into \(parts.count) parts", outputs: parts,
                               bytes: parts.reduce(0) { $0 + PDFTools.size($1) })
        let tooBig = parts.filter { PDFTools.size($0) > over.target }.count
        result.note = tooBig > 0
            ? "\(tooBig) part\(tooBig == 1 ? " is" : "s are") a single page that's still over \(ByteSize.string(over.target))."
            : "Each part is under \(ByteSize.string(over.target)), images at 150 DPI."
        return result
    }

    // MARK: finishing a PDF

    struct Finalized {
        var url: URL
        var pages: Int
        var searchable: Bool
        var shrink: JobResult.Shrink?
        var best: (url: URL, bytes: Int64)?

        func overLimit(_ options: JobOptions) -> JobResult.OverLimit? {
            best.map { JobResult.OverLimit(best: $0.url, bestBytes: $0.bytes, target: options.targetBytes,
                                           baseName: options.baseName, folder: options.folder) }
        }
    }

    /// OCR, then shrink-to-fit, then bookmarks — in that order because redrawing drops bookmarks.
    /// If even the smallest allowed step is over the limit, the full-quality file is kept and the small
    /// one is offered for splitting.
    static func finalizePDF(_ src: URL, outline: [OutlineEntry], options: JobOptions, workDir: URL,
                            progress: @escaping ProgressHandler) throws -> Finalized {
        var current = src
        var result = Finalized(url: src, pages: 0, searchable: false)

        if options.ocr {
            let out = workDir.appendingPathComponent("ocr-\(UUID().uuidString).pdf")
            try OCRService.makeSearchable(current, to: out) { n, total in
                progress(JobProgress(message: "Reading text · page \(n) of \(total)", fraction: Double(n - 1) / Double(total)))
            }
            current = out
        }

        if options.shrink {
            let before = PDFTools.size(current)
            let outcome = try PDFShrinker.fit(current, target: Int64(Double(options.targetBytes) * 0.98), workDir: workDir) { step in
                progress(JobProgress(message: "Shrinking to fit \(ByteSize.string(options.targetBytes)) · images at \(step.dpi) DPI", fraction: nil))
            }
            switch outcome {
            case .fits:
                break
            case .shrunk(let url, let step):
                current = url
                result.shrink = JobResult.Shrink(before: before, after: PDFTools.size(url), dpi: step.dpi)
            case .tooBig(let best, _):
                result.best = (best, PDFTools.size(best))
            }
        }

        if !outline.isEmpty {
            let out = workDir.appendingPathComponent("outlined-\(UUID().uuidString).pdf")
            try PDFTools.addOutline(outline, to: current, writingTo: out)
            current = out
            if let shrink = result.shrink {
                result.shrink = JobResult.Shrink(before: shrink.before, after: PDFTools.size(out), dpi: shrink.dpi)
            }
        }

        let doc = try PDFTools.open(current)
        result.url = current
        result.pages = doc.pageCount
        result.searchable = (0..<doc.pageCount).allSatisfy { doc.page(at: $0).map { !OCRService.needsOCR($0) } ?? false }
        return result
    }

    // MARK: helpers

    /// Several outputs go into a new folder named after the output name; one goes straight into the folder.
    private static func outputFolder(count: Int, options: JobOptions) throws -> URL {
        guard count > 1 else { return options.folder }
        let folder = OutputNaming.uniqueURL(in: options.folder, base: options.baseName, ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func reason(_ error: Error) -> String {
        if let pdf = error as? PDFTools.Failure, case .locked = pdf { return "password-protected" }
        if error is OfficeConverter.Failure { return "LibreOffice couldn't convert it" }
        return "couldn't be read"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
