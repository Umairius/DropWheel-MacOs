import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - The drawing surface

/// Mouse or trackpad. Fast strokes get thinner and slow ones thicker, like a pen.
final class DrawCanvas: NSView {
    static let pen: CGFloat = 2.6

    var strokes: [[InkPoint]] = []
    var color: InkColor = .black { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?

    private var current: [InkPoint] = []
    private var lastTime: TimeInterval = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var hasInk: Bool { strokes.flatMap { $0 }.count > 3 }

    func clear() {
        strokes = []
        current = []
        needsDisplay = true
        onChange?()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        current = [InkPoint(x: Double(p.x), y: Double(p.y), w: 1)]
        lastTime = event.timestamp
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let last = current.last else { return }
        let dist = hypot(Double(p.x) - last.x, Double(p.y) - last.y)
        if dist < 0.8 { return }
        let dt = max(event.timestamp - lastTime, 0.001)
        let speed = dist / dt
        let target = min(1.5, max(0.5, 1.6 - speed / 1400))
        current.append(InkPoint(x: Double(p.x), y: Double(p.y), w: last.w * 0.7 + target * 0.3))
        lastTime = event.timestamp
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !current.isEmpty { strokes.append(current) }
        current = []
        needsDisplay = true
        onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.stroke()

        let y = bounds.height * 0.72
        NSColor(calibratedWhite: 0.75, alpha: 0.6).setStroke()
        let guide = NSBezierPath()
        guide.move(to: NSPoint(x: 24, y: y))
        guide.line(to: NSPoint(x: bounds.width - 24, y: y))
        guide.lineWidth = 1
        guide.stroke()

        if strokes.isEmpty && current.isEmpty {
            let s = NSAttributedString(string: "Sign here with your mouse or trackpad", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)])
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2 - 20))
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var budget = Int.max
        let all = current.isEmpty ? strokes : strokes + [current]
        for s in all {
            StrokePainter.paint(StrokePainter.smooth(s), pen: DrawCanvas.pen, color: color.cgColor, ctx: ctx, budget: &budget)
        }
    }

    /// Normalizes what was drawn into a 0...1 box, so it can be resized without losing quality.
    func makeInk() -> Ink? {
        let all = strokes.flatMap { $0 }
        guard all.count > 3,
              let minXv = all.map({ $0.x }).min(), let maxXv = all.map({ $0.x }).max(),
              let minYv = all.map({ $0.y }).min(), let maxYv = all.map({ $0.y }).max() else { return nil }
        let pad = Double(DrawCanvas.pen) * 1.5
        let minX = minXv - pad, minY = minYv - pad
        let bw = max(maxXv + pad - minX, 8), bh = max(maxYv + pad - minY, 8)
        let norm = strokes.map { s in
            Stroke(points: s.map { InkPoint(x: ($0.x - minX) / bw, y: ($0.y - minY) / bh, w: $0.w) })
        }
        return Ink(source: .strokes(norm), color: color, aspect: bw / bh, pen: Double(DrawCanvas.pen) / bh)
    }
}

/// Shows an ink, fitted into the box.
final class InkPreview: NSView {
    var ink: Ink? { didSet { needsDisplay = true } }
    var emptyHint = ""

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.stroke()
        guard let ctx = NSGraphicsContext.current?.cgContext, let ink else {
            let s = NSAttributedString(string: emptyHint, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)])
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
            return
        }
        let box = bounds.insetBy(dx: 28, dy: 22)
        var w = box.width
        var h = w / CGFloat(ink.aspect)
        if h > box.height {
            h = box.height
            w = h * CGFloat(ink.aspect)
        }
        ink.draw(in: ctx, rect: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
    }
}

// MARK: - The sheet

/// Create a signature (or initials): draw it, type it, or import a photo of one on paper.
final class SignaturePad: NSObject, NSTextFieldDelegate {
    private static var live: [SignaturePad] = []

    /// Shown as a sheet when `parent` is given, otherwise as its own window.
    /// `forceSave` is for "Redraw signature": no checkbox, always saved.
    static func present(slot: SignSlot, from parent: NSWindow?, forceSave: Bool = false,
                        completion: @escaping (Ink?) -> Void) {
        let pad = SignaturePad(slot: slot, forceSave: forceSave, completion: completion)
        live.append(pad)
        pad.show(on: parent)
    }

