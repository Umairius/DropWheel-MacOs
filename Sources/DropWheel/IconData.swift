// GENERATED from the approved icon sheets. Do not edit by hand.
// Each glyph is the "content" drawn inside the page (lines, mountains, play buttons, waveforms...)
// on a 64x64 grid. `line` = quiet ink, `accent` = the format's colour.
import CoreGraphics

enum IconInk { case none, line, accent }

struct IconEl {
    let d: String
    let fill: IconInk
    let stroke: IconInk
    let width: CGFloat
    let dash: [CGFloat]
    let opacity: CGFloat
}

private func E(_ d: String, _ fill: IconInk, _ stroke: IconInk, _ width: CGFloat,
               _ dash: [CGFloat] = [], _ opacity: CGFloat = 1) -> IconEl {
    IconEl(d: d, fill: fill, stroke: stroke, width: width, dash: dash, opacity: opacity)
}

enum IconData {
    static let glyphs: [String: [IconEl]] = build()

    private static func build() -> [String: [IconEl]] {
        var g: [String: [IconEl]] = [:]
        g["jpg"] = [
            E("M39.2 19a2.8 2.8 0 1 0 5.6 0a2.8 2.8 0 1 0 -5.6 0z", .accent, .none, 2.6),
            E("M23 34l8-10 6 7 4-4.5 7 7.5", .none, .line, 2.6),
        ]
        g["png"] = [
            E("M40 14.5H46a1.5 1.5 0 0 1 1.5 1.5V22a1.5 1.5 0 0 1 -1.5 1.5H40a1.5 1.5 0 0 1 -1.5 -1.5V16a1.5 1.5 0 0 1 1.5 -1.5z", .none, .line, 2),
            E("M38.5 14.5h4.5v4.5h-4.5zM43 19h4.5v4.5H43z", .accent, .none, 2.6),
            E("M23 34l8-10 6 7 3-3.5 7 6.5", .none, .line, 2.6),
        ]
        g["heic"] = [
            E("M39.8 19a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0 -4.4 0z", .accent, .none, 2.6),
            E("M36.6 19a5.4 5.4 0 1 0 10.8 0a5.4 5.4 0 1 0 -10.8 0z", .none, .accent, 1.8, [], 0.7),
            E("M23 34l8-10 6 7 4-4.5 7 7.5", .none, .line, 2.6),
        ]
        g["webp"] = [
            E("M36.5 19.5a5 5 0 1 0 10 0a5 5 0 1 0 -10 0z", .none, .accent, 2),
            E("M36.5 19.5h10M41.5 14.5c-2.4 2.8-2.4 7.2 0 10M41.5 14.5c2.4 2.8 2.4 7.2 0 10", .none, .accent, 1.7),
            E("M23 34l8-10 6 7 4-4.5 7 7.5", .none, .line, 2.6),
        ]
        g["tiff"] = [
            E("M26 14.5h18M24 19h22", .none, .accent, 2, [], 0.8),
            E("M23 34l7-7.5 5 5.5 3.5-3.5 9.5 5.5", .none, .line, 2.6),
        ]
        g["gif"] = [
            E("M35 17a7 7 0 1 1-7 7", .none, .accent, 2.6),
            E("M25 27l3-3 3 3", .none, .accent, 2.6),
            E("M33.1 24a1.9 1.9 0 1 0 3.8 0a1.9 1.9 0 1 0 -3.8 0z", .accent, .none, 2.6),
        ]
        g["bmp"] = [
            E("M23 34v-4h4v-4h4v-4h4v4h4v4h4v4", .none, .line, 2.6),
            E("M41 15h4v4h-4z", .accent, .none, 2.6),
        ]
        g["mp4"] = [
            E("M27 14H43a4 4 0 0 1 4 4V30a4 4 0 0 1 -4 4H27a4 4 0 0 1 -4 -4V18a4 4 0 0 1 4 -4z", .none, .line, 2.6),
            E("M32 19.5v9l8-4.5z", .accent, .accent, 1.6),
        ]
        g["mov"] = [
            E("M25.5 20H44.5a2.5 2.5 0 0 1 2.5 2.5V31.5a2.5 2.5 0 0 1 -2.5 2.5H25.5a2.5 2.5 0 0 1 -2.5 -2.5V22.5a2.5 2.5 0 0 1 2.5 -2.5z", .none, .line, 2.6),
            E("M23 20l-.6-4.8 24.2-3.9.7 4.8z", .none, .line, 2.6),
            E("M29.5 19l-.9-5.6M36 17.9l-.9-5.6M42.5 16.9l-.9-5.6", .none, .accent, 2.6),
            E("M32.5 24.5v6l5-3z", .accent, .accent, 1.4),
        ]
        g["mkv"] = [
            E("M27 14H43a4 4 0 0 1 4 4V30a4 4 0 0 1 -4 4H27a4 4 0 0 1 -4 -4V18a4 4 0 0 1 4 -4z", .none, .line, 2.6),
            E("M28 19.5v9l6-4.5z", .accent, .accent, 1.4),
            E("M38 19h5M38 24h5M38 29h5", .none, .accent, 2.6),
        ]
        g["webm"] = [
            E("M27 14H43a4 4 0 0 1 4 4V30a4 4 0 0 1 -4 4H27a4 4 0 0 1 -4 -4V18a4 4 0 0 1 4 -4z", .none, .line, 2.6),
            E("M31 18.5v8l7-4z", .accent, .accent, 1.4),
            E("M27 30.5h10", .none, .accent, 2.2),
            E("M41 30.5h.01", .none, .accent, 3.6),
        ]
        g["mp3"] = [
            E("M25 21v6M30 17v14M35 14v20M40 18v12M45 21v6", .none, .accent, 3.4),
        ]
        g["m4a"] = [
            E("M31 29V16l12-3v13", .none, .accent, 2.6),
            E("M25 29.5a3 3 0 1 0 6 0a3 3 0 1 0 -6 0z", .accent, .accent, 2.6),
            E("M37 26.5a3 3 0 1 0 6 0a3 3 0 1 0 -6 0z", .accent, .accent, 2.6),
        ]
        g["wav"] = [
            E("M23 24h3l2-6 3 12 3-16 3 20 3-12 2 2h3", .none, .accent, 2.6),
        ]
        g["aiff"] = [
            E("M23 29h5v-10h5v14h5v-12h5v8h4", .none, .accent, 2.6),
        ]
        g["flac"] = [
            E("M35 13l3.6 3.6L35 20.2l-3.6-3.6z", .accent, .none, 2.6),
            E("M23 31h4l2-3 3 6 3-8 3 6 2-1.5h5", .none, .accent, 2.6),
        ]
        g["ogg"] = [
            E("M24.5 24a10.5 10.5 0 1 0 21 0a10.5 10.5 0 1 0 -21 0z", .none, .accent, 2.6),
            E("M30 24a5 5 0 1 0 10 0a5 5 0 1 0 -10 0z", .none, .line, 2.6),
            E("M33.4 24a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0z", .accent, .none, 2.6),
        ]
        g["pdf"] = [
            E("M23 15h24M23 21h24M23 27h24M23 33h15", .none, .line, 2.6),
        ]
        g["docx"] = [
            E("M23 15h13", .none, .accent, 4),
            E("M23 22h24M23 28h24M23 34h14", .none, .line, 2.6),
        ]
        g["odt"] = [
            E("M23 15h24M23 21h24", .none, .line, 2.6),
            E("M25.2 30a4.3 4.3 0 1 0 8.6 0a4.3 4.3 0 1 0 -8.6 0z", .none, .accent, 2.6),
            E("M38 28.5h9M38 33h6", .none, .line, 2.6),
        ]
        g["rtf"] = [
            E("M23 15h13", .none, .accent, 4),
            E("M23 22h24", .none, .line, 2.6),
            E("M23 28h24", .none, .line, 2.6, [5, 3.5]),
            E("M23 34h14", .none, .line, 2.6),
        ]
        g["txt"] = [
            E("M23 15h24M23 21h24M23 27h24M23 33h18", .none, .line, 2.6),
        ]
        g["md"] = [
            E("M23 29V16l5.5 7 5.5-7v13", .none, .line, 2.6),
            E("M42 16v12M38 24l4 4 4-4", .none, .accent, 2.6),
        ]
        g["html"] = [
            E("M29 17l-6 7 6 7M41 17l6 7-6 7", .none, .line, 2.6),
            E("M37 14.5l-4 19", .none, .accent, 2.6),
        ]
        g["epub"] = [
            E("M35 17c-4-2.6-9-2.6-12 0v15c3-2.6 8-2.6 12 0 4-2.6 9-2.6 12 0V17c-3-2.6-8-2.6-12 0z", .none, .line, 2.6),
            E("M35 17v15", .none, .accent, 2.6),
        ]
        g["xlsx"] = [
            E("M25.5 15H44.5a2.5 2.5 0 0 1 2.5 2.5V31.5a2.5 2.5 0 0 1 -2.5 2.5H25.5a2.5 2.5 0 0 1 -2.5 -2.5V17.5a2.5 2.5 0 0 1 2.5 -2.5z", .none, .line, 2.6),
            E("M23 28h24M31 15v19", .none, .line, 2.6),
            E("M23 21.5h24", .none, .accent, 2.6),
        ]
        g["csv"] = [
            E("M23 17h8M37 17h10M23 24h11M40 24h7M23 31h6M35 31h12", .none, .line, 2.6),
            E("M34 17h.01M37 24h.01M32 31h.01", .none, .accent, 4),
        ]
        g["json"] = [
            E("M29 14.5c-3.5 0-4.5 1.5-4.5 4.5v2.5c0 2-1 2.5-2.5 2.5 1.5 0 2.5.5 2.5 2.5V29c0 3 1 4.5 4.5 4.5M41 14.5c3.5 0 4.5 1.5 4.5 4.5v2.5c0 2 1 2.5 2.5 2.5-1.5 0-2.5.5-2.5 2.5V29c0 3-1 4.5-4.5 4.5", .none, .line, 2.6),
            E("M35 24h.01", .none, .accent, 4),
        ]
        g["zip"] = [
            E("M35 13v14M31.5 16.5h7M31.5 21.5h7", .none, .line, 2.6),
            E("M33.2 27H36.8a2.2 2.2 0 0 1 2.2 2.2V31.8a2.2 2.2 0 0 1 -2.2 2.2H33.2a2.2 2.2 0 0 1 -2.2 -2.2V29.2a2.2 2.2 0 0 1 2.2 -2.2z", .none, .accent, 2.6),
        ]
        g["unpack"] = [
        ]
        g["sign"] = [
            E("M23 15h24M23 21h12", .none, .line, 2.6),
            E("M23 33c2-6 4-9 6-9s-1 8 1.5 8 2-5 4-5 1.5 3 3.5 3 2-2.5 3-3.5", .none, .accent, 2.6),
            E("M23 36.2h24", .none, .line, 1.8, [], 0.6),
        ]
        g["merge"] = [
            E("M23 16h5c4 0 7 2 7 7M23 32h5c4 0 7-2 7-7", .none, .line, 2.6),
            E("M35 23h10M41.5 19.5L45 23l-3.5 3.5", .none, .accent, 2.6),
        ]
        g["split"] = [
            E("M22 15h7M22 21h7M22 27h7M42 21h9M42 27h9M42 33h6", .none, .line, 2.6),
        ]
        g["compress"] = [
            E("M28 15h16M28 21h16M28 27h10", .none, .line, 2.6),
        ]
        return g
    }
}
