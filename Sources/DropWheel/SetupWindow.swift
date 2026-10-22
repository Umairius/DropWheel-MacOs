import AppKit

// MARK: - Small building blocks

/// A flat rounded panel. Draws its own (appearance-aware) fill, takes no clicks, never looks like a control.
private final class CardView: NSView {
    var fill: NSColor = NSColor.labelColor.withAlphaComponent(0.06) { didSet { needsDisplay = true } }
    var radius: CGFloat = 12 { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.cornerRadius = radius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Measures real download speed against the file we're about to fetch (a few MB, a few seconds).
/// Includes connection latency on purpose: the estimate errs on the slow side, so "no more than" holds.
private final class SpeedProbe: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?
    private var session: URLSession?
    private var received: Int64 = 0
    private var started = Date()
    private var maxBytes: Int64 = 4_000_000

    /// Megabits per second, or nil if nothing useful came back (offline, blocked, too slow to tell).
    func run(url: URL, maxBytes: Int64 = 4_000_000, maxSeconds: TimeInterval = 5) async -> Double? {
        self.maxBytes = maxBytes
        return await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 8
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
            lock.lock()
            continuation = c
            session = s
            received = 0
            started = Date()
            lock.unlock()
            s.dataTask(with: req).resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds) { [weak self] in self?.finish() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received += Int64(data.count)
        let enough = received >= maxBytes
        lock.unlock()
        if enough { finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        lock.lock()
        let c = continuation
        continuation = nil
        let s = session
        session = nil
        let bytes = received
        let secs = max(Date().timeIntervalSince(started), 0.05)
        lock.unlock()
        guard let c else { return }
        s?.invalidateAndCancel()
        c.resume(returning: bytes > 100_000 ? Double(bytes) * 8 / secs / 1_000_000 : nil)
    }
}

private extension HelperTool {
    var symbol: String {
        switch self {
        case .ffmpeg: return "play.rectangle.fill"
        case .pandoc: return "doc.text.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .ffmpeg: return .systemPink
        case .pandoc: return .systemBlue
        }
    }
}

// MARK: - Controller

/// The one-time "getting DropWheel ready" window.
/// welcome → installing → done   (or → failed → Try Again)
/// Written for people who don't know what ffmpeg is: plain words, one obvious button, no surprises.
final class SetupController: NSObject, NSWindowDelegate, @unchecked Sendable {
    /// Menu-bar icon hooks.
    var onBegin: (() -> Void)?
    var onEnd: ((Bool) -> Void)?       // true = everything installed

    private enum Phase { case welcome, installing, done, failed }
    private enum RowState { case pending, active, done, failed }
    private struct Row { let card: CardView; let status: NSImageView; let spinner: NSProgressIndicator }

    private let width: CGFloat = 480
    private let inner: CGFloat = 416

    private var phase = Phase.welcome
    private var items: [HelperTool] = []
    private var rows: [HelperTool: Row] = [:]
    private var lead: String?
    private var failure = ""
    private var shownProgress = 0.0
    private var task: Task<Void, Never>?

    // Time estimate from a real speed probe.
    private var probing = false
    private var estimateMinutes: Int?
    private var probeGeneration = 0

    private var window: NSWindow?
    private let root = NSStackView()
    private let iconTile = CardView()
    private let iconGlyph = NSTextField(labelWithString: "◎")
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(wrappingLabelWithString: "")
    private let listCaption = NSTextField(labelWithString: "WHAT YOU'LL GET")
    private let listStack = NSStackView()
    private let bar = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let footnote = NSTextField(wrappingLabelWithString: "")

    // MARK: Entry point

    /// Shows the window for `missing` helpers. Safe to call any time; does nothing if nothing is missing
    /// and just brings the window forward if an install is already running.
    func show(missing: [HelperTool], because reason: String? = nil) {
        guard !missing.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            if phase == .installing, window?.isVisible == true {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                return
            }
            items = missing
            lead = reason
            failure = ""
            phase = .welcome
            probing = true                     // never flash a stale estimate from an earlier open
            estimateMinutes = nil
            buildWindowIfNeeded()
            rebuildRows()
            render()
            present()
            measureSpeed()
        }
    }

    // MARK: Time estimate

    private func measureSpeed() {
        guard let url = items.first?.url else { return }
        probing = true
        estimateMinutes = nil
        probeGeneration += 1
        let generation = probeGeneration
        refreshEstimateText()
        Task { [self] in
            let mbps = await SpeedProbe().run(url: url)
            await MainActor.run {
                guard probeGeneration == generation else { return }
                probing = false
                if let mbps { estimateMinutes = estimate(forMbps: mbps) }
                refreshEstimateText()
            }
        }
    }

    /// Download time at the measured speed, +25% safety margin, +10 s per helper for unpacking and checking.
    private func estimate(forMbps mbps: Double) -> Int {
        let todo = items.filter { !$0.isInstalled }
        let bytes = todo.reduce(Int64(0)) { $0 + $1.downloadBytes }
        let seconds = Double(bytes) * 8 / (max(mbps, 0.1) * 1_000_000) * 1.25 + Double(todo.count) * 10
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    private func minutesPhrase(_ m: Int) -> String { m <= 1 ? "a minute" : "\(m) minutes" }

    private func refreshEstimateText() {
        switch phase {
        case .welcome:
            if probing {
                timeLabel.stringValue = "Checking your internet speed…"
            } else if let m = estimateMinutes {
                timeLabel.stringValue = "Based on your internet speed right now, this should take no more than \(minutesPhrase(m))."
            } else {
                timeLabel.stringValue = "This usually takes a minute or two."
            }
        case .installing:
            if let m = estimateMinutes {
                bodyLabel.stringValue = "This should take no more than \(minutesPhrase(m)). Feel free to keep using your Mac."
            } else {
                bodyLabel.stringValue = "This usually takes a minute or two. Feel free to keep using your Mac."
            }
        default:
            break
        }
        resize()
    }

    // MARK: Actions

    @objc private func primaryTapped() {
        switch phase {
        case .welcome, .failed: start()
        case .done: window?.close()
        case .installing: break
        }
    }

    @objc private func secondaryTapped() {
        switch phase {
        case .welcome:
            Settings.setupDeclined = true      // don't auto-open again; the menu still offers it
            window?.close()
        case .installing:
            task?.cancel()
            phase = .failed                    // so closing doesn't count as "declined"
            window?.close()
        case .failed, .done:
            window?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        probeGeneration += 1                   // drop any in-flight speed probe result
        if phase == .welcome { Settings.setupDeclined = true }
        if phase == .installing { task?.cancel(); phase = .failed }
    }

    // MARK: Install sequence

    private func start() {
        phase = .installing
        shownProgress = 0
        bar.doubleValue = 0
        for h in items { setState(h.isInstalled ? .done : .pending, h) }
        render()
        task = Task { [self] in await run() }
    }

    private func run() async {
        let todo = items.filter { !$0.isInstalled }
        await MainActor.run { self.onBegin?() }

        // Keep the Mac awake while we work: a sleeping laptop is the #1 way downloads die.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Setting up DropWheel")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // 1. Free space check, before any download.
        do {
            try HelperInstaller.preflight(todo)
        } catch {
            await MainActor.run {
                for h in todo { self.setState(.failed, h) }
                self.failure = error.localizedDescription
                self.phase = .failed
                self.render()
                self.onEnd?(false)
            }
            return
        }

        // 2. One helper at a time; a failure on one doesn't stop the others.
        let total = Double(todo.reduce(Int64(0)) { $0 + $1.downloadBytes })
        var base = 0.0
        var errors: [String] = []
        for h in todo {
            if Task.isCancelled { break }
            let start = base
            await MainActor.run {
                self.setState(.active, h)
                self.setStatus("Downloading \(h.phrase)…")
            }
            do {
                try await HelperInstaller.install(h) { ev in
                    DispatchQueue.main.async { self.apply(ev, for: h, base: start, total: total) }
                }
                await MainActor.run { self.setState(.done, h) }
            } catch is CancellationError {
                break
            } catch {
                errors.append(error.localizedDescription)
                await MainActor.run { self.setState(.failed, h) }
            }
            base += Double(h.downloadBytes)
        }

        if Task.isCancelled {
            await MainActor.run { self.onEnd?(false) }
            return
        }

        // 3. Let the full bar and the ticks register for a beat before switching screens.
        let finalErrors = errors
        if finalErrors.isEmpty {
            await MainActor.run {
                self.advance(1)
                self.setStatus("All done.")
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        await MainActor.run {
            if finalErrors.isEmpty {
                self.phase = .done
            } else {
                self.failure = finalErrors[0]
                self.phase = .failed
            }
            self.render()
            self.onEnd?(finalErrors.isEmpty)
        }
    }

    private func apply(_ ev: InstallEvent, for h: HelperTool, base: Double, total: Double) {
        guard phase == .installing, total > 0 else { return }
        let weight = Double(h.downloadBytes)
        switch ev {
        case .waiting:
            setStatus("Waiting for your internet connection… we'll carry on as soon as it's back.")
        case .downloading(let got, let expected):
            let frac = expected > 0 ? min(Double(got) / Double(expected), 1) : 0
            advance((base + frac * 0.92 * weight) / total)
            if expected > 0 {
                setStatus("Downloading \(h.phrase) · \(mb(got)) of \(mb(expected)) MB")
            } else {
                setStatus("Downloading \(h.phrase)…")
            }
        case .finishing:
            advance((base + 0.96 * weight) / total)
            setStatus("Installing \(h.phrase)…")
        }
    }

    /// The bar only ever moves forward, even when a retry restarts a download.
    private func advance(_ fraction: Double) {
        shownProgress = max(shownProgress, min(fraction, 1))
        bar.doubleValue = shownProgress * 100
    }

    private func mb(_ bytes: Int64) -> Int { Int((Double(bytes) / 1_000_000).rounded()) }
    private func setStatus(_ s: String) { statusLabel.stringValue = s }

    // MARK: Window construction

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 460),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "DropWheel"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView()
        w.contentView = content

        // App tile
        iconTile.fill = .controlAccentColor
        iconTile.radius = 16
        iconGlyph.font = .systemFont(ofSize: 34, weight: .medium)
        iconGlyph.textColor = .white
        iconGlyph.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(iconGlyph)
        NSLayoutConstraint.activate([
            iconTile.widthAnchor.constraint(equalToConstant: 64),
            iconTile.heightAnchor.constraint(equalToConstant: 64),
            iconGlyph.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconGlyph.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center

        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.preferredMaxLayoutWidth = inner

        timeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .labelColor
        timeLabel.alignment = .center
        timeLabel.preferredMaxLayoutWidth = inner

        listCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        listCaption.textColor = .tertiaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = inner

        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        footnote.alignment = .center
        footnote.preferredMaxLayoutWidth = inner

        // One obvious button; the escape hatch is quiet text underneath, not a second button.
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
        for v in [iconTile, titleLabel, bodyLabel, timeLabel, listCaption, listStack, bar, statusLabel,
                  primary, secondary, footnote] {
            root.addArrangedSubview(v)
        }
        root.setCustomSpacing(18, after: iconTile)
        root.setCustomSpacing(8, after: titleLabel)
        root.setCustomSpacing(10, after: bodyLabel)
        root.setCustomSpacing(24, after: timeLabel)
        root.setCustomSpacing(8, after: listCaption)
        root.setCustomSpacing(24, after: listStack)
        root.setCustomSpacing(10, after: bar)
        root.setCustomSpacing(20, after: statusLabel)
        root.setCustomSpacing(8, after: primary)
        root.setCustomSpacing(16, after: secondary)
        listCaption.widthAnchor.constraint(equalToConstant: inner).isActive = true
        for v in [bodyLabel, timeLabel, listStack, bar, statusLabel, footnote, primary] {
            v.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }

        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: (width - inner) / 2),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(width - inner) / 2),
        ])
        window = w
    }

    private func rebuildRows() {
        for v in listStack.arrangedSubviews { listStack.removeArrangedSubview(v); v.removeFromSuperview() }
        rows = [:]
        for h in items {
            let row = makeRow(h)
            rows[h] = row
            listStack.addArrangedSubview(row.card)
            row.card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            setState(.pending, h)
        }
    }

    /// [ colored icon tile ]  Title / one-line blurb                    [ status ]
    private func makeRow(_ h: HelperTool) -> Row {
        let tile = CardView()
        tile.radius = 10
        tile.fill = h.tint.withAlphaComponent(0.16)
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: h.symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        glyph.contentTintColor = h.tint
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 40),
            tile.heightAnchor.constraint(equalToConstant: 40),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let name = NSTextField(labelWithString: h.title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: h.blurb)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 270
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Status lives on the right, like Apple's own installers: spinner while working, tick when done.
        let status = NSImageView()
        status.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        status.isHidden = true
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        let trailing = NSStackView(views: [status, spinner])
        trailing.alignment = .centerY
        trailing.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let rowStack = NSStackView(views: [tile, text, trailing])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let card = CardView()
        card.radius = 12
        card.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return Row(card: card, status: status, spinner: spinner)
    }

