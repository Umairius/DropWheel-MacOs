import AppKit
import CoreText

/// The wheel's own voice: Bricolage Grotesque, a characterful grotesque with a *width* axis.
/// Long words (COMPRESS) get condensed instead of shrunk, so every label stays the same height and
/// readable. The font is embedded in the app (FontData.swift), so there's nothing to install.
/// If anything goes wrong loading it, everything falls back to the system font.
enum Brand {
    private static let weightAxis = NSNumber(value: 0x77676874)   // 'wght'
    private static let widthAxis = NSNumber(value: 0x77647468)    // 'wdth'

    private static var registered = false
    private static var fontName: String?

    /// True once the embedded font is registered. Safe to call repeatedly.
    @discardableResult
    static func register() -> Bool {
        if registered { return fontName != nil }
        registered = true
        guard let data = Data(base64Encoded: FontData.base64, options: .ignoreUnknownCharacters),
              let provider = CGDataProvider(data: data as CFData),
              let cg = CGFont(provider) else { return false }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterGraphicsFont(cg, &error) else { return false }
        fontName = cg.postScriptName as String?
        return fontName != nil
    }

    /// weight 400...800, width 75 (condensed)...100 (normal).
    static func font(_ size: CGFloat, weight: CGFloat = 700, width: CGFloat = 100) -> NSFont {
        register()
        if let name = fontName {
            let w = max(400, min(800, weight))
            let x = max(75, min(100, width))
            let descriptor = NSFontDescriptor(fontAttributes: [
                .name: name,
                .variation: [weightAxis: NSNumber(value: Double(w)), widthAxis: NSNumber(value: Double(x))],
            ])
            if let f = NSFont(descriptor: descriptor, size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size, weight: systemWeight(weight))
    }

    /// The largest, widest version of the font that fits `maxWidth`: condense first (down to 75),
    /// and only if that still isn't enough, shrink the size (never below `minSize`).
    static func fitted(_ text: String, size: CGFloat, weight: CGFloat = 700, maxWidth: CGFloat,
                       minSize: CGFloat = 12) -> NSFont {
        func width(_ f: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: f]).width
        }
        var f = font(size, weight: weight, width: 100)
        if width(f) <= maxWidth { return f }
        for w in [90, 82, 75] as [CGFloat] {
            f = font(size, weight: weight, width: w)
            if width(f) <= maxWidth { return f }
        }
        // Still too wide at full condensing: shrink, but stay legible.
        let natural = width(f)
        let scaled = max(minSize, size * maxWidth / max(natural, 1))
        return font(scaled, weight: weight, width: 75)
    }

    private static func systemWeight(_ w: CGFloat) -> NSFont.Weight {
        if w >= 780 { return .heavy }
        if w >= 680 { return .bold }
        if w >= 580 { return .semibold }
        if w >= 480 { return .medium }
        return .regular
    }
}
