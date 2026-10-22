import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class MenuFeedbackTests: XCTestCase {
    @MainActor func testToolsAreFilteredPerFamilyWhileConversionsStayFixed() async {
        let model = AppModel(persistPreferences: false)
        let image = SelectionCapabilities(formats: [.jpeg, .png], tools: [.resize, .rotate], families: [.image])
        let video = SelectionCapabilities(tools: [.rotate], families: [.video])
        model.menuPreferences.setEnabled(false, tool: .rotate, family: .image)
        XCTAssertEqual(model.choices(from: image, mode: .tools), [.tool(.resize)])
        XCTAssertEqual(model.choices(from: video, mode: .tools), [.tool(.rotate)])
        XCTAssertEqual(model.choices(from: image, mode: .convert), [.format(.jpeg), .format(.png)])
        model.menuPreferences.setEnabled(false, action: .airDrop)
        XCTAssertFalse(model.choices(from: image, mode: .actions, selectionCount: 1).contains(.action(.airDrop)))
        XCTAssertFalse(model.choices(from: image, mode: .actions, selectionCount: 1).contains(.action(.createZip)))
        XCTAssertTrue(model.choices(from: image, mode: .actions, selectionCount: 2).contains(.action(.createZip)))
        XCTAssertEqual(try? JSONDecoder().decode(WheelMenuPreferences.self, from: JSONEncoder().encode(model.menuPreferences)), model.menuPreferences)
        await model.shutdown()
    }

    @MainActor func testHoverHapticsAreRateLimitedWithoutMovingOrClickingTargets() {
        var pulses = 0
        var now: TimeInterval = 1
        let haptics = WheelHaptics(perform: { pulses += 1 }, uptime: { now })
        haptics.selection()
        now += 0.01; haptics.selection()
        XCTAssertEqual(pulses, 1)
        now += 0.1; haptics.selection()
        XCTAssertEqual(pulses, 2)
        haptics.reset(); haptics.selection()
        XCTAssertEqual(pulses, 3)
    }

    @MainActor func testHidingTheActiveActionRepairsSelectionAndClearsItWhenNoActionsRemain() async {
        let model = AppModel(persistPreferences: false)
        model.inputs = [URL(fileURLWithPath: #filePath)]
        model.mode = .actions
        model.selectedChoice = .action(.copyPath)

        model.menuPreferences.setEnabled(false, action: .copyPath)

        XCTAssertFalse(model.choices.contains(.action(.copyPath)))
        XCTAssertEqual(model.selectedChoice, model.choices.first)
        XCTAssertNotNil(model.selectedChoice)

        for action in FileAction.allCases { model.menuPreferences.setEnabled(false, action: action) }
        XCTAssertTrue(model.choices.isEmpty)
        XCTAssertNil(model.selectedChoice)
        await model.shutdown()
    }

    @MainActor func testStaleHiddenChoiceCannotExecuteOrOverwriteClipboard() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("clipboard must survive", forType: .string)
        let actions = FileActionCoordinator(pasteboard: board, makeAirDrop: { nil })
        let model = AppModel(persistPreferences: false, fileActionCoordinator: actions)
        model.inputs = [URL(fileURLWithPath: #filePath)]
        model.mode = .actions
        model.menuPreferences.setEnabled(false, action: .copyPath)
        // A stale view callback can retain a choice after preferences changed.
        model.selectedChoice = .action(.copyPath)

        model.performSelected()

        XCTAssertEqual(board.string(forType: .string), "clipboard must survive")
        XCTAssertEqual(model.actionFeedback, "Choose an available option.")
        XCTAssertEqual(model.selectedChoice, model.choices.first)
        XCTAssertTrue(model.jobs.isEmpty)
        await model.shutdown()
    }
}
