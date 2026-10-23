import AppKit

/// Floating, non-activating panel that shows the wheel under the cursor and acts as the drop target.
final class WheelController {
    /// Called with the chosen target and the dropped files.
    var onChoose: ((Target, [URL]) -> Void)?

    /// First-run tutorial: id of the segment to gently pulse ("jpg"). nil = none.
    var hintTargetID: String?

    /// Room around the ring for the hover pill, which sits just outside the rim.
    private let pad: CGFloat = 76
    private var panel: NSPanel?
    private var effect: NSVisualEffectView?
    private var wheel: WheelView?
    private var generation = 0
    private var shownRing: CGFloat = 0

    func show(at point: NSPoint, title: String, subtitle: String, targets: [Target]) {
        generation += 1
        let ring = Settings.wheelSize.diameter
        let side = ring + pad * 2
        let p = panel ?? makePanel(side: side)

        if shownRing != ring {
            p.setContentSize(NSSize(width: side, height: side))
            effect?.maskImage = WheelController.disc(side: side, radius: ring / 2 - 6)
            shownRing = ring
        }
        // Reduce Transparency: no frosted glass, the segments go opaque instead.
        effect?.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        p.alphaValue = 1
        wheel?.configure(targets: targets, title: title, subtitle: subtitle, ring: ring, hint: hintTargetID)

        var origin = NSPoint(x: point.x - side / 2, y: point.y - side / 2)
        if let vis = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })?.visibleFrame {
            // The ring must stay on screen; the padding around it may hang off the edge.
            let slack = pad - 24
            origin.x = min(max(origin.x, vis.minX - slack), vis.maxX - side + slack)
            origin.y = min(max(origin.y, vis.minY - slack), vis.maxY - side + slack)
        }
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        Sound.shared.play(.appear)
    }

    func hide(after delay: TimeInterval = 0) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == g, let p = self.panel else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                p.orderOut(nil)
                self.wheel?.stopAnimations()
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.generation == g else { return }
                p.orderOut(nil)
                p.alphaValue = 1
                self.wheel?.stopAnimations()
            })
        }
    }

    private func makePanel(side: CGFloat) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))

        // Real frosted glass behind the wheel, so Finder icons never bleed through the segments.
        let fx = NSVisualEffectView(frame: root.bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.autoresizingMask = [.width, .height]

        let v = WheelView(frame: root.bounds)
        v.autoresizingMask = [.width, .height]
        v.onChoose = { [weak self] target, urls in
            self?.onChoose?(target, urls)
            self?.hide(after: 0.22)            // let the "committed" flash land first
        }

        root.addSubview(fx)
        root.addSubview(v)
        p.contentView = root
        panel = p
        effect = fx
        wheel = v
        return p
    }

    private static func disc(side: CGFloat, radius: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
    }
}

// MARK: - The wheel itself

final class WheelView: NSView {
    var onChoose: ((Target, [URL]) -> Void)?

    private var targets: [Target] = []
    private var title = ""
    private var subtitle = ""
    private var hintTargetID: String?
    private var hover: Int?
    private var hoverAmt: [CGFloat] = []          // 0...1 per segment, eased toward hover state
    private var committed: Int?
    private var commitStart: CFTimeInterval = 0
    private var bloomStart: CFTimeInterval = 0
    private var ring: CGFloat = 520
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    private var outerR: CGFloat { ring / 2 - 6 }
    private var innerR: CGFloat { outerR * 0.34 }          // same proportions as the original 56 : 165
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(targets: [Target], title: String, subtitle: String, ring: CGFloat, hint: String?) {
        self.targets = targets
        self.title = title
        self.subtitle = subtitle
        self.ring = ring
        self.hintTargetID = hint
        hover = nil
        committed = nil
        hoverAmt = Array(repeating: 0, count: targets.count)
        bloomStart = CACurrentMediaTime()
        needsDisplay = true
        startTimer()
    }

