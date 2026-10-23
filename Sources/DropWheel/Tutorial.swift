import AppKit

// MARK: - Small building blocks

/// A flat rounded plate that follows light/dark mode.
private final class Plate: NSView {
    var fill: NSColor = NSColor.labelColor.withAlphaComponent(0.05) { didSet { refresh() } }
    var radius: CGFloat = 12 { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() { refresh() }

    private func refresh() {
        layer?.cornerRadius = radius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }
}

/// A keyboard key that lights up while the real key is held, so you can see DropWheel noticed it.
private final class KeyCap: NSView {
    var title = "⇧ Shift" { didSet { needsDisplay = true } }
    var lit = false { didSet { if lit != oldValue { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 34) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 2).offsetBy(dx: 0, dy: 1)
        let body = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (lit ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.09)).setFill()
        body.fill()
        NSColor.labelColor.withAlphaComponent(lit ? 0 : 0.14).setStroke()
        body.lineWidth = 1
        body.stroke()
        let str = NSAttributedString(string: title, attributes: [
            .font: Brand.font(13, weight: 700),
            .foregroundColor: lit ? NSColor.white : NSColor.secondaryLabelColor,
        ])
        let s = str.size()
        str.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: r.midY - s.height / 2))
    }
}

/// One numbered instruction. Looks different when it's the current step and when it's finished.
private final class StepRow: NSView {
    enum State { case pending, active, done }

    private let plate = Plate()
    private let badge = Plate()
    private let number = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    let accessory: NSView?
    private let index: Int

    init(index: Int, title: String, detail text: String, accessory: NSView? = nil) {
        self.index = index
        self.accessory = accessory
        super.init(frame: .zero)

        plate.radius = 12
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)

        badge.radius = 13
        badge.translatesAutoresizingMaskIntoConstraints = false
        number.font = Brand.font(13, weight: 800)
        number.alignment = .center
        number.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(number)

        heading.stringValue = title
        heading.font = Brand.font(15, weight: 700)
        detail.stringValue = text
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 270

        let texts = NSStackView(views: [heading, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var row: [NSView] = [badge, texts]
        if let accessory { row.append(accessory) }
        let h = NSStackView(views: row)
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)

        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            number.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            h.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
        set(.pending)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setTitle(_ s: String) { heading.stringValue = s }
    func setDetail(_ s: String) { detail.stringValue = s }

    func set(_ state: State) {
        switch state {
        case .pending:
            plate.fill = NSColor.labelColor.withAlphaComponent(0.04)
            badge.fill = NSColor.labelColor.withAlphaComponent(0.10)
            number.stringValue = "\(index + 1)"
            number.textColor = .tertiaryLabelColor
            heading.textColor = .tertiaryLabelColor
            detail.textColor = .tertiaryLabelColor
        case .active:
            plate.fill = NSColor.controlAccentColor.withAlphaComponent(0.15)
            badge.fill = .controlAccentColor
            number.stringValue = "\(index + 1)"
            number.textColor = .white
            heading.textColor = .labelColor
            detail.textColor = .secondaryLabelColor
        case .done:
            plate.fill = NSColor.labelColor.withAlphaComponent(0.04)
            badge.fill = .systemGreen
            number.stringValue = "✓"
            number.textColor = .white
            heading.textColor = .secondaryLabelColor
            detail.textColor = .tertiaryLabelColor
        }
    }
}

// MARK: - Controller

/// "Let's try it": a ten-second practice run with a real file, so people know it works.
/// hold key → drag the picture → the wheel appears (the JPG slice pulses) → let go → the toast confirms.
/// Without this, the end of setup is just a window that closes and leaves you wondering.
final class TutorialController: NSObject, NSWindowDelegate {
    var onFinish: (() -> Void)?

    private enum Phase { case hold, drag, flick, converting, done, failed }

    private static let hintID = "jpg"

    private var phase = Phase.hold
    private var window: NSWindow?
    private var timer: Timer?
    private var heldSince: TimeInterval?
    private var wheelSeenThisDrag = false
    private var nudge: String?
    private var nudgeToken = 0
    private var outputs: [URL] = []
    private var failure = ""
    private var chosenLabel = "JPG"

    private let root = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [StepRow] = []
    private let key = KeyCap()
    private let tile = DragFileView(frame: NSRect(x: 0, y: 0, width: 150, height: 100))
    private let tileCaption = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)

    private let width: CGFloat = 480
    private let inner: CGFloat = 416

    var isActive: Bool { window?.isVisible == true }

    // MARK: Where the practice file lives

