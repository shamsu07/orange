import Foundation

/// Owns every preparation/preview task until it finishes, including cancelled
/// requests superseded by a newer slider value or a closed panel.
@MainActor final class PreviewTaskGroup {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var isShutdown = false

    @discardableResult func spawn(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        guard !isShutdown else {
            let cancelled = Task {}
            cancelled.cancel()
            return cancelled
        }
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }
    func cancelAll() { for task in tasks.values { task.cancel() } }
    func shutdown() async {
        isShutdown = true
        cancelAll()
        await drain()
    }
    func drain() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { await task.value }
        }
    }
}