    private let slot: SignSlot
    private let forceSave: Bool
    private var completion: ((Ink?) -> Void)?
    private weak var parent: NSWindow?

    private let window: NSWindow
    private let tabs = NSSegmentedControl(labels: ["Draw", "Type", "Photo"], trackingMode: .selectOne, target: nil, action: nil)
    private let colors = NSSegmentedControl(labels: ["Black ink", "Blue ink"], trackingMode: .selectOne, target: nil, action: nil)
    private let stageDraw = NSView(frame: NSRect(x: 20, y: 100, width: 520, height: 250))
    private let stageType = NSView(frame: NSRect(x: 20, y: 100, width: 520, height: 250))
    private let stagePhoto = NSView(frame: NSRect(x: 20, y: 100, width: 520, height: 250))
    private let canvas = DrawCanvas(frame: NSRect(x: 0, y: 0, width: 520, height: 250))
    private let typeField = NSTextField(string: "")
    private let fontPop = NSPopUpButton(frame: NSRect(x: 0, y: 180, width: 240, height: 26), pullsDown: false)
    private let typePreview = InkPreview(frame: NSRect(x: 0, y: 0, width: 520, height: 170))
    private let photoPreview = InkPreview(frame: NSRect(x: 0, y: 0, width: 520, height: 205))
    private let photoNote = NSTextField(labelWithString: "")
    private let remember = NSButton(checkboxWithTitle: "Remember it for next time", target: nil, action: nil)
    private let fonts = SignFonts.available
    private var photo: CGImage?
    private var photoInk: Ink?

    private init(slot: SignSlot, forceSave: Bool, completion: @escaping (Ink?) -> Void) {
        self.slot = slot
        self.forceSave = forceSave
        self.completion = completion
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        build()
    }

    // MARK: Layout

    private var currentColor: InkColor { colors.selectedSegment == 1 ? .blue : .black }

    private func build() {
        window.title = slot == .signature ? "Your signature" : "Your initials"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        window.contentView = content

        let title = NSTextField(labelWithString: slot == .signature ? "Create your signature" : "Create your initials")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        title.frame = NSRect(x: 20, y: 400, width: 520, height: 24)
        content.addSubview(title)

        tabs.frame = NSRect(x: 20, y: 362, width: 300, height: 26)
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        content.addSubview(tabs)

        colors.frame = NSRect(x: 340, y: 362, width: 200, height: 26)
        colors.selectedSegment = 0
        colors.target = self
        colors.action = #selector(colorChanged)
        content.addSubview(colors)

        // Draw
        canvas.onChange = { [weak self] in self?.refreshButtons() }
        stageDraw.addSubview(canvas)

        // Type
        let name = SignatureStore.shared.printedName ?? NSFullUserName()
        typeField.stringValue = slot == .signature ? name : SignaturePad.initials(of: name)
        typeField.placeholderString = slot == .signature ? "Type your name" : "Type your initials"
        typeField.font = NSFont.systemFont(ofSize: 15)
        typeField.frame = NSRect(x: 0, y: 215, width: 520, height: 28)
        typeField.delegate = self
        stageType.addSubview(typeField)
        for f in fonts { fontPop.addItem(withTitle: f.label) }
        fontPop.target = self
        fontPop.action = #selector(typeChanged)
        stageType.addSubview(fontPop)
        typePreview.emptyHint = "Type something above"
        stageType.addSubview(typePreview)

        // Photo
        let choose = NSButton(title: "Choose a photo of your signature…", target: self, action: #selector(choosePhoto))
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: 0, y: 215, width: 260, height: 28)
        stagePhoto.addSubview(choose)
        photoNote.frame = NSRect(x: 270, y: 219, width: 250, height: 20)
        photoNote.font = NSFont.systemFont(ofSize: 11)
        photoNote.textColor = .secondaryLabelColor
        photoNote.stringValue = "Sign on white paper, flat and well lit"
        stagePhoto.addSubview(photoNote)
        photoPreview.emptyHint = "Paper turns transparent, only the ink is kept"
        stagePhoto.addSubview(photoPreview)

        for v in [stageDraw, stageType, stagePhoto] { content.addSubview(v) }

        remember.state = .on
        remember.frame = NSRect(x: 20, y: 64, width: 300, height: 20)
        remember.isHidden = forceSave
        content.addSubview(remember)

        let hint = NSTextField(labelWithString: "Stays on this Mac, encrypted. It is only used when you press Sign.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 40, width: 520, height: 16)
        content.addSubview(hint)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearCanvas))
        clear.frame = NSRect(x: 20, y: 10, width: 80, height: 28)
        clear.bezelStyle = .rounded
        clear.identifier = NSUserInterfaceItemIdentifier("clear")
        content.addSubview(clear)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.frame = NSRect(x: 350, y: 10, width: 90, height: 28)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        content.addSubview(cancelButton)

