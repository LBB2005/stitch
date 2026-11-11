#if DEBUG
import AppKit
import CoreText
import PDFKit

/// Debug builds only: `-StitchDemo app` shows the Stitch window, `document` opens a sample lease with a
/// signature, a date and a text box placed, `form` a fillable form, `appsettings` the Settings window.
@MainActor
enum DocumentDemo {
    static let screens: Set<String> = ["app", "document", "form", "appsettings"]

    /// `-StitchDemoSnapshot /path.png`: after the demo is up, the frontmost Stitch window draws itself
    /// into that PNG (no Screen Recording permission needed), then Stitch quits.
    static func snapshotIfAsked() {
        guard let path = UserDefaults.standard.string(forKey: "StitchDemoSnapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal }
            if let frame = window?.contentView?.superview {
                frame.layoutSubtreeIfNeeded()
                if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    // PDFKit draws pages in its own layers, which cacheDisplay skips: paint those on top.
                    if let pdf = findPDFView(in: frame), let layer = pdf.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                        let r = pdf.convert(pdf.bounds, to: frame)
                        let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
                        ctx.cgContext.scaleBy(x: scale, y: scale)
                        ctx.cgContext.translateBy(x: r.minX, y: r.minY)
                        layer.render(in: ctx.cgContext)
                    }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                if let pdf = findPDFView(in: frame), let page = pdf.document?.page(at: 0) {
                    let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items
                        .map { "\($0.title)[\($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")\($0.keyEquivalent)]" } ?? []
                    let info = "file-menu=\(file)\n" + "pages=\(pdf.document?.pageCount ?? -1) scale=\(pdf.scaleFactor) frame=\(pdf.frame) annotations=\(page.annotations.count) text=\(page.string?.prefix(40) ?? "")"
                    try? info.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
                    let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .cropBox)
                    if let tiff = image.tiffRepresentation, let r = NSBitmapImageRep(data: tiff) {
                        try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".page.png"))
                    }
                }
            }
            exit(0)   // not terminate(): the demo document has unsaved changes and would ask
        }
    }

    private static func findPDFView(in view: NSView) -> PDFView? {
        if let p = view as? PDFView { return p }
        for sub in view.subviews { if let p = findPDFView(in: sub) { return p } }
        return nil
    }

    static func run(_ screen: String, documents: DocumentController) {
        defer { snapshotIfAsked() }
        if let style = UserDefaults.standard.string(forKey: "StitchDemoAppearance") {
            NSApp.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StitchDocDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch screen {
        case "app":
            documents.showHome()
        case "appsettings":
            SettingsOpener.open(tab: .general)
        case "form":
            let url = form(dir)
            documents.open(url)
        default:
            let url = lease(dir)
            documents.open(url)
            guard let doc = documents.current else { return }
            let sig = Signature.typed("Liam Blackshaw-Brown", fontName: "SnellRoundhand")!
            doc.session.add(Overlay(page: 0, rect: CGRect(x: 80, y: 150, width: 200, height: 200 / sig.aspect), rotation: 0,
                                    kind: .signature(sig)), actionName: "Signature")
            let date = TextBox(text: "11/11/2026")
            doc.session.add(Overlay(page: 0, rect: CGRect(origin: CGPoint(x: 360, y: 156), size: date.naturalSize), rotation: 0,
                                    kind: .text(date)), actionName: "Date")
            var note = TextBox(text: "Unit 4B")
            note.ink = .blue
            let ov = Overlay(page: 0, rect: CGRect(origin: CGPoint(x: 398, y: 618), size: note.naturalSize), rotation: 0, kind: .text(note))
            doc.session.add(ov, actionName: "Text")
            doc.pdfView.select(ov.id)
        }
    }

    private static func lease(_ dir: URL) -> URL {
        let url = dir.appendingPathComponent("Lease.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
        ctx.beginPDFPage(nil)
        text("Residential Lease Agreement", ctx, CGPoint(x: 72, y: 700), 22, bold: true)
        let body = [
            "This agreement is made between the Landlord and the Tenant for the",
            "property at 1200 Figueroa Street, Los Angeles, CA 90007, Unit ____.",
            "The term begins on the first day of the month and runs twelve months.",
            "Rent is due on the first of each month. Late payments incur a fee.",
        ]
        for (i, line) in body.enumerated() { text(line, ctx, CGPoint(x: 72, y: 640 - CGFloat(i) * 18), 12, bold: false) }
        ctx.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
        ctx.setLineWidth(0.75)
        for x in [72.0, 340.0] {
            ctx.move(to: CGPoint(x: x, y: 150)); ctx.addLine(to: CGPoint(x: x + 200, y: 150)); ctx.strokePath()
        }
        text("Tenant signature", ctx, CGPoint(x: 72, y: 136), 9, bold: false)
        text("Date", ctx, CGPoint(x: 340, y: 136), 9, bold: false)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func form(_ dir: URL) -> URL {
        let blank = lease(dir)
        let doc = PDFDocument(url: blank)!
        let page = doc.page(at: 0)!
        for (i, name) in ["First Name", "Last Name", "Email", "USC ID"].enumerated() {
            let w = PDFAnnotation(bounds: CGRect(x: 72, y: 500 - CGFloat(i) * 34, width: 260, height: 22), forType: .widget, withProperties: nil)
            w.widgetFieldType = .text
            w.fieldName = name
            w.font = NSFont.systemFont(ofSize: 12)
            page.addAnnotation(w)
        }
        let url = dir.appendingPathComponent("Application Form.pdf")
        doc.write(to: url)
        return url
    }

    private static func text(_ s: String, _ ctx: CGContext, _ at: CGPoint, _ size: CGFloat, bold: Bool) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]))
        ctx.textPosition = at
        CTLineDraw(line, ctx)
    }
}
#endif
