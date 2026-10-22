import AppKit
import LocalAuthentication
import PDFKit
import QuartzCore

// MARK: - The pages, and everything placed on them

/// All pages stacked vertically. Stamps are drawn live (vector), so zooming never blurs a signature.
/// Coordinates: this view is flipped, and a page's upright space (origin top-left, y down) is just
/// its frame's origin plus the stamp's rect.
final class PageStackView: NSView {
    // Content
    private(set) var pageSizes: [CGSize] = []
    private(set) var pageFrames: [NSRect] = []
    var stamps: [Stamp] = [] { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var snapSpots: [Spot] = []

    // Hooks
    var renderPage: ((Int) -> CGImage?)?          // runs on a background queue
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCycleSpot: ((Int) -> Void)?
    var onStampsChanged: (() -> Void)?

    // State
    private var images: [Int: CGImage] = [:]
    private var inflight = Set<Int>()
    private var failed = Set<Int>()
    private let renderQueue = DispatchQueue(label: "dropwheel.sign.render", qos: .userInitiated)
    private var undoStack: [[Stamp]] = []
    private var animStart: [UUID: CFTimeInterval] = [:]
    private var animTimer: Timer?
    private let animDuration: CFTimeInterval = 0.6
    private var drag: Drag?
    private var pendingPlace: NSPoint?
    private var snappedTo: Int?
    private let margin: CGFloat = 28
    private let gap: CGFloat = 18

    private enum Corner { case tl, tr, bl, br }

    private struct Drag {
        enum Mode {
            case move(grab: CGSize)
            case resize(Corner, anchor: CGPoint)
        }
        var index: Int
        var mode: Mode
        var before: [Stamp]
        var pushed = false
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    func setPages(_ sizes: [CGSize]) {
        pageSizes = sizes
        images.removeAll()
        inflight.removeAll()
        failed.removeAll()
        let maxW = sizes.map { $0.width }.max() ?? 600
        let docW = maxW + margin * 2
        var y = margin
        var frames: [NSRect] = []
        for s in sizes {
            frames.append(NSRect(x: (docW - s.width) / 2, y: y, width: s.width, height: s.height))
            y += s.height + gap
        }
        pageFrames = frames
        setFrameSize(NSSize(width: docW, height: max(y - gap + margin, 100)))
        needsDisplay = true
    }

    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var selectedIndex: Int? { stamps.firstIndex { $0.id == selectedID } }

    private func stampFrame(_ s: Stamp) -> NSRect {
        guard s.page >= 0, s.page < pageFrames.count else { return .zero }
        let f = pageFrames[s.page]
        return NSRect(x: f.minX + s.rect.minX, y: f.minY + s.rect.minY, width: s.rect.width, height: s.rect.height)
    }

    func visibleCenter() -> (page: Int, local: CGPoint) {
        let vis = enclosingScrollView?.contentView.bounds ?? bounds
        let c = CGPoint(x: vis.midX, y: vis.midY)
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, f) in pageFrames.enumerated() {
            let dx = max(f.minX - c.x, 0, c.x - f.maxX)
            let dy = max(f.minY - c.y, 0, c.y - f.maxY)
            let d = hypot(dx, dy)
            if d < bestDist { best = i; bestDist = d }
        }
        guard best < pageFrames.count else { return (0, .zero) }
        let f = pageFrames[best]
        return (best, CGPoint(x: min(max(c.x - f.minX, 0), f.width), y: min(max(c.y - f.minY, 0), f.height)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let z = zoom

        for (i, f) in pageFrames.enumerated() where f.intersects(dirtyRect.insetBy(dx: -30, dy: -30)) {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
            NSColor.white.setFill()
            f.fill()
            ctx.restoreGState()

            if let img = images[i] {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                NSImage(cgImage: img, size: f.size).draw(in: f, from: .zero, operation: .sourceOver,
                                                         fraction: 1, respectFlipped: true, hints: nil)
                ctx.restoreGState()
            } else {
                ensureImage(i)
            }
        }

        for s in stamps where s.page >= 0 && s.page < pageFrames.count {
            let f = pageFrames[s.page]
            guard f.intersects(dirtyRect.insetBy(dx: -60, dy: -60)) else { continue }
            ctx.saveGState()
            ctx.translateBy(x: f.minX, y: f.minY)
            s.draw(in: ctx, progress: progress(for: s.id), alpha: s.ghost ? 0.62 : 1)
            ctx.restoreGState()

            let isSel = s.id == selectedID
            guard isSel || s.ghost else { continue }
            let fr = stampFrame(s)
            let path = NSBezierPath(rect: fr.insetBy(dx: -3, dy: -3))
            path.lineWidth = 1.2 / z
            if s.ghost && !isSel { path.setLineDash([4 / z, 3 / z], count: 2, phase: 0) }
            NSColor.controlAccentColor.withAlphaComponent(isSel ? 0.95 : 0.6).setStroke()
            path.stroke()
            if isSel {
                for c in [Corner.tl, .tr, .bl, .br] {
                    let h = handleRect(c, of: fr, zoom: z)
                    NSColor.white.setFill()
                    NSColor.controlAccentColor.setStroke()
                    let hp = NSBezierPath(roundedRect: h, xRadius: 2 / z, yRadius: 2 / z)
                    hp.fill()
                    hp.lineWidth = 1.5 / z
                    hp.stroke()
                }
            }
        }
    }

    private func handleRect(_ c: Corner, of fr: NSRect, zoom z: CGFloat) -> NSRect {
        let s = 10 / z
        let p: NSPoint
        switch c {
        case .tl: p = NSPoint(x: fr.minX - 3, y: fr.minY - 3)
        case .tr: p = NSPoint(x: fr.maxX + 3, y: fr.minY - 3)
        case .bl: p = NSPoint(x: fr.minX - 3, y: fr.maxY + 3)
        case .br: p = NSPoint(x: fr.maxX + 3, y: fr.maxY + 3)
        }
        return NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
    }

    // MARK: Page images (rendered lazily, a few kept)

    private func ensureImage(_ i: Int) {
        guard images[i] == nil, !inflight.contains(i), !failed.contains(i), let render = renderPage else { return }
        inflight.insert(i)
        renderQueue.async { [weak self] in
            let img = render(i)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(i)
                if let img {
                    self.images[i] = img
                    self.trimCache(keeping: i)
                } else {
                    self.failed.insert(i)
                }
                if i < self.pageFrames.count { self.setNeedsDisplay(self.pageFrames[i].insetBy(dx: -30, dy: -30)) }
            }
        }
    }

    private func trimCache(keeping i: Int) {
        while images.count > 8 {
            guard let far = images.keys.max(by: { abs($0 - i) < abs($1 - i) }), far != i else { break }
            images.removeValue(forKey: far)
        }
    }

    // MARK: Replay animation (the signature writes itself onto the line)

    func replay(_ ids: [UUID]) {
        let now = CACurrentMediaTime()
        for (n, id) in ids.enumerated() { animStart[id] = now + Double(n) * 0.14 }
        if animTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tickAnim() }
            RunLoop.main.add(t, forMode: .common)
            animTimer = t
        }
    }

