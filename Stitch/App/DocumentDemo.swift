#if DEBUG
import AppKit
import CoreText
import PDFKit

/// Debug builds only: `-StitchDemo app` shows the empty Stitch window (`app-merge` with files on its merge
/// list, `app-search` with ⌘K open, `document-rename` a lease with its title being renamed), `document` opens a sample lease with a
/// signature, a date and a text box placed (Pages panel), `document-todo`, `-sign`, `-myinfo`,
/// `-history`, `-find` and `-folded` the same lease with that panel open or the sidebar folded, `form` a
/// fillable form, `appsettings` the Settings window.
@MainActor
enum DocumentDemo {
    static let screens: Set<String> = ["app", "app-merge", "app-search", "app-flow", "document-rename", "document", "document-todo", "document-sign", "document-myinfo", "document-history", "document-combine",
                                       "document-find", "document-folded", "form", "appsettings"]

    /// `-StitchDemoSnapshot /path.png`: after the demo is up, the frontmost Stitch window draws itself
    /// into that PNG (no Screen Recording permission needed), then Stitch quits.
    static func snapshotIfAsked() {
        guard let path = UserDefaults.standard.string(forKey: "StitchDemoSnapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let window = NSApp.windows.first { $0 is CommandPanel && $0.isVisible } ?? NSApp.keyWindow
                ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal }
            if let frame = window?.contentView?.superview {
                // PDFKit draws pages in its own layers, which cacheDisplay skips: paint the visible pages
                // (with their annotations and the selection chrome) into an image view inside the PDF view
                // for the moment, so the window draws everything above it (rail, toolbar, bars) as usual.
                var cover: NSImageView?
                if let pdf = findPDFView(in: frame) {
                    let image = pageImage(pdf)
                    let view = NSImageView(frame: pdf.bounds)
                    view.image = image
                    view.imageScaling = .scaleNone
                    pdf.addSubview(view)
                    cover = view
                }
                frame.layoutSubtreeIfNeeded()
                if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                cover?.removeFromSuperview()
                if let pdf = findPDFView(in: frame), let page = pdf.document?.page(at: 0) {
                    let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items
                        .map { "\($0.title)[\($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")\($0.keyEquivalent)]" } ?? []
                    let geo = "frame=\(frame.bounds) flipped=\(frame.isFlipped) pdfInFrame=\(pdf.convert(pdf.bounds, to: frame)) page0=\(pdf.convert(pdf.convert(page.bounds(for: .cropBox), from: page), to: frame)) window=\(frame.window?.frame ?? .zero)\n"
                    let sidebar = (frame.window?.contentViewController as? NSSplitViewController)?.splitViewItems.first?.viewController.view
                    let looks = "appearance window=\(frame.window?.effectiveAppearance.name.rawValue ?? "-") sidebar=\(sidebar?.effectiveAppearance.name.rawValue ?? "-") pdf=\(pdf.effectiveAppearance.name.rawValue)\n"
                    let info = looks + geo + "file-menu=\(file)\n" + "pages=\(pdf.document?.pageCount ?? -1) scale=\(pdf.scaleFactor) frame=\(pdf.frame) annotations=\(page.annotations.count) text=\(page.string?.prefix(40) ?? "")"
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

    /// The PDF view's visible pages, chrome on top, as an image the size of the view.
    private static func pageImage(_ pdf: PDFView) -> NSImage {
        NSImage(size: pdf.bounds.size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext, let doc = pdf.document else { return false }
            cg.setFillColor(NSColor.underPageBackgroundColor.cgColor)
            cg.fill(pdf.bounds)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .cropBox)
                let r = pdf.convert(box, from: page)
                guard r.intersects(pdf.bounds) else { continue }
                cg.saveGState()
                cg.setFillColor(.white)
                cg.fill(r)
                cg.translateBy(x: r.minX, y: r.minY)
                cg.scaleBy(x: r.width / box.width, y: r.height / box.height)
                cg.translateBy(x: -box.minX, y: -box.minY)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
            }
            for sub in pdf.documentView?.subviews ?? [] where !sub.isHidden && sub.alphaValue > 0 && !(sub is NSScrollView) {
                let r = sub.convert(sub.bounds, to: pdf)
                guard r.intersects(pdf.bounds) else { continue }
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: r.minX, yBy: r.minY)
                t.concat()
                sub.draw(sub.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    private static func findPDFView(in view: NSView) -> PDFView? {
        if let p = view as? PDFView { return p }
        for sub in view.subviews { if let p = findPDFView(in: sub) { return p } }
        return nil
    }

    static func run(_ screen: String, documents: DocumentController) {
        if screen == "app-flow" { return flow(documents) }
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
        case "app-merge":
            documents.showHome()
            let files = ["Lecture 2.pdf", "Lecture 1.pdf", "Lecture 3.pdf"].map { name in
                let url = dir.appendingPathComponent(name)
                try? FileManager.default.copyItem(at: lease(dir), to: url)
                return url
            }
            documents.stageMerge(files + [form(dir)])
        case "app-search":
            _ = lease(dir)
            documents.showHome()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { documents.showCommandBar() }
        case "appsettings":
            SettingsOpener.open(tab: .general)
        case "form":
            let url = form(dir)
            documents.open(url)
            documents.current?.showPanel(.myInfo)
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
            if let window = doc.window, window.frame.width < 1100 {
                window.setContentSize(NSSize(width: 1100, height: window.frame.height))
            }
            switch screen {
            case "document-todo":
                doc.showPanel(.todo)
            case "document-sign":
                doc.ui.revealed = true
                doc.showPanel(.sign)
            case "document-myinfo":
                doc.showPanel(.myInfo)
            case "document-history":
                doc.showPanel(.history)
                // Later events, so each is its own undo step.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    doc.session.add(Overlay(page: 1, rect: CGRect(x: 500, y: 48, width: 40, height: 20), rotation: 0,
                                            kind: .text(TextBox(text: "LB"))), actionName: "Text")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { doc.session.undoManager.undo() }
                }
            case "document-combine":
                doc.showPanel(.combine)
                let extra = doc.session.workDir.appendingPathComponent("Lecture 2.pdf")
                try? FileManager.default.copyItem(at: doc.session.original, to: extra)
                doc.combineAdd([doc.session.original, extra])
            case "document-find":
                doc.showPanel(.find)
                doc.ui.find.query = "notice"
                doc.findChanged()
            case "document-rename":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { doc.beginRename() }
            case "document-folded":
                doc.pdfView.select(ov.id)
                doc.window?.setContentSize(NSSize(width: 1100, height: doc.window?.frame.height ?? 900))
                // By hand, once the window is up: the animated path.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { doc.toggleSidebar() }
            default:
                doc.showPanel(.pages)
                doc.pdfView.select(ov.id)
            }
        }
    }

    /// `-StitchDemo app-flow -saveFolder /some/folder`: drives the one-window flows for real (open into the
    /// empty window, rename, close back to it, merge there) and writes PASS/FAIL lines to
    /// `<saveFolder>/flow.txt`, then quits. The save folder argument keeps the merge out of Downloads.
    private static func flow(_ documents: DocumentController) {
        Task { @MainActor in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("StitchFlow", isDirectory: true)
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var log: [String] = []
            func check(_ name: String, _ ok: Bool) { log.append((ok ? "PASS " : "FAIL ") + name) }

            documents.showHome()
            let window = documents.starts.first?.window
            check("launch shows one empty window", window?.isVisible == true && documents.windows.isEmpty && documents.starts.count == 1)

            let url = lease(dir)
            documents.open(url)
            check("a PDF opens in that same window", documents.windows.first?.window === window && documents.starts.isEmpty)
            if let doc = documents.windows.first {
                let renamed = dir.appendingPathComponent("Lease signed.pdf")
                check("rename moves the file", doc.rename(to: "Lease signed") && fm.fileExists(atPath: renamed.path)
                      && !fm.fileExists(atPath: url.path))
                check("rename updates the window and Recent", doc.session.name == "Lease signed.pdf" && window?.title == "Lease signed.pdf"
                      && documents.recents.first?.lastPathComponent == "Lease signed.pdf")
                try? fm.copyItem(at: renamed, to: dir.appendingPathComponent("Other.pdf"))
                check("rename never replaces another file", !doc.rename(to: "Other.pdf") && fm.fileExists(atPath: renamed.path))
                check("rename refuses an empty name", !doc.rename(to: " .. "))
                check("case-only rename works", doc.rename(to: "lease signed") && doc.session.name == "lease signed.pdf"
                      && (try? fm.contentsOfDirectory(atPath: dir.path))?.contains("lease signed.pdf") == true)

                window?.performClose(nil)
                try? await Task.sleep(for: .milliseconds(600))
                check("closing the last PDF keeps the window, empty", documents.windows.isEmpty
                      && documents.starts.first?.window === window && window?.isVisible == true)

                let one = dir.appendingPathComponent("Lecture 1.pdf"), two = dir.appendingPathComponent("Lecture 2.pdf")
                try? fm.copyItem(at: dir.appendingPathComponent("lease signed.pdf"), to: one)
                try? fm.copyItem(at: one, to: two)
                documents.stageMerge([two, one])
                if let start = documents.starts.first {
                    check("files go on that window's merge list", start.window === window && start.job.files.count == 2)
                    check("smart order", start.job.files.map(\.name) == ["Lecture 1.pdf", "Lecture 2.pdf"])
                    start.run()
                    for _ in 0..<60 where documents.windows.isEmpty {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    let merged = documents.windows.first
                    check("the merged PDF opens in the same window", merged?.window === window && documents.starts.isEmpty)
                    check("merged PDF has every page", merged?.session.pageCount == 6)
                    check("the originals are untouched", fm.fileExists(atPath: one.path) && fm.fileExists(atPath: two.path))
                    documents.newTab()
                    check("New Tab adds an empty tab beside it", documents.starts.count == 1 && (window?.tabbedWindows?.count ?? 1) == 2)
                }
            }
            // ⌘K's Spotlight search: any PDF in the home folder whose name has "license" in it.
            let spotlight = SpotlightSearch()
            var found: [URL] = []
            spotlight.onResults = { urls, _ in if !urls.isEmpty { found = urls } }
            spotlight.search("license")
            for _ in 0..<20 where found.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            spotlight.stop()
            log.append("INFO Spotlight found \(found.count) PDF(s) for “license”: " + found.prefix(3).map(\.lastPathComponent).joined(separator: ", "))
            let out = documents.prefs.saveFolder.appendingPathComponent("flow.txt")
            try? log.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            exit(0)
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
        text("Initials ________", ctx, CGPoint(x: 460, y: 50), 10, bold: false)
        ctx.endPDFPage()
        for p in 2...3 {
            ctx.beginPDFPage(nil)
            text("\(p == 2 ? "Notice and Repairs" : "Ending the Lease")", ctx, CGPoint(x: 72, y: 700), 16, bold: true)
            let lines = p == 2 ? [
                "The Landlord will give the Tenant 24 hours' written notice before entering.",
                "The Tenant will give notice of any repair that is needed as soon as possible.",
                "Notice may be given by email to the addresses on the first page.",
            ] : [
                "Either party may end this lease with 60 days' written notice.",
                "The deposit is returned within 21 days of the Tenant moving out.",
            ]
            for (i, line) in lines.enumerated() { text(line, ctx, CGPoint(x: 72, y: 660 - CGFloat(i) * 18), 11, bold: false) }
            text("Initials ________", ctx, CGPoint(x: 460, y: 50), 10, bold: false)
            ctx.endPDFPage()
        }
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
