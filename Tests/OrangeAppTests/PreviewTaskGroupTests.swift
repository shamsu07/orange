import XCTest
@testable import Orange

final class PreviewTaskGroupTests: XCTestCase {
    @MainActor func testTerminalShutdownRejectsLateCallbacksAndJoinsCancelledWork() async throws {
        let group = PreviewTaskGroup()
        let gate = PreviewLifecycleTestGate()
        group.spawn { await gate.hold() }
        let deadline = Date().addingTimeInterval(3)
        while await gate.started == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await gate.started
        XCTAssertEqual(started, 1)
        guard started == 1 else { await gate.releaseAll(); await group.shutdown(); return }

        var didReturn = false
        let shutdown = Task { await group.shutdown(); didReturn = true }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(didReturn)
        XCTAssertTrue(group.isShutdown)
        var lateCallbackRan = false
        let rejected = group.spawn { lateCallbackRan = true }
        await rejected.value
        XCTAssertFalse(lateCallbackRan)
        await gate.releaseAll()
        await shutdown.value
        XCTAssertTrue(didReturn)
        let cancelledOnReturn = await gate.cancelledOnReturn
        XCTAssertEqual(cancelledOnReturn, 1)
    }
}
