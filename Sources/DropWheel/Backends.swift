import AppKit
import Foundation
import PDFKit

// MARK: - Errors and threading

struct ConvError: LocalizedError {
    let message: String
    /// Not a failure: there was simply nothing to do ("already as small as it gets"). Shown calmly, no error sound.
    let isNotice: Bool
    init(_ message: String, notice: Bool = false) {
        self.message = message
        self.isNotice = notice
    }
    var errorDescription: String? { message }
}

/// AppKit's text-import and print APIs want the main thread. Conversions run on a
/// background queue, so hop over when needed.
func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
}

// MARK: - External tools

enum Tools {
    static let textutil = "/usr/bin/textutil"

    static var soffice: String? {
        firstExecutable([
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
        ])
    }

    static var pandoc: String? {
        bundled("pandoc") ?? downloaded("pandoc") ?? firstExecutable(["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"])
    }

    static var qpdf: String? {
        bundled("qpdf") ?? firstExecutable(["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf", "/usr/bin/qpdf"])
    }

    static var ffmpeg: String? {
        bundled("ffmpeg") ?? downloaded("ffmpeg") ?? firstExecutable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"])
    }

    /// Tools shipped inside the app: DropWheel.app/Contents/Resources/bin/<name>. Checked before Homebrew.
    private static func bundled(_ name: String) -> String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) else { return nil }
        let path = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Where first-run setup puts helpers it downloaded. Path only, no mkdir: this is hit on every drag.
    static var downloadedBin: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropWheel/bin", isDirectory: true)
    }

    private static func downloaded(_ name: String) -> String? {
        let path = downloadedBin.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum Engine: CaseIterable {
    case builtin, textutil, libreOffice, pandoc, ffmpeg, qpdf

    var name: String {
        switch self {
        case .builtin: return "Built-in (ImageIO, PDFKit, AVFoundation)"
        case .textutil: return "textutil (ships with macOS)"
        case .libreOffice: return "LibreOffice"
        case .pandoc: return "pandoc"
        case .ffmpeg: return "ffmpeg"
        case .qpdf: return "qpdf"
        }
    }

    var unlocks: String {
        switch self {
        case .builtin: return "images, PDF merge/split/compress/to-image, MOV/MP4, basic audio, CSV/JSON, basic documents, zip/unpack, signing"
        case .textutil: return "DOCX/DOC/ODT/RTF/HTML/TXT conversions"
        case .libreOffice: return "faithful Office to PDF, XLSX/PPTX, PDF to DOCX (rough)"
        case .pandoc: return "proper Markdown, EPUB, DOCX/HTML to MD"
        case .ffmpeg: return "MKV/AVI/WebM/GIF video, MP3/FLAC/OGG audio, WebP output"
        case .qpdf: return "signing that keeps links, form fields and bookmarks"
        }
    }

    var installCommand: String? {
        switch self {
        case .libreOffice: return "brew install --cask libreoffice"
        case .pandoc: return "brew install pandoc"
        case .ffmpeg: return "brew install ffmpeg"
        case .qpdf: return "brew install qpdf"
        default: return nil
        }
    }

    /// For tools we don't bundle: where a non-technical person can get them.
    var downloadURL: URL? {
        switch self {
        case .libreOffice: return URL(string: "https://www.libreoffice.org/download/")
        default: return nil
        }
    }

    var isAvailable: Bool {
        switch self {
        case .builtin: return true
        case .textutil: return FileManager.default.isExecutableFile(atPath: Tools.textutil)
        case .libreOffice: return Tools.soffice != nil
        case .pandoc: return Tools.pandoc != nil
        case .ffmpeg: return Tools.ffmpeg != nil
        case .qpdf: return Tools.qpdf != nil
        }
    }
}

// MARK: - Process runner

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 120, cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardInput = FileHandle.nullDevice   // nothing may ever sit waiting for a password or a "y"
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let tool = (exe as NSString).lastPathComponent
            throw ConvError("\(tool) failed (exit \(p.terminationStatus)): \(String(text.suffix(300)))")
        }
        return text
    }
}

// MARK: - Conversion backends

