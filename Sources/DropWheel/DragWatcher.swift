import AppKit

/// Detects "a file drag is in progress and the trigger key is held", system-wide,
/// by polling. Polling avoids event-monitor quirks during another app's drag session:
///  - NSEvent.pressedMouseButtons / modifierFlags are readable without permissions.
///  - The drag pasteboard's changeCount bumps when any app starts a drag.
final class DragWatcher {
    var modifier: NSEvent.ModifierFlags = .shift
    var onTrigger: (([URL]) -> Void)?
    var onEnd: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var wasDown = false
    private var countAtMouseDown = 0
    private var triggered = false

    func start() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0

        if down && !wasDown {
            countAtMouseDown = dragPasteboard.changeCount
            triggered = false
        }

        if down, !triggered,
           dragPasteboard.changeCount != countAtMouseDown,
           NSEvent.modifierFlags.contains(modifier) {
            let urls = fileURLs()
            if !urls.isEmpty {
                triggered = true
                onTrigger?(urls)
            }
        }

        if !down && wasDown && triggered {
            triggered = false
            onEnd?()
        }
        wasDown = down
    }

    /// Files and folders on the drag pasteboard (file promises, e.g. Mail/browser drags, are ignored in v1).
    private func fileURLs() -> [URL] {
        let objs = dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return objs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
