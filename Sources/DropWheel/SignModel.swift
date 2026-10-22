import AppKit
import CoreText
import PDFKit

// MARK: - Colors

struct InkColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let black = InkColor(r: 0.06, g: 0.06, b: 0.09)
    static let blue = InkColor(r: 0.05, g: 0.18, b: 0.62)

    var cgColor: CGColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1).cgColor
    }
}

// MARK: - Ink (what a saved signature is)

struct InkPoint: Equatable {
    var x: Double
    var y: Double
    var w: Double       // pen width factor: fast strokes get thinner, slow ones thicker
}

/// A drawn stroke. Stored flat (x, y, w, x, y, w, ...) so the JSON stays small.
struct Stroke: Codable, Equatable {
    var v: [Double]

    init(points: [InkPoint]) {
        v = points.flatMap { [$0.x, $0.y, $0.w] }
    }

    var points: [InkPoint] {
        stride(from: 0, to: v.count - 2, by: 3).map { InkPoint(x: v[$0], y: v[$0 + 1], w: v[$0 + 2]) }
    }
}

enum InkSource: Codable, Equatable {
    case strokes([Stroke])      // coordinates are 0...1 inside the ink's box. Stays vector at any size.
    case typed(String, String)  // text, PostScript font name. Also vector.
    case image(Data)            // PNG with transparency (a photo of a wet-ink signature)
}

struct Ink: Codable, Equatable {
    var source: InkSource
    var color: InkColor
    var aspect: Double          // width / height of the box
    var pen: Double? = nil      // stroke thickness as a fraction of the box height
}

// MARK: - Smoothing and painting strokes

enum StrokePainter {
    /// Catmull-Rom through the captured points, so mouse input doesn't look like a seismograph.
    static func smooth(_ p: [InkPoint]) -> [InkPoint] {
        guard p.count > 2 else { return p }
        var out: [InkPoint] = [p[0]]
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let d = hypot(p2.x - p1.x, p2.y - p1.y)
            let n = max(1, Int(d / 2.0))
            for k in 1...n {
                let t = Double(k) / Double(n)
                let t2 = t * t
                let t3 = t2 * t
                func c(_ a: Double, _ b: Double, _ c2: Double, _ d2: Double) -> Double {
                    0.5 * ((2 * b) + (-a + c2) * t + (2 * a - 5 * b + 4 * c2 - d2) * t2 + (-a + 3 * b - 3 * c2 + d2) * t3)
                }
                out.append(InkPoint(x: c(p0.x, p1.x, p2.x, p3.x),
                                    y: c(p0.y, p1.y, p2.y, p3.y),
                                    w: p1.w + (p2.w - p1.w) * t))
            }
        }
        return out
    }

    /// Segments left to draw: `budget` lets the replay animation stop partway through.
    static func paint(_ pts: [InkPoint], pen: CGFloat, color: CGColor, ctx: CGContext, budget: inout Int) {
        guard let first = pts.first else { return }
        if pts.count == 1 {
            let r = pen * CGFloat(first.w) / 2
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: first.x - Double(r), y: first.y - Double(r), width: Double(r) * 2, height: Double(r) * 2))
            budget -= 1
            return
        }
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for i in 1..<pts.count {
            if budget <= 0 { return }
            ctx.setLineWidth(pen * CGFloat(pts[i].w))
            ctx.move(to: CGPoint(x: pts[i - 1].x, y: pts[i - 1].y))
            ctx.addLine(to: CGPoint(x: pts[i].x, y: pts[i].y))
            ctx.strokePath()
            budget -= 1
        }
    }
}

// MARK: - Typed text (signatures typed in a script font, dates, one-line stamps)

enum TextInk {
    static func line(_ text: String, fontName: String, color: CGColor) -> (CTLine, CGRect)? {
        let font = NSFont(name: fontName, size: 100) ?? NSFont.systemFont(ofSize: 100)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard b.width > 0, b.height > 0 else { return nil }
        return (line, b)
    }

    static func aspect(of text: String, fontName: String) -> Double {
        guard let (_, b) = line(text, fontName: fontName, color: InkColor.black.cgColor) else { return 4 }
        return Double(b.width / b.height)
    }

    /// Into a y-DOWN context (origin top-left), scaled to fit `rect`.
    static func draw(_ text: String, fontName: String, color: CGColor, in ctx: CGContext, rect: CGRect) {
        guard let (ln, b) = line(text, fontName: fontName, color: color) else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)                       // y-up, origin at the rect's bottom-left
        let s = min(rect.width / b.width, rect.height / b.height)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.setFillColor(color)
        ctx.textPosition = .zero
        CTLineDraw(ln, ctx)
        ctx.restoreGState()
    }
}

