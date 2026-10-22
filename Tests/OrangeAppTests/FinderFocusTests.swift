import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class FinderFocusTests: XCTestCase {
    @MainActor func testBindingHidesPrimaryWindowsOnceAndReleaseDoesNotRestoreThem() async throws {
        _ = NSApplication.shared
        let model = AppModel(persistPreferences: false)
        model.soundFeedback = false
        let primary = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: false)
        primary.isReleasedWhenClosed = false
        primary.orderFrontRegardless()
        defer { primary.close() }
        var primaryWindowDismissals = 0
        model.onBeginFinderInteraction = { primaryWindowDismissals += 1; primary.orderOut(nil) }
        var deferred: [@MainActor @Sendable () -> Void] = []
        let controller = DragWheelController(model: model, capabilityLoader: { _ in SelectionCapabilities(formats: [.png]) },
                                             afterDragCallback: { deferred.append($0) })
        let point = NSPoint(x: 700, y: 450)
        controller.receive(DragWheelInput(kind: .mouseDown, timestamp: 1, screenPoint: point))
        controller.receive(DragWheelInput(kind: .dragged, timestamp: 2, flags: .shift, screenPoint: point))
        let generation = controller.snapshot.generation
        let input = URL(fileURLWithPath: #filePath)
        XCTAssertTrue(controller.bindNativeDrag([input], sequenceNumber: 912, generation: generation))
        XCTAssertTrue(controller.bindNativeDrag([input], sequenceNumber: 912, generation: generation))
        XCTAssertEqual(primaryWindowDismissals, 1)
        XCTAssertFalse(primary.isVisible)
        controller.receive(DragWheelInput(kind: .mouseUp, timestamp: 3, screenPoint: point))
        for action in deferred { action() }
        XCTAssertTrue(controller.snapshot.picking)
        XCTAssertFalse(primary.isVisible)
        await controller.stop()
        await model.shutdown()
    }
}