    func stopAnimations() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Animation

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)       // .common: drags run the loop in tracking mode
        timer = t
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        var moving = false

        for i in 0..<hoverAmt.count {
            let goal: CGFloat = (hover == i) ? 1 : 0
            let diff = goal - hoverAmt[i]
            if abs(diff) < 0.004 {
                hoverAmt[i] = goal
            } else {
                hoverAmt[i] += diff * CGFloat(min(1, dt * 16))
                moving = true
            }
        }
        if now - bloomStart < 0.30 + Double(targets.count) * 0.016 { moving = true }
        if committed != nil, now - commitStart < 0.5 { moving = true }
        if hintTargetID != nil, hover == nil { moving = true }      // the tutorial pulse
        needsDisplay = true
        if !moving { stopAnimations() }
    }

    private func bloomProgress(_ i: Int, _ now: CFTimeInterval) -> CGFloat {
        if reduceMotion { return 1 }
        let t = (now - bloomStart - Double(i) * 0.016) / 0.20
        let c = max(0, min(1, t))
        return CGFloat(1 - pow(1 - c, 3))
    }

    private func commitPulse(_ now: CFTimeInterval) -> CGFloat {
        guard committed != nil, !reduceMotion else { return 0 }
        let t = min(1, max(0, (now - commitStart) / 0.28))
        return CGFloat(0.06 * sin(Double.pi * t))
    }

    private func commitFade(_ now: CFTimeInterval) -> CGFloat {
        guard committed != nil else { return 0 }
        if reduceMotion { return 1 }
        return CGFloat(min(1, (now - commitStart) / 0.18))
    }

    // MARK: Geometry helpers (angles in degrees, clockwise from 12 o'clock)

    private func onCircle(_ c: CGPoint, _ r: CGFloat, _ deg: Double) -> CGPoint {
        let a = deg * Double.pi / 180
        return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y + r * CGFloat(cos(a)))
    }

    private func sector(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ d0: Double, _ d1: Double) -> CGPath {
        let p = CGMutablePath()
        p.addArc(center: c, radius: r1, startAngle: CGFloat((90 - d0) * Double.pi / 180),
                 endAngle: CGFloat((90 - d1) * Double.pi / 180), clockwise: true)
        p.addArc(center: c, radius: r0, startAngle: CGFloat((90 - d1) * Double.pi / 180),
                 endAngle: CGFloat((90 - d0) * Double.pi / 180), clockwise: false)
        p.closeSubpath()
        return p
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !targets.isEmpty else { return }
        ctx.interpolationQuality = .high

        let now = CACurrentMediaTime()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let n = targets.count
        let step = 360.0 / Double(n)
        let gap = n == 1 ? 0.0 : 3.0
        let opaqueFills = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let moreContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let ins = max(4, outerR * 0.022)                  // corner rounding: inset + round-joined stroke
        let pop = outerR * 0.07
        let radial = outerR - innerR
        let fade = commitFade(now)
        let hintIndex = hintTargetID.flatMap { id in targets.firstIndex(where: { $0.id == id }) }

        let idle = NSColor(srgbRed: 0.085, green: 0.085, blue: 0.10, alpha: 1)
        let lifted = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1)

        // Segments
        for (i, t) in targets.enumerated() {
            let p = bloomProgress(i, now)
            if p <= 0.001 { continue }
            let h = i < hoverAmt.count ? hoverAmt[i] : 0
            let isCommitted = committed == i
            let accent = IconKit.accent(for: t.id)

            var s = 0.88 + 0.12 * p
            if isCommitted { s += commitPulse(now) }
            let ro = (outerR + pop * h) * s
            let ri = innerR * s
            let midDeg = Double(i) * step
            let midR = (ro + ri) / 2
            let insDeg = Double(ins / midR) * 180 / Double.pi
            var a0 = midDeg - step / 2 + gap / 2 + insDeg
            var a1 = midDeg + step / 2 - gap / 2 - insDeg
            if n == 1 { a0 = -179.5; a1 = 179.5 }
            let path = sector(c, ri + ins, ro - ins, a0, a1)

            let liftedTint = lifted.blended(withFraction: 0.30, of: accent) ?? lifted
            let fill = idle.blended(withFraction: h, of: liftedTint) ?? idle
            var alpha = p * ((opaqueFills || moreContrast) ? 1 : 0.62 + 0.33 * h)
            if committed != nil, !isCommitted { alpha *= 1 - 0.75 * fade }

            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)      // fill + stroke composite as one shape
            ctx.setFillColor(fill.cgColor)
            ctx.setStrokeColor(fill.cgColor)
            ctx.setLineWidth(ins * 2)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
            ctx.endTransparencyLayer()
            ctx.restoreGState()

            // Outline: family colour on hover, white with Increase Contrast, a soft pulse for the tutorial hint.
            var outlineAlpha: CGFloat = h * p
            var outlineColor = accent
            if moreContrast { outlineColor = .white; outlineAlpha = max(outlineAlpha, 0.85 * p) }
            if hintIndex == i, hover != i {
                outlineAlpha = max(outlineAlpha, CGFloat(0.40 + 0.35 * sin(now * 6)) * p)
            }
            if outlineAlpha > 0.02 {
                ctx.saveGState()
                ctx.setLineWidth(2.2)
                ctx.setStrokeColor(outlineColor.withAlphaComponent(outlineAlpha).cgColor)
                ctx.addPath(path)
                ctx.strokePath()
                ctx.restoreGState()
            }

            // Icon (+ label for tools, or for everything when the user asked for labels)
            let info = IconCatalog.info(t.id)
            let showLabel = Settings.alwaysLabels || info.isTool
            let fs = max(13, outerR * 0.058)
            // Sizes come from the resting geometry, never the animated one: a size that changes every
            // frame would re-render the icon bitmap every frame.
            let restMidR = (outerR + innerR) / 2
            let arcLen = 2 * CGFloat.pi * restMidR / CGFloat(n)
            var px = min(radial * 0.58, arcLen * 0.64)
            if showLabel { px = min(px, radial * 0.78 - fs * 1.7) }
            px = max(px, 28)
            let blockH = px + (showLabel ? fs * 1.45 : 0)
            let mid = onCircle(c, midR + pop * h * 0.5, midDeg)
            let iconSide = px * (1 + 0.10 * h) * (0.82 + 0.18 * p)
            let iconCenterY = mid.y + blockH / 2 - px / 2
            let iconRect = CGRect(x: mid.x - iconSide / 2, y: iconCenterY - iconSide / 2, width: iconSide, height: iconSide)
            var iconAlpha = p
            if committed != nil, !isCommitted { iconAlpha *= 1 - 0.75 * fade }
            IconKit.image(t.id, size: px).draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: iconAlpha)

            if showLabel {
                let font = Brand.fitted(t.label, size: fs, weight: 700,
                                        maxWidth: min(arcLen * 0.92, outerR * 0.7), minSize: 12)
                let str = NSAttributedString(string: t.label, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.92 * iconAlpha),
                ])
                let sz = str.size()
                let labelCenterY = mid.y - blockH / 2 + fs * 1.45 / 2
                str.draw(at: CGPoint(x: mid.x - sz.width / 2, y: labelCenterY - sz.height / 2))
            }
        }

        // Centre: what you're dragging, or (while hovering) what you'll get.
        let p0 = bloomProgress(0, now)
        let dr = (innerR - 6) * (0.88 + 0.12 * p0)
        ctx.saveGState()
        ctx.setAlpha(p0 * (opaqueFills ? 1 : 0.80))
        ctx.setFillColor(idle.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2))
        ctx.restoreGState()
        if moreContrast {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2))
            ctx.restoreGState()
        }

        if let hv = hover, hv < n, hoverAmt[hv] > 0.02 {
            let rest = (innerR - 6) * 1.25                 // bitmap size stays fixed; only the drawn rect eases
            let side = rest * (0.88 + 0.12 * p0)
            let img = IconKit.image(targets[hv].id, size: rest)
            img.draw(in: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side),
                     from: .zero, operation: .sourceOver, fraction: hoverAmt[hv])
        } else {
            drawIdleCentre(c, radius: dr, alpha: p0)
        }

        // The pill: the reliable readout, because the drag ghost sits on top of the centre.
        if let hv = hover, hv < n, hoverAmt[hv] > 0.05 {
            drawPill(ctx, index: hv, centre: c, step: step, pop: pop)
        }
    }

    private func drawIdleCentre(_ c: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        let tSize = max(12, outerR * 0.052)
        let sSize = max(11, outerR * 0.042)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: tSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: para,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: sSize, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62 * alpha),
            .paragraphStyle: para,
        ]
        let w = radius * 1.7
        (title as NSString).draw(in: CGRect(x: c.x - w / 2, y: c.y + 1, width: w, height: tSize * 1.4), withAttributes: titleAttrs)
        (subtitle as NSString).draw(in: CGRect(x: c.x - w / 2, y: c.y - sSize * 1.5, width: w, height: sSize * 1.4), withAttributes: subAttrs)
    }

    private func drawPill(_ ctx: CGContext, index: Int, centre c: CGPoint, step: Double, pop: CGFloat) {
        let t = targets[index]
        let amt = hoverAmt[index]
        let accent = IconKit.accent(for: t.id)
        let info = IconCatalog.info(t.id)

        let f1 = Brand.font(max(14, outerR * 0.06), weight: 700, width: 100)
        let f2 = NSFont.systemFont(ofSize: max(11, outerR * 0.042), weight: .regular)
        let a1: [NSAttributedString.Key: Any] = [.font: f1, .foregroundColor: NSColor.white.withAlphaComponent(amt)]
        let a2: [NSAttributedString.Key: Any] = [.font: f2, .foregroundColor: NSColor.white.withAlphaComponent(0.66 * amt)]
        let s1 = (info.verb as NSString).size(withAttributes: a1)
        let s2 = (subtitle as NSString).size(withAttributes: a2)

        let iconSide = max(30, outerR * 0.12)
        let w = iconSide + 12 + max(s1.width, s2.width) + 34
        let h = max(iconSide + 18, s1.height + s2.height + 18)

        // Sit just outside the rim, along the segment's direction.
        let deg = Double(index) * step
        let dirX = CGFloat(sin(deg * Double.pi / 180))
        let dirY = CGFloat(cos(deg * Double.pi / 180))
        let dist = outerR + pop + 14 + abs(dirX) * w / 2 + abs(dirY) * h / 2
        var rect = CGRect(x: c.x + dirX * dist - w / 2, y: c.y + dirY * dist - h / 2, width: w, height: h)
        let lim = bounds.insetBy(dx: 6, dy: 6)
        rect.origin.x = min(max(rect.origin.x, lim.minX), lim.maxX - rect.width)
        rect.origin.y = min(max(rect.origin.y, lim.minY), lim.maxY - rect.height)

        let capsule = CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(srgbRed: 0.06, green: 0.06, blue: 0.075, alpha: 0.96 * amt).cgColor)
        ctx.addPath(capsule)
        ctx.fillPath()
        ctx.setStrokeColor(accent.withAlphaComponent(amt).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(capsule)
        ctx.strokePath()
        ctx.restoreGState()

        let iconRect = CGRect(x: rect.minX + 14, y: rect.midY - iconSide / 2, width: iconSide, height: iconSide)
        IconKit.image(t.id, size: iconSide).draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: amt)
        let tx = iconRect.maxX + 12
        let blockH = s1.height + s2.height
        (info.verb as NSString).draw(at: CGPoint(x: tx, y: rect.midY + blockH / 2 - s1.height), withAttributes: a1)
        (subtitle as NSString).draw(at: CGPoint(x: tx, y: rect.midY - blockH / 2), withAttributes: a2)
    }

    // MARK: Accessibility (VoiceOver gets the same segments the eyes do)

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "DropWheel. \(title). Choose what to turn it into." }

    override func accessibilityChildren() -> [Any]? {
        let n = targets.count
        guard n > 0 else { return [] }
        let step = 360.0 / Double(n)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let midR = (outerR + innerR) / 2
        var out: [NSAccessibilityElement] = []
        for (i, t) in targets.enumerated() {
            let p = onCircle(c, midR, Double(i) * step)
            let side = max(40, min(outerR - innerR, 2 * CGFloat.pi * midR / CGFloat(n)))
            let e = NSAccessibilityElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel(IconCatalog.info(t.id).verb)
            e.setAccessibilityFrameInParentSpace(NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
            out.append(e)
        }
        return out
    }

    // MARK: Hit testing (anywhere past the dead zone selects: flick toward a segment)

    private func segment(at p: NSPoint) -> Int? {
        guard !targets.isEmpty else { return nil }
        let dx = Double(p.x - bounds.midX)
        let dy = Double(p.y - bounds.midY)
        let r = hypot(dx, dy)
        guard r >= Double(innerR), r <= Double(bounds.width / 2) else { return nil }
        var deg = atan2(dx, dy) * 180 / Double.pi          // clockwise from 12 o'clock
        if deg < 0 { deg += 360 }
        let step = 360.0 / Double(targets.count)
        let idx = Int(((deg + step / 2).truncatingRemainder(dividingBy: 360)) / step)
        return min(idx, targets.count - 1)
    }

    private func setHover(_ h: Int?) {
        guard h != hover else { return }
        hover = h
        if reduceMotion {
            for i in hoverAmt.indices { hoverAmt[i] = (i == h) ? 1 : 0 }
            needsDisplay = true
        } else {
            startTimer()
        }
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHover(nil)
        needsDisplay = true
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let h = segment(at: p)
        if h != hover {
            setHover(h)
            if let h {
                Sound.shared.hover(targets[h].id)      // only on change, never per drag tick
                Haptics.tick()
            }
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
        Haptics.commit()
        committed = h
        commitStart = CACurrentMediaTime()
        startTimer()
        onChoose?(targets[h], urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if committed == nil { setHover(nil) }       // keep the chosen segment lit while it flashes
        needsDisplay = true
    }
}
