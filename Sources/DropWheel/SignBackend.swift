import AppKit
import CryptoKit
import Foundation
import PDFKit

// MARK: - What can be signed, and how it gets burned in

enum SignBackend {
    static let docKinds: Set<String> = ["docx", "doc", "odt", "rtf"]
    static let imageKinds: Set<String> = ["jpg", "png", "heic", "tiff", "gif", "bmp", "webp"]

    static func canSign(kind: String) -> Bool {
        if kind == "pdf" { return true }
        guard docKinds.contains(kind) || imageKinds.contains(kind) else { return false }
        return Registry.recipe(id: "pdf", type: kind) != nil
    }

    // MARK: Input -> PDF

    struct Prepared {
        let pdf: URL
        let isTemp: Bool
        let note: String?       // shown in the window when the conversion may have shifted the layout

        func cleanup() {
            if isTemp { try? FileManager.default.removeItem(at: pdf) }
        }
    }

    /// PDFs are used as they are. Documents and images go through the normal "to PDF" recipe first.
    static func prepare(_ url: URL) throws -> Prepared {
        let kind = Registry.kind(of: url)
        if kind == "pdf" { return Prepared(pdf: url, isTemp: false, note: nil) }
        guard canSign(kind: kind), let rec = Registry.recipe(id: "pdf", type: kind) else {
            throw ConvError("DropWheel can't sign .\(kind) files yet")
        }
        let tmp = Backends.tempURL(ext: "pdf")
        _ = try rec.run([url], tmp)
        guard FileManager.default.fileExists(atPath: tmp.path) else {
            throw ConvError("The conversion to PDF produced no file")
        }
        var note: String?
        if docKinds.contains(kind) && rec.engine == .builtin {
            note = "Converted with the basic renderer, so the layout may differ from your original. LibreOffice gives an exact conversion."
        }
        return Prepared(pdf: tmp, isTemp: true, note: note)
    }

    /// Next to the original, never replacing it: "name signed.pdf", " (1)" if taken.
    static func outputURL(for original: URL) -> URL {
        Converter.uniqueOutput(in: original.deletingLastPathComponent(),
                               base: Converter.baseName(of: original) + " signed", ext: "pdf")
    }

    // MARK: Burn in

    struct Outcome {
        let output: URL
        let engine: String
        var problems: [String]      // empty = the self-check passed
    }

