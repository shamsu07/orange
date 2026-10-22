import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class WheelViewTests: XCTestCase {
    @MainActor func testMouseReleaseAfterDragDoesNotCommitThenFreshClickCommitsEachMode() async throws {
        _ = NSApplication.shared
        for (mode, choice) in [(WheelMode.convert, WheelChoice.format(.jpeg)), (.tools, .tool(.rotate)), (.actions, .action(.copyPath))] {
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            let url = URL(fileURLWithPath: #filePath)
            view.configure(choices: [choice, .format(.png), .format(.pdf)], mode: mode, inputs: [url],
                           appearance: .solid, diameter: 252, preview: false, byteCount: 100, duringDrag: true)
            var commits: [WheelChoice] = []
            view.onDrop = { choice, urls in commits.append(choice); XCTAssertEqual(urls, [url]) }
            let point = NSPoint(x: 186, y: 270)
            view.mouseDown(with: try event(.leftMouseDown, at: point, window: window))
            view.mouseUp(with: try event(.leftMouseUp, at: point, window: window))
            XCTAssertTrue(commits.isEmpty)
            view.releaseDrag()
            view.mouseUp(with: try event(.leftMouseUp, at: point, window: window))
            XCTAssertTrue(commits.isEmpty)
            view.mouseDown(with: try event(.leftMouseDown, at: point, window: window))
            view.mouseUp(with: try event(.leftMouseUp, at: point, window: window))
            XCTAssertEqual(commits, [choice])
        }
    }
    @MainActor func testHoverLeavesDrawingGeometryUnchangedAndNeverCommits() async throws {
        _ = NSApplication.shared
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.configure(choices: [.format(.jpeg), .format(.png), .format(.pdf)], mode: .convert,
                       inputs: [URL(fileURLWithPath: #filePath)], appearance: .solid, diameter: 252,
                       preview: false, byteCount: 100)
        var commits = 0
        view.onDrop = { _, _ in commits += 1 }
        let frames = view.layer?.sublayers?.prefix(3).map(\.frame)
        for point in [NSPoint(x: 186, y: 270), NSPoint(x: 259, y: 144), NSPoint(x: 113, y: 144)] {
            view.mouseMoved(with: try event(.mouseMoved, at: point, window: window))
        }
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(view.layer?.sublayers?.prefix(3).map(\.frame), frames)
        for layer in view.layer?.sublayers?.prefix(3) ?? [] { XCTAssertTrue(CATransform3DIsIdentity(layer.transform)) }
    }
    @MainActor func testSameSelectionCanBeReopenedAndConfirmedAfterReset() async throws {
        _ = NSApplication.shared
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let url = URL(fileURLWithPath: #filePath)
        var commits = 0
        view.onDrop = { choice, urls in
            XCTAssertEqual(choice, .action(.copyPath))
            XCTAssertEqual(urls, [url])
            commits += 1
        }
        for _ in 0..<2 {
            view.configure(choices: [.action(.copyPath), .action(.copy), .action(.float)], mode: .actions,
                           inputs: [url], appearance: .solid, diameter: 252, preview: false,
                           byteCount: 100, duringDrag: true)
            view.releaseDrag()
            XCTAssertTrue(view.isPicking)
            let point = NSPoint(x: 186, y: 270)
            view.mouseDown(with: try event(.leftMouseDown, at: point, window: window))
            view.mouseUp(with: try event(.leftMouseUp, at: point, window: window))
            view.reset()
        }
        XCTAssertEqual(commits, 2)
    }
    @MainActor func testUnchangedRefreshPreservesPickerPageAndKeyboardSelection() async throws {
        _ = NSApplication.shared
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let choices = OutputFormat.allCases.map(WheelChoice.format)
        let url = URL(fileURLWithPath: #filePath)
        view.configure(choices: choices, mode: .convert, inputs: [url], appearance: .solid,
                       diameter: 252, preview: false, byteCount: 100)
        var committed: WheelChoice?
        view.onDrop = { choice, _ in committed = choice }
        view.advancePage()
        view.keyDown(with: try keyEvent(124, window: window))
        view.configure(choices: choices, mode: .convert, inputs: [url], appearance: .solid,
                       diameter: 252, preview: false, byteCount: 100)
        view.keyDown(with: try keyEvent(36, window: window))
        XCTAssertEqual(committed, choices[8])
    }
    @MainActor func testReleasedPickerRejectsReplacementDropAndKeepsOriginalSelection() async throws {
        _ = NSApplication.shared
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 372, height: 372))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let original = URL(fileURLWithPath: #filePath)
        let replacement = original.deletingLastPathComponent().appendingPathComponent("replacement.pdf")
        view.configure(choices: [.action(.copyPath), .action(.copy), .action(.float)], mode: .actions,
                       inputs: [original], appearance: .solid, diameter: 252, preview: false,
                       byteCount: 100, duringDrag: true)
        var releases = 0
        view.onDragReleased = { releases += 1 }
        var committed: [URL] = []
        view.onDrop = { _, urls in committed = urls }
        XCTAssertTrue(view.completeDrag(with: [original]))
        XCTAssertTrue(view.isPicking)
        XCTAssertFalse(view.completeDrag(with: [replacement]))
        XCTAssertEqual(releases, 1)
        let point = NSPoint(x: 186, y: 270)
        view.mouseDown(with: try event(.leftMouseDown, at: point, window: window))
        view.mouseUp(with: try event(.leftMouseUp, at: point, window: window))
        XCTAssertEqual(committed, [original])
    }
    @MainActor func testNativePreviewCloseResetsControllerAndAllowsReopen() async throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let model = AppModel(persistPreferences: false)
        model.soundFeedback = false
        let controller = DragWheelController(model: model)
        controller.preview()
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existing.contains($0.windowNumber) && $0.title == "Orange wheel preview"
        })
        let view = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? WheelView }.first)
        XCTAssertTrue(view.isPreview)
        panel.close()
        XCTAssertFalse(view.isPreview)
        XCTAssertFalse(view.isPicking)
        controller.preview()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(view.isPreview)
        await controller.stop()
        panel.close()
        await model.shutdown()
    }
    @MainActor private func event(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }
    @MainActor private func keyEvent(_ keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "",
                                      charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
    }
}
