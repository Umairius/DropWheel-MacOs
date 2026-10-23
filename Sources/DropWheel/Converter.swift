import Foundation

/// One wheel segment: `id` is what gets run, `label` is what's shown.
struct Target: Equatable {
    let id: String
    let label: String
}

/// One way of doing `id` to files of type(s) `from`, using a given engine.
/// Order in `Registry.recipes` is priority: the first usable recipe for a file wins.
struct Recipe {
    let id: String
    let label: String
    let from: [String]        // input types. "*" accepts anything, "folder" is a directory
    let to: String            // output extension (used for naming)
    let suffix: String        // appended to the output name ("" for plain conversions)
    let engine: Engine
    let batch: Bool           // true: consumes all dropped files, produces one output
    let minInputs: Int        // batch recipes: how many dropped items it needs (merge 2, zip 1)
    let pure: Bool            // false for tools that must never trash the original (zip, unpack)
    let naming: (([URL]) -> String)?   // batch recipes: output base name (nil = first item's name + suffix)
    let when: () -> Bool      // extra runtime check (e.g. "this macOS can decode WebP")
    let run: ([URL], URL) throws -> URL

    var usable: Bool { engine.isAvailable && when() }
    func accepts(_ type: String) -> Bool { from.contains(type) || from.contains("*") }
    /// Only plain format conversions can "replace the original". Tools (merge/split/compress/zip/unpack) never do.
    var isPureConversion: Bool { pure && !batch && suffix.isEmpty }
}

enum Registry {
    static let aliases = [
        "htm": "html", "markdown": "md", "mdown": "md", "text": "txt",
        "jpeg": "jpg", "tif": "tiff", "heif": "heic", "mpeg": "mpg", "aif": "aiff",
        "tgz": "tar.gz", "tbz2": "tar.bz2", "tbz": "tar.bz2", "txz": "tar.xz",
    ]

    /// Wheel order (first = 12 o'clock, then clockwise). Chosen so the most likely target comes first
    /// for each kind of input: images → png/jpg, documents → pdf, video → mp4.
    static let displayOrder = [
        "jpg", "png", "pdf", "sign", "mp4", "mp3", "docx", "xlsx", "csv", "json", "md", "txt", "html", "rtf", "odt",
        "epub", "heic", "webp", "tiff", "gif", "bmp", "mov", "mkv", "webm", "m4a", "wav", "aiff", "flac", "ogg",
        "merge", "split", "compress", "zip", "unpack",
    ]

    static func normalize(_ ext: String) -> String {
        let e = ext.lowercased()
        return aliases[e] ?? e
    }

