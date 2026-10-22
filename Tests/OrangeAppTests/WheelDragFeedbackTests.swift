import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class WheelDragFeedbackTests: XCTestCase {
    @MainActor func testHeldDragTargetChangesGiveFeedbackWithoutConfirmingAnOperation() async throws {
        _ = NSApplication.shared
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let original = URL(fileURLWithPath: #filePath)
        view.configure(choices: [.format(.jpeg), .format(.png), .format(.pdf)], mode: .convert,
                       inputs: [original], appearance: .solid, diameter: 252, preview: false,
                       byteCount: 100, duringDrag: true)
        var feedbackCount = 0
        var committed: [WheelChoice] = []
        view.onHighlight = { feedbackCount += 1 }
        view.onDrop = { choice, urls in
            committed.append(choice)
            XCTAssertEqual(urls, [original])
        }
        let first = NSPoint(x: 186, y: 270)
        let second = NSPoint(x: 259, y: 144)
        view.mouseDragged(with: try event(.leftMouseDragged, at: first, flags: .shift, window: window))
        XCTAssertEqual(feedbackCount, 1)
        view.mouseDragged(with: try event(.leftMouseDragged, at: first, flags: .shift, window: window))
        XCTAssertEqual(feedbackCount, 1)
        view.mouseDragged(with: try event(.leftMouseDragged, at: second, flags: .shift, window: window))
        XCTAssertEqual(feedbackCount, 2)
        view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 186, y: 186), flags: .shift, window: window))
        XCTAssertEqual(feedbackCount, 2)
        XCTAssertTrue(committed.isEmpty)
        view.releaseDrag()
        view.mouseUp(with: try event(.leftMouseUp, at: second, window: window))
        XCTAssertTrue(committed.isEmpty)
        view.mouseDown(with: try event(.leftMouseDown, at: second, window: window))
        view.mouseUp(with: try event(.leftMouseUp, at: second, window: window))
        XCTAssertEqual(committed, [.format(.png)])
    }

    @MainActor private func event(_ type: NSEvent.EventType, at point: NSPoint,
                                 flags: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseDragged || type == .leftMouseDown ? 1 : 0))
    }
}
