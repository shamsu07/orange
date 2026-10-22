import XCTest
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
}
