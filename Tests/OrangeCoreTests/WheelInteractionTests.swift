import XCTest
@testable import OrangeCore

final class WheelInteractionTests: XCTestCase {
    func testDragReleaseNeverExecutesEvenOverAnOption() {
        var state = WheelInteraction()
        state.present(duringDrag: true)
        state.press(option: 2)
        XCTAssertNil(state.release(option: 2))
        state.releaseDrag()
        XCTAssertEqual(state.phase, .picking)
        XCTAssertNil(state.release(option: 2))
        XCTAssertEqual(state.phase, .picking)
    }
    func testFreshMatchingClickCommitsExactlyOnce() {
        var state = WheelInteraction()
        state.present(duringDrag: true)
        state.releaseDrag()
        state.press(option: 4)
        XCTAssertEqual(state.release(option: 4), 4)
        XCTAssertEqual(state.phase, .inactive)
        XCTAssertNil(state.release(option: 4))
        XCTAssertNil(state.confirm(option: 4))
    }
    func testMovingToAnotherOptionDuringClickDoesNotConfirmEither() {
        var state = WheelInteraction()
        state.present(duringDrag: false)
        state.press(option: 0)
        XCTAssertNil(state.release(option: 1))
        XCTAssertNil(state.release(option: 0))
        XCTAssertEqual(state.phase, .picking)
    }
    func testCenterGapsAndOutsideClicksDoNotExecute() {
        var state = WheelInteraction()
        state.present(duringDrag: false)
        state.press(option: nil)
        XCTAssertNil(state.release(option: 1))
        state.press(option: 1)
        XCTAssertNil(state.release(option: nil))
        state.press(option: -1)
        XCTAssertNil(state.release(option: -1))
    }
    func testCancellationDisarmsAStartedClickAndKeyboardConfirmation() {
        var state = WheelInteraction()
        state.present(duringDrag: false)
        state.press(option: 1)
        state.cancel()
        XCTAssertNil(state.release(option: 1))
        XCTAssertNil(state.confirm(option: 1))
        state.releaseDrag()
        XCTAssertEqual(state.phase, .inactive)
    }
    func testKeyboardOnlyConfirmsAfterTheDragHasEnded() {
        var state = WheelInteraction()
        state.present(duringDrag: true)
        XCTAssertNil(state.confirm(option: 3))
        state.releaseDrag()
        XCTAssertEqual(state.confirm(option: 3), 3)
    }
    func testRepeatedDragEndNotificationsKeepPickerOpen() {
        var state = WheelInteraction()
        state.present(duringDrag: true)
        state.releaseDrag()
        state.releaseDrag()
        XCTAssertEqual(state.phase, .picking)
        state.press(option: 2)
        state.releaseDrag()
        XCTAssertEqual(state.release(option: 2), 2)
    }
    func testPreviewSelectionNeverTurnsIntoARealOperation() {
        var state = WheelInteraction()
        state.present(duringDrag: false, preview: true)
        state.press(option: 1)
        XCTAssertEqual(state.release(option: 1), 1)
        XCTAssertEqual(state.phase, .preview)
        XCTAssertEqual(state.confirm(option: 4), 4)
        XCTAssertEqual(state.phase, .preview)
    }
}
