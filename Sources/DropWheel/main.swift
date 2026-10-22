import AppKit

// Headless test mode, so conversions can be verified without the gesture:
//   DropWheel --engines
//   DropWheel --options <file> [file...]       what the wheel would offer
//   DropWheel --convert <file|folder> [...] <id>  id = pdf, jpg, png, mp4, merge, split, compress, zip, unpack, ...
//   DropWheel --preflight <file> [file...]     tamper / red-flag check of a PDF (or a document/image, via its PDF)
//   DropWheel --spots <file> [file...]         where auto-spot would put the signature
//   DropWheel --sign <file> [--name "X"] [--blue] [--no-date]   sign headlessly at the best spot, then self-check
enum CLI {
    static func job() -> (() -> Int32)? {
        let a = Array(CommandLine.arguments.dropFirst())
        guard let cmd = a.first, cmd.hasPrefix("--") else { return nil }

        switch cmd {
        case "--engines":
            return {
                for e in Engine.allCases {
                    print("\(e.isAvailable ? "✓" : "✗") \(e.name): \(e.unlocks)")
                }
                return 0
            }
        case "--options" where a.count >= 2:
            return {
                let urls = a.dropFirst().map { URL(fileURLWithPath: $0) }
                let t = Registry.targets(for: urls)
                print(t.isEmpty ? "no conversions available" : t.map { $0.id }.joined(separator: " "))
                return 0
            }
        case "--convert" where a.count >= 3:
            return {
                let id = a[a.count - 1].lowercased()
                let urls = a[1..<(a.count - 1)].map { URL(fileURLWithPath: $0) }
                let result = Converter.convert(urls, to: id, replace: false)
                result.outputs.forEach { print("✓ \($0.path)") }
                result.errors.forEach { FileHandle.standardError.write(Data("✗ \($0)\n".utf8)) }
                return result.errors.isEmpty ? 0 : 1
            }
        case "--preflight" where a.count >= 2:
            return { SignCLI.preflight(Array(a.dropFirst())) }
        case "--spots" where a.count >= 2:
            return { SignCLI.spots(Array(a.dropFirst())) }
        case "--sign" where a.count >= 2:
            return { SignCLI.sign(Array(a.dropFirst())) }
        default:
            FileHandle.standardError.write(Data("usage: DropWheel [--engines | --options <file...> | --convert <file...> <id> | --preflight <file...> | --spots <file...> | --sign <file> [--name \"X\"]]\n".utf8))
            exit(2)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon

let delegate = AppDelegate()

if let job = CLI.job() {
    // Main thread must keep running: AppKit text/print work hops back to it.
    DispatchQueue.global().async { exit(job()) }
} else {
    app.delegate = delegate
}
app.run()