enum Backends {
    /// Plain-text-ish formats the built-in renderer can turn into a monospaced PDF.
    static let textLike: Set<String> = [
        "txt", "log", "json", "yaml", "yml", "xml", "csv", "toml", "ini", "css",
        "py", "js", "ts", "swift", "go", "rs", "c", "h", "java", "sh",
    ]

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DropWheel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dw-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    static func readText(_ url: URL) throws -> String {
        var enc = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &enc)
    }

    // MARK: textutil (ships with macOS)

    static func textutil(_ input: URL, to out: URL, format: String) throws {
        var args = ["-convert", format, "-output", out.path]
        let ext = input.pathExtension.lowercased()
        if ext == "txt" || ext == "html" { args += ["-inputencoding", "UTF-8"] }
        if format == "txt" || format == "html" { args += ["-encoding", "UTF-8"] }
        args.append(input.path)
        try Shell.run(Tools.textutil, args)
    }

    // MARK: LibreOffice (headless)

    static func libreOffice(_ input: URL, to out: URL, filter: String, inFilter: String? = nil) throws {
        guard let soffice = Tools.soffice else {
            throw ConvError("This conversion needs LibreOffice, a free app (libreoffice.org). Install it, then try again.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Private profile so we never collide with a running LibreOffice window.
        let profile = appSupport.appendingPathComponent("lo-profile", isDirectory: true)
        var args = ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore"]
        if let inFilter { args.append("--infilter=" + inFilter) }
        args += ["--convert-to", filter, "--outdir", tmp.path, input.path]
        try Shell.run(soffice, args, timeout: 240)

        let produced = tmp
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(out.pathExtension)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConvError("LibreOffice finished but produced no .\(out.pathExtension) file")
        }
        try FileManager.default.moveItem(at: produced, to: out)
    }

    // MARK: pandoc

    static func pandoc(_ input: URL, to out: URL, extra: [String]) throws {
        guard let exe = Tools.pandoc else {
            throw ConvError("DropWheel's document tools aren't set up yet. Click the ◎ menu and choose “Finish setup…”.")
        }
        try Shell.run(exe, [input.path] + extra + ["-o", out.path])
    }

    // MARK: Built-in: PDF text extraction

    static func pdfToText(_ input: URL, to out: URL) throws {
        guard let doc = PDFDocument(url: input) else { throw ConvError("Couldn't open this PDF") }
        let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ConvError("No selectable text in this PDF (scanned?). OCR isn't supported yet.")
        }
        try text.write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: Built-in: text/Office/HTML/MD to PDF via Cocoa

    static func cocoaPDF(_ input: URL, to out: URL) throws {
        try onMain { () throws -> Void in
            let text = try loadAttributed(input)
            try renderPDF(text, to: out)
        }
    }

    static func markdownToHTMLFile(_ input: URL, to out: URL) throws {
        try MarkdownHTML.fullHTML(for: input).write(to: out, atomically: true, encoding: .utf8)
    }

    static func markdownToDocxViaTextutil(_ input: URL, to out: URL) throws {
        let tmp = tempURL(ext: "html")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try MarkdownHTML.fullHTML(for: input).write(to: tmp, atomically: true, encoding: .utf8)
        try textutil(tmp, to: out, format: "docx")
    }

    private static func loadAttributed(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case _ where textLike.contains(ext):
            return NSAttributedString(string: try readText(url), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.black,
            ])
        case "md", "markdown":
            return try htmlToAttributed(try MarkdownHTML.fullHTML(for: url))
        case "html", "htm":
            return try htmlToAttributed(try readText(url))
        default:
            let type: NSAttributedString.DocumentType
            switch ext {
            case "docx": type = .officeOpenXML
            case "doc": type = .docFormat
            case "odt": type = .openDocument
            case "rtf": type = .rtf
            default: throw ConvError("Built-in renderer can't read .\(ext)")
            }
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        }
    }

    private static func htmlToAttributed(_ html: String) throws -> NSAttributedString {
        guard let data = html.data(using: .utf8) else { throw ConvError("Bad text encoding") }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return try NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    private static func renderPDF(_ text: NSAttributedString, to out: URL) throws {
        let paper = NSSize(width: 595.28, height: 841.89) // A4
        let margin: CGFloat = 54
        let width = paper.width - margin * 2

        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: paper.height))
        tv.appearance = NSAppearance(named: .aqua) // keep text black even in dark mode
        tv.drawsBackground = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(text)

        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            tv.frame = NSRect(x: 0, y: 0, width: width, height: max(used.height + 20, 100))
        }

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else {
            throw ConvError("Built-in PDF renderer failed")
        }
    }
}

// MARK: - Markdown → full HTML document (pandoc if present, otherwise MiniMarkdown)

enum MarkdownHTML {
    static let css = """
    body { font-family: Helvetica; font-size: 11pt; color: #000000; }
    h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; }
    code, pre { font-family: Menlo; font-size: 9.5pt; }
    pre { background-color: #f2f2f2; }
    blockquote { color: #555555; }
    th, td { border: 1px solid #999999; padding: 4px; }
    """

    static func fullHTML(for url: URL) throws -> String {
        let source = try Backends.readText(url)
        let body: String
        if let exe = Tools.pandoc, let html = try? pandocFragment(exe, url) {
            body = html
        } else {
            body = MiniMarkdown.toHTML(source)
        }
        return "<html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body>\(body)</body></html>"
    }

    private static func pandocFragment(_ exe: String, _ url: URL) throws -> String {
        let tmp = Backends.tempURL(ext: "html")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.run(exe, [url.path, "-f", "gfm", "-t", "html", "-o", tmp.path])
        return try String(contentsOf: tmp, encoding: .utf8)
    }
}
