import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Image conversion using Apple's ImageIO: no external tools.
enum ImageBackend {
    private static let readable: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    private static let writable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// Checked at runtime: e.g. WebP/AVIF decoding depends on the macOS version.
    static func canRead(_ ext: String) -> Bool {
        guard let t = UTType(filenameExtension: ext) else { return false }
        return readable.contains(t.identifier)
    }

    static func canWrite(_ ext: String) -> Bool {
        guard let t = UTType(filenameExtension: ext) else { return false }
        return writable.contains(t.identifier)
    }

    static func convert(_ input: URL, to out: URL, ext: String) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ConvError("Couldn't read \(input.lastPathComponent) as an image")
        }
        guard let type = UTType(filenameExtension: ext),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvError("This Mac can't write .\(ext) images")
        }

        var props: [CFString: Any] = [:]
        if ext == "jpg" || ext == "heic" { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }

        let info = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let hasAlpha = (info?[kCGImagePropertyHasAlpha] as? Bool) ?? false

        if hasAlpha && (ext == "jpg" || ext == "bmp") {
            // JPEG/BMP have no transparency; flatten onto white instead of getting black.
            let flat = try flattenOnWhite(try orientedImage(src))
            CGImageDestinationAddImage(dest, flat, props as CFDictionary)
        } else {
            // Copies metadata and keeps orientation intact.
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConvError("The image encoder failed") }
    }

    /// Full-size image with EXIF orientation applied.
    static func orientedImage(_ src: CGImageSource) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConvError("Couldn't decode image")
        }
        return img
    }

    static func flattenOnWhite(_ img: CGImage) throws -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConvError("Couldn't allocate an image buffer")
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        guard let flat = ctx.makeImage() else { throw ConvError("Couldn't flatten image") }
        return flat
    }

    /// Encode an in-memory image (used by PDF to image).
    static func write(_ img: CGImage, to url: URL, ext: String) throws {
        let image: CGImage
        if ext == "jpg" || ext == "bmp" { image = try flattenOnWhite(img) } else { image = img }
        guard let type = UTType(filenameExtension: ext),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvError("This Mac can't write .\(ext) images")
        }
        let props = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { throw ConvError("The image encoder failed") }
    }

    /// One PDF page sized to fit A4's long side, full-resolution pixels kept.
    static func pdfPage(from url: URL) throws -> PDFPage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ConvError("Couldn't read \(url.lastPathComponent) as an image")
        }
        let cg = try orientedImage(src)
        let longSide = 842.0
        let scale = min(1.0, longSide / Double(max(cg.width, cg.height)))
        let size = NSSize(width: Double(cg.width) * scale, height: Double(cg.height) * scale)
        guard let page = PDFPage(image: NSImage(cgImage: cg, size: size)) else {
            throw ConvError("Couldn't make a PDF page from \(url.lastPathComponent)")
        }
        return page
    }
}
