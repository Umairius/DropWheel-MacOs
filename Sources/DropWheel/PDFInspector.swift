import CoreGraphics
import Foundation
import PDFKit

// MARK: - Result types

enum FlagLevel: Int, Comparable {
    case info = 0, caution = 1, danger = 2
    static func < (a: FlagLevel, b: FlagLevel) -> Bool { a.rawValue < b.rawValue }
}

struct Finding {
    let level: FlagLevel
    let title: String
    let detail: String
}

struct Preflight {
    var findings: [Finding] = []

    /// nil = nothing worth flagging.
    var level: FlagLevel? { findings.map { $0.level }.max() }

    /// Wording is deliberate: these are heuristics. We say what we found, never "safe".
    var chipText: String {
        switch level {
        case .none: return "No red flags found"
        case .some(.info):
            let n = findings.count
            return n == 1 ? "No red flags found (1 note)" : "No red flags found (\(n) notes)"
        case .some(.caution): return findings.first { $0.level == .caution }?.title ?? "Worth a look"
        case .some(.danger): return findings.first { $0.level == .danger }?.title ?? "Heads up"
        }
    }

    var report: String {
        if findings.isEmpty { return "Nothing unusual in the file structure.\n\nThis is a heuristic check, not a guarantee." }
        let marks: [FlagLevel: String] = [.danger: "RED", .caution: "AMBER", .info: "NOTE"]
        let body = findings.sorted { $0.level > $1.level }
            .map { "[\(marks[$0.level] ?? "")] \($0.title)\n\($0.detail)" }
            .joined(separator: "\n\n")
        return body + "\n\nThis is a heuristic check, not a guarantee."
    }
}

// MARK: - Inspector

enum PDFInspector {
    private static let byteRangePattern = try? NSRegularExpression(
        pattern: "\\[\\s*(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s*\\]")
    private static let maxScan = 150 * 1024 * 1024

    static func inspect(_ url: URL, doc: PDFDocument?) -> Preflight {
        var pf = Preflight()
        var raw = RawFacts()
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0

        if size > maxScan {
            pf.findings.append(Finding(level: .info, title: "Too large to scan fully",
                                       detail: "The structure check was skipped because the file is over 150 MB."))
        } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            raw = scanRaw(data)
        }

        let s = structure(url)

        // ---- Existing digital signatures: the big one.
        if raw.signatures > 0 {
            let n = raw.signatures
            pf.findings.append(Finding(
                level: .danger,
                title: n == 1 ? "Already digitally signed" : "Already digitally signed (\(n) signatures)",
                detail: "Saving a changed copy breaks \(n == 1 ? "that signature" : "those signatures"): it won't verify any more. "
                    + "Your original file is never touched. DropWheel adds a visual signature, not a cryptographic one."))
            if raw.bytesAfterLastSignature > 0 {
                pf.findings.append(Finding(
                    level: .danger,
                    title: "Content was added after the last signature",
                    detail: "\(raw.bytesAfterLastSignature) bytes follow the last signed region. Some tools add validation data there on purpose, "
                        + "but it's also exactly how edits get slipped in after someone signed. Be sure you trust where this file came from."))
            }
            if raw.rangeBeyondFile {
                pf.findings.append(Finding(
                    level: .danger,
                    title: "A signature claims more data than the file contains",
                    detail: "The file is shorter than its signed range says. It was cut, damaged or edited."))
            }
        }

        // ---- Things that deserve a look.
        if s.certified {
            pf.findings.append(Finding(
                level: .caution, title: "Certified document",
                detail: "The author limited which changes are allowed after certifying. Adding a visual signature may not be permitted by them."))
        }
        if raw.hasJavaScript || s.hasJavaScript {
            pf.findings.append(Finding(
                level: .caution, title: "Contains JavaScript",
                detail: "Normal in some forms, but it can also change what you see or do things when the file opens."))
        }
        if raw.hasLaunch || s.hasLaunch {
            pf.findings.append(Finding(
                level: .caution, title: "Can launch other programs",
                detail: "This PDF contains an action that starts an external program or file. Don't open it unless you know where it came from."))
        }
        if raw.hasEmbeddedFiles || s.hasEmbeddedFiles {
            pf.findings.append(Finding(
                level: .caution, title: "Has files embedded inside",
                detail: "Other documents are attached within this PDF. Signing covers the visible pages, not those attachments."))
        }
        if let doc, doc.isEncrypted && !doc.allowsDocumentChanges {
            pf.findings.append(Finding(
                level: .caution, title: "The author restricted editing",
                detail: "We save a signed copy, but the restriction isn't carried over to it."))
        }

