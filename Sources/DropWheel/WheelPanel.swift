import AppKit

/// Floating, non-activating panel that shows the wheel under the cursor and acts as the drop target.
final class WheelController {
    /// Called with the chosen output extension and the dropped files.
    var onChoose: ((Target, [URL]) -> Void)?

    private let size: CGFloat = 380
    private var panel: NSPanel?
    private var wheel: WheelView?
    private var generation = 0

    func show(at point: NSPoint, title: String, subtitle: String, targets: [Target]) {
        generation += 1
        let p = panel ?? makePanel()
        wheel?.configure(targets: targets, title: title, subtitle: subtitle)

        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let vis = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size)
        }
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        Sound.shared.play(.appear)
    }

    func hide(after delay: TimeInterval = 0) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == g else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let v = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.onChoose = { [weak self] target, urls in
            self?.onChoose?(target, urls)
            self?.hide()
        }
        p.contentView = v
        panel = p
        wheel = v
        return p
    }
}

final class WheelView: NSView {
    var onChoose: ((Target, [URL]) -> Void)?

    private var targets: [Target] = []
    private var title = ""
    private var subtitle = ""
    private var hover: Int?

    private let innerR: CGFloat = 56
    private let outerR: CGFloat = 165

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(targets: [Target], title: String, subtitle: String) {
        self.targets = targets
        self.title = title
        self.subtitle = subtitle
        hover = nil
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let n = max(targets.count, 1)
        let step = 360.0 / Double(n)
        let gap = 3.0

        for (i, t) in targets.enumerated() {
            let mid = Double(i) * step                 // degrees clockwise from 12 o'clock
            let s = mid - step / 2 + gap / 2
            let e = mid + step / 2 - gap / 2

            let path = NSBezierPath()
            path.appendArc(withCenter: c, radius: outerR,
                           startAngle: CGFloat(90 - s), endAngle: CGFloat(90 - e), clockwise: true)
            path.appendArc(withCenter: c, radius: innerR,
                           startAngle: CGFloat(90 - e), endAngle: CGFloat(90 - s), clockwise: false)
            path.close()

            (hover == i ? NSColor.controlAccentColor : NSColor(calibratedWhite: 0.10, alpha: 0.90)).setFill()
            path.fill()

            let theta = (90 - mid) * .pi / 180
            let r = (innerR + outerR) / 2
            let p = NSPoint(x: c.x + r * CGFloat(cos(theta)), y: c.y + r * CGFloat(sin(theta)))
            let len = t.label.count
            let fontSize: CGFloat = len <= 4 ? 15 : (len <= 6 ? 12.5 : 10.5)
            drawCentered(t.label, at: p, size: fontSize, weight: .semibold, alpha: 1)
        }

        // Center disc: shows what will happen.
        let d = innerR - 5
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2))
        NSColor(calibratedWhite: 0.10, alpha: 0.90).setFill()
        disc.fill()

        if let h = hover {
            drawCentered("→ " + targets[h].label, at: NSPoint(x: c.x, y: c.y + 7), size: targets[h].label.count > 6 ? 11 : 14, weight: .bold, alpha: 1)
        } else {
            drawCentered(String(title.prefix(14)), at: NSPoint(x: c.x, y: c.y + 7), size: 11, weight: .medium, alpha: 1)
        }
        drawCentered(subtitle, at: NSPoint(x: c.x, y: c.y - 9), size: 9, weight: .regular, alpha: 0.65)
    }

    private func drawCentered(_ text: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ])
        let sz = str.size()
        str.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }

    // MARK: Hit testing (anywhere past the dead zone selects: flick toward a segment)

    private func segment(at p: NSPoint) -> Int? {
        guard !targets.isEmpty else { return nil }
        let dx = Double(p.x - bounds.midX)
        let dy = Double(p.y - bounds.midY)
        let r = hypot(dx, dy)
        guard r >= Double(innerR), r <= Double(bounds.width / 2) else { return nil }
        var deg = atan2(dx, dy) * 180 / .pi          // clockwise from 12 o'clock
        if deg < 0 { deg += 360 }
        let step = 360.0 / Double(targets.count)
        let idx = Int(((deg + step / 2).truncatingRemainder(dividingBy: 360)) / step)
        return min(idx, targets.count - 1)
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hover = nil
        needsDisplay = true
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let h = segment(at: p)
        if h != hover {
            hover = h
            if let h { Sound.shared.hover(targets[h].id) }   // only on change, never per drag tick
            needsDisplay = true
        }
        return h == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hover != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let h = hover else { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        Sound.shared.play(.commit)
        onChoose?(targets[h], urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hover = nil
        needsDisplay = true
    }
}
