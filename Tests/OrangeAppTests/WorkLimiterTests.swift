import XCTest
@testable import Orange

final class WorkLimiterTests: XCTestCase {
    func testCancelledWaiterDoesNotStartAndReturnsCapacityForLaterWork() async throws {
        let limiter = WorkLimiter()
        let first = PreviewLifecycleTestGate()
        let holders = (0..<2).map { _ in
            Task { try await limiter.withPermit { await first.hold() } }
        }
        let deadline = Date().addingTimeInterval(3)
        while await first.started < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await first.started
        XCTAssertEqual(started, 2)
        guard started == 2 else {
            await first.releaseAll()
            for task in holders { _ = try? await task.value }
            return
        }
        let queued = PreviewLifecycleTestGate()
        let cancelled = Task { try await limiter.withPermit { await queued.hold() } }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        let queuedStarts = await queued.started
        XCTAssertEqual(queuedStarts, 0)
        // Release both gates before joining so even a broken limiter fails an
        // assertion instead of leaving the test suite suspended indefinitely.
        await first.releaseAll()
        await queued.releaseAll()
        do {
            try await cancelled.value
            XCTFail("The cancelled waiter must finish without starting its encoder.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let totalQueuedStarts = await queued.started
        XCTAssertEqual(totalQueuedStarts, 0)
        for task in holders { try await task.value }

        let next = PreviewLifecycleTestGate()
        let nextHolders = (0..<2).map { _ in
            Task { try await limiter.withPermit { await next.hold() } }
        }
        let nextDeadline = Date().addingTimeInterval(3)
        while await next.started < 2 && Date() < nextDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let nextStarts = await next.started
        XCTAssertEqual(nextStarts, 2, "Cancelling a queued preview must not leak one of the two permits.")
        await next.releaseAll()
        for task in nextHolders { try await task.value }
    }

    func testWorkerErrorReturnsItsPermit() async throws {
        enum FailedEncode: Error { case expected }
        let limiter = WorkLimiter()
        do {
            try await limiter.withPermit { throw FailedEncode.expected }
            XCTFail("The worker error must reach its caller.")
        } catch { XCTAssertTrue(error is FailedEncode) }

        let gate = PreviewLifecycleTestGate()
        let holders = (0..<2).map { _ in
            Task { try await limiter.withPermit { await gate.hold() } }
        }
        let deadline = Date().addingTimeInterval(3)
        while await gate.started < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await gate.started
        XCTAssertEqual(started, 2, "An encoder failure must return capacity for both subsequent jobs.")
        await gate.releaseAll()
        for task in holders { try await task.value }
    }
}
