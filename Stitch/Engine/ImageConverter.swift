import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// HEIC/PNG/… → JPEG, and images → PDF pages. Reads the source, writes a new file.
enum ImageConverter {
    enum Failure: LocalizedError {
        case unreadable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name)."
            case .writeFailed(let name): "Couldn't write \(name)."
            }
        }
    }

    /// A photo's page is scaled down so its long side is at most A4's (842 pt); the image keeps every pixel.
    static let maxPageSide: CGFloat = 842

    struct Loaded {
        /// Upright: the EXIF orientation has been applied to the pixels.
        let image: CGImage
        let properties: [CFString: Any]
        /// The file's EXIF orientation (1 = already upright).
        let orientation: Int
    }

    static func load(_ url: URL) throws -> Loaded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return Loaded(image: image, properties: props, orientation: orientation)
    }

    // MARK: JPEG

    /// Writes an upright JPEG. Keeps the camera metadata except location (when `stripLocation`).
    static func writeJPEG(from src: URL, to dst: URL, quality: Double = 0.9, stripLocation: Bool) throws {
        let loaded = try load(src)
        var meta = loaded.properties
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        if stripLocation { meta.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyHasAlpha,
                    kCGImagePropertyDepth, kCGImagePropertyPNGDictionary] {
            meta.removeValue(forKey: key)
        }
        meta[kCGImageDestinationLossyCompressionQuality] = quality

        guard let image = opaque(loaded.image),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.writeFailed(dst.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: dst)
            throw Failure.writeFailed(dst.lastPathComponent)
        }
    }

    /// JPEG has no transparency: transparent areas become white instead of black.
    private static func opaque(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    // MARK: PDF

    /// One page per image, each page the image's shape.
    static func writePDF(images: [URL], to dst: URL) throws {
        var box = CGRect.zero
        let info = [kCGPDFContextCreator: "Stitch"] as CFDictionary
        guard let ctx = CGContext(dst as CFURL, mediaBox: &box, info) else {
            throw Failure.writeFailed(dst.lastPathComponent)
        }
        for url in images {
            try Task.checkCancellation()
            let loaded = try load(url)
            let size = pageSize(for: loaded)
            var page = CGRect(origin: .zero, size: size)
            let pageInfo = [kCGPDFContextMediaBox: NSData(bytes: &page, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.interpolationQuality = .high
            ctx.draw(embeddable(loaded, source: url), in: page)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// The page size in points: the image's size at its own DPI, scaled down to fit `maxPageSide`.
    static func pageSize(for loaded: Loaded) -> CGSize {
        let dpi = (loaded.properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        var size = CGSize(width: CGFloat(loaded.image.width) * 72 / dpi, height: CGFloat(loaded.image.height) * 72 / dpi)
        let long = max(size.width, size.height)
        if long > maxPageSide {
            let scale = maxPageSide / long
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// Photos go into the PDF as JPEG data (an upright JPEG file is passed through untouched), so a
    /// 3 MB HEIC makes a ~3 MB page rather than 36 MB of raw pixels. Images with transparency stay lossless.
    private static func embeddable(_ loaded: Loaded, source: URL) -> CGImage {
        switch loaded.image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default: return loaded.image
        }
        let isJPEG = UTType(filenameExtension: source.pathExtension)?.conforms(to: .jpeg) ?? false
        if isJPEG, loaded.orientation == 1, let provider = CGDataProvider(url: source as CFURL),
           let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return image
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return loaded.image
        }
        CGImageDestinationAddImage(dest, loaded.image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return loaded.image
        }
        return image
    }
}
