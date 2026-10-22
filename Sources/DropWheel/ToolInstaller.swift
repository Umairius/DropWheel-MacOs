import AppKit
import Foundation

// MARK: - What can be downloaded

/// A helper program DropWheel can fetch for the user.
/// Versions are pinned (URLs verified live, sizes from the servers), so there's no GitHub API call
/// to rate-limit or break. Bump the constants below to upgrade.
enum HelperTool: CaseIterable {
    case ffmpeg, pandoc

    private static var isARM: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Shown in the setup window.
    var title: String {
        switch self {
        case .ffmpeg: return "Video & audio"
        case .pandoc: return "Documents"
        }
    }

    /// Used inside sentences ("Downloading video & audio tools…").
    var phrase: String {
        switch self {
        case .ffmpeg: return "video & audio tools"
        case .pandoc: return "document tools"
        }
    }

    var blurb: String {
        switch self {
        case .ffmpeg: return "Converts videos and music: MP4, MOV, MP3, GIF and more."
        case .pandoc: return "Converts Markdown, Word and e-books into other formats."
        }
    }

    var binaryName: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .pandoc: return "pandoc"
        }
    }

    var url: URL {
        switch self {
        case .ffmpeg:
            let arch = HelperTool.isARM ? "arm64" : "x64"
            return URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-darwin-\(arch)")!
        case .pandoc:
            let arch = HelperTool.isARM ? "arm64" : "x86_64"
            return URL(string: "https://github.com/jgm/pandoc/releases/download/3.12.1/pandoc-3.12.1-\(arch)-macOS.zip")!
        }
    }

    /// Exact download sizes (bytes) as reported by the servers. Used to weight the progress bar.
    var downloadBytes: Int64 {
        switch self {
        case .ffmpeg: return HelperTool.isARM ? 45_568_216 : 78_829_164
        case .pandoc: return HelperTool.isARM ? 42_313_957 : 26_487_481
        }
    }

    /// Peak disk use while installing (download + unpacked), for the free-space pre-check.
    var diskBytes: Int64 {
        switch self {
        case .ffmpeg: return downloadBytes * 2
        case .pandoc: return downloadBytes + 200_000_000
        }
    }

    var verifyArgs: [String] {
        switch self {
        case .ffmpeg: return ["-version"]
        case .pandoc: return ["--version"]
        }
    }

    var verifyToken: String {
        switch self {
        case .ffmpeg: return "ffmpeg version"
        case .pandoc: return "pandoc"
        }
    }

    var isInstalled: Bool {
        switch self {
        case .ffmpeg: return Tools.ffmpeg != nil
        case .pandoc: return Tools.pandoc != nil
        }
    }
}

extension Engine {
    /// The downloadable helper behind this engine, if there is one.
    var helper: HelperTool? {
        switch self {
        case .ffmpeg: return .ffmpeg
        case .pandoc: return .pandoc
        default: return nil
        }
    }
}

// MARK: - Errors and events (messages are written for non-technical people)

enum InstallError: LocalizedError {
    case offline
    case interrupted
    case server(Int)
    case incomplete
    case diskSpace(neededMB: Int)
    case wontRun(HelperTool)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "DropWheel couldn't reach the internet. Check your connection and try again."
        case .interrupted:
            return "The download was interrupted. Please try again."
        case .server:
            return "The download server isn't responding right now. Please try again in a few minutes."
        case .incomplete:
            return "The download didn't finish properly. Please try again."
        case .diskSpace(let mb):
            return "Your Mac is a little short on free space. DropWheel needs about \(mb) MB for its helper tools. Free up some space, then try again."
        case .wontRun(let h):
            return "The \(h.phrase) downloaded but wouldn't start. Security software may be blocking them. Please try again."
        case .other(let m):
            return m
        }
    }
}

enum InstallEvent {
    case waiting                          // offline: URLSession is waiting for the network to come back
    case downloading(Int64, Int64)        // received, expected (expected <= 0 when unknown)
    case finishing                        // unpacking and verifying
}

// MARK: - HelperDownloader (progress, waits for connectivity, cancellable)

