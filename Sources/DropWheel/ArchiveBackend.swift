import Foundation

/// ZIP and UNPACK, using tools that ship with macOS: /usr/bin/zip and /usr/bin/tar (bsdtar).
enum ArchiveBackend {
    static let zipExe = "/usr/bin/zip"
    static let tarExe = "/usr/bin/tar"
    private static let xattrExe = "/usr/bin/xattr"

    /// Finder junk and AppleDouble leftovers: never worth carrying to another computer.
    private static let junk = [".DS_Store", "*/.DS_Store", "__MACOSX", "__MACOSX/*", "*/__MACOSX/*", "._*", "*/._*"]

    // MARK: ZIP

    /// One item: its full name, so "report.pdf" becomes "report.pdf.zip" (like Finder) and a folder
    /// "Photos" becomes "Photos.zip". Several items from one folder: that folder's name. Otherwise "Archive".
    static func zipBaseName(_ urls: [URL]) -> String {
        if urls.count == 1 { return urls[0].lastPathComponent }
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        if parents.count == 1, let first = urls.first {
            let name = first.deletingLastPathComponent().lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        return "Archive"
    }

    /// Files and folders into one zip, junk excluded, symlinks stored as links (not followed).
    static func makeZip(_ inputs: [URL], to out: URL) throws -> URL {
        let fm = FileManager.default
        let items = Registry.naturalSorted(inputs)

        // Entry names come from the last path component, so they have to be unique.
        var seen = Set<String>()
        for u in items {
            let name = u.lastPathComponent
            if seen.contains(name) { throw ConvError("Two items are both called “\(name)”. Zip them separately.") }
            seen.insert(name)
            if !fm.fileExists(atPath: u.path) { throw ConvError("“\(name)” no longer exists") }
        }

        // zip stores paths relative to its working directory, so run it once per parent folder.
        // The "./" keeps a name like "-notes.txt" from being read as an option; zip stores it without it.
        var groups: [(parent: URL, names: [String])] = []
        for u in items {
            let parent = u.deletingLastPathComponent()
            let arg = "./" + u.lastPathComponent
            if let i = groups.firstIndex(where: { $0.parent.path == parent.path }) {
                groups[i].names.append(arg)
            } else {
                groups.append((parent, [arg]))
            }
        }

        for g in groups {
            // -r recurse, -X no extra attributes, -y keep symlinks as links, -q quiet.
            let args = ["-r", "-X", "-y", "-q", out.path] + g.names + ["-x"] + junk
            try Shell.run(zipExe, args, timeout: 6 * 3600, cwd: g.parent)
        }
        return out
    }

    // MARK: UNPACK

    /// Name of an archive without its (possibly double) extension.
    static func archiveBase(_ url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Extracts next to the archive. One top-level item lands directly beside the archive (no "name/name/"
    /// nesting); several go into a folder named after the archive. Returns what was created.
    static func unpack(_ input: URL) throws -> URL {
        let fm = FileManager.default
        let dir = input.deletingLastPathComponent()

        // Same volume as the destination, hidden, always cleaned up.
        let staging = dir.appendingPathComponent(".dropwheel-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // bsdtar reads zip and tar (.gz/.bz2/.xz); 7z and rar should work too but are untested. By default it refuses ".." paths and
        // symlinks that would escape the target. Encrypted archives fail with an error, never a prompt.
        do {
            try Shell.run(tarExe, ["-xf", input.path, "-C", staging.path], timeout: 6 * 3600)
        } catch {
            // bsdtar answers an encrypted archive with a flood of "Enter passphrase:" prompts.
            let text = error.localizedDescription
            if text.contains("passphrase") || text.contains("ncrypted") {
                throw ConvError("\(input.lastPathComponent) is password-protected. Unpack it with Finder or 7-Zip.")
            }
            throw error
        }

        // Archive Utility hands the download quarantine flag on to what it extracts; bsdtar does not.
        // Without this, unpacking a downloaded zip would launder an app past Gatekeeper. Best effort.
        if let q = try? Shell.run(xattrExe, ["-p", "com.apple.quarantine", input.path]) {
            let value = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                _ = try? Shell.run(xattrExe, ["-s", "-r", "-w", "com.apple.quarantine", value, staging.path])
            }
        }

        // Junk that old Mac zips carry.
        try? fm.removeItem(at: staging.appendingPathComponent("__MACOSX"))
        var top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        for u in top where u.lastPathComponent == ".DS_Store" { try? fm.removeItem(at: u) }
        top.removeAll { $0.lastPathComponent == ".DS_Store" }
        guard !top.isEmpty else { throw ConvError("This archive is empty") }

        if top.count == 1 {
            let item = top[0]
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            let dest: URL
            if isDir.boolValue {
                dest = Converter.uniqueOutput(in: dir, base: item.lastPathComponent, ext: "")
            } else {
                dest = Converter.uniqueOutput(in: dir, base: item.deletingPathExtension().lastPathComponent,
                                              ext: item.pathExtension)
            }
            try fm.moveItem(at: item, to: dest)
            return dest
        }

        let dest = Converter.uniqueOutput(in: dir, base: archiveBase(input), ext: "")
        try fm.moveItem(at: staging, to: dest)
        return dest
    }
}
