import AppKit

/// AppKit's alignment pattern is its subtle positioning cue. Public macOS APIs
/// do not expose haptic intensity; supported hardware determines the sensation.
@MainActor final class WheelHaptics {
    private let perform: @MainActor () -> Void
    private let uptime: @MainActor () -> TimeInterval
    private var lastPlayed: TimeInterval?

    init(perform: @escaping @MainActor () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }, uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.perform = perform
        self.uptime = uptime
    }
    func selection() {
        let now = uptime()
        if let lastPlayed, now - lastPlayed < 0.090 { return }
        lastPlayed = now
        perform()
    }
    func reset() { lastPlayed = nil }
}