        let useButton = NSButton(title: "Use", target: self, action: #selector(use(_:)))
        useButton.frame = NSRect(x: 450, y: 10, width: 90, height: 28)
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.identifier = NSUserInterfaceItemIdentifier("use")
        content.addSubview(useButton)

        tabChanged()
        refreshTypePreview()
    }

    static func initials(of name: String) -> String {
        name.split(separator: " ").compactMap { $0.first }.prefix(3).map { String($0) }.joined().uppercased()
    }

    // MARK: Presenting

    func show(on parent: NSWindow?) {
        self.parent = parent
        if let parent {
            parent.beginSheet(window, completionHandler: nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(canvas)
    }

    private func finish(_ ink: Ink?) {
        if let parent { parent.endSheet(window) }
        window.orderOut(nil)
        SignaturePad.live.removeAll { $0 === self }
        let done = completion
        completion = nil
        done?(ink)
    }

    // MARK: Actions

    @objc private func tabChanged() {
        stageDraw.isHidden = tabs.selectedSegment != 0
        stageType.isHidden = tabs.selectedSegment != 1
        stagePhoto.isHidden = tabs.selectedSegment != 2
        if let clear = window.contentView?.subviews.first(where: { $0.identifier?.rawValue == "clear" }) {
            clear.isHidden = tabs.selectedSegment != 0
        }
        if tabs.selectedSegment == 1 { window.makeFirstResponder(typeField) }
        refreshButtons()
    }

    @objc private func colorChanged() {
        canvas.color = currentColor
        refreshTypePreview()
        if let cg = photo { photoInk = PhotoInk.make(from: cg, color: currentColor); photoPreview.ink = photoInk }
    }

    @objc private func typeChanged() { refreshTypePreview() }

    func controlTextDidChange(_ obj: Notification) { refreshTypePreview() }

    @objc private func clearCanvas() { canvas.clear() }

    @objc private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a photo or scan of your signature on white paper"
        guard panel.runModal() == .OK, let url = panel.url,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = try? ImageBackend.orientedImage(src) else { return }
        photo = cg
        photoInk = PhotoInk.make(from: cg, color: currentColor)
        photoPreview.ink = photoInk
        photoNote.stringValue = photoInk == nil
            ? "No clear ink found. Try a flat, well-lit page."
            : "Paper removed. Looks right? Press Use."
        refreshButtons()
    }

    private func refreshTypePreview() {
        let text = typeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = fonts[max(fontPop.indexOfSelectedItem, 0)].ps
        if text.isEmpty {
            typePreview.ink = nil
        } else {
            typePreview.ink = Ink(source: .typed(text, font), color: currentColor,
                                  aspect: TextInk.aspect(of: text, fontName: font))
        }
        refreshButtons()
    }

    private func refreshButtons() {
        guard let use = window.contentView?.subviews.first(where: { $0.identifier?.rawValue == "use" }) as? NSButton else { return }
        switch tabs.selectedSegment {
        case 0: use.isEnabled = canvas.hasInk
        case 1: use.isEnabled = typePreview.ink != nil
        default: use.isEnabled = photoInk != nil
        }
    }

    private func currentInk() -> Ink? {
        switch tabs.selectedSegment {
        case 0:
            canvas.color = currentColor
            return canvas.makeInk()
        case 1: return typePreview.ink
        default: return photoInk
        }
    }

    @objc private func use(_ sender: Any?) {
        guard let ink = currentInk() else { NSSound.beep(); return }
        if forceSave || remember.state == .on { SignatureStore.shared.save(ink, slot: slot) }
        finish(ink)
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }
}
