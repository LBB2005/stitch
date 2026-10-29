#if DEBUG
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Debug builds only: `open Stitch.app --args -StitchDemo arrange` loads sample files and opens the panel
/// on a screen (empty, files, drop, arrange, done, settings), for checking the UI and taking screenshots.
@MainActor
enum DemoMode {
    static func run(_ screen: String, model: AppModel, panel: PanelController) {
        if let style = UserDefaults.standard.string(forKey: "StitchDemoAppearance") {
            NSApp.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StitchDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if screen != "empty" && screen != "drop-empty" {
            model.add([
                pdf(dir, "Lecture 2 Slides.pdf", pages: 3, slides: true),
                pdf(dir, "Lecture 10 Slides.pdf", pages: 2, slides: true),
                photo(dir, "Lecture 7 whiteboard.heic"),
                pdf(dir, "Lecture 1 Slides.pdf", pages: 3, slides: true),
            ])
        }
        panel.open(takeFocus: false)
        switch screen {
        case "drop", "drop-empty": model.dropHover = 4
        case "arrange", "done": model.startMerge()
        case "settings": model.openSettings()
        default: break
        }
        if screen == "done" {
            Task {
                while model.screen != .arrange { try? await Task.sleep(for: .milliseconds(100)) }
                model.useFolder(dir)
                model.merge()
            }
        }
    }

    private static func pdf(_ dir: URL, _ name: String, pages: Int, slides: Bool) -> URL {
        let url = dir.appendingPathComponent(name)
        var box = slides ? CGRect(x: 0, y: 0, width: 720, height: 540) : CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
        let title = (name as NSString).deletingPathExtension
        for p in 1...pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0.14, green: 0.27, blue: 0.48, alpha: 1))
            ctx.fill(CGRect(x: 0, y: box.height - 130, width: box.width, height: 130))
            text(p == 1 ? title : "\(title) — part \(p)", ctx, CGPoint(x: 40, y: box.height - 80), 34, white: true)
            ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
            for line in 0..<6 {
                ctx.fill(CGRect(x: 40, y: box.height - 190 - CGFloat(line) * 44, width: box.width * [0.7, 0.55, 0.62, 0.48, 0.66, 0.4][line], height: 12))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private static func photo(_ dir: URL, _ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        let w = 1200, h = 900
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return url }
        ctx.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: CGRect(x: 200, y: 200, width: 500, height: 400))
        text("E = mc²", ctx, CGPoint(x: 760, y: 420), 90, white: false)
        if let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        return url
    }

    private static func text(_ s: String, _ ctx: CGContext, _ at: CGPoint, _ size: CGFloat, white: Bool) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let color = white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.1, alpha: 1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        ctx.textPosition = at
        CTLineDraw(line, ctx)
    }
}
#endif
