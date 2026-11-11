import CoreGraphics
import Foundation
import StitchMuPDF

/// A PDF opened with MuPDF, for the edits PDFKit can't do: reading text with its fonts, removing text,
/// stamping new content and writing form fields. One MuPDF context per document; use each instance
/// from one task at a time. Every call goes through the C shim, which catches MuPDF's errors.
final class MuPDFDocument: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case needsPassword
        case wrongPassword
        case mupdf(String)
        case fieldNotFound(String)

        var errorDescription: String? {
            switch self {
            case .needsPassword: "This PDF needs a password."
            case .wrongPassword: "That password didn't work."
            case .mupdf(let message): message
            case .fieldNotFound(let name): "No form field named \(name)."
            }
        }
    }

    struct PageInfo: Sendable, Equatable {
        /// PDF user space (PDFKit's page coordinates) → display space (top-left origin, y down, rotated).
        let toDisplay: CGAffineTransform
        let displaySize: CGSize
        let rotation: Int
        var toUserSpace: CGAffineTransform { toDisplay.inverted() }
    }

    struct Char: Sendable, Equatable {
        let scalar: UnicodeScalar
        /// Display space.
        let box: CGRect
        let origin: CGPoint
        let size: CGFloat
        let argb: UInt32
        let block: Int
        let line: Int
        let fontName: String
        let bold: Bool
        let italic: Bool
        let serif: Bool
        let mono: Bool
    }

    enum FieldType: Int32, Sendable {
        case unknown = 0, button, checkbox, combobox, listbox, radio, signature, text
    }

    struct Field: Sendable, Equatable {
        let name: String
        let type: FieldType
        let page: Int
        /// Display space.
        let box: CGRect
        let value: String
        let onState: String
    }

    struct Flags: OptionSet, Sendable {
        let rawValue: Int32
        static let xfa = Flags(rawValue: Int32(SMU_DOC_HAS_XFA))
        static let digitallySigned = Flags(rawValue: Int32(SMU_DOC_DIGITALLY_SIGNED))
    }

    private let handle: OpaquePointer

    init(url: URL, password: String? = nil) throws {
        var status: Int32 = 0
        var err = [CChar](repeating: 0, count: 512)
        let opened: OpaquePointer? = url.path.withCString { path in
            if let password {
                return password.withCString { smu_open(path, $0, &status, &err, Int32(err.count)) }
            }
            return smu_open(path, nil, &status, &err, Int32(err.count))
        }
        guard let opened else {
            if status == SMU_NEEDS_PASSWORD { throw password == nil ? Failure.needsPassword : Failure.wrongPassword }
            throw Failure.mupdf(Self.message(err, fallback: "Couldn't open \(url.lastPathComponent)."))
        }
        handle = opened
    }

    deinit { smu_close(handle) }

    var pageCount: Int { Int(smu_page_count(handle)) }

    var flags: Flags { Flags(rawValue: smu_doc_flags(handle)) }

    func save(to url: URL) throws {
        try call { err, len in url.path.withCString { smu_save(handle, $0, err, len) } }
    }

    func pageInfo(_ page: Int) throws -> PageInfo {
        var ctm = [Float](repeating: 0, count: 6)
        var size = [Float](repeating: 0, count: 2)
        var rotation: Int32 = 0
        try call { err, len in smu_page_info(handle, Int32(page), &ctm, &size, &rotation, err, len) }
        let t = CGAffineTransform(a: CGFloat(ctm[0]), b: CGFloat(ctm[1]), c: CGFloat(ctm[2]),
                                  d: CGFloat(ctm[3]), tx: CGFloat(ctm[4]), ty: CGFloat(ctm[5]))
        return PageInfo(toDisplay: t, displaySize: CGSize(width: CGFloat(size[0]), height: CGFloat(size[1])),
                        rotation: Int(rotation))
    }

    func chars(onPage page: Int) throws -> [Char] {
        var raw: UnsafeMutablePointer<smu_char>?
        var count: Int32 = 0
        try call { err, len in smu_page_chars(handle, Int32(page), &raw, &count, err, len) }
        defer { smu_free(raw) }
        guard let raw else { return [] }
        return UnsafeBufferPointer(start: raw, count: Int(count)).compactMap { c in
            guard let scalar = UnicodeScalar(c.c) else { return nil }
            var font = c.font
            let name = withUnsafeBytes(of: &font) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Char(scalar: scalar,
                        box: CGRect(x: CGFloat(c.x0), y: CGFloat(c.y0), width: CGFloat(c.x1 - c.x0), height: CGFloat(c.y1 - c.y0)),
                        origin: CGPoint(x: CGFloat(c.ox), y: CGFloat(c.oy)), size: CGFloat(c.size), argb: c.argb,
                        block: Int(c.block), line: Int(c.line), fontName: name,
                        bold: c.font_flags & Int32(SMU_FONT_BOLD) != 0, italic: c.font_flags & Int32(SMU_FONT_ITALIC) != 0,
                        serif: c.font_flags & Int32(SMU_FONT_SERIF) != 0, mono: c.font_flags & Int32(SMU_FONT_MONO) != 0)
        }
    }

    /// Removes the text touching these display-space rectangles; images and drawings stay.
    func removeText(onPage page: Int, in rects: [CGRect]) throws {
        guard !rects.isEmpty else { return }
        let flat = rects.flatMap { [Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)] }
        try call { err, len in smu_remove_text(handle, Int32(page), flat, Int32(rects.count), err, len) }
    }

    /// Draws page 1 of `stamp` onto `page`; `transform` maps the stamp's coordinates to the page's user space.
    func place(_ stamp: URL, onPage page: Int, transform t: CGAffineTransform) throws {
        let m = [Float(t.a), Float(t.b), Float(t.c), Float(t.d), Float(t.tx), Float(t.ty)]
        try call { err, len in stamp.path.withCString { smu_place_pdf(handle, Int32(page), $0, m, err, len) } }
    }

    func fields() throws -> [Field] {
        var raw: UnsafeMutablePointer<smu_field>?
        var count: Int32 = 0
        try call { err, len in smu_list_fields(handle, &raw, &count, err, len) }
        defer { smu_free(raw) }
        guard let raw else { return [] }
        return UnsafeBufferPointer(start: raw, count: Int(count)).map { f in
            var f = f
            let name = withUnsafeBytes(of: &f.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let value = withUnsafeBytes(of: &f.value) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &f.on_state) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Field(name: name, type: FieldType(rawValue: f.type) ?? .unknown, page: Int(f.page),
                         box: CGRect(x: CGFloat(f.x0), y: CGFloat(f.y0), width: CGFloat(f.x1 - f.x0), height: CGFloat(f.y1 - f.y0)),
                         value: value, onState: on)
        }
    }

    func setField(_ name: String, to value: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        let status = name.withCString { n in value.withCString { smu_set_field(handle, n, $0, &err, Int32(err.count)) } }
        if status == SMU_NOT_FOUND { throw Failure.fieldNotFound(name) }
        if status != SMU_OK { throw Failure.mupdf(Self.message(err, fallback: "Couldn't fill \(name).")) }
    }

    /// Flatten: annotations and form fields become part of the page.
    func bake() throws {
        try call { err, len in smu_bake(handle, err, len) }
    }

    // MARK: helpers

    private func call(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws {
        var err = [CChar](repeating: 0, count: 512)
        let status = err.withUnsafeMutableBufferPointer { body($0.baseAddress!, Int32($0.count)) }
        guard status == SMU_OK else { throw Failure.mupdf(Self.message(err, fallback: "The PDF couldn't be changed.")) }
    }

    private static func message(_ err: [CChar], fallback: String) -> String {
        let text = err.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return text.isEmpty ? fallback : text
    }
}
