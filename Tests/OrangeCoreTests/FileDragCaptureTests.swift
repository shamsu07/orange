import XCTest
@testable import OrangeCore

final class FileDragCaptureTests: XCTestCase {
    private let original = URL(fileURLWithPath: "/fixture/original.png")
    private let replacement = URL(fileURLWithPath: "/fixture/replacement.pdf")

    func testNativeSessionBindsWithoutPriorMouseDownOrNamedPasteboardState() {
        var capture = FileDragCapture()
        XCTAssertTrue(capture.inputs.isEmpty)
        XCTAssertNil(capture.sequenceNumber)
        // The destination's native session is sufficient, even if global mouse
        // events arrive late or an unrelated named pasteboard never changes.
        XCTAssertTrue(capture.capture([original], sequenceNumber: 0))
        XCTAssertEqual(capture.inputs, [original])
        XCTAssertEqual(capture.sequenceNumber, 0)
    }

    func testRepeatedUpdatesForBoundSessionAndIdenticalFilesAreStable() {
        var capture = FileDragCapture()
        let files = [original, replacement]
        XCTAssertTrue(capture.capture(files, sequenceNumber: 10))
        for _ in 0..<3 {
            XCTAssertTrue(capture.capture(files, sequenceNumber: 10))
            XCTAssertEqual(capture.inputs, files)
            XCTAssertEqual(capture.sequenceNumber, 10)
        }
    }

    func testChangedSessionOrPayloadCannotReplaceBoundSelection() {
        var capture = FileDragCapture()
        XCTAssertTrue(capture.capture([original], sequenceNumber: 10))
        XCTAssertFalse(capture.capture([replacement], sequenceNumber: 10))
        XCTAssertFalse(capture.capture([original, replacement], sequenceNumber: 10))
        XCTAssertFalse(capture.capture([original], sequenceNumber: 11))
        XCTAssertFalse(capture.capture([replacement], sequenceNumber: 11))
        XCTAssertEqual(capture.inputs, [original])
        XCTAssertEqual(capture.sequenceNumber, 10)
    }

    func testInvalidPayloadOrSequenceDoesNotBindAndAllowsLaterValidUpdate() {
        let remote = URL(string: "https://example.com/file.png")!
        for (urls, sequence) in [([], 10), ([remote], 10), ([original, remote], 10), ([original], -1)] {
            var capture = FileDragCapture()
            XCTAssertFalse(capture.capture(urls, sequenceNumber: sequence))
            XCTAssertTrue(capture.inputs.isEmpty)
            XCTAssertNil(capture.sequenceNumber)
            XCTAssertTrue(capture.capture([original], sequenceNumber: 10))
            XCTAssertEqual(capture.inputs, [original])
            XCTAssertEqual(capture.sequenceNumber, 10)
        }
    }

    func testReleaseBeforeBindingRejectsLateNativeSessionData() {
        var capture = FileDragCapture()
        capture.releaseMouseGesture()
        XCTAssertFalse(capture.capture([original], sequenceNumber: 10))
        XCTAssertTrue(capture.inputs.isEmpty)
        XCTAssertNil(capture.sequenceNumber)
    }

    func testReleasePreservesSelectionAndRejectsEveryFurtherUpdate() {
        var capture = FileDragCapture()
        XCTAssertTrue(capture.capture([original], sequenceNumber: 10))
        capture.releaseMouseGesture()
        XCTAssertFalse(capture.capture([original], sequenceNumber: 10))
        XCTAssertFalse(capture.capture([replacement], sequenceNumber: 10))
        XCTAssertFalse(capture.capture([replacement], sequenceNumber: 11))
        XCTAssertEqual(capture.inputs, [original])
        XCTAssertEqual(capture.sequenceNumber, 10)
    }

    func testResetAllowsRepeatedAndAlternatingFilesInNewNativeSessions() {
        var capture = FileDragCapture()
        for (index, file) in [original, original, replacement, original, replacement].enumerated() {
            capture.reset()
            XCTAssertTrue(capture.inputs.isEmpty)
            XCTAssertNil(capture.sequenceNumber)
            XCTAssertTrue(capture.capture([file], sequenceNumber: index))
            XCTAssertEqual(capture.inputs, [file])
            capture.releaseMouseGesture()
        }
    }
}
