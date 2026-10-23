import AppKit

/// Trackpad taps that go with the sounds: a tick when you cross into a new segment, a firmer
/// click when you commit, a buzz when something fails. Silent on Macs without a Force Touch
/// trackpad (and with an external mouse), and off entirely when the user turns it off.
enum Haptics {
    static func tick() { perform(.alignment) }
    static func commit() { perform(.levelChange) }
    static func fail() { perform(.generic) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