    private func setState(_ s: RowState, _ h: HelperTool) {
        guard let row = rows[h] else { return }
        row.spinner.stopAnimation(nil)
        row.spinner.isHidden = true
        row.status.isHidden = true
        switch s {
        case .pending:
            break
        case .active:
            row.spinner.isHidden = false
            row.spinner.startAnimation(nil)
        case .done:
            row.status.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
            row.status.contentTintColor = .systemGreen
            row.status.isHidden = false
        case .failed:
            row.status.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Problem")
            row.status.contentTintColor = .systemOrange
            row.status.isHidden = false
        }
    }

    private func styleSecondary(_ title: String) {
        secondary.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    // MARK: Rendering per phase

    private func render() {
        switch phase {
        case .welcome:
            let total = items.reduce(Int64(0)) { $0 + $1.downloadBytes }
            let intro = lead.map { $0 + "\n\n" } ?? ""
            titleLabel.stringValue = "Let's get DropWheel ready"
            bodyLabel.stringValue = intro
                + "DropWheel converts your files right here on your Mac, so nothing is ever uploaded. "
                + "To do that it needs a few free helper tools that macOS doesn't include. "
                + "We'll download them once (about \(mb(total)) MB) and you won't see this again."
            footnote.stringValue = "Free, open-source tools: FFmpeg and Pandoc."
            primary.title = "Set Up DropWheel"
            styleSecondary("Not Now")
            timeLabel.isHidden = false
            listCaption.isHidden = false
            bar.isHidden = true
            statusLabel.isHidden = true
            primary.isHidden = false
            secondary.isHidden = false
            footnote.isHidden = false
            refreshEstimateText()

        case .installing:
            titleLabel.stringValue = "Setting things up…"
            setStatus("Starting…")
            styleSecondary("Cancel")
            timeLabel.isHidden = true
            listCaption.isHidden = true
            bar.isHidden = false
            statusLabel.isHidden = false
            primary.isHidden = true
            secondary.isHidden = false
            footnote.isHidden = true
            refreshEstimateText()

        case .done:
            titleLabel.stringValue = "You're all set"
            bodyLabel.stringValue = "Hold \(Settings.trigger.title) while you drag any file, then flick toward what you want it turned into. "
                + "DropWheel lives in your menu bar at the top of the screen (look for ◎)."
            primary.title = "Got It"
            timeLabel.isHidden = true
            listCaption.isHidden = true
            bar.isHidden = true
            statusLabel.isHidden = true
            primary.isHidden = false
            secondary.isHidden = true
            footnote.isHidden = true

        case .failed:
            titleLabel.stringValue = "Couldn't finish setting up"
            bodyLabel.stringValue = failure
                + "\n\nNothing is broken, and anything that already downloaded is kept, so trying again is quick."
            primary.title = "Try Again"
            styleSecondary("Later")
            timeLabel.isHidden = true
            listCaption.isHidden = true
            bar.isHidden = true
            statusLabel.isHidden = true
            primary.isHidden = false
            secondary.isHidden = false
            footnote.isHidden = true
        }
        resize()
    }

    /// Fit the window to its content, keeping the top edge where it is.
    private func resize() {
        guard let w = window else { return }
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: ceil(root.fittingSize.height) + 64)
        let target = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var f = w.frame
        f.origin.y += f.height - target.height
        f.size = target.size
        w.setFrame(f, display: true, animate: false)
    }

    private func present() {
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