    /// What a dropped item is: "folder" for directories (checked first, because "Project v1.2" has a
    /// bogus extension), "tar.gz"-style for double extensions, otherwise the normalized extension.
    static func kind(of url: URL) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return "folder"
        }
        let name = url.lastPathComponent.lowercased()
        for double in ["tar.gz", "tar.bz2", "tar.xz"] where name.hasSuffix("." + double) {
            return double
        }
        return normalize(url.pathExtension)
    }

    static func naturalSorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static let recipes: [Recipe] = build()

    // MARK: - The catalogue

    private static func build() -> [Recipe] {
        var r: [Recipe] = []

        // Builders. `each`: one file in, one file out. `eachProducing`: recipe reports what it made
        // (a folder, for multi-page results). `batch`: all dropped files in, one file out.
        func each(_ from: [String], _ to: String, _ engine: Engine,
                  label: String? = nil, suffix: String = "", id: String? = nil,
                  when: @escaping () -> Bool = { true },
                  _ run: @escaping (URL, URL) throws -> Void) {
            r.append(Recipe(id: id ?? to, label: label ?? to.uppercased(), from: from, to: to, suffix: suffix,
                            engine: engine, batch: false, minInputs: 1, pure: true, naming: nil, when: when,
                            run: { ins, out in try run(ins[0], out); return out }))
        }
        func eachProducing(_ from: [String], _ to: String, _ engine: Engine,
                           label: String? = nil, suffix: String = "", id: String? = nil, pure: Bool = true,
                           _ run: @escaping (URL, URL) throws -> URL) {
            r.append(Recipe(id: id ?? to, label: label ?? to.uppercased(), from: from, to: to, suffix: suffix,
                            engine: engine, batch: false, minInputs: 1, pure: pure, naming: nil, when: { true },
                            run: { ins, out in try run(ins[0], out) }))
        }
        func batch(_ from: [String], id: String, label: String, to: String, suffix: String, _ engine: Engine,
                   _ run: @escaping ([URL], URL) throws -> URL) {
            r.append(Recipe(id: id, label: label, from: from, to: to, suffix: suffix,
                            engine: engine, batch: true, minInputs: 2, pure: false, naming: nil, when: { true },
                            run: run))
        }

        // ================= DOCUMENTS =================

        // To PDF. LibreOffice first: best fidelity for Office files.
        each(["docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp", "csv"], "pdf", .libreOffice) { i, o in
            try Backends.libreOffice(i, to: o, filter: "pdf")
        }
        // Built-in fallback: fine for simple documents, weak on complex layout.
        each(["docx", "doc", "odt", "rtf", "html", "md"] + Array(Backends.textLike), "pdf", .builtin) { i, o in
            try Backends.cocoaPDF(i, to: o)
        }
        // EPUB → PDF: via DOCX (pandoc), then whichever DOCX → PDF is best.
        each(["epub"], "pdf", .pandoc) { i, o in
            let tmp = Backends.tempURL(ext: "docx")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Backends.pandoc(i, to: tmp, extra: [])
            guard let rec = Registry.recipe(id: "pdf", type: "docx") else {
                throw ConvError("No DOCX → PDF converter available")
            }
            _ = try rec.run([tmp], o)
        }

        // Spreadsheets
        each(["xlsx", "xls", "ods"], "csv", .libreOffice) { i, o in try Backends.libreOffice(i, to: o, filter: "csv") }
        each(["csv", "xls", "ods"], "xlsx", .libreOffice) { i, o in try Backends.libreOffice(i, to: o, filter: "xlsx") }
        each(["csv"], "json", .builtin) { i, o in try DataBackend.csvToJSON(i, to: o) }
        each(["json"], "csv", .builtin) { i, o in try DataBackend.jsonToCSV(i, to: o) }

        // Markdown / ebooks (pandoc)
        each(["md"], "docx", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: ["-f", "gfm"]) }
        each(["md"], "odt", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: ["-f", "gfm"]) }
        each(["md"], "rtf", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: ["-f", "gfm", "-s"]) }
        each(["md"], "html", .pandoc) { i, o in
            try Backends.pandoc(i, to: o, extra: ["-f", "gfm", "-s", "--metadata", "pagetitle=Document"])
        }
        each(["md"], "txt", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: ["-f", "gfm", "-t", "plain", "--wrap=none"]) }
        each(["md"], "epub", .pandoc) { i, o in
            try Backends.pandoc(i, to: o, extra: ["-f", "gfm", "--metadata", "title=" + i.deletingPathExtension().lastPathComponent])
        }
        each(["docx"], "epub", .pandoc) { i, o in
            try Backends.pandoc(i, to: o, extra: ["--metadata", "title=" + i.deletingPathExtension().lastPathComponent])
        }
        each(["html"], "epub", .pandoc) { i, o in
            try Backends.pandoc(i, to: o, extra: ["-f", "html", "--metadata", "title=" + i.deletingPathExtension().lastPathComponent])
        }
        each(["docx", "epub"], "md", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: ["-t", "gfm", "--wrap=none"]) }
        each(["html"], "md", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: ["-f", "html", "-t", "gfm", "--wrap=none"]) }
        each(["epub"], "docx", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: []) }
        each(["epub"], "txt", .pandoc) { i, o in try Backends.pandoc(i, to: o, extra: ["-t", "plain", "--wrap=none"]) }
        // Without pandoc: tiny built-in Markdown renderer.
        each(["md"], "html", .builtin) { i, o in try Backends.markdownToHTMLFile(i, to: o) }
        each(["md"], "docx", .textutil) { i, o in try Backends.markdownToDocxViaTextutil(i, to: o) }

        // Word-processor formats via textutil (ships with macOS)
        let tuWritable = ["docx", "odt", "rtf", "html", "txt"]
        for t in tuWritable {
            each(["docx", "doc", "odt", "rtf", "html", "txt"], t, .textutil) { i, o in
                try Backends.textutil(i, to: o, format: t)
            }
        }

        // ================= PDF =================

        each(["pdf"], "txt", .builtin) { i, o in try Backends.pdfToText(i, to: o) }
        each(["pdf"], "docx", .libreOffice) { i, o in
            // Rough: PDFs don't carry document structure. Expect broken layout.
            try Backends.libreOffice(i, to: o, filter: "docx:MS Word 2007 XML", inFilter: "writer_pdf_import")
        }
        eachProducing(["pdf"], "png", .builtin) { i, o in try PDFBackend.toImages(i, to: o, ext: "png") }
        eachProducing(["pdf"], "jpg", .builtin) { i, o in try PDFBackend.toImages(i, to: o, ext: "jpg") }
        eachProducing(["pdf"], "pdf", .builtin, label: "SPLIT", suffix: " pages", id: "split") { i, o in
            try PDFBackend.split(i, near: o)
        }
        each(["pdf"], "pdf", .builtin, label: "COMPRESS", suffix: " compressed", id: "compress",
             when: { PDFBackend.canCompress }) { i, o in
            try PDFBackend.compress(i, to: o)
        }
        batch(["pdf", "jpg", "png", "heic", "tiff", "gif", "bmp"], id: "merge", label: "MERGE",
              to: "pdf", suffix: " merged", .builtin) { ins, o in
            try PDFBackend.merge(ins, to: o)
        }

        // ================= ARCHIVES (any file or folder; ships with macOS) =================

        // ZIP: anything in (files, folders, mixed), one archive out. A single item is fine.
        r.append(Recipe(id: "zip", label: "ZIP", from: ["*"], to: "zip", suffix: "", engine: .builtin,
                        batch: true, minInputs: 1, pure: false, naming: ArchiveBackend.zipBaseName,
                        when: { FileManager.default.isExecutableFile(atPath: ArchiveBackend.zipExe) },
                        run: { ins, out in try ArchiveBackend.makeZip(ins, to: out) }))

        // UNPACK: one archive in, a folder (or its single top-level item) out. Never replaces the archive.
        eachProducing(["zip", "tar", "tar.gz", "tar.bz2", "tar.xz", "7z", "rar"], "folder", .builtin,
                      label: "UNPACK", id: "unpack", pure: false) { i, _ in
            try ArchiveBackend.unpack(i)
        }

        // ================= IMAGES =================

        let imageIn = ["jpg", "png", "heic", "tiff", "gif", "bmp", "webp", "avif"]
        let imageOut = ["jpg", "png", "heic", "tiff", "gif", "bmp"]
        for f in imageIn {
            for t in imageOut where f != t {
                each([f], t, .builtin, when: { ImageBackend.canRead(f) && ImageBackend.canWrite(t) }) { i, o in
                    try ImageBackend.convert(i, to: o, ext: t)
                }
            }
            each([f], "pdf", .builtin, when: { ImageBackend.canRead(f) }) { i, o in
                _ = try PDFBackend.merge([i], to: o)
            }
        }
        // Fallbacks when this macOS can't decode WebP/AVIF itself.
        each(["webp", "avif"], "png", .ffmpeg) { i, o in try MediaBackend.ffmpegConvert(i, to: o, ext: "png") }
        each(["webp", "avif"], "jpg", .ffmpeg) { i, o in try MediaBackend.ffmpegConvert(i, to: o, ext: "jpg") }
        each(["jpg", "png", "gif", "bmp", "tiff"], "webp", .ffmpeg) { i, o in
            try MediaBackend.ffmpegConvert(i, to: o, ext: "webp")
        }
        // SVG: rendered by QuickLook, then converted onward.
        each(["svg"], "png", .builtin) { i, o in try MediaBackend.svgToPNG(i, to: o) }
        each(["svg"], "jpg", .builtin) { i, o in
            let tmp = Backends.tempURL(ext: "png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MediaBackend.svgToPNG(i, to: tmp)
            try ImageBackend.convert(tmp, to: o, ext: "jpg")
        }
        each(["svg"], "pdf", .builtin) { i, o in
            let tmp = Backends.tempURL(ext: "png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MediaBackend.svgToPNG(i, to: tmp)
            _ = try PDFBackend.merge([tmp], to: o)
        }

        // ================= AUDIO / VIDEO =================

        // Built in (no installs): MOV ↔ MP4, video → M4A, audio → WAV/M4A/AIFF.
        each(["mov", "m4v"], "mp4", .builtin) { i, o in try MediaBackend.avRewrap(i, to: o, type: .mp4) }
        each(["mp4", "m4v"], "mov", .builtin) { i, o in try MediaBackend.avRewrap(i, to: o, type: .mov) }
        each(["mov", "mp4", "m4v"], "m4a", .builtin) { i, o in try MediaBackend.avToM4A(i, to: o) }
        for t in ["wav", "m4a", "aiff"] {
            each(["mp3", "wav", "aiff", "m4a", "flac", "caf"], t, .builtin) { i, o in
                try MediaBackend.afconvert(i, to: o, ext: t)
            }
        }

        // ffmpeg: everything else.
        let videoIn = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv", "flv", "mpg", "3gp", "ts"]
        let audioIn = ["mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "aiff", "wma"]
        for t in ["mp4", "mkv", "webm", "mov", "gif"] {
            each(videoIn, t, .ffmpeg) { i, o in try MediaBackend.ffmpegConvert(i, to: o, ext: t) }
        }
        each(["gif"], "mp4", .ffmpeg) { i, o in try MediaBackend.ffmpegConvert(i, to: o, ext: "mp4") }
        for t in ["mp3", "m4a", "wav", "flac", "ogg"] {
            each(videoIn + audioIn, t, .ffmpeg) { i, o in try MediaBackend.ffmpegConvert(i, to: o, ext: t) }
        }

        return r
    }

    // MARK: - Lookup

    /// First usable per-file recipe for `id` on a file of `type`. Skips no-op conversions (jpg → jpg).
    static func recipe(id: String, type: String) -> Recipe? {
        recipes.first {
            $0.usable && !$0.batch && $0.id == id && $0.accepts(type)
                && !($0.suffix.isEmpty && $0.to == type)
        }
    }

    static func batchRecipe(id: String, types: [String]) -> Recipe? {
        recipes.first { rec in
            rec.usable && rec.batch && rec.id == id && types.allSatisfy { rec.accepts($0) }
        }
    }

    /// True when a downloadable helper (ffmpeg, pandoc) would add at least two wheel segments for these files.
    /// Drives the "one-time download" nudge. The threshold keeps it quiet for e.g. a JPG, where a helper
    /// only adds WebP output.
    static func wouldUnlock(_ urls: [URL]) -> Bool {
        let types = urls.map { kind(of: $0) }
        var ids = Set<String>()
        for rec in recipes where rec.engine.helper != nil && !rec.engine.isAvailable && !rec.batch {
            if types.allSatisfy({ rec.accepts($0) }) { ids.insert(rec.id) }
        }
        let have = Set(targets(for: urls).map { $0.id })
        return ids.subtracting(have).count >= 2
    }

    static func replaceApplies(id: String) -> Bool {
        recipes.contains { $0.id == id && $0.isPureConversion }
    }

    /// Wheel segments for what's being dragged: per-file targets every file supports,
    /// plus batch targets (merge, zip) when enough items are dragged.
    static func targets(for urls: [URL]) -> [Target] {
        guard !urls.isEmpty else { return [] }
        let types = urls.map { kind(of: $0) }
        var found: [String: Target] = [:]

        for rec in recipes where rec.usable && found[rec.id] == nil {
            if rec.batch {
                if urls.count >= rec.minInputs, batchRecipe(id: rec.id, types: types) != nil {
                    found[rec.id] = Target(id: rec.id, label: rec.label)
                }
            } else if types.allSatisfy({ recipe(id: rec.id, type: $0) != nil }) {
                found[rec.id] = Target(id: rec.id, label: rec.label)
            }
        }

        // SIGN isn't a recipe (it opens a window instead of producing a file), so it's added here.
        if urls.count == 1, SignBackend.canSign(kind: types[0]) {
            found["sign"] = Target(id: "sign", label: "SIGN")
        }

        // Don't offer what can't work. A one-page PDF can't be split; a locked PDF can't be split or shrunk.
        if found["split"] != nil || found["compress"] != nil {
            for (u, t) in zip(urls, types) where t == "pdf" {
                guard let info = PDFBackend.info(u) else { continue }
                if info.pages <= 1 || info.locked { found["split"] = nil }
                if info.locked { found["compress"] = nil }
            }
        }

        func rank(_ t: Target) -> Int { displayOrder.firstIndex(of: t.id) ?? 999 }
        return found.values.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
    }
}

struct ConversionResult {
    var outputs: [URL] = []
    var errors: [String] = []
    /// Things that weren't failures, just "nothing to do" (already as small as it gets, a one-page PDF can't be split).
    var notices: [String] = []
    /// Originals that "Replace" moved to the Trash: where they were, and where they are now. Lets Undo restore them.
    var trashed: [(original: URL, inTrash: URL)] = []
}

enum Converter {
    /// Name without extension. Folders keep their whole name ("Project v1.2" has no extension).
    static func baseName(of url: URL) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `dir/base.ext`, or " (1)", " (2)"… if taken. An empty `ext` means no extension at all (folders).
    static func uniqueOutput(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name)
            return ext.isEmpty ? u : u.appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) (\(n))")
            n += 1
        }
        return candidate
    }

    /// Same folder as the input; new extension; " (1)", " (2)"… if taken.
    static func uniqueOutput(for input: URL, ext: String, suffix: String = "") -> URL {
        uniqueOutput(in: input.deletingLastPathComponent(), base: baseName(of: input) + suffix, ext: ext)
    }

    /// Blocking; call from a background queue. `replace` moves originals to the Trash after
    /// a successful plain conversion (never for merge/split/compress/zip/unpack).
    static func convert(_ urls: [URL], to id: String, replace: Bool) -> ConversionResult {
        var result = ConversionResult()
        let types = urls.map { Registry.kind(of: $0) }

        // Batch operation (merge, zip): everything in, one file out, next to the first item.
        if let rec = Registry.batchRecipe(id: id, types: types), urls.count >= rec.minInputs {
            let first = Registry.naturalSorted(urls)[0]
            let base = rec.naming?(urls) ?? (baseName(of: first) + rec.suffix)
            let out = uniqueOutput(in: first.deletingLastPathComponent(), base: base, ext: rec.to)
            do {
                let produced = try rec.run(urls, out)
                guard FileManager.default.fileExists(atPath: produced.path) else { throw ConvError("no file was produced") }
                result.outputs.append(produced)
            } catch {
                try? FileManager.default.removeItem(at: out)
                if let e = error as? ConvError, e.isNotice {
                    result.notices.append(e.localizedDescription)
                } else {
                    result.errors.append(error.localizedDescription)
                }
            }
            return result
        }

        for (url, type) in zip(urls, types) {
            guard let rec = Registry.recipe(id: id, type: type) else {
                result.errors.append("\(url.lastPathComponent): no converter for \(type) → \(id)")
                continue
            }
            let out = uniqueOutput(for: url, ext: rec.to, suffix: rec.suffix)
            do {
                let produced = try rec.run([url], out)
                guard FileManager.default.fileExists(atPath: produced.path) else {
                    throw ConvError("converter produced no file")
                }
                result.outputs.append(produced)
                let producedBytes = ((try? FileManager.default.attributesOfItem(atPath: produced.path))?[.size] as? Int) ?? 0
                if replace && rec.isPureConversion && producedBytes > 0 {
                    var trashed: NSURL?
                    if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil, let t = trashed {
                        result.trashed.append((original: url, inTrash: t as URL))
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: out)
                if let e = error as? ConvError, e.isNotice {
                    result.notices.append(e.localizedDescription)
                } else {
                    result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return result
    }
}
