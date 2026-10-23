import AppKit

// MARK: - What every target is

enum IconFamily {
    case pdf, doc, data, image, video, audio, archive

    var hex: String {
        switch self {
        case .pdf: return "#E5484D"
        case .doc: return "#4C8DF6"
        case .data: return "#2FB27A"
        case .image: return "#F2764B"
        case .video: return "#8F6BF2"
        case .audio: return "#E5589E"
        case .archive: return "#D9A21F"
        }
    }
}

struct IconMeta {
    let family: IconFamily
    let badge: String?      // text on the corner badge
    let label: String       // words under the icon, when labels are shown
    let verb: String        // the sentence in the hover pill
    let isTool: Bool        // tools share a PDF badge, so they always carry a text label
}

/// Every wheel id and what it looks like. Unknown ids (a recipe added later) still get a sensible icon.
enum IconCatalog {
    static let all: [String: IconMeta] = build()

    static func info(_ id: String) -> IconMeta {
        if let m = all[id] { return m }
        let up = id.uppercased()
        return IconMeta(family: .doc, badge: String(up.prefix(4)), label: up, verb: "Convert to \(up)", isTool: false)
    }

    private static func build() -> [String: IconMeta] {
        var m: [String: IconMeta] = [:]
        func formats(_ ids: [String], _ family: IconFamily) {
            for id in ids {
                let up = id.uppercased()
                m[id] = IconMeta(family: family, badge: up, label: up, verb: "Convert to \(up)", isTool: false)
            }
        }
        formats(["jpg", "png", "heic", "webp", "tiff", "gif", "bmp"], .image)
        formats(["mp4", "mov", "mkv", "webm"], .video)
        formats(["mp3", "m4a", "wav", "aiff", "flac", "ogg"], .audio)
        formats(["docx", "odt", "rtf", "txt", "md", "html", "epub"], .doc)
        formats(["xlsx", "csv", "json"], .data)
        formats(["pdf"], .pdf)
        m["zip"] = IconMeta(family: .archive, badge: "ZIP", label: "ZIP", verb: "Zip it up", isTool: false)
        m["unpack"] = IconMeta(family: .archive, badge: nil, label: "UNPACK", verb: "Unpack here", isTool: true)
        m["sign"] = IconMeta(family: .pdf, badge: "PDF", label: "SIGN", verb: "Sign this document", isTool: true)
        m["merge"] = IconMeta(family: .pdf, badge: "PDF", label: "MERGE", verb: "Merge into one PDF", isTool: true)
        m["split"] = IconMeta(family: .pdf, badge: "PDF", label: "SPLIT", verb: "Split into pages", isTool: true)
        m["compress"] = IconMeta(family: .pdf, badge: "PDF", label: "COMPRESS", verb: "Shrink the file size", isTool: true)
        return m
    }
}

// MARK: - Colour maths (contrast-checked so badge text is always readable)

private struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }

    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        r = CGFloat((v >> 16) & 0xFF) / 255
        g = CGFloat((v >> 8) & 0xFF) / 255
        b = CGFloat(v & 0xFF) / 255
    }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let ink = RGB(hex: "#111111")

    func color(alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    var luminance: CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with o: RGB) -> CGFloat {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// amount < 0 darkens, > 0 lightens.
    func shaded(_ amount: CGFloat) -> RGB {
        if amount < 0 {
            return RGB(r: r * (1 + amount), g: g * (1 + amount), b: b * (1 + amount))
        }
        return RGB(r: r + (1 - r) * amount, g: g + (1 - g) * amount, b: b + (1 - b) * amount)
    }

    var bestTextColor: RGB { contrast(with: .white) >= contrast(with: .ink) ? .white : .ink }
}

struct IconPalette {
    var color: NSColor          // the format's colour
    var bg: NSColor             // what's behind the icon (used to hide stacked pages)
    var pageFill: NSColor
    var pageStroke: NSColor?    // nil = no outline (solid style)
    var line: NSColor
    var accent: NSColor
    var badgeFill: NSColor
    var badgeText: NSColor
    var badgeStroke: NSColor?
    var fold: NSColor

