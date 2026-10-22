import Foundation

/// Global bound across batches, so simultaneous drops cannot spawn unlimited encoders.
actor WorkLimiter {
    static let shared = WorkLimiter()
    private var active = 0
    private let limit = 2
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire(_ id: UUID) async -> Bool {
        if Task.isCancelled { return false }
        if active < limit { active += 1; return true }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in waiters.append((id, continuation)) }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().1.resume(returning: true) }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(returning: false) }
    }
    func withPermit<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        guard await acquire(UUID()) else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}
