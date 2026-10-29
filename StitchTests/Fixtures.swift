import AppKit
import CoreText
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest

/// Builds test files in a temporary folder.
final class Fixtures {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("StitchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// A PDF whose pages each carry real text "<label> page N".
    func textPDF(_ name: String, pages: Int, label: String, size: CGSize = CGSize(width: 612, height: 792)) -> URL {
        let url = url(name)
        var box = CGRect(origin: .zero, size: size)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for p in 1...pages {
            ctx.beginPDFPage(nil)
            draw("\(label) page \(p)", in: ctx, at: CGPoint(x: 60, y: size.height - 100), size: 28)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A PDF of text pages each holding a big, noisy photo-like image, so it compresses poorly.
    func heavyPDF(_ name: String, pages: Int, imagePixels: Int = 2400) -> URL {
        let url = url(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for p in 1...pages {
            let image = noise(width: imagePixels, height: imagePixels * 2 / 3, seed: UInt32(p))
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: CGRect(x: 36, y: 300, width: 540, height: 360))
            draw("Heavy page \(p)", in: ctx, at: CGPoint(x: 60, y: 700), size: 24)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A "scan": one page that is only a picture of the words, with no text layer. With `sideways`, the
    /// picture is stored turned a quarter left and the page has /Rotate 90, as scanners often do, so it
    /// still displays upright (landscape).
    func scannedPDF(_ name: String, words: String, sideways: Bool = false) -> URL {
        let url = url(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        if sideways {
            ctx.translateBy(x: 612, y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(textImage(words, width: 2200, height: 1700), in: CGRect(x: 0, y: 0, width: 792, height: 612))
        } else {
            ctx.draw(textImage(words, width: 1700, height: 2200), in: box)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        if sideways, let doc = PDFDocument(url: url) {
            doc.page(at: 0)?.rotation = 90
            doc.write(to: url)
        }
        return url
    }

    /// An image file. `orientation` is written as EXIF; `gps` adds a location.
    func image(_ name: String, type: UTType, width: Int = 400, height: Int = 300, orientation: Int = 1,
               gps: Bool = false, alpha: Bool = false) -> URL {
        let url = url(name)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
        if !alpha {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // A red block in the top-left corner (of the stored pixels) shows which way is up.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"]
        }
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifLensModel: "Test Lens"]
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func digest(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: drawing

    func draw(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    func textImage(_ text: String, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        draw(text, in: ctx, at: CGPoint(x: 150, y: height - 400), size: 90)
        return ctx.makeImage()!
    }

    func noise(width: Int, height: Int, seed: UInt32 = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let buffer = ctx.data!.assumingMemoryBound(to: UInt32.self)
        var seed: UInt32 = 2463534242 &+ seed &* 7919
        for i in 0..<(width * height) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            buffer[i] = seed | 0xFF00_0000
        }
        return ctx.makeImage()!
    }
}
