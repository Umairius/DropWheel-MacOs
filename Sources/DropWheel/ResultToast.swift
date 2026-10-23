import AppKit

// MARK: - Helpers shared by the toast, the app and the tutorial

/// Selecting the new file in Finder, the way you'd expect after a conversion.
enum Reveal {
    /// Only when Finder is what you're looking at (you dragged from Finder or the Desktop), so a drag
    /// out of some other app never yanks you over to a Finder window.
    static func shouldAutoSelect(_ outputs: [URL]) -> Bool {
        guard Settings.selectResult, !outputs.isEmpty else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    /// Selects the outputs (and only them), so the source stops being the highlighted item.
    static func select(_ urls: [URL], after delay: TimeInterval = 0.25) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

/// Undo for one conversion. It can only ever do two things, and never deletes:
///   - move the files THIS conversion just made to the Trash (the Trash is recoverable), and only if they
///     haven't been touched since (edited, renamed or moved files are left exactly where they are);
///   - put an original back from the Trash, if "Replace" had sent it there and its old spot is still free.
enum Undo {
    struct Snapshot {
        let time: Date
        let counts: [String: Int]      // output path -> how many items it holds (1 for a file)
    }

    static func snapshot(_ outputs: [URL]) -> Snapshot {
        var counts: [String: Int] = [:]
        for o in outputs { counts[o.path] = measure(o).count }
        return Snapshot(time: Date(), counts: counts)
    }

    /// Returns how many new files went to the Trash and how many were kept because they changed.
    static func perform(_ result: ConversionResult, snapshot: Snapshot) -> (trashed: Int, kept: Int) {
        let fm = FileManager.default
        var trashed = 0
        var kept = 0
        for out in result.outputs {
            guard fm.fileExists(atPath: out.path) else { continue }
            let now = measure(out)
            let unchanged = now.latest <= snapshot.time && now.count == snapshot.counts[out.path]
            if unchanged, (try? fm.trashItem(at: out, resultingItemURL: nil)) != nil {
                trashed += 1
            } else {
                kept += 1
            }
        }
        // Originals come back only if nothing has taken their place.
        for (original, inTrash) in result.trashed where fm.fileExists(atPath: inTrash.path) && !fm.fileExists(atPath: original.path) {
            try? fm.moveItem(at: inTrash, to: original)
        }
        return (trashed, kept)
    }

    /// Item count and the newest modification date inside (a folder is only "unchanged" if nothing in it changed).
    private static func measure(_ url: URL) -> (count: Int, latest: Date) {
        let fm = FileManager.default
        func modified(_ u: URL) -> Date {
            ((try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date) ?? .distantPast
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return (1, modified(url)) }
        var count = 1
        var latest = modified(url)
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let u as URL in e {
                count += 1
                latest = max(latest, modified(u))
            }
        }
        return (count, latest)
    }
}

/// A square that shows an image and can be dragged out as real files. Used for the sample file in the
/// tutorial and for the result icon in the toast ("drag it straight into an email").
final class DragFileView: NSView, NSDraggingSource {
    var fileURLs: [URL] = []
    var image: NSImage? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState()
        if cornerRadius > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !fileURLs.isEmpty else { return }
        let items = fileURLs.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            return item
        }
        onDragBegan?()
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - The toast

/// Tells the toast when the pointer is on it, so it can wait instead of fading while you reach for a button.
private final class HoverEffectView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A small floating card. It never takes focus, so it can't interrupt typing.
///   working  ->  the icon of what's being made, a spinner
///   success  ->  the new file (drag it anywhere), then Undo / Show in Finder
///   error    ->  what went wrong, with a little shake, then Dismiss / Details
///   notice   ->  not a failure, just "nothing to do" (already smallest, can't split one page...)
///
/// Placement: never on the cursor, never on the file you dragged or on the spot next to it where the new
/// file appears. It holds for a few seconds, then fades away slowly. Pointing at it keeps it there.
final class ResultToast {
    static let shared = ResultToast()

    private var panel: NSPanel?
    private var effect: HoverEffectView?
    private var content: NSView?
    /// Where the source file is (the drag started here). The new file lands right next to it.
    private var origin = NSPoint.zero

    private var lifeToken = 0
    private var hovering = false
    private var autoFades = false
    private var currentFade: TimeInterval = 2

    private let cardWidth: CGFloat = 376
    private let white = NSColor.white
    private let dim = NSColor.white.withAlphaComponent(0.62)

    // MARK: Public

    func showWorking(target: Target, count: Int, at point: NSPoint) {
        origin = point
        let what = count > 1 ? "\(count) files" : target.label
        let title = label("Making \(what)…", font: Brand.font(16, weight: 700), color: white)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let row = NSStackView(views: [imageView(IconKit.image(target.id, size: 44), side: 44), title, spinner])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 20)
        present(row, hold: nil, fade: 0)             // stays until the result replaces it
    }

    func showResult(outputs: [URL], sources: [URL], replaced: Bool, note: String? = nil, undo: (() -> Void)?) {
        guard let first = outputs.first else { return }
        let side: CGFloat = 56
        let drag = DragFileView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        drag.fileURLs = outputs
        drag.image = IconKit.image(forFile: first, size: side)
        drag.toolTip = "Drag this anywhere: an email, a chat, a folder"
        drag.translatesAutoresizingMaskIntoConstraints = false
        drag.widthAnchor.constraint(equalToConstant: side).isActive = true
        drag.heightAnchor.constraint(equalToConstant: side).isActive = true

        let name = outputs.count == 1 ? first.lastPathComponent : "\(outputs.count) new files"
        var detail = sizeText(outputs) + (replaced ? "  ·  original is in the Trash" : "  ·  saved next to the original")
        if let note { detail += "\n" + note }

        var buttons: [NSView] = []
        if let undo {
            buttons.append(pill("Undo", .secondary) { [weak self] in
                self?.dismiss()
                undo()
            })
        }
        buttons.append(pill("Show in Finder", .primary) { [weak self] in
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            self?.dismiss()
        })
        present(card(icon: drag, title: name, detail: detail, buttons: buttons, detailLines: note == nil ? 1 : 2),
                hold: 3.5, fade: 2.2)
    }

    func showError(title: String, detail: String, onDetails: (() -> Void)?) {
        var buttons: [NSView] = [pill("Dismiss", .secondary) { [weak self] in self?.dismiss() }]
        if let onDetails {
            buttons.append(pill("Details", .primary) { [weak self] in
                self?.dismiss()
                onDetails()
            })
        }
        let tile = symbolTile("exclamationmark.triangle.fill", tint: .systemOrange)
        present(card(icon: tile, title: title, detail: detail, buttons: buttons, detailLines: 2), hold: 7, fade: 2.5)
        shake()
    }

    /// Not a failure: nothing went wrong, there was just nothing to do.
    func showNotice(title: String, detail: String, at point: NSPoint? = nil) {
        if let point { origin = point }
        let tile = symbolTile("info.circle.fill", tint: .systemBlue)
        let buttons: [NSView] = [pill("OK", .secondary) { [weak self] in self?.dismiss() }]
        present(card(icon: tile, title: title, detail: detail, buttons: buttons, detailLines: 2), hold: 3, fade: 1.6)
    }

    func showMessage(_ text: String, at point: NSPoint? = nil) {
        if let point { origin = point }
        let l = label(text, font: Brand.font(15, weight: 700), color: white)
        let row = NSStackView(views: [l])
        row.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        present(row, hold: 1.4, fade: 0.9)
    }

    /// Quick fade, for when a button was pressed.
    func dismiss() {
        lifeToken += 1
        autoFades = false
        guard let p = panel, p.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            p.orderOut(nil)
            return
        }
        let token = lifeToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.lifeToken == token else { return }
            p.orderOut(nil)
            p.alphaValue = 1
        })
    }

    // MARK: Life cycle: hold, then fade slowly

    private func scheduleFade(hold: TimeInterval, fade: TimeInterval) {
        lifeToken += 1
        let token = lifeToken
        autoFades = true
        currentFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            self?.beginFade(token, fade: fade)
        }
    }

    private func beginFade(_ token: Int, fade: TimeInterval) {
        guard token == lifeToken, let p = panel, p.isVisible else { return }
        if hovering {                               // you're pointing at it: wait
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.beginFade(token, fade: fade) }
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            p.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.lifeToken == token else { return }   // cancelled by a hover
            p.orderOut(nil)
            p.alphaValue = 1
        })
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        guard let p = panel, p.isVisible else { return }
        if inside {
            lifeToken += 1                          // cancels a fade that's already running
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 1
            })
        } else if autoFades {
            scheduleFade(hold: 1.8, fade: currentFade)
        }
    }

    // MARK: Layout

    /// icon + title/detail on top, a row of buttons underneath, aligned right with real breathing room.
    private func card(icon: NSView, title: String, detail: String, buttons: [NSView], detailLines: Int = 1) -> NSView {
        let t = label(title, font: Brand.font(17, weight: 700), color: white)
        t.lineBreakMode = .byTruncatingMiddle
        t.maximumNumberOfLines = 1
        let d = label(detail, font: NSFont.systemFont(ofSize: 12), color: dim)
        d.maximumNumberOfLines = detailLines
        d.lineBreakMode = .byTruncatingTail
        d.usesSingleLineMode = false
        d.cell?.wraps = detailLines > 1
        d.preferredMaxLayoutWidth = cardWidth - 36 - 56 - 14

        let text = NSStackView(views: [t, d])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [icon, text])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 14

        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .width
        v.spacing = 16
        v.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        v.addArrangedSubview(top)

        if !buttons.isEmpty {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [spacer] + buttons)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            v.addArrangedSubview(row)
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        return v
    }

    /// `hold` nil = stays until replaced (the working state).
    private func present(_ view: NSView, hold: TimeInterval?, fade: TimeInterval) {
        lifeToken += 1
        autoFades = false
        let p = panel ?? makePanel()
        p.alphaValue = 1

        content?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        if let fx = effect {
            fx.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                view.topAnchor.constraint(equalTo: fx.topAnchor),
                view.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
        }
        content = view
        view.layoutSubtreeIfNeeded()

        let size = view.fittingSize
        place(p, size: NSSize(width: max(size.width, 160), height: max(size.height, 52)))
        hovering = false
        p.orderFrontRegardless()

        if let hold { scheduleFade(hold: hold, fade: fade) }
    }

    /// Never on the cursor, never on the source file or the spot beside it where the new file appears.
    /// Candidates are tried nearest-first: above the file, left of it, right of it, below it. If none is
    /// clear, it goes to a screen corner, like a system notification.
    private func place(_ p: NSPanel, size: NSSize) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(origin, $0.frame, false) }) ?? NSScreen.main
        guard let full = screen?.visibleFrame else { return }
        let vis = full.insetBy(dx: 12, dy: 12)

        // The file, plus the neighbouring cells where Finder puts what we just wrote.
        let keepFile = NSRect(x: origin.x - 170, y: origin.y - 120, width: 340, height: 240)
        let keepCursor = NSRect(x: cursor.x - 70, y: cursor.y - 70, width: 140, height: 140)
        let gap: CGFloat = 16

        func rect(_ x: CGFloat, _ y: CGFloat) -> NSRect { NSRect(x: x, y: y, width: size.width, height: size.height) }
        let candidates: [NSRect] = [
            rect(origin.x - size.width / 2, keepFile.maxY + gap),                  // above
            rect(keepFile.minX - gap - size.width, origin.y - size.height / 2),    // left
            rect(keepFile.maxX + gap, origin.y - size.height / 2),                 // right
            rect(origin.x - size.width / 2, keepFile.minY - gap - size.height),    // below
            rect(vis.maxX - size.width, vis.minY),                                 // corner: bottom right
            rect(vis.minX, vis.minY),                                              // corner: bottom left
            rect(vis.maxX - size.width, vis.maxY - size.height),                   // corner: top right
        ]
        for var r in candidates {
            // Slide along the screen edge rather than giving up on a candidate that only overhangs a little.
            r.origin.x = min(max(r.origin.x, vis.minX), vis.maxX - r.width)
            r.origin.y = min(max(r.origin.y, vis.minY), vis.maxY - r.height)
            if !r.intersects(keepFile), !r.intersects(keepCursor) {
                p.setFrame(r, display: true)
                return
            }
        }
        // Everything is blocked (a tiny screen): the bottom-right corner is the least bad.
        p.setFrame(rect(vis.maxX - size.width, vis.minY), display: true)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let fx = HoverEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 24
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        p.contentView = fx

        panel = p
        effect = fx
        return p
    }

    private func shake() {
        guard let p = panel, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let home = p.frame.origin
        let offsets: [CGFloat] = [-9, 9, -7, 7, -4, 4, 0]
        for (i, dx) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i + 1)) {
                p.setFrameOrigin(NSPoint(x: home.x + dx, y: home.y))
            }
        }
    }

    // MARK: Small view factories

    private func label(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.lineBreakMode = .byTruncatingTail
        return t
    }

    private func imageView(_ image: NSImage, side: CGFloat) -> NSView {
        let v = NSImageView()
        v.image = image
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: side).isActive = true
        v.heightAnchor.constraint(equalToConstant: side).isActive = true
        return v
    }

    /// A tinted rounded square with an SF Symbol in it (error and notice states).
    private func symbolTile(_ symbol: String, tint: NSColor) -> NSView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        v.contentTintColor = tint
        v.imageAlignment = .alignCenter
        v.wantsLayer = true
        v.layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
        v.layer?.cornerRadius = 16
        v.layer?.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 56).isActive = true
        v.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return v
    }

    private func pill(_ title: String, _ style: PillButton.Style, action: @escaping () -> Void) -> NSButton {
        PillButton(title, style: style, action: action)
    }

    private func sizeText(_ urls: [URL]) -> String {
        var total: Int64 = 0
        var folders = 0
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                folders += 1
                continue
            }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(v?.fileSize ?? 0)
        }
        if folders > 0 && total == 0 { return folders == 1 ? "Folder" : "\(folders) folders" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

/// A rounded pill button that runs a closure. Two looks: filled white (the main action) and quiet (the rest).
private final class PillButton: NSButton {
    enum Style { case primary, secondary }

    private let handler: () -> Void

    init(_ title: String, style: Style, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        let primary = style == .primary
        layer?.backgroundColor = (primary ? NSColor.white.withAlphaComponent(0.94)
                                          : NSColor.white.withAlphaComponent(0.14)).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Brand.font(13, weight: 700),
            .foregroundColor: primary ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1) : NSColor.white,
        ])
        self.target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: max(s.width + 32, 76), height: 32)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.opacity = flag ? 0.65 : 1
    }

    @objc private func fire() { handler() }
}
