import AppKit

// MARK: - Settings

enum TriggerKey: String, CaseIterable {
    case shift, control, option, command

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }

    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        }
    }
}

enum AfterConvert: String, CaseIterable {
    case keep, ask, replace

    var title: String {
        switch self {
        case .keep: return "Keep original"
        case .ask: return "Ask every time"
        case .replace: return "Replace (original goes to Trash)"
        }
    }

    var wheelHint: String {
        switch self {
        case .keep: return "keeps original"
        case .ask: return "asks first"
        case .replace: return "replaces original"
        }
    }
}

/// How big the wheel is. The old wheel was 380 pt across; "Standard" is already a third bigger.
enum WheelSize: String, CaseIterable {
    case compact, standard, large, huge

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        case .huge: return "Extra large"
        }
    }

    /// Diameter of the ring in points.
    var diameter: CGFloat {
        switch self {
        case .compact: return 420
        case .standard: return 520
        case .large: return 640
        case .huge: return 760
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var trigger: TriggerKey {
        get { TriggerKey(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .shift }
        set { defaults.set(newValue.rawValue, forKey: "trigger") }
    }

    static var after: AfterConvert {
        get { AfterConvert(rawValue: defaults.string(forKey: "after") ?? "") ?? .keep }
        set { defaults.set(newValue.rawValue, forKey: "after") }
    }

    static var sound: SoundMode {
        get { SoundMode(rawValue: defaults.string(forKey: "sound") ?? "") ?? .subtle }
        set { defaults.set(newValue.rawValue, forKey: "sound") }
    }

    /// Ask for Touch ID / Apple Watch / password before a saved signature is used.
    static var signAuth: Bool {
        get { defaults.object(forKey: "signAuth") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "signAuth") }
    }

    /// Fill in today's date next to a "Date:" label when signing.
    static var signAutoDate: Bool {
        get { defaults.object(forKey: "signAutoDate") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "signAutoDate") }
    }

    /// True once the user chose "Not Now" on the setup window: don't auto-open it at launch again.
    static var setupDeclined: Bool {
        get { defaults.bool(forKey: "setupDeclined") }
        set { defaults.set(newValue, forKey: "setupDeclined") }
    }

    // MARK: Look and feel

    static var wheelSize: WheelSize {
        get { WheelSize(rawValue: defaults.string(forKey: "wheelSize") ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "wheelSize") }
    }

    /// Solid, app-icon-like page icons instead of the default outlined ones.
    static var iconSolid: Bool {
        get { defaults.bool(forKey: "iconSolid") }
        set { defaults.set(newValue, forKey: "iconSolid") }
    }

    /// All icons in one calm white instead of a colour per kind of file.
    static var calmColors: Bool {
        get { defaults.bool(forKey: "calmColors") }
        set { defaults.set(newValue, forKey: "calmColors") }
    }

    /// Words under every slice (JPG, PDF, SPLIT...). On by default; turn off for icons only.
    static var alwaysLabels: Bool {
        get { defaults.object(forKey: "alwaysLabels") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "alwaysLabels") }
    }

    // MARK: Feedback

    /// Off by default: a tap on the trackpad you didn't ask for breaks your flow. Opt in from the menu.
    static var haptics: Bool {
        get { defaults.object(forKey: "haptics") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "haptics") }
    }

    /// The little card after a conversion (the new file, Show, Undo).
    static var resultToast: Bool {
        get { defaults.object(forKey: "resultToast") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "resultToast") }
    }

    /// After converting, select the new file in Finder instead of leaving the original highlighted.
    static var selectResult: Bool {
        get { defaults.object(forKey: "selectResult") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "selectResult") }
    }

    /// The first-run practice has been shown (or skipped).
    static var tutorialSeen: Bool {
        get { defaults.bool(forKey: "tutorialSeen") }
        set { defaults.set(newValue, forKey: "tutorialSeen") }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()
    private let wheel = WheelController()
    private let setup = SetupController()
    private let tutorial = TutorialController()
    private let toast = ResultToast.shared
    private var pendingNudge = false
    private var nudgedThisLaunch = false
    private var nudgeEpoch = 0
    private var pendingTutorial = false
    private var lastOutput: URL?
    /// Where the dragged file was when the wheel opened. The result card stays clear of this spot,
    /// because the new file is written right next to it.
    private var dragOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Brand.register()

        MainMenu.install()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("◎")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.modifier = Settings.trigger.flag
        watcher.onTrigger = { [weak self] urls in self?.showWheel(for: urls) }
        watcher.onEnd = { [weak self] in
            self?.wheel.hide(after: 0.15)
            self?.flushSetupNudge()
        }
        watcher.start()

        Sound.shared.mode = Settings.sound
        DispatchQueue.main.async { Sound.shared.warmUp() }

        wheel.onChoose = { [weak self] target, urls in self?.handleDrop(urls, to: target) }

        // First-run setup: downloads the helper tools (video/audio, documents) behind a friendly window.
        setup.onBegin = { [weak self] in self?.setIcon("⏳") }
        setup.onEnd = { [weak self] ok in
            guard let self else { return }
            self.setIcon(ok ? "✓" : "◎")
            if ok { Sound.shared.play(.done) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.setIcon("◎") }
        }
        // When the setup window goes away, the practice run comes next (first launch only).
        setup.onDismiss = { [weak self] _ in
            guard let self, self.pendingTutorial else { return }
            self.pendingTutorial = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.tutorial.show() }
        }
        // Small delay so the menu-bar icon appears first, then the welcome window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            var setupShown = false
            if !Settings.setupDeclined, !HelperInstaller.missing().isEmpty {
                self.setup.show(missing: HelperInstaller.missing())
                setupShown = true
            }
            if !Settings.tutorialSeen {
                if setupShown { self.pendingTutorial = true } else { self.tutorial.show() }
            }
        }
    }

    /// The wheel was shown for files a missing helper could convert more ways. If the user lets go
    /// without picking anything, explain and offer the one-time download (never during the drag).
    private func flushSetupNudge() {
        guard pendingNudge else { return }
        pendingNudge = false
        nudgedThisLaunch = true
        let epoch = nudgeEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.nudgeEpoch == epoch else { return }   // they picked a segment: stay quiet
            self.setup.show(missing: HelperInstaller.missing(),
                            because: "DropWheel needs a one-time download before it can convert this kind of file.")
        }
    }

    private func setIcon(_ s: String) {
        statusItem.button?.title = s
    }

    // MARK: Wheel + conversion flow

    private func showWheel(for urls: [URL]) {
        let targets = Registry.targets(for: urls)
        if !nudgedThisLaunch, !HelperInstaller.missing().isEmpty, Registry.wouldUnlock(urls) {
            pendingNudge = true
        }
        guard !targets.isEmpty else {
            // Silence feels broken. Say so, quietly.
            if Settings.resultToast {
                let ext = urls.count == 1 ? urls[0].pathExtension.lowercased() : ""
                let detail = urls.count == 1 && !ext.isEmpty
                    ? ".\(ext) files can't be converted yet."
                    : "These files don't have a conversion in common. Try one kind of file at a time."
                Sound.shared.blocked()
                toast.showNotice(title: "Nothing to turn this into", detail: detail, at: NSEvent.mouseLocation)
            }
            return
        }
        dragOrigin = NSEvent.mouseLocation
        tutorial.wheelShown(for: urls)
        wheel.hintTargetID = tutorial.hintTarget(for: urls)
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        wheel.show(at: NSEvent.mouseLocation, title: title,
                   subtitle: Settings.after.wheelHint, targets: targets)
    }

    private func handleDrop(_ urls: [URL], to target: Target) {
        nudgeEpoch += 1
        pendingNudge = false
        let point = dragOrigin ?? NSEvent.mouseLocation     // where the file is: the card keeps clear of it
        tutorial.didChoose(target, urls: urls)
        // Leave the drag callback before doing anything slow or modal.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // SIGN opens its own window instead of converting.
            if target.id == "sign" {
                if let first = urls.first { self.startSigning(first, at: point) }
                return
            }
            // Merge/split/compress never replace originals, so there's nothing to ask.
            let mode = Registry.replaceApplies(id: target.id) ? Settings.after : .keep
            switch mode {
            case .keep:
                self.run(urls, to: target, replace: false, at: point)
            case .replace:
                self.run(urls, to: target, replace: true, at: point)
            case .ask:
                NSApp.activate(ignoringOtherApps: true)
                let names = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) files"
                let alert = NSAlert()
                alert.messageText = "Convert \(names) to \(target.label)?"
                alert.informativeText = "Keep the original, or replace it? Replaced originals go to the Trash."
                alert.addButton(withTitle: "Keep original")
                alert.addButton(withTitle: "Replace original")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: self.run(urls, to: target, replace: false, at: point)
                case .alertSecondButtonReturn: self.run(urls, to: target, replace: true, at: point)
                default: break
                }
            }
        }
    }

    private func startSigning(_ url: URL, at point: NSPoint) {
        setIcon("✍︎")
        SignController.start(url: url) { [weak self] out in
            guard let self else { return }
            if let out {
                self.lastOutput = out
                self.setIcon("✓")
                var r = ConversionResult()
                r.outputs = [out]
                self.presentSuccess(r, sources: [url], at: point)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.setIcon("◎") }
            } else {
                self.setIcon("◎")
            }
        }
    }

    private func run(_ urls: [URL], to target: Target, replace: Bool, at point: NSPoint) {
        setIcon("⏳")
        if Settings.resultToast {
            toast.showWorking(target: target, count: urls.count, at: point)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Converter.convert(urls, to: target.id, replace: replace)
            DispatchQueue.main.async { self?.finish(result, sources: urls, at: point) }
        }
    }

    private func finish(_ result: ConversionResult, sources: [URL], at point: NSPoint) {
        if let last = result.outputs.last { lastOutput = last }
        tutorial.didFinish(result, urls: sources)
        if result.errors.isEmpty, result.outputs.isEmpty, let note = result.notices.first {
            // Nothing failed; there was just nothing to do. No error sound, no warning colours.
            setIcon("◎")
            Sound.shared.blocked()
            if Settings.resultToast {
                toast.showNotice(title: "Nothing to do", detail: note, at: point)
            }
            return
        }
        if result.errors.isEmpty {
            setIcon("✓")
            Sound.shared.play(.done)
            presentSuccess(result, sources: sources, at: point)
        } else {
            setIcon("⚠︎")
            Sound.shared.play(.error)
            Haptics.fail()
            // Whatever did convert still gets selected, so it's easy to find.
            if !tutorial.owns(sources), Reveal.shouldAutoSelect(result.outputs) { Reveal.select(result.outputs) }
            presentFailure(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.setIcon("◎") }
    }

    /// The new file becomes the selected one in Finder, and a toast offers to drag it out, show it, or undo.
    private func presentSuccess(_ result: ConversionResult, sources: [URL], at point: NSPoint) {
        // The practice file lives in a hidden support folder, so never pop Finder open for it.
        if !tutorial.owns(sources), Reveal.shouldAutoSelect(result.outputs) {
            Reveal.select(result.outputs)
        }
        guard Settings.resultToast, !result.outputs.isEmpty else { return }
        let snapshot = Undo.snapshot(result.outputs)
        let note: String? = result.notices.isEmpty ? nil
            : "\(result.notices.count) skipped: nothing to do for \(result.notices.count == 1 ? "it" : "them")"
        toast.showResult(outputs: result.outputs, sources: sources, replaced: !result.trashed.isEmpty, note: note,
                         undo: { [weak self] in self?.undo(result, snapshot: snapshot) })
    }

    private func presentFailure(_ result: ConversionResult) {
        let all = result.errors.joined(separator: "\n\n")
        let first = result.errors.first ?? "Something went wrong."
        let firstLine = first.split(separator: "\n").first.map(String.init) ?? first
        if Settings.resultToast {
            let title = result.outputs.isEmpty
                ? "Couldn't convert"
                : "\(result.outputs.count) converted, \(result.errors.count) failed"
            toast.showError(title: title, detail: firstLine, onDetails: { [weak self] in self?.showFailureAlert(all) })
        } else {
            showFailureAlert(all)
        }
    }

    private func showFailureAlert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Conversion failed"
        alert.informativeText = text
        alert.runModal()
    }

    private func undo(_ result: ConversionResult, snapshot: Undo.Snapshot) {
        let r = Undo.perform(result, snapshot: snapshot)
        if r.kept > 0 {
            toast.showMessage("Kept \(r.kept) file\(r.kept == 1 ? "" : "s") that changed since it was made")
        } else {
            toast.showMessage("Moved to the Trash")
        }
    }

    /// Shows the wheel for a moment in the middle of the screen, so a size or style change is visible at once.
    private func previewWheel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let ids = ["jpg", "png", "pdf", "sign", "docx", "txt", "split", "zip"]
        let labels = ["JPG", "PNG", "PDF", "SIGN", "DOCX", "TXT", "SPLIT", "ZIP"]
        let targets = zip(ids, labels).map { Target(id: $0.0, label: $0.1) }
        wheel.hintTargetID = nil
        wheel.show(at: NSPoint(x: frame.midX, y: frame.midY), title: "Your wheel", subtitle: "preview", targets: targets)
        wheel.hide(after: 1.8)
    }

    // MARK: Menu (rebuilt each time it opens so engine status is always fresh)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !HelperInstaller.missing().isEmpty {
            let fix = NSMenuItem(title: "⚠︎ Finish setup… (one-time download)", action: #selector(openSetup), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: "Hold \(Settings.trigger.title) while dragging a file", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let triggerItem = NSMenuItem(title: "Trigger key", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for k in TriggerKey.allCases {
            let item = NSMenuItem(title: k.title, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = k.rawValue
            item.state = k == Settings.trigger ? .on : .off
            triggerMenu.addItem(item)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        let afterItem = NSMenuItem(title: "After converting", action: nil, keyEquivalent: "")
        let afterMenu = NSMenu()
        for a in AfterConvert.allCases {
            let item = NSMenuItem(title: a.title, action: #selector(pickAfter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = a.rawValue
            item.state = a == Settings.after ? .on : .off
            afterMenu.addItem(item)
        }
        afterItem.submenu = afterMenu
        menu.addItem(afterItem)

        // Appearance: how big the wheel is, and what the icons look like.
        let looksItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let looksMenu = NSMenu()
        let sizeHeader = NSMenuItem(title: "Wheel size", action: nil, keyEquivalent: "")
        sizeHeader.isEnabled = false
        looksMenu.addItem(sizeHeader)
        for s in WheelSize.allCases {
            let item = NSMenuItem(title: s.title, action: #selector(pickWheelSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = s == Settings.wheelSize ? .on : .off
            item.indentationLevel = 1
            looksMenu.addItem(item)
        }
        looksMenu.addItem(.separator())
        addToggle(looksMenu, "Solid icons", #selector(toggleSolidIcons), on: Settings.iconSolid)
        addToggle(looksMenu, "Calm colours (all white)", #selector(toggleCalmColors), on: Settings.calmColors)
        addToggle(looksMenu, "Label every slice with words", #selector(toggleAlwaysLabels), on: Settings.alwaysLabels)
        looksItem.submenu = looksMenu
        menu.addItem(looksItem)

        let soundItem = NSMenuItem(title: "Sounds", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for m in SoundMode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickSound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = m == Settings.sound ? .on : .off
            soundMenu.addItem(item)
        }
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        let feedbackItem = NSMenuItem(title: "Feedback", action: nil, keyEquivalent: "")
        let feedbackMenu = NSMenu()
        addToggle(feedbackMenu, "Haptic ticks on the trackpad (off by default)", #selector(toggleHaptics), on: Settings.haptics)
        addToggle(feedbackMenu, "Show a card when a file is ready", #selector(toggleToast), on: Settings.resultToast)
        addToggle(feedbackMenu, "Select the new file in Finder", #selector(toggleSelectResult), on: Settings.selectResult)
        feedbackItem.submenu = feedbackMenu
        menu.addItem(feedbackItem)

        let signItem = NSMenuItem(title: "Signing", action: nil, keyEquivalent: "")
        let signMenu = NSMenu()
        func signEntry(_ title: String, _ action: Selector, on: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
            signMenu.addItem(item)
        }
        signEntry("Ask Touch ID before signing", #selector(toggleSignAuth), on: Settings.signAuth)
        signEntry("Fill in the date automatically", #selector(toggleSignDate), on: Settings.signAutoDate)
        signMenu.addItem(.separator())
        signEntry("Redraw signature…", #selector(redrawSignature))
        signEntry("Redraw initials…", #selector(redrawInitials))
        signEntry("My printed name…", #selector(setPrintedName))
        signMenu.addItem(.separator())
        signEntry("Forget my signature and initials", #selector(forgetSignature))
        signItem.submenu = signMenu
        menu.addItem(signItem)

        let enginesItem = NSMenuItem(title: "Engines", action: nil, keyEquivalent: "")
        let enginesMenu = NSMenu()
        for e in Engine.allCases {
            if e.isAvailable {
                let item = NSMenuItem(title: "✓ \(e.name)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                enginesMenu.addItem(item)
            } else if e.helper != nil {
                let item = NSMenuItem(title: "✗ \(e.name): \(e.unlocks). Click to set up",
                                      action: #selector(openSetup), keyEquivalent: "")
                item.target = self
                enginesMenu.addItem(item)
            } else if let url = e.downloadURL {
                let item = NSMenuItem(title: "✗ \(e.name): \(e.unlocks). Click to open the download page",
                                      action: #selector(openDownload(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                enginesMenu.addItem(item)
            } else if let cmd = e.installCommand {
                let item = NSMenuItem(title: "✗ \(e.name): \(e.unlocks). Click to copy “\(cmd)”",
                                      action: #selector(copyCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = cmd
                enginesMenu.addItem(item)
            }
        }
        enginesItem.submenu = enginesMenu
        menu.addItem(enginesItem)

        menu.addItem(.separator())
        let tour = NSMenuItem(title: "Try it: show the tutorial…", action: #selector(showTutorial), keyEquivalent: "")
        tour.target = self
        menu.addItem(tour)
        let reveal = NSMenuItem(title: "Reveal last output", action: #selector(revealLast), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = lastOutput != nil
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DropWheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    @objc private func pickTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = TriggerKey(rawValue: raw) else { return }
        Settings.trigger = k
        watcher.modifier = k.flag
    }

    @objc private func pickAfter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = AfterConvert(rawValue: raw) else { return }
        Settings.after = a
    }

    @objc private func pickWheelSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = WheelSize(rawValue: raw) else { return }
        Settings.wheelSize = s
        previewWheel()
    }

    @objc private func toggleSolidIcons() {
        Settings.iconSolid.toggle()
        previewWheel()
    }

    @objc private func toggleCalmColors() {
        Settings.calmColors.toggle()
        previewWheel()
    }

    @objc private func toggleAlwaysLabels() {
        Settings.alwaysLabels.toggle()
        previewWheel()
    }

    @objc private func toggleHaptics() {
        Settings.haptics.toggle()
        if Settings.haptics { Haptics.commit() }       // so you feel what you just turned on
    }

    @objc private func toggleToast() { Settings.resultToast.toggle() }
    @objc private func toggleSelectResult() { Settings.selectResult.toggle() }

    @objc private func showTutorial() { tutorial.show() }

    @objc private func pickSound(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = SoundMode(rawValue: raw) else { return }
        Settings.sound = m
        Sound.shared.mode = m
        Sound.shared.demo()   // so you hear what you just picked
    }

    @objc private func toggleSignAuth() { Settings.signAuth.toggle() }
    @objc private func toggleSignDate() { Settings.signAutoDate.toggle() }

    @objc private func redrawSignature() { redrawFromMenu(.signature) }
    @objc private func redrawInitials() { redrawFromMenu(.initials) }

    private func redrawFromMenu(_ slot: SignSlot) {
        // If the saved one is locked behind a denied Keychain prompt, sort that out first, or nothing would be saved.
        if SignatureStore.shared.isLocked, SignUnlock.resolve(slot: slot, allowSessionOnly: false) == .cancelled { return }
        SignaturePad.present(slot: slot, from: nil, forceSave: true) { _ in }
    }

    @objc private func forgetSignature() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget your saved signature and initials?"
        alert.informativeText = "They're deleted from this Mac. You'll draw them again next time you sign."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { SignatureStore.shared.forgetEverything() }
    }

    /// Lets auto-spot tell your signature block from the other party's.
    @objc private func setPrintedName() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Your printed name"
        alert.informativeText = "As it appears next to your signature line. Auto-spot uses it to find your block in contracts with two parties."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = SignatureStore.shared.printedName ?? NSFullUserName()
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { SignatureStore.shared.printedName = field.stringValue }
    }

    @objc private func copyCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    @objc private func openSetup() {
        setup.show(missing: HelperInstaller.missing())
    }

    @objc private func openDownload(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func revealLast() {
        if let url = lastOutput { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