    /// The system temp folder: macOS empties it on its own, so DropWheel never deletes anything here.
    static var sampleDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DropWheel Tutorial", isDirectory: true)
    }

    /// True when `urls` are the practice file (or something made from it).
    func owns(_ urls: [URL]) -> Bool {
        let dir = TutorialController.sampleDir.resolvingSymlinksInPath().path
        return !urls.isEmpty && urls.allSatisfy { $0.resolvingSymlinksInPath().deletingLastPathComponent().path == dir }
    }

    // MARK: Hooks from the app

    /// The wheel opened for these files.
    func wheelShown(for urls: [URL]) {
        guard isActive, owns(urls) else { return }
        wheelSeenThisDrag = true
        if phase == .hold || phase == .drag || phase == .flick {
            phase = .flick
            render()
        }
    }

    /// Which slice should pulse: JPG, but only for the practice file.
    func hintTarget(for urls: [URL]) -> String? {
        (isActive && owns(urls)) ? TutorialController.hintID : nil
    }

    func didChoose(_ target: Target, urls: [URL]) {
        guard isActive, owns(urls) else { return }
        chosenLabel = target.label
        phase = .converting
        render()
    }

    func didFinish(_ result: ConversionResult, urls: [URL]) {
        guard isActive, owns(urls), phase == .converting else { return }
        if result.errors.isEmpty, !result.outputs.isEmpty {
            outputs = result.outputs
            phase = .done
        } else {
            failure = result.errors.first ?? "Something went wrong."
            phase = .failed
        }
        render()
    }

    // MARK: Showing

    func show() {
        guard let sample = makeSample() else { return }
        phase = .hold
        heldSince = nil
        nudge = nil
        outputs = []
        wheelSeenThisDrag = false

        buildWindowIfNeeded()
        tile.fileURLs = [sample]
        tile.image = NSImage(contentsOf: sample)
        tile.cornerRadius = 12
        tileCaption.stringValue = sample.lastPathComponent
        rows[0].setTitle("Hold \(Settings.trigger.title)")
        key.title = Settings.trigger.title
        render()

        if let w = window, !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Lights the key cap while the real key is down, and moves to step 2 once it has been held.
    private func poll() {
        let down = NSEvent.modifierFlags.contains(Settings.trigger.flag)
        key.lit = down
        if down {
            if heldSince == nil { heldSince = ProcessInfo.processInfo.systemUptime }
            if phase == .hold, let s = heldSince, ProcessInfo.processInfo.systemUptime - s > 0.2 {
                phase = .drag
                render()
            }
        } else {
            heldSince = nil
        }
    }

    // MARK: Actions

    @objc private func primaryTapped() {
        if phase == .done { window?.close() } else { show() }       // "Try again" on failure
    }

    @objc private func secondaryTapped() {
        if phase == .done { show() } else { window?.close() }       // "Try again" / "Skip"
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        Settings.tutorialSeen = true
        onFinish?()
    }

    private func say(_ text: String) {
        nudge = text
        nudgeToken += 1
        let token = nudgeToken
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.nudgeToken == token else { return }
            self.nudge = nil
            self.render()
        }
    }

    private func dragEnded() {
        // Give the drop a beat to register before deciding nothing happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isActive else { return }
            switch self.phase {
            case .hold, .drag:
                if !self.wheelSeenThisDrag {
                    self.say("The wheel only appears if you're already holding \(Settings.trigger.title) when you start dragging. Hold it, then try again.")
                }
            case .flick:
                self.say("Almost. Let go on one of the slices. JPG is the one that's pulsing.")
            default:
                break
            }
        }
    }

    // MARK: Rendering

    private func render() {
        let trigger = Settings.trigger.title
        var active: Int?
        var finished = 0
        switch phase {
        case .hold: active = 0
        case .drag: active = 1; finished = 1
        case .flick: active = 2; finished = 2
        case .converting: active = 2; finished = 2
        case .done: finished = 3
        case .failed: finished = 2
        }
        for (i, row) in rows.enumerated() {
            if i < finished { row.set(.done) }
            else if i == active { row.set(.active) }
            else { row.set(.pending) }
        }

        switch phase {
        case .done:
            titleLabel.stringValue = "You've got it"
            subtitleLabel.stringValue = "That's all there is to it. Hold \(trigger) whenever you drag a file, and DropWheel will be there. It lives in your menu bar (look for ◎)."
            hintLabel.stringValue = "Your new \(chosenLabel) file is saved next to the original. You can drag it anywhere from here."
            if let out = outputs.first {
                tile.fileURLs = outputs
                tile.image = IconKit.image(forFile: out, size: 96, dark: isDark)
                tile.cornerRadius = 0
                tileCaption.stringValue = out.lastPathComponent
            }
            primary.title = "Finish"
            secondary.attributedTitle = quiet("Try again")
        case .failed:
            titleLabel.stringValue = "That didn't work"
            subtitleLabel.stringValue = "Nothing is broken. Here's what happened:"
            hintLabel.stringValue = failure
            primary.title = "Try Again"
            secondary.attributedTitle = quiet("Skip")
        default:
            titleLabel.stringValue = "Let's try it"
            subtitleLabel.stringValue = "Ten seconds, with a practice file. Follow the highlighted step."
            switch phase {
            case .hold: hintLabel.stringValue = "Press and hold \(trigger) to begin."
            case .drag: hintLabel.stringValue = "Good. Keep holding it, then click the picture and drag."
            case .flick: hintLabel.stringValue = "There it is. Flick toward JPG and let go."
            case .converting: hintLabel.stringValue = "Converting…"
            default: break
            }
            if let n = nudge { hintLabel.stringValue = n }
            primary.title = "Finish"
            secondary.attributedTitle = quiet("Skip")
        }
        primary.isHidden = phase != .done && phase != .failed
        resize()
    }

    private var isDark: Bool {
        window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func quiet(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    // MARK: The practice picture

    private func makeSample() -> URL? {
        let dir = TutorialController.sampleDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Try me.png")
        // Reuse the picture if it's already there. Nothing is ever removed or overwritten: results of
        // "Try again" just get " (1)", " (2)"... like every other conversion.
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let w = 1200, h = 800
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let rect = NSRect(x: 0, y: 0, width: w, height: h)
        NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.54, blue: 0.36, alpha: 1),
                            NSColor(srgbRed: 0.42, green: 0.36, blue: 0.91, alpha: 1)])?.draw(in: rect, angle: 35)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: 780, y: 330, width: 560, height: 560)).fill()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: -160, y: -200, width: 520, height: 520)).fill()

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        (("Try me") as NSString).draw(in: NSRect(x: 0, y: 340, width: w, height: 260), withAttributes: [
            .font: Brand.font(230, weight: 800), .foregroundColor: NSColor.white, .paragraphStyle: para,
        ])
        (("a practice file for DropWheel") as NSString).draw(in: NSRect(x: 0, y: 270, width: w, height: 60), withAttributes: [
            .font: Brand.font(46, weight: 600), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: para,
        ])
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    // MARK: Window

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "DropWheel"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView()
        w.contentView = content

        titleLabel.font = Brand.font(32, weight: 800)
        titleLabel.alignment = .center

        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.preferredMaxLayoutWidth = inner

        rows = [
            StepRow(index: 0, title: "Hold \(Settings.trigger.title)", detail: "Keep holding it while you drag.", accessory: key),
            StepRow(index: 1, title: "Drag the picture below", detail: "Click it, then start dragging."),
            StepRow(index: 2, title: "Flick toward JPG, then let go",
                    detail: "A circle opens around your cursor. Push toward the pulsing JPG slice and release."),
        ]

        let steps = NSStackView(views: rows)
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 8
        for r in rows { r.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true }

        tile.cornerRadius = 12
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.widthAnchor.constraint(equalToConstant: 150).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 100).isActive = true
        tile.onDragBegan = { [weak self] in self?.wheelSeenThisDrag = false }
        tile.onDragEnded = { [weak self] in self?.dragEnded() }

        tileCaption.font = NSFont.systemFont(ofSize: 11)
        tileCaption.textColor = .tertiaryLabelColor

        hintLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .labelColor
        hintLabel.alignment = .center
        hintLabel.preferredMaxLayoutWidth = inner

        primary.bezelStyle = .rounded
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryTapped)
        secondary.isBordered = false
        secondary.target = self
        secondary.action = #selector(secondaryTapped)

        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        for v in [titleLabel, subtitleLabel, steps, tile, tileCaption, hintLabel, primary, secondary] as [NSView] {
            root.addArrangedSubview(v)
        }
        root.setCustomSpacing(6, after: titleLabel)
        root.setCustomSpacing(22, after: subtitleLabel)
        root.setCustomSpacing(22, after: steps)
        root.setCustomSpacing(4, after: tile)
        root.setCustomSpacing(18, after: tileCaption)
        root.setCustomSpacing(16, after: hintLabel)
        for v in [subtitleLabel, steps, hintLabel] as [NSView] {
            v.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
        primary.widthAnchor.constraint(equalToConstant: 160).isActive = true

        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: (width - inner) / 2),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(width - inner) / 2),
        ])
        window = w
    }

    /// Fit the window to its content, keeping the top edge where it is.
    private func resize() {
        guard let w = window else { return }
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: ceil(root.fittingSize.height) + 56)
        let target = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var f = w.frame
        f.origin.y += f.height - target.height
        f.size = target.size
        w.setFrame(f, display: true, animate: false)
    }
}