    fileprivate static func make(base c: RGB, solid: Bool, dark: Bool) -> IconPalette {
        let bg = dark ? RGB(hex: "#1C1C20") : RGB.white
        let ink = dark ? NSColor.white.withAlphaComponent(0.6) : NSColor.black.withAlphaComponent(0.5)

        // Badge: white text on a fill deepened until it reaches 4.5:1. Near-white colours get dark text.
        func badge(_ c: RGB) -> (fill: RGB, text: RGB) {
            if c.luminance > 0.55 { return (c, .ink) }
            var f = c
            var a: CGFloat = 0
            while f.contrast(with: .white) < 4.5 && a > -0.7 {
                a -= 0.04
                f = c.shaded(a)
            }
            return (f, .white)
        }

        if !solid {
            let b = badge(c)
            return IconPalette(color: c.color(), bg: bg.color(),
                               pageFill: (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.04 : 0.03),
                               pageStroke: c.color(), line: ink, accent: c.color(),
                               badgeFill: b.fill.color(), badgeText: b.text.color(), badgeStroke: nil,
                               fold: c.color())
        }
        let on = c.bestTextColor
        let line = on.r > 0.5 ? NSColor.white.withAlphaComponent(0.9) : NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 0.78)
        return IconPalette(color: c.color(), bg: bg.color(),
                           pageFill: c.color(), pageStroke: nil, line: line, accent: on.color(),
                           badgeFill: NSColor.white, badgeText: c.shaded(-0.55).color(),
                           badgeStroke: c.color(), fold: NSColor.black.withAlphaComponent(0.28))
    }
}

// MARK: - Renderer

enum IconKit {
    private static var cache: [String: NSImage] = [:]
    private static var pathCache: [String: CGPath] = [:]

    /// The colour a target is known by (outlines, pill borders, hover tint).
    static func accent(for id: String) -> NSColor {
        baseColor(for: id).color()
    }

    private static func baseColor(for id: String) -> RGB {
        if Settings.calmColors { return RGB(hex: "#EDEDED") }
        return RGB(hex: IconCatalog.info(id).family.hex)
    }

    /// The end-result icon for an id ("jpg", "merge", ...). `badge` overrides the corner text.
    /// Main thread only. Cached per size and style, so calling this every frame is cheap.
    static func image(_ id: String, size: CGFloat, dark: Bool = true, badge: String? = nil) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(id)|\(Int((size * 10).rounded()))|\(dark ? 1 : 0)|\(Settings.iconSolid ? 1 : 0)|\(Settings.calmColors ? 1 : 0)|\(badge ?? "-")|\(Int(scale))"
        if let hit = cache[key] { return hit }

