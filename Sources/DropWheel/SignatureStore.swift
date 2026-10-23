import AppKit
import CryptoKit
import Foundation
import ImageIO
import Security

enum SignSlot: String, CaseIterable, Codable {
    case signature, initials

    var title: String { self == .signature ? "signature" : "initials" }
}

/// Your saved signature and initials.
/// Strokes are kept as data (not as a loose PNG), encrypted with a key that lives in the Keychain.
/// If the Keychain refuses, it falls back to a user-only-readable file so signing still works.
final class SignatureStore {
    static let shared = SignatureStore()

    private struct Payload: Codable {
        var signature: Ink?
        var initials: Ink?
        var printedName: String?
    }

    private var payload = Payload()
    private let lock = NSLock()
    /// A saved signature exists on disk, but macOS wouldn't give us the key to open it (the Keychain prompt was
    /// denied). That's different from "nothing saved": we must not start over, overwrite it, or write a plaintext copy.
    private var locked = false
    private let keychainService = "com.dropwheel.signature-key"

    private var encryptedFile: URL { Backends.appSupport.appendingPathComponent("signatures.dws") }
    private var plainFile: URL { Backends.appSupport.appendingPathComponent("signatures.json") }

    private init() { load() }

    // MARK: Access

    /// True when a saved signature is waiting behind a Keychain permission that was denied.
    var isLocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return locked
    }

    /// Asks the Keychain again (macOS shows its prompt again). Returns true if the signature is now available.
    @discardableResult
    func retryUnlock() -> Bool {
        guard isLocked else { return true }
        load()
        return !isLocked
    }

    func ink(_ slot: SignSlot) -> Ink? {
        lock.lock(); defer { lock.unlock() }
        return slot == .signature ? payload.signature : payload.initials
    }

    func save(_ ink: Ink, slot: SignSlot) {
        lock.lock()
        if slot == .signature { payload.signature = ink } else { payload.initials = ink }
        lock.unlock()
        persist()
    }

    func clear(_ slot: SignSlot) {
        lock.lock()
        if slot == .signature { payload.signature = nil } else { payload.initials = nil }
        lock.unlock()
        persist()
    }

    func forgetEverything() {
        lock.lock(); payload.signature = nil; payload.initials = nil; lock.unlock()
        persist()
    }

    /// Used by auto-spot to tell your signature block from the other party's.
    var printedName: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return payload.printedName
        }
        set {
            lock.lock()
            let t = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            payload.printedName = (t?.isEmpty ?? true) ? nil : t
            lock.unlock()
            persist()
        }
    }

    // MARK: Persistence

    private func load() {
        let fm = FileManager.default
        lock.lock(); locked = false; lock.unlock()

        if fm.fileExists(atPath: encryptedFile.path), let sealed = try? Data(contentsOf: encryptedFile) {
            switch fetchKey() {
            case .key(let key):
                if let box = try? AES.GCM.SealedBox(combined: sealed),
                   let plain = try? AES.GCM.open(box, using: key),
                   let p = try? JSONDecoder().decode(Payload.self, from: plain) {
                    payload = p
                    return
                }
            case .denied:
                // The signature is still there; macOS just wouldn't unlock it. Say so instead of
                // pretending there is none, and don't fall back to some other copy.
                lock.lock(); locked = true; lock.unlock()
                return
            case .missing:
                break       // the key is gone for good: nothing to unlock
            }
        }
        if let data = try? Data(contentsOf: plainFile), let p = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = p
        }
    }

    private func persist() {
        lock.lock(); let snapshot = payload; let isLocked = locked; lock.unlock()
        // Locked: the saved signature stays untouched on disk, and no plaintext copy is written beside it.
        // Anything drawn meanwhile lives in memory for this session only.
        if isLocked { return }
        guard let json = try? JSONEncoder().encode(snapshot) else { return }
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]

        if let key = keychainKey(create: true), let box = try? AES.GCM.seal(json, using: key), let sealed = box.combined {
            try? sealed.write(to: encryptedFile, options: .atomic)
            try? fm.setAttributes(attrs, ofItemAtPath: encryptedFile.path)
            try? fm.removeItem(at: plainFile)
        } else {
            // The Keychain refused while an encrypted signature exists: that's "locked", never a reason to
            // write the signature out in plaintext.
            if fm.fileExists(atPath: encryptedFile.path) {
                lock.lock(); locked = true; lock.unlock()
                return
            }
            try? json.write(to: plainFile, options: .atomic)
            try? fm.setAttributes(attrs, ofItemAtPath: plainFile.path)
        }
    }

    private enum KeyResult {
        case key(SymmetricKey)
        case missing        // no key stored yet
        case denied         // a key exists, but macOS wouldn't hand it over (prompt denied, locked, no access)
    }

    private var keychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "default",
        ]
    }

    private func fetchKey() -> KeyResult {
        var q = keychainBase
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess {
            if let data = out as? Data, data.count == 32 { return .key(SymmetricKey(data: data)) }
            return .missing
        }
        return status == errSecItemNotFound ? .missing : .denied
    }

    private func keychainKey(create: Bool) -> SymmetricKey? {
        let base = keychainBase
        switch fetchKey() {
        case .key(let k): return k
        case .denied: return nil
        case .missing: break
        }
        guard create else { return nil }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}