// MARK: - Drawing an ink

private let imageCache = NSCache<NSNumber, CGImage>()

extension Ink {
    /// Draws into a y-DOWN context (origin top-left, y grows downward) inside `rect`.
    /// `progress` < 1 draws only the first part: the replay animation.
    func draw(in ctx: CGContext, rect: CGRect, progress: Double = 1, alpha: CGFloat = 1) {
        ctx.saveGState()
        if alpha < 1 {
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // one group: overlapping segments don't darken
        }
        switch source {
        case .strokes(let strokes):
            let penPx = CGFloat(max((pen ?? 0.03) * Double(rect.height), 0.6))
            var smoothed: [[InkPoint]] = []
            var total = 0
            for s in strokes {
                let pts = s.points.map {
                    InkPoint(x: Double(rect.minX) + $0.x * Double(rect.width),
                             y: Double(rect.minY) + $0.y * Double(rect.height), w: $0.w)
                }
                let sm = StrokePainter.smooth(pts)
                smoothed.append(sm)
                total += max(sm.count - 1, 1)
            }
            var budget = progress >= 1 ? Int.max : Int(Double(total) * max(progress, 0))
            for sm in smoothed {
                if budget <= 0 { break }
                StrokePainter.paint(sm, pen: penPx, color: color.cgColor, ctx: ctx, budget: &budget)
            }

        case .typed(let text, let font):
            if progress < 1 { ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(max(progress, 0)), height: rect.height)) }
            TextInk.draw(text, fontName: font, color: color.cgColor, in: ctx, rect: rect)

        case .image(let data):
            guard let cg = Ink.decode(data) else { break }
            if progress < 1 { ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(max(progress, 0)), height: rect.height)) }
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        }
        if alpha < 1 { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    private static func decode(_ data: Data) -> CGImage? {
        var h = Hasher()
        h.combine(data.count)
        h.combine(data.prefix(2048))
        h.combine(data.suffix(2048))
        let key = NSNumber(value: h.finalize())
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Stamps: things placed on a page

enum StampKind: String {
    case signature, initials, date, text
}

enum StampContent: Equatable {
    case ink(Ink)
    case text(String, InkColor)
}

struct Stamp: Identifiable, Equatable {
    var id = UUID()
    var page: Int                 // 0-based
    var rect: CGRect              // upright page points, origin top-left, y down
    var kind: StampKind
    var content: StampContent
    var aspect: Double
    var ghost = false             // proposed by auto-spot, not touched yet

    func draw(in ctx: CGContext, progress: Double = 1, alpha: CGFloat = 1) {
        switch content {
        case .ink(let ink):
            ink.draw(in: ctx, rect: rect, progress: progress, alpha: alpha)
        case .text(let s, let c):
            ctx.saveGState()
            if alpha < 1 { ctx.setAlpha(alpha) }
            if progress < 1 { ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(max(progress, 0)), height: rect.height)) }
            TextInk.draw(s, fontName: "Helvetica", color: c.cgColor, in: ctx, rect: rect)
            ctx.restoreGState()
        }
    }

    static func make(kind: StampKind, ink: Ink, page: Int, rect: CGRect) -> Stamp {
        Stamp(page: page, rect: rect, kind: kind, content: .ink(ink), aspect: ink.aspect)
    }

    static func makeText(_ s: String, color: InkColor = .black, page: Int, rect: CGRect) -> Stamp {
        Stamp(page: page, rect: rect, kind: .text, content: .text(s, color),
              aspect: TextInk.aspect(of: s, fontName: "Helvetica"))
    }
}

enum StampSizing {
    static func height(for kind: StampKind) -> CGFloat {
        switch kind {
        case .signature: return 42
        case .initials: return 26
        case .date, .text: return 12
        }
    }

    static func size(kind: StampKind, aspect: Double, room: CGFloat? = nil) -> CGSize {
        var h = height(for: kind)
        var w = h * CGFloat(aspect)
        if let room, w > room - 8 {
            w = max(room - 8, 30)
            h = max(w / CGFloat(aspect), 12)
            w = h * CGFloat(aspect)
        }
        return CGSize(width: w, height: h)
    }

    /// A box that sits on the spot's baseline, kept inside the page.
    static func rect(for spot: Spot, kind: StampKind, aspect: Double, pageSize: CGSize) -> CGRect {
        let s = size(kind: kind, aspect: aspect, room: spot.width)
        let isText = kind == .date || kind == .text
        var x = spot.x + (isText ? 6 : 4)
        // Ink dips a little below the line, like a real pen. Typed text sits on top of it.
        var y = isText ? spot.baseline - 3 - s.height : spot.baseline + 2 - s.height
        x = min(max(x, 8), max(pageSize.width - s.width - 8, 8))
        y = min(max(y, 8), max(pageSize.height - s.height - 8, 8))
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }
}