        let px = max(2, Int((size * scale).rounded(.up)))
        let image = NSImage(size: NSSize(width: size, height: size))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: size, height: size)       // points; set before the context is made
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        // Work out the context's own units, so this is right whether AppKit hands us points or pixels.
        let k = max(ctx.ctm.a, 0.0001)
        let extent = CGFloat(px) / k
        ctx.translateBy(x: 0, y: extent)
        ctx.scaleBy(x: extent / 64, y: -extent / 64)           // 64-unit grid, y pointing down
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let pal = IconPalette.make(base: baseColor(for: id), solid: Settings.iconSolid, dark: dark)
        draw(ctx, id: id, pal: pal, badge: badge ?? IconCatalog.info(id).badge)
        NSGraphicsContext.restoreGraphicsState()

        image.addRepresentation(rep)
        cache[key] = image
        return image
    }

    /// The icon for a file on disk: its format badge, or a folder icon for directories.
    static func image(forFile url: URL, size: CGFloat, dark: Bool = true) -> NSImage {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return image("unpack", size: size, dark: dark)
        }
        let ext = Registry.normalize(url.pathExtension)
        if IconCatalog.all[ext] != nil, !(IconCatalog.all[ext]?.isTool ?? false) {
            return image(ext, size: size, dark: dark)
        }
        // A format with no icon of its own: generic page, its extension on the badge.
        return image("txt", size: size, dark: dark, badge: String(ext.uppercased().prefix(4)))
    }

    // MARK: Drawing (64 x 64 grid, y down)

    private static func draw(_ ctx: CGContext, id: String, pal: IconPalette, badge: String?) {
        let solid = pal.pageStroke == nil

        func path(_ d: String) -> CGPath {
            if let p = pathCache[d] { return p }
            let p = SVGPath.parse(d)
            pathCache[d] = p
            return p
        }

        func paint(_ d: String, fill: NSColor?, stroke: NSColor?, width: CGFloat,
                   dash: [CGFloat] = [], alpha: CGFloat = 1) {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if let fill {
                ctx.addPath(path(d))
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()
            }
            if let stroke {
                ctx.addPath(path(d))
                ctx.setStrokeColor(stroke.cgColor)
                ctx.setLineWidth(width)
                ctx.setLineDash(phase: 0, lengths: dash)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        func page(_ p: (d: String, fold: String), opaque: Bool = false) {
            if opaque { paint(p.d, fill: pal.bg, stroke: nil, width: 0) }
            paint(p.d, fill: pal.pageFill, stroke: pal.pageStroke, width: 3)
            paint(p.fold, fill: nil, stroke: pal.fold, width: 3)
        }

        func shapePaint(_ d: String, fillBg: Bool = true) {
            if fillBg { paint(d, fill: pal.bg, stroke: nil, width: 0) }
            paint(d, fill: pal.pageFill, stroke: pal.pageStroke, width: 3)
        }

        func glyph() {
            guard let els = IconData.glyphs[id] else { return }
            for e in els {
                func ink(_ i: IconInk) -> NSColor? {
                    switch i {
                    case .none: return nil
                    case .line: return pal.line
                    case .accent: return pal.accent
                    }
                }
                paint(e.d, fill: ink(e.fill), stroke: ink(e.stroke), width: e.width, dash: e.dash, alpha: e.opacity)
            }
        }

        func badgeView() {
            guard let text = badge, !text.isEmpty else { return }
            let n = text.count
            let w = (10 + CGFloat(n) * 8.4).rounded()
            let rect = CGRect(x: 4, y: 39, width: w, height: 17)
            let box = CGPath(roundedRect: rect, cornerWidth: 4.2, cornerHeight: 4.2, transform: nil)
            ctx.saveGState()
            ctx.addPath(box)
            ctx.setFillColor(pal.badgeFill.cgColor)
            ctx.fillPath()
            if let s = pal.badgeStroke {
                ctx.addPath(box)
                ctx.setStrokeColor(s.cgColor)
                ctx.setLineWidth(2)
                ctx.strokePath()
            }
            ctx.restoreGState()

            // Text: Bricolage ExtraBold, condensed to fit the badge (never stretched wider).
            let target = w - 11
            var font = Brand.font(11.5, weight: 800, width: 100)
            let attrs: (NSFont) -> [NSAttributedString.Key: Any] = { [.font: $0, .foregroundColor: pal.badgeText] }
            var str = NSAttributedString(string: text, attributes: attrs(font))
            if str.size().width > target {
                font = Brand.font(11.5, weight: 800, width: 75)
                str = NSAttributedString(string: text, attributes: attrs(font))
            }
            let size = str.size()
            var sx: CGFloat = 1
            if size.width > target { sx = target / size.width }
            let baseline = rect.midY + font.capHeight / 2
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: 0)
            ctx.scaleBy(x: sx, y: 1)
            str.draw(at: CGPoint(x: -size.width / 2, y: baseline - font.ascender))
            ctx.restoreGState()
        }

        switch id {
        case "unpack":
            page(pageStrings(18, 46, 4, 34, 9, 4), opaque: true)
            paint("M24 15h14M24 21h10", fill: nil, stroke: pal.line, width: 2.6)
            let folder = "M8 22a4 4 0 0 1 4-4h11l5 5h24a4 4 0 0 1 4 4v28a4 4 0 0 1-4 4H12a4 4 0 0 1-4-4z"
            shapePaint(folder)
            paint("M32 50V36M26 42l6-6 6 6", fill: nil, stroke: pal.accent, width: 3)

        case "split":
            shapePaint("M31 4H20a4 4 0 0 0-4 4v48a4 4 0 0 0 4 4h11z")
            shapePaint("M39 4H42L54 16V56a4 4 0 0 1-4 4H39z")
            paint("M42 4v8a4 4 0 0 0 4 4h8", fill: nil, stroke: pal.fold, width: 3)
            paint("M35 1v62", fill: nil, stroke: pal.accent, width: 2.4, dash: [1, 5.5])
            glyph()
            badgeView()

        case "compress":
            page(pageStrings(22, 50, 4, 60, 10, 4))
            glyph()
            paint("M8 17l6 6-6 6M62 17l-6 6 6 6", fill: nil, stroke: solid ? pal.color : pal.accent, width: 3)
            badgeView()

        case "merge":
            paint("M26 1H56a4 4 0 0 1 4 4V52a4 4 0 0 1-4 4h-2", fill: nil, stroke: pal.pageStroke ?? pal.color,
                  width: 3, alpha: 0.6)
            page(pageStrings(16, 54, 4, 60, 12, 4), opaque: true)
            glyph()
            badgeView()

        default:
            page(pageStrings(16, 54, 4, 60, 12, 4))
            glyph()
            badgeView()
        }
    }

    private static func pageStrings(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ f: Int, _ r: Int) -> (d: String, fold: String) {
        let d = "M\(x0 + r) \(y0)H\(x1 - f)L\(x1) \(y0 + f)V\(y1 - r)a\(r) \(r) 0 0 1-\(r) \(r)H\(x0 + r)a\(r) \(r) 0 0 1-\(r)-\(r)V\(y0 + r)a\(r) \(r) 0 0 1 \(r)-\(r)z"
        let fold = "M\(x1 - f) \(y0)v\(f - r)a\(r) \(r) 0 0 0 \(r) \(r)H\(x1)"
        return (d, fold)
    }
}