    private func progress(for id: UUID) -> Double {
        guard let start = animStart[id] else { return 1 }
        let p = min(max((CACurrentMediaTime() - start) / animDuration, 0), 1)
        return 1 - pow(1 - p, 2)
    }

    private func tickAnim() {
        let now = CACurrentMediaTime()
        animStart = animStart.filter { now - $0.value < animDuration }
        needsDisplay = true
        if animStart.isEmpty {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
    }

    // MARK: Editing

    func pushUndo() {
        undoStack.append(stamps)
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    @objc func undo(_ sender: Any?) {
        guard let last = undoStack.popLast() else { NSSound.beep(); return }
        stamps = last
        if selectedID != nil && selectedIndex == nil { selectedID = nil }
        onStampsChanged?()
    }

    func addStamp(_ s: Stamp) {
        pushUndo()
        stamps.append(s)
        selectedID = s.id
        replay([s.id])
        onStampsChanged?()
    }

    func deleteSelected() {
        guard let i = selectedIndex else { NSSound.beep(); return }
        pushUndo()
        stamps.remove(at: i)
        selectedID = nil
        onStampsChanged?()
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let i = selectedIndex else { return }
        pushUndo()
        var r = stamps[i].rect
        r.origin.x += dx
        r.origin.y += dy
        stamps[i].rect = clamp(r, in: pageSizes[stamps[i].page])
        stamps[i].ghost = false
        onStampsChanged?()
    }

    private func clamp(_ r: CGRect, in size: CGSize) -> CGRect {
        var out = r
        out.origin.x = min(max(out.origin.x, 0), max(size.width - out.width, 0))
        out.origin.y = min(max(out.origin.y, 0), max(size.height - out.height, 0))
        return out
    }

    private func compatible(_ k: StampKind, _ s: SpotKind) -> Bool {
        switch k {
        case .signature, .initials: return s == .signature || s == .initials
        case .date, .text: return s == .date
        }
    }

    /// Bottom edge jumps onto a detected line when it's close, with a haptic tick.
    private func snap(_ r: CGRect, page: Int, kind: StampKind) -> CGRect {
        var out = r
        var hit: Int?
        for (i, s) in snapSpots.enumerated() where s.page == page && compatible(kind, s.kind) {
            let target = (kind == .date || kind == .text) ? s.baseline - 3 - r.height : s.baseline + 2 - r.height
            if abs(r.minY - target) < 9 && r.midX > s.x - 24 && r.midX < s.x + s.width + 24 {
                out.origin.y = target
                hit = i
                break
            }
        }
        if hit != nil && hit != snappedTo {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snappedTo = hit
        return out
    }

    // MARK: Zoom

    func setZoom(_ z: CGFloat) {
        guard let sv = enclosingScrollView else { return }
        let c = NSPoint(x: sv.contentView.bounds.midX, y: sv.contentView.bounds.midY)
        sv.setMagnification(min(max(z, sv.minMagnification), sv.maxMagnification), centeredAt: c)
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(zoom * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoom / 1.25) }
    @objc func zoomFit(_ sender: Any?) {
        guard let sv = enclosingScrollView, frame.width > 0 else { return }
        setZoom((sv.contentSize.width - 8) / frame.width)
    }

    // MARK: Mouse

    private func pageIndex(at p: NSPoint) -> Int? { pageFrames.firstIndex { $0.contains(p) } }

    private func hitStamp(_ p: NSPoint) -> Int? {
        stamps.indices.reversed().first { stampFrame(stamps[$0]).insetBy(dx: -4, dy: -4).contains(p) }
    }

    private func corner(at p: NSPoint, of index: Int, zoom z: CGFloat) -> Corner? {
        let fr = stampFrame(stamps[index])
        for c in [Corner.tl, .tr, .bl, .br] where handleRect(c, of: fr, zoom: z).insetBy(dx: -4 / z, dy: -4 / z).contains(p) {
            return c
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let sel = selectedIndex, corner(at: p, of: sel, zoom: zoom) != nil {
            NSCursor.crosshair.set()
        } else if hitStamp(p) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        pendingPlace = nil
        snappedTo = nil

        if let sel = selectedIndex, let c = corner(at: p, of: sel, zoom: zoom) {
            let r = stamps[sel].rect
            let anchor: CGPoint
            switch c {
            case .tl: anchor = CGPoint(x: r.maxX, y: r.maxY)
            case .tr: anchor = CGPoint(x: r.minX, y: r.maxY)
            case .bl: anchor = CGPoint(x: r.maxX, y: r.minY)
            case .br: anchor = CGPoint(x: r.minX, y: r.minY)
            }
            drag = Drag(index: sel, mode: .resize(c, anchor: anchor), before: stamps)
            return
        }
        if let i = hitStamp(p) {
            selectedID = stamps[i].id
            let fr = stampFrame(stamps[i])
            drag = Drag(index: i, mode: .move(grab: CGSize(width: p.x - fr.minX, height: p.y - fr.minY)), before: stamps)
            return
        }
        drag = nil
        pendingPlace = p       // a plain click on empty paper puts the selected stamp there
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, d.index < stamps.count else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !d.pushed {
            undoStack.append(d.before)
            if undoStack.count > 60 { undoStack.removeFirst() }
            d.pushed = true
            drag = d
        }
        switch d.mode {
        case .move(let grab):
            let page = pageIndex(at: p) ?? stamps[d.index].page
            let f = pageFrames[page]
            var r = stamps[d.index].rect
            r.origin = CGPoint(x: p.x - grab.width - f.minX, y: p.y - grab.height - f.minY)
            r = clamp(r, in: pageSizes[page])
            r = snap(r, page: page, kind: stamps[d.index].kind)
            stamps[d.index].page = page
            stamps[d.index].rect = r
        case .resize(let c, let anchor):
            let page = stamps[d.index].page
            let f = pageFrames[page]
            let local = CGPoint(x: p.x - f.minX, y: p.y - f.minY)
            let aspect = CGFloat(stamps[d.index].aspect)
            let w = max(abs(local.x - anchor.x), 24)
            let h = w / aspect
            let x = (c == .tl || c == .bl) ? anchor.x - w : anchor.x
            let y = (c == .tl || c == .tr) ? anchor.y - h : anchor.y
            stamps[d.index].rect = clamp(CGRect(x: x, y: y, width: w, height: h), in: pageSizes[page])
        }
        stamps[d.index].ghost = false
        onStampsChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            pendingPlace = nil
            snappedTo = nil
        }
        guard drag == nil, let p = pendingPlace else { return }
        guard let sel = selectedIndex, let page = pageIndex(at: p) else {
            selectedID = nil
            return
        }
        pushUndo()
        let f = pageFrames[page]
        var r = stamps[sel].rect
        r.origin = CGPoint(x: p.x - f.minX - r.width / 2, y: p.y - f.minY - r.height / 2)
        stamps[sel].page = page
        stamps[sel].rect = clamp(r, in: pageSizes[page])
        stamps[sel].ghost = false
        onStampsChanged?()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 10 : 1
        switch event.keyCode {
        case 36, 76: onConfirm?()                        // return, enter
        case 53: onCancel?()                             // escape
        case 48: onCycleSpot?(shift ? -1 : 1)            // tab
        case 51, 117: deleteSelected()                   // delete, forward delete
        case 123: nudge(dx: -step, dy: 0)
        case 124: nudge(dx: step, dy: 0)
        case 125: nudge(dx: 0, dy: step)
        case 126: nudge(dx: 0, dy: -step)
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - The window

final class SignController: NSObject, NSWindowDelegate {
    private static var live: [SignController] = []

    /// Opens the sign window for a PDF, a document or an image. `finished` gets the signed file, or nil.
    static func start(url: URL, finished: @escaping (URL?) -> Void) {
        let c = SignController(original: url, finished: finished)
        live.append(c)
        c.begin()
    }

    private let original: URL
    private var finished: ((URL?) -> Void)?

    private var prepared: SignBackend.Prepared?
    private var doc: PDFDocument?
    private var geos: [PageGeometry] = []
    private var preflight = Preflight()
    private var spots: [Spot] = []
    private var sigSpots: [Spot] = []
    private var spotCursor = 0
    private var busy = false
    private var acknowledgedDanger = false

    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var canvas: PageStackView!
    private let chip = NSButton(title: "", target: nil, action: nil)
    private let spotLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let signButton = NSButton(title: "Sign  ⏎", target: nil, action: nil)
    private let addPop = NSPopUpButton(frame: .zero, pullsDown: true)
    private let status = NSTextField(labelWithString: "")

    private init(original: URL, finished: @escaping (URL?) -> Void) {
        self.original = original
        self.finished = finished
        super.init()
    }

    // MARK: Start (off the main thread: conversion, structure check, OCR)

    private func begin() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let prepared = try SignBackend.prepare(original)
                guard let doc = PDFDocument(url: prepared.pdf) else {
                    prepared.cleanup()
                    throw ConvError("Couldn't open this PDF")
                }
                if doc.isLocked {
                    prepared.cleanup()
                    throw ConvError("This PDF is password-protected. Unlock it first, then sign.")
                }
                let geos = (0..<doc.pageCount).compactMap { i in doc.page(at: i).map { PageGeometry(page: $0) } }
                guard !geos.isEmpty, geos.count == doc.pageCount else {
                    prepared.cleanup()
                    throw ConvError("This PDF has no readable pages")
                }
                let pre = PDFInspector.inspect(prepared.pdf, doc: doc)
                let found = SpotFinder.find(in: doc, printedName: SignatureStore.shared.printedName)
                DispatchQueue.main.async { self.present(prepared, doc, geos, pre, found) }
            } catch {
                DispatchQueue.main.async { self.failStart(error) }
            }
        }
    }

    private func failStart(_ error: Error) {
        Sound.shared.play(.error)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Can't sign this one"
        a.informativeText = error.localizedDescription
        a.runModal()
        complete(nil)
    }

    // MARK: Window

    private func present(_ prepared: SignBackend.Prepared, _ doc: PDFDocument, _ geos: [PageGeometry],
                         _ pre: Preflight, _ found: [Spot]) {
        self.prepared = prepared
        self.doc = doc
        self.geos = geos
        self.preflight = pre
        self.spots = found
        self.sigSpots = found.filter { $0.kind == .signature }

        let size = NSRect(x: 0, y: 0, width: 1040, height: 800)
        let w = NSWindow(contentRect: size, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Sign: \(original.lastPathComponent)"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 520)
        w.delegate = self
        window = w

        let content = NSView(frame: size)
        w.contentView = content

        // Bars
        let barH: CGFloat = 46
        let statusH: CGFloat = 28
        let top = NSVisualEffectView(frame: NSRect(x: 0, y: size.height - barH, width: size.width, height: barH))
        top.material = .headerView
        top.blendingMode = .withinWindow
        top.state = .active
        top.autoresizingMask = [.width, .minYMargin]
        content.addSubview(top)

        let bottom = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size.width, height: statusH))
        bottom.material = .headerView
        bottom.blendingMode = .withinWindow
        bottom.state = .active
        bottom.autoresizingMask = [.width]
        content.addSubview(bottom)

        // Pages
        scroll = NSScrollView(frame: NSRect(x: 0, y: statusH, width: size.width, height: size.height - barH - statusH))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2
        scroll.maxMagnification = 5
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.underPageBackgroundColor
        canvas = PageStackView(frame: .zero)
        scroll.documentView = canvas
        content.addSubview(scroll)

        let renderDoc = doc
        let renderGeos = geos
        canvas.renderPage = { i in
            guard let page = renderDoc.page(at: i) else { return nil }
            return PageRaster.displayImage(page, geo: renderGeos[i], scale: 2.5)
        }
        canvas.onConfirm = { [weak self] in self?.confirm() }
        canvas.onCancel = { [weak self] in self?.window.performClose(nil) }
        canvas.onCycleSpot = { [weak self] d in self?.cycleSpot(d) }
        canvas.onStampsChanged = { [weak self] in self?.refreshStatus() }
        canvas.setPages(geos.map { $0.size })
        canvas.snapSpots = found

        // Toolbar
        chip.target = self
        chip.action = #selector(showReport)
        chip.isBordered = false
        chip.alignment = .left
        chip.frame = NSRect(x: 12, y: 9, width: 270, height: 28)
        top.addSubview(chip)
        refreshChip()

        prevButton.target = self
        prevButton.action = #selector(prevSpot)
        prevButton.bezelStyle = .texturedRounded
        prevButton.frame = NSRect(x: 292, y: 9, width: 28, height: 28)
        nextButton.target = self
        nextButton.action = #selector(nextSpot)
        nextButton.bezelStyle = .texturedRounded
        nextButton.frame = NSRect(x: 408, y: 9, width: 28, height: 28)
        spotLabel.frame = NSRect(x: 322, y: 14, width: 84, height: 18)
        spotLabel.alignment = .center
        spotLabel.font = NSFont.systemFont(ofSize: 12)
        spotLabel.textColor = .secondaryLabelColor
        for v in [prevButton, spotLabel, nextButton] { top.addSubview(v) }

        signButton.target = self
        signButton.action = #selector(signPressed)
        signButton.bezelStyle = .rounded
        signButton.keyEquivalent = "\r"
        signButton.frame = NSRect(x: size.width - 124, y: 9, width: 112, height: 28)
        signButton.autoresizingMask = [.minXMargin]
        top.addSubview(signButton)

        addPop.frame = NSRect(x: size.width - 244, y: 9, width: 112, height: 28)
        addPop.autoresizingMask = [.minXMargin]
        buildAddMenu()
        top.addSubview(addPop)

        status.frame = NSRect(x: 12, y: 6, width: size.width - 24, height: 16)
        status.font = NSFont.systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.autoresizingMask = [.width]
        bottom.addSubview(status)

        updateSpotLabel()
        refreshStatus()

        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(canvas)

        DispatchQueue.main.async { [self] in
            if let ink = SignatureStore.shared.ink(.signature) {
                placeFirst(with: ink)
            } else {
                SignaturePad.present(slot: .signature, from: window) { [self] ink in
                    guard let ink else { complete(nil); return }
                    placeFirst(with: ink)
                    window.makeFirstResponder(canvas)
                }
            }
        }
    }

    private func placeFirst(with ink: Ink) {
        guard let doc else { return }
        let stamps = SignPlan.initialStamps(doc: doc, spots: spots, signature: ink,
                                            initials: SignatureStore.shared.ink(.initials),
                                            withDate: Settings.signAutoDate)
        canvas.stamps = stamps
        canvas.selectedID = stamps.first?.id
        window.layoutIfNeeded()
        let fit = (scroll.contentSize.width - 8) / max(canvas.frame.width, 1)
        if let first = sigSpots.first {
            focus(on: first, zoom: min(max(fit * 1.55, 0.3), 3))
        } else {
            scroll.magnification = max(fit, 0.3)
        }
        canvas.replay(stamps.map { $0.id })
        refreshStatus()
    }

    private func focus(on spot: Spot, zoom: CGFloat? = nil) {
        guard spot.page < canvas.pageFrames.count else { return }
        let f = canvas.pageFrames[spot.page]
        let pt = NSPoint(x: f.minX + spot.x + min(spot.width, 240) / 2, y: f.minY + spot.baseline - 20)
        scroll.setMagnification(zoom ?? scroll.magnification, centeredAt: pt)
    }

    // MARK: Toolbar bits

    private func buildAddMenu() {
        addPop.removeAllItems()
        addPop.addItem(withTitle: "Add")
        func item(_ title: String, _ tag: Int) {
            let it = NSMenuItem(title: title, action: #selector(addMenuChosen(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
            addPop.menu?.addItem(it)
        }
        item("Signature", 1)
        item("Initials", 2)
        item("Date", 3)
        item("Text…", 4)
        addPop.menu?.addItem(.separator())
        item("Initials on every page", 5)
        addPop.menu?.addItem(.separator())
        item("Redraw signature…", 6)
        item("Redraw initials…", 7)
    }

    private func refreshChip() {
        let color: NSColor
        switch preflight.level {
        case .none, .some(.info): color = .systemGreen
        case .some(.caution): color = .systemOrange
        case .some(.danger): color = .systemRed
        }
        let s = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 13)])
        s.append(NSAttributedString(string: preflight.chipText, attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12, weight: .medium)]))
        chip.attributedTitle = s
        chip.toolTip = "Click for details. A heuristic check of the file, not a guarantee."
    }

    private func updateSpotLabel() {
        let show = sigSpots.count > 1
        prevButton.isHidden = !show
        nextButton.isHidden = !show
        spotLabel.isHidden = !show
        spotLabel.stringValue = "Spot \(spotCursor + 1) of \(sigSpots.count)"
    }

    private func refreshStatus() {
        var text = "⏎ sign   ·   ⇥ next spot   ·   drag to move, corners to resize   ·   ⌫ delete   ·   ⌘Z undo"
        var color = NSColor.secondaryLabelColor
        if let note = prepared?.note {
            text = note
            color = .systemOrange
        } else if sigSpots.indices.contains(spotCursor), sigSpots[spotCursor].crowd > 0.04,
                  let sig = canvas.stamps.first(where: { $0.kind == .signature }), sig.ghost {
            text = "Heads up: something is already printed where the signature sits. Drag it if that's wrong."
            color = .systemOrange
        } else if Tools.qpdf == nil {
            text += "   ·   basic engine (brew install qpdf keeps links and forms)"
        }
        status.stringValue = text
        status.textColor = color
    }

    // MARK: Actions

    @objc private func showReport() {
        let a = NSAlert()
        a.alertStyle = preflight.level == .danger ? .critical : .informational
        a.messageText = preflight.chipText
        a.informativeText = preflight.report
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func prevSpot() { cycleSpot(-1) }
    @objc private func nextSpot() { cycleSpot(1) }
    @objc private func signPressed() { confirm() }

    private func cycleSpot(_ delta: Int) {
        guard sigSpots.count > 1,
              let idx = canvas.stamps.firstIndex(where: { $0.kind == .signature }) else { NSSound.beep(); return }
        spotCursor = (spotCursor + delta + sigSpots.count) % sigSpots.count
        let spot = sigSpots[spotCursor]
        canvas.pushUndo()
        var st = canvas.stamps[idx]
        st.page = spot.page
        st.rect = StampSizing.rect(for: spot, kind: .signature, aspect: st.aspect, pageSize: geos[spot.page].size)
        st.ghost = true
        canvas.stamps[idx] = st
        canvas.selectedID = st.id
        focus(on: spot)
        canvas.replay([st.id])
        updateSpotLabel()
        refreshStatus()
    }

    @objc private func addMenuChosen(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: add(.signature)
        case 2: add(.initials)
        case 3: add(.date)
        case 4: add(.text)
        case 5: initialsEverywhere()
        case 6: redraw(.signature)
        case 7: redraw(.initials)
        default: break
        }
    }

    private func ensureInk(_ slot: SignSlot, _ done: @escaping (Ink) -> Void) {
        if let ink = SignatureStore.shared.ink(slot) {
            done(ink)
        } else {
            SignaturePad.present(slot: slot, from: window) { [weak self] ink in
                if let ink { done(ink) }
                self?.window.makeFirstResponder(self?.canvas)
            }
        }
    }

    private func centered(_ size: CGSize, at local: CGPoint, page: Int) -> CGRect {
        let ps = geos[page].size
        let x = min(max(local.x - size.width / 2, 0), max(ps.width - size.width, 0))
        let y = min(max(local.y - size.height / 2, 0), max(ps.height - size.height, 0))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func add(_ kind: StampKind) {
        let here = canvas.visibleCenter()
        switch kind {
        case .signature, .initials:
            ensureInk(kind == .signature ? .signature : .initials) { [weak self] ink in
                guard let self else { return }
                let size = StampSizing.size(kind: kind, aspect: ink.aspect)
                self.canvas.addStamp(Stamp.make(kind: kind, ink: ink, page: here.page,
                                                rect: self.centered(size, at: here.local, page: here.page)))
            }
        case .date:
            let text = SignPlan.dateString()
            let aspect = TextInk.aspect(of: text, fontName: "Helvetica")
            let size = StampSizing.size(kind: .date, aspect: aspect)
            canvas.addStamp(Stamp.makeText(text, page: here.page, rect: centered(size, at: here.local, page: here.page)))
        case .text:
            guard let text = promptText(), !text.isEmpty else { return }
            let aspect = TextInk.aspect(of: text, fontName: "Helvetica")
            let size = StampSizing.size(kind: .text, aspect: aspect)
            canvas.addStamp(Stamp.makeText(text, page: here.page, rect: centered(size, at: here.local, page: here.page)))
        }
    }

    private func promptText() -> String? {
        let a = NSAlert()
        a.messageText = "Add a line of text"
        a.informativeText = "A name, a place, a reference number. It's drawn onto the page like the signature."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func initialsEverywhere() {
        ensureInk(.initials) { [weak self] ink in
            guard let self else { return }
            self.canvas.pushUndo()
            var made: [Stamp] = []
            for (i, g) in self.geos.enumerated().prefix(300) {
                let size = StampSizing.size(kind: .initials, aspect: ink.aspect)
                let rect = CGRect(x: g.size.width - 56 - size.width, y: g.size.height - 40 - size.height,
                                  width: size.width, height: size.height)
                made.append(Stamp.make(kind: .initials, ink: ink, page: i, rect: rect))
            }
            self.canvas.stamps.append(contentsOf: made)
            self.canvas.replay(made.map { $0.id })
            self.refreshStatus()
        }
    }

    private func redraw(_ slot: SignSlot) {
        SignaturePad.present(slot: slot, from: window, forceSave: true) { [weak self] ink in
            guard let self, let ink else { return }
            self.canvas.pushUndo()
            let kind: StampKind = slot == .signature ? .signature : .initials
            var changed: [UUID] = []
            for i in self.canvas.stamps.indices where self.canvas.stamps[i].kind == kind {
                let old = self.canvas.stamps[i].rect
                let size = StampSizing.size(kind: kind, aspect: ink.aspect)
                self.canvas.stamps[i].content = .ink(ink)
                self.canvas.stamps[i].aspect = ink.aspect
                self.canvas.stamps[i].rect = CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
                changed.append(self.canvas.stamps[i].id)
            }
            self.canvas.replay(changed)
            self.window.makeFirstResponder(self.canvas)
        }
    }

    // MARK: Signing

    private func confirm() {
        guard !busy, let prepared else { return }
        let stamps = canvas.stamps
        guard !stamps.isEmpty else { NSSound.beep(); return }

        if preflight.level == .danger && !acknowledgedDanger {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "This PDF is already digitally signed"
            a.informativeText = "Your copy will carry your visual signature, but the existing digital signature won't verify on it any more. "
                + "The original file stays exactly as it is.\n\n" + preflight.report
            a.addButton(withTitle: "Sign a copy anyway")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            acknowledgedDanger = true
        }

        authenticate { [weak self] ok in
            guard let self, ok else { return }
            self.run(stamps, prepared: prepared)
        }
    }

    /// Touch ID, Apple Watch or the Mac password: a saved signature image is a forgery kit,
    /// so using it takes a deliberate "yes, it's me".
    private func authenticate(_ done: @escaping (Bool) -> Void) {
        guard Settings.signAuth else { done(true); return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { done(true); return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "sign “\(original.lastPathComponent)” with your saved signature") { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    private func run(_ stamps: [Stamp], prepared: SignBackend.Prepared) {
        busy = true
        signButton.isEnabled = false
        status.stringValue = "Signing…"
        status.textColor = .secondaryLabelColor
        Sound.shared.play(.commit)
        let out = SignBackend.outputURL(for: original)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let outcome = try SignBackend.apply(stamps, to: prepared.pdf, output: out)
                DispatchQueue.main.async { self.finish(outcome) }
            } catch {
                DispatchQueue.main.async { self.fail(error) }
            }
        }
    }

    private func finish(_ outcome: SignBackend.Outcome) {
        if !outcome.problems.isEmpty {
            Sound.shared.play(.error)
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "The self-check found a problem"
            a.informativeText = outcome.problems.joined(separator: "\n")
                + "\n\nThe signed copy is saved next to your original. Look at it before you send it."
            a.addButton(withTitle: "Keep it")
            a.addButton(withTitle: "Delete it")
            if a.runModal() == .alertSecondButtonReturn {
                try? FileManager.default.removeItem(at: outcome.output)
                busy = false
                signButton.isEnabled = true
                refreshStatus()
                return
            }
        } else {
            Sound.shared.play(.done)
        }
        NSWorkspace.shared.activateFileViewerSelecting([outcome.output])
        complete(outcome.output)
    }

    private func fail(_ error: Error) {
        Sound.shared.play(.error)
        busy = false
        signButton.isEnabled = true
        refreshStatus()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Signing failed"
        a.informativeText = error.localizedDescription
        a.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: Closing

    private func complete(_ url: URL?) {
        let f = finished
        finished = nil
        f?(url)
        if let w = window { w.close() } else { cleanup() }
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    private func cleanup() {
        canvas?.stopAnimating()
        prepared?.cleanup()
        prepared = nil
        let f = finished
        finished = nil
        f?(nil)
        SignController.live.removeAll { $0 === self }
    }
}
