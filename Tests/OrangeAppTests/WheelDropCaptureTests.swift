import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class WheelDropCaptureTests: XCTestCase {
    @MainActor func testMismatchedOrMissingDropDataCancelsInsteadOfUsingCachedFiles() async throws {
        _ = NSApplication.shared
        let original = URL(fileURLWithPath: #filePath)
        let replacement = original.deletingLastPathComponent().appendingPathComponent("replacement.pdf")
        for dropped in [[replacement], []] {
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.configure(choices: [.action(.copyPath), .action(.copy), .action(.float)], mode: .actions,
                           inputs: [original], appearance: .solid, diameter: 252, preview: false,
                           byteCount: 100, duringDrag: true)
            var cancellations = 0
            var releases = 0
            var commits = 0
            view.onCancel = { cancellations += 1 }
            view.onDragReleased = { releases += 1 }
            view.onDrop = { _, _ in commits += 1 }
            XCTAssertFalse(view.completeDrag(with: dropped))
            XCTAssertEqual(cancellations, 1)
            XCTAssertEqual(releases, 0)
            // The trailing native drag-ended/release callbacks cannot revive it.
            view.releaseDrag()
            XCTAssertFalse(view.isPicking)
            let point = NSPoint(x: 186, y: 270)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            view.mouseDown(with: down)
            view.mouseUp(with: up)
            XCTAssertEqual(commits, 0)
        }
    }
}
