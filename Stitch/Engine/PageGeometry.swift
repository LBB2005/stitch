import CoreGraphics

/// Page rotation helpers. PDFKit and MuPDF both place things in PDF user space (the page before its
/// /Rotate is applied); Stitch draws overlays and stamps "upright", as the page is shown, so they need
/// turning back on rotated pages.
enum PageGeometry {
    /// 0, 90, 180 or 270.
    static func normalized(_ rotation: Int) -> Int {
        (((rotation / 90) * 90) % 360 + 360) % 360
    }

    /// The size of `rect` (user space) as it appears on screen.
    static func uprightSize(of rect: CGRect, rotation: Int) -> CGSize {
        normalized(rotation) % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
    }

    /// The user-space size of something that is `size` on screen.
    static func userSize(ofUpright size: CGSize, rotation: Int) -> CGSize {
        normalized(rotation) % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Maps an upright box `(0, 0, uprightSize)` (y up, as shown) onto `rect` in user space of a page
    /// rotated clockwise by `rotation` degrees.
    static func uprightTransform(for rect: CGRect, rotation: Int) -> CGAffineTransform {
        switch normalized(rotation) {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.maxX, ty: rect.minY)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: rect.maxX, ty: rect.maxY)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: rect.minX, ty: rect.maxY)
        default: CGAffineTransform(translationX: rect.minX, y: rect.minY)
        }
    }

    /// Maps a stamp `(0, 0, rect.size)` (y up) onto the display-space `rect` (y down) and then into user
    /// space with `toUserSpace` (from `MuPDFDocument.PageInfo`).
    static func stampTransform(forDisplayRect rect: CGRect, toUserSpace: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY).concatenating(toUserSpace)
    }
}
