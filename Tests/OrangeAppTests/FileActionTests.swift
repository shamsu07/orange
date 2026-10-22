import XCTest
import AppKit
@testable import Orange

final class FileActionTests: XCTestCase {
    @MainActor func testCopyFilesAndPathsWriteActualClipboardPayloads() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = FileActionCoordinator(pasteboard: board, makeAirDrop: { nil })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let urls = [root.appendingPathComponent("a b.png"), root.appendingPathComponent("other.png")]
        var feedback: [String] = []
        coordinator.onFeedback = { feedback.append($0) }
        coordinator.copyFiles(urls)
        let copied = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(copied, urls)
        coordinator.copyPaths(urls)
        XCTAssertEqual(board.string(forType: .string), urls.map(\.path).joined(separator: "\n"))
        XCTAssertEqual(feedback.count, 2)
    }
    @MainActor func testAirDropSessionIsRetainedUntilCompletion() async {
        weak var weakSession: FakeAirDrop?
        let coordinator = FileActionCoordinator(makeAirDrop: {
            let session = FakeAirDrop()
            weakSession = session
            return session
        })
        var feedback: String?
        coordinator.onFeedback = { feedback = $0 }
        coordinator.airDrop([URL(fileURLWithPath: #filePath)])
        XCTAssertNotNil(weakSession)
        XCTAssertEqual(weakSession?.beginCalls, 1)
        weakSession?.completion?(.success(()))
        XCTAssertEqual(feedback, "AirDrop finished")
        XCTAssertNil(weakSession)
    }
    @MainActor func testUnavailableAirDropReportsFailureWithoutStarting() async {
        let session = FakeAirDrop()
        session.available = false
        let coordinator = FileActionCoordinator(makeAirDrop: { session })
        var error: String?
        coordinator.onError = { error = $0 }
        coordinator.airDrop([URL(fileURLWithPath: #filePath)])
        XCTAssertEqual(session.beginCalls, 0)
        XCTAssertTrue(error?.contains("unavailable") == true)
    }
    @MainActor func testAirDropFailureReleasesSessionAndReportsError() async {
        let session = FakeAirDrop()
        let coordinator = FileActionCoordinator(makeAirDrop: { session })
        var error: String?
        coordinator.onError = { error = $0 }
        coordinator.airDrop([URL(fileURLWithPath: #filePath)])
        session.completion?(.failure(NSError(domain: "fixture.airdrop", code: 9)))
        XCTAssertTrue(error?.contains("AirDrop failed") == true)
    }
    @MainActor func testShutdownCancelsSharingAndRejectsNewActions() async {
        let session = FakeAirDrop()
        let coordinator = FileActionCoordinator(makeAirDrop: { session })
        coordinator.airDrop([URL(fileURLWithPath: #filePath)])
        coordinator.shutdown()
        coordinator.airDrop([URL(fileURLWithPath: #filePath)])
        XCTAssertEqual(session.cancelCalls, 1)
        XCTAssertEqual(session.beginCalls, 1)
    }
}

@MainActor private final class FakeAirDrop: AirDropSharing {
    var available = true
    var beginCalls = 0
    var cancelCalls = 0
    var completion: ((Result<Void, Error>) -> Void)?
    func canShare(_ urls: [URL]) -> Bool { available }
    func begin(_ urls: [URL], completion: @escaping (Result<Void, Error>) -> Void) { beginCalls += 1; self.completion = completion }
    func cancel() { cancelCalls += 1; completion = nil }
}