    /// Writes a signed copy. The original is never modified; a fingerprint taken before and after proves it.
    static func apply(_ stamps: [Stamp], to input: URL, output: URL) throws -> Outcome {
        guard !stamps.isEmpty else { throw ConvError("There's nothing to place on the page") }
        guard let doc = PDFDocument(url: input) else { throw ConvError("Couldn't open \(input.lastPathComponent)") }
        if doc.isLocked { throw ConvError("\(input.lastPathComponent) is password-protected") }
        if stamps.contains(where: { $0.page < 0 || $0.page >= doc.pageCount }) {
            throw ConvError("A stamp points at a page that doesn't exist")
        }

        let before = try fingerprint(input)
        let boxesAgree = Set(stamps.map { $0.page }).allSatisfy { p in
            doc.page(at: p).map { PageGeometry(page: $0).qpdfExact } ?? false
        }
        var engine = ""
        var problems: [String] = []
        var done = false

        // qpdf keeps links, forms and bookmarks. It's only used where it's proven exact, and a result that
        // fails its own self-check is thrown away in favour of the built-in engine: never ship it.
        if let q = Tools.qpdf, boxesAgree {
            do {
                try qpdfStamp(q, doc: doc, stamps: stamps, input: input, output: output)
                if verify(original: input, output: output, stamps: stamps).isEmpty {
                    engine = "qpdf: exact, keeps links, forms and bookmarks"
                    done = true
                } else {
                    try? FileManager.default.removeItem(at: output)
                }
            } catch {
                try? FileManager.default.removeItem(at: output)
            }
        }
        if !done {
            do {
                try nativeStamp(doc: doc, stamps: stamps, input: input, output: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            if Tools.qpdf == nil {
                engine = "built-in: pages are redrawn, so links and form fields are not kept"
            } else if !boxesAgree {
                engine = "built-in: this PDF's crop/trim boxes would make qpdf shift the page, so pages are redrawn (links and form fields are not kept)"
            } else {
                engine = "built-in: qpdf's result failed the self-check, so pages are redrawn (links and form fields are not kept)"
            }
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw ConvError("No signed file was produced")
            }
            problems = verify(original: input, output: output, stamps: stamps)
        }
        if (try? fingerprint(input)) != before { problems.append("the original file changed while signing") }
        return Outcome(output: output, engine: engine, problems: problems)
    }

    private static func fingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Engine 1: qpdf overlay (only the stamped pages are touched)

    private static func qpdfStamp(_ exe: String, doc: PDFDocument, stamps: [Stamp], input: URL, output: URL) throws {
        let pages = Array(Set(stamps.map { $0.page })).sorted()
        let stampPDF = Backends.tempURL(ext: "pdf")
        defer { try? FileManager.default.removeItem(at: stampPDF) }
        try writeStampPDF(doc: doc, pages: pages, stamps: stamps, to: stampPDF)

        let to = pages.map { String($0 + 1) }.joined(separator: ",")
        let from = (1...pages.count).map { String($0) }.joined(separator: ",")
        try runQpdf(exe, [input.path, "--overlay", stampPDF.path, "--from=" + from, "--to=" + to, "--", output.path])
    }

    /// One stamp page per signed page, in upright space. This path only runs when crop = trim = media
    /// (see PageGeometry.qpdfExact), where qpdf fits the stamp page to the page 1:1 at every rotation;
    /// trimFrame is then simply the whole page.
    private static func writeStampPDF(doc: PDFDocument, pages: [Int], stamps: [Stamp], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConvError("Couldn't create the stamp page")
        }
        for p in pages {
            guard let page = doc.page(at: p) else { continue }
            let frame = PageGeometry(page: page).trimFrame
            var pageBox = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: frame.height)       // PDF is y-up, stamps are y-down
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -frame.minX, y: -frame.minY)
            for s in stamps where s.page == p { s.draw(in: ctx) }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// qpdf exits 3 for "worked, with warnings".
    private static func runQpdf(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || p.terminationStatus == 3 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ConvError("qpdf failed (exit \(p.terminationStatus)): \(String(text.suffix(300)))")
        }
    }

    // MARK: Engine 2: redraw every page with CoreGraphics (no extra tools, loses links and form fields)

    private static func nativeStamp(doc: PDFDocument, stamps: [Stamp], input: URL, output: URL) throws {
        guard let cgDoc = CGPDFDocument(input as CFURL) else { throw ConvError("Couldn't read the PDF") }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(output as CFURL, mediaBox: &box, nil) else {
            throw ConvError("Couldn't create the output PDF")
        }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let cgPage = cgDoc.page(at: i + 1) else {
                throw ConvError("Couldn't read page \(i + 1)")
            }
            let size = PageGeometry(page: page).size
            var pageBox = CGRect(origin: .zero, size: size)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            ctx.saveGState()
            // Maps the cropped, rotated page into an upright box starting at the origin.
            ctx.concatenate(cgPage.getDrawingTransform(.cropBox, rect: pageBox, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(cgPage)
            ctx.restoreGState()

            let mine = stamps.filter { $0.page == i }
            if !mine.isEmpty {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                for s in mine { s.draw(in: ctx) }
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: Self-check
    //
    // Re-open what we just wrote and prove it: same pages, text still selectable, nothing else on the
    // page moved, and the signature really is there. Metric calibrated on real output: a good qpdf
    // result changes 0.0% of pixels outside the signature, a 4 pt shift changes 6%, a missing
    // signature leaves the inside untouched.

    private static func verify(original: URL, output: URL, stamps: [Stamp]) -> [String] {
        guard let a = PDFDocument(url: original), let b = PDFDocument(url: output) else {
            return ["couldn't reopen the files to check them"]
        }
        if a.pageCount != b.pageCount { return ["the page count changed (\(a.pageCount) to \(b.pageCount))"] }

        var problems: [String] = []
        let ta = (a.string ?? "").filter { !$0.isWhitespace }.count
        let tb = (b.string ?? "").filter { !$0.isWhitespace }.count
        if ta >= 50 && Double(tb) < Double(ta) * 0.97 {
            problems.append("selectable text shrank (\(ta) to \(tb) characters)")
        }

        var check = Set(stamps.map { $0.page })
        check.insert(0)
        for i in check.sorted() {
            guard let pa = a.page(at: i), let pb = b.page(at: i),
                  let ga = PageRaster.gray(pa, geo: PageGeometry(page: pa), scale: 1),
                  let gb = PageRaster.gray(pb, geo: PageGeometry(page: pb), scale: 1),
                  ga.w == gb.w, ga.h == gb.h else {
                problems.append("page \(i + 1) came out a different size")
                continue
            }
            let rects = stamps.filter { $0.page == i }.map { $0.rect }
            let w = ga.w, h = ga.h

            var masked = [Bool](repeating: false, count: w * h)
            for r in rects {
                let x0 = max(Int((Double(r.minX) - 6) * ga.sx), 0), x1 = min(Int((Double(r.maxX) + 6) * ga.sx) + 1, w)
                let y0 = max(Int((Double(r.minY) - 6) * ga.sy), 0), y1 = min(Int((Double(r.maxY) + 6) * ga.sy) + 1, h)
                if x1 > x0 && y1 > y0 {
                    for y in y0..<y1 { for x in x0..<x1 { masked[y * w + x] = true } }
                }
            }
            var diff = 0, total = 0
            for idx in 0..<(w * h) where !masked[idx] {
                total += 1
                if abs(Int(ga.px[idx]) - Int(gb.px[idx])) > 48 { diff += 1 }
            }
            let outside = total > 0 ? Double(diff) / Double(total) : 0
            if outside > 0.005 {
                problems.append(String(format: "page %ld changed outside the signature (%.1f%% of it)", i + 1, outside * 100))
            }

            for r in rects {
                let x0 = max(Int(Double(r.minX) * ga.sx), 0), x1 = min(Int(Double(r.maxX) * ga.sx), w)
                let y0 = max(Int(Double(r.minY) * ga.sy), 0), y1 = min(Int(Double(r.maxY) * ga.sy), h)
                guard x1 > x0, y1 > y0 else { continue }
                var changed = 0
                for y in y0..<y1 {
                    for x in x0..<x1 where abs(Int(ga.px[y * w + x]) - Int(gb.px[y * w + x])) > 48 { changed += 1 }
                }
                if Double(changed) / Double((x1 - x0) * (y1 - y0)) < 0.003 {
                    problems.append("the stamp on page \(i + 1) doesn't show up in the result")
                }
            }
        }
        return problems
    }
}

// MARK: - First placement (shared by the window and the CLI, so the CLI tests the real logic)

enum SignPlan {
    static func dateString() -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("ddMMyyyy")
        return f.string(from: Date())
    }

    /// The signature on the best spot, the date next to it, initials where the document asks for them.
    static func initialStamps(doc: PDFDocument, spots: [Spot], signature: Ink, initials: Ink?, withDate: Bool) -> [Stamp] {
        func pageSize(_ i: Int) -> CGSize {
            doc.page(at: i).map { PageGeometry(page: $0).size } ?? CGSize(width: 595, height: 842)
        }
        var out: [Stamp] = []
        guard let primary = spots.first(where: { $0.kind == .signature }) else { return out }

        var sig = Stamp.make(kind: .signature, ink: signature, page: primary.page,
                             rect: StampSizing.rect(for: primary, kind: .signature, aspect: signature.aspect,
                                                    pageSize: pageSize(primary.page)))
        sig.ghost = true
        out.append(sig)

        if withDate {
            let near = spots.filter { $0.kind == .date && $0.page == primary.page && abs($0.baseline - primary.baseline) < 170 }
                .min { abs($0.baseline - primary.baseline) < abs($1.baseline - primary.baseline) }
            if let d = near {
                let text = dateString()
                let aspect = TextInk.aspect(of: text, fontName: "Helvetica")
                var st = Stamp.makeText(text, page: d.page,
                                        rect: StampSizing.rect(for: d, kind: .date, aspect: aspect, pageSize: pageSize(d.page)))
                st.ghost = true
                out.append(st)
            }
        }

        if let ini = initials {
            var seen = Set<Int>()
            for s in spots where s.kind == .initials && s.score >= 6 && !seen.contains(s.page) {
                seen.insert(s.page)
                var st = Stamp.make(kind: .initials, ink: ini, page: s.page,
                                    rect: StampSizing.rect(for: s, kind: .initials, aspect: ini.aspect, pageSize: pageSize(s.page)))
                st.ghost = true
                out.append(st)
            }
        }
        return out
    }
}

// MARK: - Headless test mode: DropWheel --preflight / --spots / --sign

enum SignCLI {
    private static func fail(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func preflight(_ paths: [String]) -> Int32 {
        var status: Int32 = 0
        for p in paths {
            let url = URL(fileURLWithPath: p)
            do {
                let prepared = try SignBackend.prepare(url)
                defer { prepared.cleanup() }
                let pf = PDFInspector.inspect(prepared.pdf, doc: PDFDocument(url: prepared.pdf))
                print("== \(url.lastPathComponent): \(pf.chipText)")
                print(pf.report)
            } catch {
                fail("✗ \(url.lastPathComponent): \(error.localizedDescription)")
                status = 1
            }
        }
        return status
    }

    static func spots(_ paths: [String]) -> Int32 {
        var status: Int32 = 0
        for p in paths {
            let url = URL(fileURLWithPath: p)
            do {
                let prepared = try SignBackend.prepare(url)
                defer { prepared.cleanup() }
                guard let doc = PDFDocument(url: prepared.pdf) else { throw ConvError("Couldn't open it") }
                let spots = SpotFinder.find(in: doc, printedName: SignatureStore.shared.printedName)
                print("== \(url.lastPathComponent): \(doc.pageCount) pages, \(spots.count) spots")
                print(SpotFinder.describe(spots))
            } catch {
                fail("✗ \(url.lastPathComponent): \(error.localizedDescription)")
                status = 1
            }
        }
        return status
    }

    /// DropWheel --sign <file> [--name "Umair Khan"] [--blue] [--no-date]
    /// Signs with a typed signature at the best auto-spot: the same path the window takes.
    static func sign(_ args: [String]) -> Int32 {
        var file: String?
        var name = NSFullUserName()
        var color = InkColor.black
        var date = true
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--name":
                i += 1
                if i < args.count { name = args[i] }
            case "--blue": color = .blue
            case "--no-date": date = false
            default: if file == nil { file = args[i] }
            }
            i += 1
        }
        guard let f = file else {
            fail("usage: DropWheel --sign <file> [--name \"Your Name\"] [--blue] [--no-date]")
            return 2
        }
        do {
            let url = URL(fileURLWithPath: f)
            let prepared = try SignBackend.prepare(url)
            defer { prepared.cleanup() }
            guard let doc = PDFDocument(url: prepared.pdf) else { throw ConvError("Couldn't open it") }
            if doc.isLocked { throw ConvError("This PDF is password-protected") }

            let pf = PDFInspector.inspect(prepared.pdf, doc: doc)
            print("preflight: \(pf.chipText)")
            for x in pf.findings where x.level >= .caution { print("  ! \(x.title)") }

            let spots = SpotFinder.find(in: doc, printedName: name)
            print(SpotFinder.describe(spots))

            let font = SignFonts.available[0].ps
            let ink = Ink(source: .typed(name, font), color: color, aspect: TextInk.aspect(of: name, fontName: font))
            let stamps = SignPlan.initialStamps(doc: doc, spots: spots, signature: ink, initials: nil, withDate: date)
            guard !stamps.isEmpty else { throw ConvError("No place to sign was found") }

            let out = SignBackend.outputURL(for: url)
            let outcome = try SignBackend.apply(stamps, to: prepared.pdf, output: out)
            print("✓ \(outcome.output.path)")
            print("engine: \(outcome.engine)")
            if outcome.problems.isEmpty {
                print("self-check: passed")
                return 0
            }
            for p in outcome.problems { fail("self-check: \(p)") }
            return 1
        } catch {
            fail("✗ \(error.localizedDescription)")
            return 1
        }
    }
}