// MARK: - Page geometry
//
// Everything the user sees and every stamp lives in "upright" space: the page as displayed (rotation applied,
// cropped to the CropBox), origin top-left, y down, in points. This maps PDF user space into it.
// Verified against real PDFs: rotations 0/90/180/270 x crop box x offset media box x trim box.

struct PageGeometry {
    let media: CGRect         // PDF user space
    let crop: CGRect
    let trim: CGRect
    let rotation: Int         // 0, 90, 180, 270 (clockwise, as displayed)

    init(page: PDFPage) {
        var m = page.bounds(for: .mediaBox).standardized
        if m.width < 1 || m.height < 1 { m = CGRect(x: 0, y: 0, width: 612, height: 792) }
        media = m
        var c = page.bounds(for: .cropBox).standardized
        if c.width < 1 || c.height < 1 { c = m }
        crop = c
        var t = page.bounds(for: .trimBox).standardized
        if t.width < 1 || t.height < 1 { t = c }
        trim = t
        rotation = ((page.rotation % 360) + 360) % 360
    }

    var size: CGSize {
        rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    /// qpdf's overlay wraps the original page and re-centres its crop area inside the media box, which
    /// shifts the page content whenever the boxes differ (measured: media 600x800, crop 40,60,540,780
    /// moves everything by +10, -20 pt). With crop = trim = media it is exact at every rotation (16/16).
    var qpdfExact: Bool {
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.05 && abs(a.minY - b.minY) < 0.05
                && abs(a.width - b.width) < 0.05 && abs(a.height - b.height) < 0.05
        }
        return same(crop, media) && same(trim, crop)
    }

    func toUpright(_ p: CGPoint) -> CGPoint {
        let c = crop
        switch rotation {
        case 90: return CGPoint(x: p.y - c.minY, y: p.x - c.minX)
        case 180: return CGPoint(x: c.maxX - p.x, y: p.y - c.minY)
        case 270: return CGPoint(x: c.maxY - p.y, y: c.maxX - p.x)
        default: return CGPoint(x: p.x - c.minX, y: c.maxY - p.y)
        }
    }

    func toUpright(rect r: CGRect) -> CGRect {
        let a = toUpright(CGPoint(x: r.minX, y: r.minY))
        let b = toUpright(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The TrimBox in upright space. qpdf fits an overlay page to the destination's TrimBox,
    /// so the stamp page has to be this size, with the stamps shifted by its origin.
    var trimFrame: CGRect { toUpright(rect: trim) }
}

// MARK: - Rasters of a page (for line detection, OCR, the sign window and the self-check)

enum PageRaster {
    struct Gray {
        var w: Int
        var h: Int
        var px: [UInt8]
        var sx: Double          // pixels per point
        var sy: Double
        var cg: CGImage

        /// Fraction of dark pixels inside a rect given in upright points.
        func inkDensity(_ r: CGRect) -> Double {
            let x0 = max(Int(Double(r.minX) * sx), 0), x1 = min(Int(Double(r.maxX) * sx), w)
            let y0 = max(Int(Double(r.minY) * sy), 0), y1 = min(Int(Double(r.maxY) * sy), h)
            guard x1 > x0, y1 > y0 else { return 0 }
            var dark = 0
            for y in y0..<y1 {
                let row = y * w
                for x in x0..<x1 where px[row + x] < 140 { dark += 1 }
            }
            return Double(dark) / Double((x1 - x0) * (y1 - y0))
        }
    }

    /// The page as displayed, `scale` pixels per point, on white.
    static func image(_ page: PDFPage, geo: PageGeometry, scale: CGFloat) -> CGImage? {
        let size = NSSize(width: max(geo.size.width * scale, 1), height: max(geo.size.height * scale, 1))
        let img = page.thumbnail(of: size, for: .cropBox)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func gray(_ page: PDFPage, geo: PageGeometry, scale: CGFloat) -> Gray? {
        guard let cg = image(page, geo: geo, scale: scale) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = ctx.data else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: w * h))
        return Gray(w: w, h: h, px: px,
                    sx: Double(w) / Double(geo.size.width), sy: Double(h) / Double(geo.size.height), cg: cg)
    }

    /// Opaque RGB copy for the sign window (some thumbnails carry transparency).
    static func displayImage(_ page: PDFPage, geo: PageGeometry, scale: CGFloat) -> CGImage? {
        guard let cg = image(page, geo: geo, scale: scale) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }
}
