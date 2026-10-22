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
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()
    private let wheel = WheelController()
    private let setup = SetupController()
    private var pendingNudge = false
    private var nudgedThisLaunch = false
    private var nudgeEpoch = 0
    private var lastOutput: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        // Small delay so the menu-bar icon appears first, then the welcome window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !Settings.setupDeclined else { return }
            self.setup.show(missing: HelperInstaller.missing())
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
        guard !targets.isEmpty else { return }
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        wheel.show(at: NSEvent.mouseLocation, title: title,
                   subtitle: Settings.after.wheelHint, targets: targets)
    }

    private func handleDrop(_ urls: [URL], to target: Target) {
        nudgeEpoch += 1
        pendingNudge = false
        // Leave the drag callback before doing anything slow or modal.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // SIGN opens its own window instead of converting.
            if target.id == "sign" {
                if let first = urls.first { self.startSigning(first) }
                return
            }
            // Merge/split/compress never replace originals, so there's nothing to ask.
            let mode = Registry.replaceApplies(id: target.id) ? Settings.after : .keep
            switch mode {
            case .keep:
                self.run(urls, to: target.id, replace: false)
            case .replace:
                self.run(urls, to: target.id, replace: true)
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
                case .alertFirstButtonReturn: self.run(urls, to: target.id, replace: false)
                case .alertSecondButtonReturn: self.run(urls, to: target.id, replace: true)
                default: break
                }
            }
        }
    }

    private func startSigning(_ url: URL) {
        setIcon("✍︎")
        SignController.start(url: url) { [weak self] out in
            guard let self else { return }
            if let out {
                self.lastOutput = out
                self.setIcon("✓")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.setIcon("◎") }
            } else {
                self.setIcon("◎")
            }
        }
    }

    private func run(_ urls: [URL], to id: String, replace: Bool) {
        setIcon("⏳")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Converter.convert(urls, to: id, replace: replace)
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func finish(_ result: ConversionResult) {
        if let last = result.outputs.last { lastOutput = last }
        if result.errors.isEmpty {
            setIcon("✓")
            Sound.shared.play(.done)
        } else {
            setIcon("⚠︎")
            Sound.shared.play(.error)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Conversion failed"
            alert.informativeText = result.errors.joined(separator: "\n\n")
            alert.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.setIcon("◎") }
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
        let reveal = NSMenuItem(title: "Reveal last output", action: #selector(revealLast), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = lastOutput != nil
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DropWheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

    @objc private func pickSound(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = SoundMode(rawValue: raw) else { return }
        Settings.sound = m
        Sound.shared.mode = m
        Sound.shared.demo()   // so you hear what you just picked
    }

    @objc private func toggleSignAuth() { Settings.signAuth.toggle() }
    @objc private func toggleSignDate() { Settings.signAutoDate.toggle() }

    @objc private func redrawSignature() {
        SignaturePad.present(slot: .signature, from: nil, forceSave: true) { _ in }
    }

    @objc private func redrawInitials() {
        SignaturePad.present(slot: .initials, from: nil, forceSave: true) { _ in }
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