        // ---- Notes.
        if raw.eofCount >= 3 && raw.signatures == 0 {
            pf.findings.append(Finding(
                level: .info, title: "Saved \(raw.eofCount) times",
                detail: "The file was changed and re-saved on top of itself \(raw.eofCount - 1) times. Normal for edited documents."))
        }
        if let doc, hasNoTextLayer(doc) {
            pf.findings.append(Finding(
                level: .info, title: "Looks like a scan",
                detail: "No selectable text. DropWheel reads the page with OCR to find where to sign."))
        }
        if s.emptySignatureFields > 0 {
            pf.findings.append(Finding(
                level: .info, title: "Has a digital-signature field",
                detail: "If the other party needs a cryptographic signature (eID, itsme, DocuSign), they'll have to send their own flow. "
                    + "DropWheel puts your signature image on the page."))
        }
        if s.formFields > 0 {
            pf.findings.append(Finding(
                level: .info, title: "Has fillable form fields",
                detail: Tools.qpdf != nil
                    ? "They stay fillable in the signed copy."
                    : "Without qpdf the basic engine can't keep form fields. Run: brew install qpdf"))
        }
        if let who = s.editorSmell {
            pf.findings.append(Finding(
                level: .info, title: "Last processed by \(who)",
                detail: "Nothing wrong with that by itself. Worth knowing if you expected the original program's output."))
        }
        if let gap = s.daysModifiedAfterCreated, gap > 30 {
            pf.findings.append(Finding(
                level: .info, title: "Modified \(gap) days after it was created",
                detail: "The file's own dates say it was changed long after creation."))
        }
        return pf
    }

    // MARK: Raw byte scan (works on the file as stored; catches what hides in plain sight)

    private struct RawFacts {
        var signatures = 0
        var bytesAfterLastSignature = 0
        var rangeBeyondFile = false
        var eofCount = 0
        var hasJavaScript = false
        var hasLaunch = false
        var hasEmbeddedFiles = false
    }

    private static func scanRaw(_ data: Data) -> RawFacts {
        var f = RawFacts()
        f.eofCount = data.occurrences(of: "%%EOF").count
        f.hasJavaScript = data.hasToken("/JavaScript") || data.hasToken("/JS")
        f.hasLaunch = data.hasToken("/Launch")
        f.hasEmbeddedFiles = data.hasToken("/EmbeddedFile")

        // The signed bytes are [a, a+b) and [c, c+d). Real signatures have non-zero lengths;
        // unsigned templates carry placeholder zeros.
        var lastCovered = 0
        for loc in data.occurrences(of: "/ByteRange") {
            let end = min(loc + 220, data.count)
            let text = String(decoding: data[(loc + 10)..<end], as: UTF8.self)
            guard let rx = byteRangePattern,
                  let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            var n: [Int] = []
            for i in 1...4 {
                guard let r = Range(m.range(at: i), in: text), let v = Int(text[r]) else { break }
                n.append(v)
            }
            guard n.count == 4, n[1] > 0, n[3] > 0 else { continue }
            f.signatures += 1
            lastCovered = max(lastCovered, n[2] + n[3])
        }
        if f.signatures > 0 {
            var stripped = data.count
            while stripped > 0, [0x0A, 0x0D, 0x20, 0x09, 0x00].contains(data[stripped - 1]) { stripped -= 1 }
            if lastCovered > data.count { f.rangeBeyondFile = true }
            f.bytesAfterLastSignature = max(0, stripped - lastCovered)
        }
        return f
    }

    // MARK: Structure (CGPDF decodes object streams, so this sees what the raw scan can't)

    private struct StructFacts {
        var certified = false
        var hasJavaScript = false
        var hasLaunch = false
        var hasEmbeddedFiles = false
        var formFields = 0
        var emptySignatureFields = 0
        var editorSmell: String?
        var daysModifiedAfterCreated: Int?
    }

    private static let editorNames = ["photoshop", "gimp", "ilovepdf", "smallpdf", "sejda", "pdfescape",
                                      "pdf24", "canva", "pdfcandy", "inkscape", "illustrator"]

    private static func structure(_ url: URL) -> StructFacts {
        var s = StructFacts()
        guard let cg = CGPDFDocument(url as CFURL), cg.isUnlocked, let cat = cg.catalog else { return s }

        if let perms = dict(cat, "Perms"), has(perms, "DocMDP") { s.certified = true }

        if let names = dict(cat, "Names") {
            if has(names, "JavaScript") { s.hasJavaScript = true }
            if has(names, "EmbeddedFiles") { s.hasEmbeddedFiles = true }
        }
        if let open = dict(cat, "OpenAction") { flagAction(open, &s) }
        if let aa = dict(cat, "AA") {
            // Document-level additional actions (will close / save / print): in practice always scripts.
            s.hasJavaScript = s.hasJavaScript || ["WC", "WS", "DS", "WP", "DP"].contains { has(aa, $0) }
        }

        if let form = dict(cat, "AcroForm"), let fields = array(form, "Fields") {
            func walk(_ arr: CGPDFArrayRef, _ depth: Int) {
                for i in 0..<CGPDFArrayGetCount(arr) {
                    var fd: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(arr, i, &fd), let f = fd else { continue }
                    if let ft = name(f, "FT") {
                        if ft == "Sig" {
                            if !has(f, "V") { s.emptySignatureFields += 1 }
                        } else {
                            s.formFields += 1
                        }
                    }
                    if depth < 8, let kids = array(f, "Kids") { walk(kids, depth + 1) }
                }
            }
            walk(fields, 0)
        }

        // Page-level actions (links that launch programs or run scripts).
        for p in 1...max(1, min(cg.numberOfPages, 200)) {
            guard let page = cg.page(at: p), let pd = page.dictionary, let annots = array(pd, "Annots") else { continue }
            for i in 0..<min(CGPDFArrayGetCount(annots), 300) {
                var ad: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, i, &ad), let a = ad, let act = dict(a, "A") else { continue }
                flagAction(act, &s)
            }
        }

        if let info = cg.info {
            let producer = string(info, "Producer") ?? ""
            let creator = string(info, "Creator") ?? ""
            let both = (producer + " " + creator).lowercased()
            if let hit = editorNames.first(where: { both.contains($0) }) {
                s.editorSmell = producer.isEmpty ? creator : producer
                _ = hit
            }
            if let created = date(info, "CreationDate"), let mod = date(info, "ModDate") {
                let days = Int(mod.timeIntervalSince(created) / 86400)
                if days > 0 { s.daysModifiedAfterCreated = days }
            }
        }
        return s
    }

    private static func flagAction(_ d: CGPDFDictionaryRef, _ s: inout StructFacts) {
        switch name(d, "S") {
        case "Launch"?: s.hasLaunch = true
        case "JavaScript"?: s.hasJavaScript = true
        default: break
        }
    }

    private static func hasNoTextLayer(_ doc: PDFDocument) -> Bool {
        let n = min(doc.pageCount, 4)
        guard n > 0 else { return false }
        var chars = 0
        for i in 0..<n { chars += (doc.page(at: i)?.string ?? "").filter { !$0.isWhitespace }.count }
        return chars < 20
    }

    // MARK: CGPDF helpers

    private static func dict(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var out: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(d, key, &out) ? out : nil
    }

    private static func array(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var out: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(d, key, &out) ? out : nil
    }

    private static func has(_ d: CGPDFDictionaryRef, _ key: String) -> Bool {
        var o: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(d, key, &o)
    }

    private static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var p: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(d, key, &p), let p else { return nil }
        return String(cString: p)
    }

    private static func string(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var s: CGPDFStringRef?
        guard CGPDFDictionaryGetString(d, key, &s), let s, let c = CGPDFStringCopyTextString(s) else { return nil }
        return c as String
    }

    private static func date(_ d: CGPDFDictionaryRef, _ key: String) -> Date? {
        var s: CGPDFStringRef?
        guard CGPDFDictionaryGetString(d, key, &s), let s, let c = CGPDFStringCopyDate(s) else { return nil }
        return c as Date
    }
}

// MARK: - Byte search on Data

private extension Data {
    func occurrences(of token: String, limit: Int = 200_000) -> [Int] {
        guard let t = token.data(using: .ascii), !t.isEmpty else { return [] }
        var out: [Int] = []
        var from = startIndex
        while out.count < limit, from < endIndex, let r = range(of: t, options: [], in: from..<endIndex) {
            out.append(r.lowerBound)
            from = r.upperBound
        }
        return out
    }

    /// The token must not run into more letters: "/JS" is not "/JSON".
    func hasToken(_ token: String) -> Bool {
        let len = token.utf8.count
        for loc in occurrences(of: token, limit: 5000) {
            let next = loc + len
            if next >= endIndex { return true }
            let b = self[next]
            let alnum = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            if !alnum { return true }
        }
        return false
    }
}
