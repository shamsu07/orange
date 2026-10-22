import Foundation

/// A suspended native worker may not notice cancellation until it returns from
/// a system encoder. This gate models that boundary without blocking a thread.
actor PreviewLifecycleTestGate {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var started = 0
    private(set) var cancelledOnReturn = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        active += 1
        started += 1
        maximumActive = max(maximumActive, active)
        if !released {
            await withCheckedContinuation { continuations.append($0) }
        }
        active -= 1
        if Task.isCancelled { cancelledOnReturn += 1 }
    }

    func releaseAll() {
        released = true
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}
