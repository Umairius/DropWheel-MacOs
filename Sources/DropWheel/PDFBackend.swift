import AppKit
import PDFKit

/// PDF tools, all via PDFKit: merge, split, compress, render to images.
enum PDFBackend {
    private static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConvError("Couldn't open \(url.lastPathComponent)") }
        if doc.isLocked { throw ConvError("\(url.lastPathComponent) is password-protected") }
        return doc
    }

    static func uniqueFolder(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + " (\(n))")
            n += 1
        }
        return candidate
    }

    // MARK: Merge (PDFs and/or images → one PDF, in filename order)

    static func merge(_ inputs: [URL], to out: URL) throws -> URL {
        let sorted = Registry.naturalSorted(inputs)
        let result = PDFDocument()
        var keepAlive: [PDFDocument] = []
        for url in sorted {
            if Registry.normalize(url.pathExtension) == "pdf" {
                let doc = try open(url)
                keepAlive.append(doc)
                let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
                for p in pages {
                    let copy = (p.copy() as? PDFPage) ?? p
                    result.insert(copy, at: result.pageCount)
                }
            } else {
                result.insert(try ImageBackend.pdfPage(from: url), at: result.pageCount)
            }
        }
        guard result.pageCount > 0, result.write(to: out) else { throw ConvError("Couldn't write the merged PDF") }
        return out
    }

    // MARK: Split (one PDF → folder of single-page PDFs)

    static func split(_ input: URL, near out: URL) throws -> URL {
        let doc = try open(input)
        guard doc.pageCount > 1 else { throw ConvError("This PDF has only one page") }
        let folder = uniqueFolder(out.deletingPathExtension())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = input.deletingPathExtension().lastPathComponent
        let digits = max(3, String(doc.pageCount).count)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let copy = page.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(copy, at: 0)
            let name = "\(base)-" + String(format: "%0\(digits)d", i + 1) + ".pdf"
            guard single.write(to: folder.appendingPathComponent(name)) else {
                throw ConvError("Couldn't write page \(i + 1)")
            }
        }
        return folder
    }

    // MARK: Compress

    /// The PDFKit image-optimization write options only exist on macOS 13.4+.
    static var canCompress: Bool {
        if #available(macOS 13.4, *) { return true } else { return false }
    }

    static func compress(_ input: URL, to out: URL) throws {
        guard #available(macOS 13.4, *) else { throw ConvError("PDF compression needs macOS 13.4 or newer") }
        let doc = try open(input)
        let ok = doc.write(to: out, withOptions: [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ])
        guard ok else { throw ConvError("Couldn't write the compressed PDF") }
        func bytes(_ u: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0
        }
        if bytes(out) >= bytes(input) {
            try? FileManager.default.removeItem(at: out)
            throw ConvError("Couldn't make this PDF any smaller (it's probably already optimized)")
        }
    }

    // MARK: PDF → PNG/JPG (200 dpi). One page → a file; several → a folder.

    static func toImages(_ input: URL, to out: URL, ext: String) throws -> URL {
        let doc = try open(input)
        guard doc.pageCount > 0 else { throw ConvError("This PDF has no pages") }
        let scale: CGFloat = 200.0 / 72.0

        func render(_ index: Int) throws -> CGImage {
            guard let page = doc.page(at: index) else { throw ConvError("Missing page \(index + 1)") }
            var box = page.bounds(for: .mediaBox)
            if page.rotation % 180 != 0 { box = NSRect(x: 0, y: 0, width: box.height, height: box.width) }
            var size = NSSize(width: box.width * scale, height: box.height * scale)
            let longest = max(size.width, size.height)
            if longest > 6000 {
                let f = 6000 / longest
                size = NSSize(width: size.width * f, height: size.height * f)
            }
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ConvError("Couldn't render page \(index + 1)")
            }
            return cg
        }

        if doc.pageCount == 1 {
            try ImageBackend.write(try render(0), to: out, ext: ext)
            return out
        }

        let base = input.deletingPathExtension().lastPathComponent
        let folder = uniqueFolder(out.deletingLastPathComponent().appendingPathComponent(base + " pages"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = max(3, String(doc.pageCount).count)
        for i in 0..<doc.pageCount {
            let name = "\(base)-" + String(format: "%0\(digits)d", i + 1) + "." + ext
            try ImageBackend.write(try render(i), to: folder.appendingPathComponent(name), ext: ext)
        }
        return folder
    }
}