// MARK: - SVG path data -> CGPath
//
// Small on purpose: only the commands the icon set uses (M L H V C S A Z, upper and lower case).
// Arcs are converted to Bezier segments by hand, so there's no ambiguity about CoreGraphics' arc
// direction in a flipped coordinate system. Verified against a reference renderer.

enum SVGPath {
    private enum Tok { case cmd(Character), num(CGFloat) }

    static func parse(_ d: String) -> CGPath {
        let toks = tokenize(d)
        let path = CGMutablePath()
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastC2: CGPoint?
        var idx = 0
        var cmd: Character = " "

        func num() -> CGFloat? {
            if idx < toks.count, case .num(let v) = toks[idx] {
                idx += 1
                return v
            }
            return nil
        }

        while idx < toks.count {
            if case .cmd(let c) = toks[idx] {
                cmd = c
                idx += 1
                if c == "z" || c == "Z" {
                    path.closeSubpath()
                    cur = start
                    lastC2 = nil
                    continue
                }
            } else if cmd == " " {
                idx += 1
                continue
            }

            let rel = String(cmd) == String(cmd).lowercased()
            let up = Character(String(cmd).uppercased())
            let ox: CGFloat = rel ? cur.x : 0
            let oy: CGFloat = rel ? cur.y : 0
            let prevC2 = lastC2
            lastC2 = nil

            switch up {
            case "M":
                guard let x = num(), let y = num() else { return path }
                cur = CGPoint(x: x + ox, y: y + oy)
                start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L"            // extra pairs after M are implicit lineto
            case "L":
                guard let x = num(), let y = num() else { return path }
                cur = CGPoint(x: x + ox, y: y + oy)
                path.addLine(to: cur)
            case "H":
                guard let x = num() else { return path }
                cur = CGPoint(x: x + ox, y: cur.y)
                path.addLine(to: cur)
            case "V":
                guard let y = num() else { return path }
                cur = CGPoint(x: cur.x, y: y + oy)
                path.addLine(to: cur)
            case "C":
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(),
                      let x = num(), let y = num() else { return path }
                let c1 = CGPoint(x: x1 + ox, y: y1 + oy)
                let c2 = CGPoint(x: x2 + ox, y: y2 + oy)
                cur = CGPoint(x: x + ox, y: y + oy)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastC2 = c2
            case "S":
                guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return path }
                let c1 = prevC2.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: x2 + ox, y: y2 + oy)
                cur = CGPoint(x: x + ox, y: y + oy)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastC2 = c2
            case "A":
                guard let rx = num(), let _ = num(), let _ = num(), let large = num(), let sweep = num(),
                      let x = num(), let y = num() else { return path }
                let end = CGPoint(x: x + ox, y: y + oy)
                arc(path, from: cur, radius: rx, large: large != 0, sweep: sweep != 0, to: end)
                cur = end
            default:
                idx += 1
            }
        }
        return path
    }

    /// Circular arc (rx == ry, no rotation: all the icon set needs) as cubic Beziers.
    private static func arc(_ p: CGMutablePath, from p0: CGPoint, radius: CGFloat, large: Bool, sweep: Bool, to p1: CGPoint) {
        if p0 == p1 { return }
        var r = abs(radius)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let d2 = dx * dx + dy * dy
        if r * r < d2 { r = sqrt(d2) }
        let sq = max(0, (r * r - d2) / d2)
        let coef: CGFloat = (large == sweep ? -1 : 1) * sqrt(sq)
        let cx = coef * dy + (p0.x + p1.x) / 2
        let cy = -coef * dx + (p0.y + p1.y) / 2
        let a0 = atan2(p0.y - cy, p0.x - cx)
        var delta = atan2(p1.y - cy, p1.x - cx) - a0
        if sweep && delta < 0 { delta += 2 * .pi }
        if !sweep && delta > 0 { delta -= 2 * .pi }
        let n = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        var a = a0
        for _ in 0..<n {
            let b = a + step
            let ps = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            let c1 = CGPoint(x: ps.x - k * r * sin(a), y: ps.y + k * r * cos(a))
            let pe = CGPoint(x: cx + r * cos(b), y: cy + r * sin(b))
            let c2 = CGPoint(x: pe.x + k * r * sin(b), y: pe.y - k * r * cos(b))
            p.addCurve(to: pe, control1: c1, control2: c2)
            a = b
        }
    }

    private static func tokenize(_ s: String) -> [Tok] {
        var out: [Tok] = []
        let ch = Array(s)
        var i = 0
        while i < ch.count {
            let c = ch[i]
            if c.isLetter {
                out.append(.cmd(c))
                i += 1
            } else if c == "-" || c == "+" || c == "." || ("0"..."9").contains(c) {
                var j = i
                if ch[j] == "-" || ch[j] == "+" { j += 1 }
                var seenDot = false
                while j < ch.count {
                    let d = ch[j]
                    if ("0"..."9").contains(d) {
                        j += 1
                    } else if d == "." && !seenDot {
                        seenDot = true
                        j += 1
                    } else {
                        break
                    }
                }
                var str = String(ch[i..<j])
                if str.hasPrefix(".") { str = "0" + str }
                else if str.hasPrefix("-.") { str = "-0" + str.dropFirst() }
                else if str.hasPrefix("+.") { str = "0" + str.dropFirst() }
                out.append(.num(CGFloat(Double(str) ?? 0)))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }
}