// MARK: - Fonts for typed signatures

enum SignFonts {
    private static let candidates: [(String, String)] = [
        ("Snell Roundhand", "SnellRoundhand"),
        ("Snell Bold", "SnellRoundhand-Bold"),
        ("Bradley Hand", "BradleyHandITCTT-Bold"),
        ("Zapfino", "Zapfino"),
        ("Savoye", "SavoyeLetPlain"),
        ("Signpainter", "SignPainter-HouseScript"),
        ("Noteworthy", "Noteworthy-Light"),
        ("Brush Script", "BrushScriptMT"),
    ]

    /// Only fonts this Mac actually has.
    static var available: [(label: String, ps: String)] {
        let found = candidates.filter { NSFont(name: $0.1, size: 12) != nil }.map { (label: $0.0, ps: $0.1) }
        return found.isEmpty ? [(label: "Helvetica Oblique", ps: "Helvetica-Oblique")] : found
    }
}

// MARK: - Photo of a wet-ink signature -> transparent ink

enum PhotoInk {
    /// Paper becomes transparent, ink keeps its darkness, the result is cropped to the ink.
    /// Works best on a flat, evenly lit page. Returns nil when there's no clear ink.
    static func make(from cg: CGImage, color: InkColor) -> Ink? {
        let scale = min(1.0, 1200.0 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
        guard let gctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = gctx.data else { return nil }
        gctx.setFillColor(CGColor(gray: 1, alpha: 1))
        gctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        gctx.interpolationQuality = .high
        gctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let gray = raw.assumingMemoryBound(to: UInt8.self)

        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<(w * h) { hist[Int(gray[i])] += 1 }
        func percentile(_ p: Double) -> Int {
            let target = Int(Double(w * h) * p)
            var acc = 0
            for v in 0..<256 {
                acc += hist[v]
                if acc >= target { return v }
            }
            return 255
        }
        let paper = Double(percentile(0.70))     // most of the photo is paper
        let ink = Double(percentile(0.004))      // the darkest sliver is pen
        let range = paper - ink
        guard range >= 40 else { return nil }

        var alpha = [UInt8](repeating: 0, count: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let g = Double(gray[y * w + x])
                var a = (paper - g - 0.15 * range) / (0.55 * range)
                a = min(max(a, 0), 1)
                a = a * a * (3 - 2 * a)          // smoothstep: soft edges, no speckle
                let v = UInt8(a * 255)
                alpha[y * w + x] = v
                if v > 40 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cr = color.r * 255, cgreen = color.g * 255, cb = color.b * 255
        for i in 0..<(w * h) {
            let a = Double(alpha[i]) / 255
            rgba[i * 4] = UInt8(cr * a)          // premultiplied
            rgba[i * 4 + 1] = UInt8(cgreen * a)
            rgba[i * 4 + 2] = UInt8(cb * a)
            rgba[i * 4 + 3] = alpha[i]
        }
        let full: CGImage? = rgba.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        let pad = Int(Double(max(maxX - minX, maxY - minY)) * 0.03) + 2
        let crop = CGRect(x: max(minX - pad, 0), y: max(minY - pad, 0),
                          width: min(maxX - minX + 2 * pad, w), height: min(maxY - minY + 2 * pad, h))
        guard let full, let cropped = full.cropping(to: crop.intersection(CGRect(x: 0, y: 0, width: w, height: h))),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { return nil }
        return Ink(source: .image(png), color: color, aspect: Double(cropped.width) / Double(cropped.height))
    }
}