final class HelperDownloader: NSObject, URLSessionDownloadDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var lastTick = Date.distantPast
    private let onProgress: (Int64, Int64) -> Void
    private let onWaiting: () -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void, onWaiting: @escaping () -> Void) {
        self.onProgress = onProgress
        self.onWaiting = onWaiting
    }

    /// Returns a temp file URL that the caller owns.
    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let cfg = URLSessionConfiguration.ephemeral
                cfg.waitsForConnectivity = true          // offline? wait quietly instead of failing
                cfg.timeoutIntervalForRequest = 30
                cfg.timeoutIntervalForResource = 1800    // slow connections are fine
                let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
                let t = s.downloadTask(with: url)
                self.lock.lock()
                self.continuation = c
                self.session = s
                self.task = t
                self.lock.unlock()
                t.resume()
                if Task.isCancelled { t.cancel() }
            }
        } onCancel: {
            self.lock.lock()
            let t = self.task
            self.lock.unlock()
            t?.cancel()
        }
    }

    private func finish(_ r: Result<URL, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        let s = session
        session = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
        guard let c else {
            if case .success(let u) = r { try? FileManager.default.removeItem(at: u) }
            return
        }
        c.resume(with: r)
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        onWaiting()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.1 || written == expected else { return }
        lastTick = now
        onProgress(written, expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns: move it right now.
        guard let http = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(InstallError.interrupted)); return
        }
        guard http.statusCode == 200 else {
            finish(.failure(InstallError.server(http.statusCode))); return
        }
        let dest = Backends.tempURL(ext: "part")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64) ?? 0
            if http.expectedContentLength > 0, size != http.expectedContentLength {
                try? FileManager.default.removeItem(at: dest)
                finish(.failure(InstallError.incomplete))
            } else {
                finish(.success(dest))
            }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - Installer

enum HelperInstaller {
    static func missing() -> [HelperTool] {
        HelperTool.allCases.filter { !$0.isInstalled }
    }

    /// Fail early, politely, before downloading a single byte.
    static func preflight(_ items: [HelperTool]) throws {
        let need = items.reduce(Int64(0)) { $0 + $1.diskBytes } + 250_000_000
        let dir = Tools.downloadedBin.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = vals?.volumeAvailableCapacityForImportantUsage, free < need {
            throw InstallError.diskSpace(neededMB: Int(need / 1_000_000))
        }
    }

    /// Download (with retries on flaky networks), unpack, verify, then swap into place atomically.
    /// Throws CancellationError if cancelled; otherwise an InstallError with a friendly message.
    static func install(_ h: HelperTool, progress: @escaping (InstallEvent) -> Void) async throws {
        let attempts = 3
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do {
                let dl = HelperDownloader(onProgress: { got, total in progress(.downloading(got, total)) },
                                    onWaiting: { progress(.waiting) })
                let file = try await dl.download(h.url)
                progress(.finishing)
                try await Task.detached(priority: .userInitiated) { try finalize(h, file) }.value
                return
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                if attempt < attempts, isTransient(error) {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                throw friendly(error)
            }
        }
    }

    private static func isTransient(_ e: Error) -> Bool {
        if let u = e as? URLError {
            switch u.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .secureConnectionFailed, .notConnectedToInternet:
                return true
            default: return false
            }
        }
        if let i = e as? InstallError {
            switch i {
            case .server(let s): return s >= 500 || s == 429
            case .incomplete, .interrupted: return true
            default: return false
            }
        }
        return false
    }

    private static func friendly(_ e: Error) -> Error {
        if e is InstallError { return e }
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return InstallError.offline
            default: return InstallError.interrupted
            }
        }
        return InstallError.other(e.localizedDescription)
    }

    // MARK: Unpack + verify + commit (runs off the main thread)

    private static func works(_ path: String, _ h: HelperTool) -> Bool {
        guard let out = try? Shell.run(path, h.verifyArgs, timeout: 60) else { return false }
        return out.contains(h.verifyToken)
    }

    private static func finalize(_ h: HelperTool, _ file: URL) throws {
        let fm = FileManager.default
        let bin = Tools.downloadedBin
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        // Everything happens in a private staging folder; the real bin/ only ever sees a verified binary.
        let staging = bin.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: file)
        }

        let staged = staging.appendingPathComponent(h.binaryName)
        switch h {
        case .ffmpeg:
            try fm.moveItem(at: file, to: staged)
        case .pandoc:
            let unzipped = staging.appendingPathComponent("unzipped", isDirectory: true)
            do {
                try Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, unzipped.path], timeout: 300)
            } catch {
                throw InstallError.incomplete
            }
            let found = fm.enumerator(at: unzipped, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "pandoc" && $0.deletingLastPathComponent().lastPathComponent == "bin" }
            guard let found else { throw InstallError.incomplete }
            try fm.moveItem(at: found, to: staged)
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        _ = try? Shell.run("/usr/bin/xattr", ["-c", staged.path])   // belt and braces: no quarantine flag

        // Prove it runs. If not, ad-hoc sign it (Apple Silicon needs a signature) and try once more.
        if !works(staged.path, h) {
            _ = try? Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", staged.path])
            guard works(staged.path, h) else { throw InstallError.wontRun(h) }
        }

        let final = bin.appendingPathComponent(h.binaryName)
        if fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: final)
        }
    }
}
