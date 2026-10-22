import XCTest
import AppKit
import OrangeCore
@testable import Orange

final class DragWheelControllerTests: XCTestCase {
    @MainActor func testArmedReceiverRemainsHitTestableBeforeNativeFilesArrive() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            let view = try XCTUnwrap(harness.controller.presentedWheel)
            let parent = try XCTUnwrap(view.superview)
            XCTAssertTrue(parent.hitTest(NSPoint(x: view.frame.midX, y: view.frame.midY)) === view,
                          "The receiver must be a real native drag destination before files are bound")
        }
    }

    @MainActor func testFirstDragUsesTheNativeSendersAlreadyPublishedFiles() async throws {
        try await withHarness { harness in
            // Finder can publish the payload before Orange processes a copied
            // mouse-down event. No pasteboard change after that event is needed.
            let sender = NativeDragInfo(urls: [harness.rotated], sequenceNumber: 100)
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            let view = try XCTUnwrap(harness.controller.presentedWheel)
            sender.draggingDestinationWindow = view.window
            XCTAssertEqual(view.draggingEntered(sender), .copy)
            XCTAssertEqual(view.draggingUpdated(sender), .copy)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
            XCTAssertEqual(harness.controller.snapshot.nativeSequence, 100)
            XCTAssertFalse(harness.controller.snapshot.picking)
            XCTAssertTrue(view.prepareForDragOperation(sender))
            XCTAssertTrue(view.performDragOperation(sender))
            harness.send(.mouseUp, at: harness.wheelCenter)
            harness.callbacks.drain()
            XCTAssertTrue(harness.controller.snapshot.picking)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
            XCTAssertTrue(harness.model.jobs.isEmpty, "Releasing a drag must never start an operation")
        }
    }

    @MainActor func testModifierHeldBeforeDragThresholdArmsOnTheFirstDraggedEvent() async throws {
        try await withHarness { harness in
            harness.send(.modifiers, flags: .shift)
            harness.send(.mouseDown, flags: .shift)
            XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            harness.send(.dragged, flags: .shift)
            XCTAssertTrue(harness.controller.snapshot.armed)
            XCTAssertEqual(harness.controller.snapshot.mode, .convert)
            try harness.enterNativeDrag([harness.sample], sequence: 101)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
        }
    }

    @MainActor func testModifierTappedAfterThresholdArmsAtTheRecordedDragPoint() async throws {
        try await withHarness { harness in
            let dragPoint = NSPoint(x: 500, y: 500)
            harness.send(.mouseDown)
            harness.send(.dragged, at: dragPoint)
            XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            // A modifier event has no new mouse location. The event stream's
            // recorded drag point must be used, rather than live cursor state.
            harness.send(.modifiers, flags: .shift, at: nil)
            XCTAssertTrue(try XCTUnwrap(harness.controller.snapshot.frame).contains(dragPoint))
            try harness.enterNativeDrag([harness.rotated], sequence: 102)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
        }
    }

    @MainActor func testDraggedEventRecoversWhenTheActivationMouseDownWasMissed() async throws {
        try await withHarness { harness in
            harness.send(.dragged, flags: .command)
            XCTAssertTrue(harness.controller.snapshot.armed)
            XCTAssertEqual(harness.controller.snapshot.mode, .tools)
            try harness.enterNativeDrag([harness.rotated], sequence: 103)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
        }
    }

    @MainActor func testRepeatedAndAlternatingFilesWorkAcrossIndependentNativeSessions() async throws {
        try await withHarness { harness in
            let files = [harness.rotated, harness.sample, harness.rotated, harness.rotated, harness.sample]
            for (index, file) in files.enumerated() {
                harness.send(.mouseDown)
                harness.send(.dragged, flags: .shift)
                try harness.enterNativeDrag([file], sequence: 200 + index)
                harness.releaseAndDrain()
                XCTAssertTrue(harness.controller.snapshot.picking, "Failed native drag \(index)")
                XCTAssertEqual(harness.controller.snapshot.inputs, [file])
                XCTAssertEqual(harness.controller.snapshot.nativeSequence, 200 + index)
                harness.controller.applicationDidDeactivate()
                XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            }
            XCTAssertTrue(harness.model.jobs.isEmpty)
        }
    }

    @MainActor func testReturningToFinderDismissesOldPickerAndAllowsANewFile() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.sample], sequence: 300)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
            harness.controller.applicationDidDeactivate()
            XCTAssertFalse(harness.controller.snapshot.picking)
            XCTAssertTrue(harness.controller.snapshot.inputs.isEmpty)
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .control)
            try harness.enterNativeDrag([harness.rotated], sequence: 301)
            // Finder already owns the drag; Orange becoming inactive must not
            // cancel this newly armed gesture.
            harness.controller.applicationDidDeactivate()
            XCTAssertTrue(harness.controller.snapshot.armed)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
            XCTAssertEqual(harness.controller.snapshot.mode, .actions)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
        }
    }

    @MainActor func testQueuedMouseUpFromAnEarlierGestureCannotFinishTheNextDrag() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.sample], sequence: 400)
            harness.send(.mouseUp, at: harness.wheelCenter)
            XCTAssertEqual(harness.callbacks.count, 1)
            let originalGeneration = harness.controller.snapshot.generation
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.rotated], sequence: 401)
            XCTAssertNotEqual(harness.controller.snapshot.generation, originalGeneration)
            harness.callbacks.drain()
            XCTAssertTrue(harness.controller.snapshot.armed)
            XCTAssertFalse(harness.controller.snapshot.picking)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
            XCTAssertEqual(harness.controller.snapshot.nativeSequence, 401)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
        }
    }

    @MainActor func testLateOldNativeSessionCannotBindToANewGesture() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.sample], sequence: 500)
            let originalGeneration = harness.controller.snapshot.generation
            harness.send(.cancel)
            harness.send(.mouseUp)
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            let currentGeneration = harness.controller.snapshot.generation
            XCTAssertFalse(harness.controller.bindNativeDrag([harness.sample], sequenceNumber: 500,
                                                            generation: originalGeneration))
            XCTAssertFalse(harness.controller.bindNativeDrag([harness.sample], sequenceNumber: 500,
                                                            generation: currentGeneration))
            let view = try XCTUnwrap(harness.controller.presentedWheel)
            let oldSender = NativeDragInfo(urls: [harness.sample], sequenceNumber: 500)
            XCTAssertEqual(view.draggingEntered(oldSender), [])
            XCTAssertTrue(harness.controller.snapshot.inputs.isEmpty)
            try harness.enterNativeDrag([harness.rotated], sequence: 501)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
        }
    }

    @MainActor func testWindowAndNonfileDragsNeverProduceAFilePicker() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.modifiers, flags: .shift)
            XCTAssertFalse(harness.controller.snapshot.receiverVisible, "A click plus modifier is not a drag")
            harness.send(.mouseUp)
            for payload in [[], [URL(string: "https://example.com/image.png")!]] {
                harness.send(.mouseDown)
                harness.send(.dragged, flags: .shift)
                let view = try XCTUnwrap(harness.controller.presentedWheel)
                let sender = NativeDragInfo(urls: payload, sequenceNumber: 600)
                XCTAssertEqual(view.draggingEntered(sender), [])
                XCTAssertEqual(view.layer?.opacity, 0, "An unverified drag must not show wheel artwork")
                XCTAssertTrue(harness.controller.snapshot.inputs.isEmpty)
                harness.releaseAndDrain()
                XCTAssertFalse(harness.controller.snapshot.picking)
                XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            }
            XCTAssertTrue(harness.model.jobs.isEmpty)
        }
    }

    @MainActor func testFreePointerMovementRecoversFromWindowDragThatConsumesMouseUp() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            XCTAssertTrue(harness.controller.snapshot.armed)
            XCTAssertTrue(harness.controller.snapshot.receiverVisible)
            XCTAssertTrue(harness.controller.snapshot.inputs.isEmpty)
            // Native window dragging can consume mouse-up. A later mouseMoved
            // is evidence of a free pointer, rather than another held drag.
            harness.send(.moved)
            XCTAssertFalse(harness.controller.snapshot.armed)
            XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            XCTAssertFalse(harness.controller.snapshot.picking)
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.rotated], sequence: 610)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
        }
    }

    @MainActor func testOlderCopiedEventsCannotDismissOrChangeTheCurrentDrag() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.sample], sequence: 700)
            let before = harness.controller.snapshot
            harness.controller.receive(DragWheelInput(kind: .mouseDown, timestamp: 0,
                flags: .control, screenPoint: NSPoint(x: -10_000, y: -10_000)))
            harness.controller.receive(DragWheelInput(kind: .mouseUp, timestamp: 0))
            harness.controller.receive(DragWheelInput(kind: .modifiers, timestamp: 0, flags: .command))
            let after = harness.controller.snapshot
            XCTAssertEqual(after.generation, before.generation)
            XCTAssertEqual(after.inputs, before.inputs)
            XCTAssertEqual(after.nativeSequence, before.nativeSequence)
            XCTAssertEqual(after.frame, before.frame)
            XCTAssertEqual(after.mode, .convert)
            XCTAssertTrue(after.armed)
            XCTAssertEqual(harness.callbacks.count, 0)
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
        }
    }

    @MainActor func testNativePayloadBecomingEmptyCancelsBeforeMouseReleaseCanLatchCachedFiles() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            let sender = try harness.enterNativeDrag([harness.rotated], sequence: 710)
            let view = try XCTUnwrap(harness.controller.presentedWheel)
            sender.setFiles([])
            XCTAssertEqual(view.draggingUpdated(sender), [])
            XCTAssertFalse(harness.controller.snapshot.armed)
            XCTAssertTrue(harness.controller.snapshot.inputs.isEmpty)
            harness.releaseAndDrain()
            XCTAssertFalse(harness.controller.snapshot.picking)
            XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            XCTAssertTrue(harness.model.jobs.isEmpty)
        }
    }

    @MainActor func testUnexpectedNewNativeSessionCancelsInsteadOfKeepingEarlierFiles() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.sample], sequence: 720)
            let view = try XCTUnwrap(harness.controller.presentedWheel)
            let replacement = NativeDragInfo(urls: [harness.rotated], sequenceNumber: 721)
            XCTAssertEqual(view.draggingEntered(replacement), [])
            XCTAssertFalse(harness.controller.snapshot.armed)
            XCTAssertTrue(harness.controller.snapshot.inputs.isEmpty)
            harness.releaseAndDrain()
            XCTAssertFalse(harness.controller.snapshot.picking)
            XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            XCTAssertTrue(harness.model.jobs.isEmpty)
        }
    }

    @MainActor func testUnexpectedEmptyNativeSessionCannotLeaveEarlierFilesAvailable() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.sample], sequence: 730)
            let view = try XCTUnwrap(harness.controller.presentedWheel)
            let replacement = NativeDragInfo(urls: [], sequenceNumber: 731)
            XCTAssertEqual(view.draggingEntered(replacement), [])
            XCTAssertTrue(harness.controller.snapshot.inputs.isEmpty)
            XCTAssertNil(harness.controller.snapshot.nativeSequence)
            XCTAssertFalse(harness.controller.snapshot.armed)
            harness.releaseAndDrain()
            XCTAssertFalse(harness.controller.snapshot.picking)
            XCTAssertFalse(harness.controller.snapshot.receiverVisible)
            XCTAssertTrue(harness.model.jobs.isEmpty)
        }
    }

    @MainActor func testModifierModeChangesPreserveTheSameFilesAndReceiverPosition() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.rotated], sequence: 800)
            let originalFrame = harness.controller.snapshot.frame
            for (flags, mode) in [(NSEvent.ModifierFlags.command, WheelMode.tools), (.control, .actions), (.shift, .convert)] {
                harness.send(.modifiers)
                harness.send(.modifiers, flags: flags)
                XCTAssertEqual(harness.controller.snapshot.mode, mode)
                XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
                XCTAssertEqual(harness.controller.snapshot.nativeSequence, 800)
                XCTAssertEqual(harness.controller.snapshot.frame, originalFrame)
            }
            harness.releaseAndDrain()
            harness.send(.modifiers)
            harness.send(.modifiers, flags: .command)
            XCTAssertTrue(harness.controller.snapshot.picking)
            XCTAssertEqual(harness.controller.snapshot.mode, .tools)
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
        }
    }

    @MainActor func testSourceThatOnlyAllowsMoveNeverReceivesAMoveOperation() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .control)
            let view = try XCTUnwrap(harness.controller.presentedWheel)
            let sender = NativeDragInfo(urls: [harness.rotated], sequenceNumber: 900, sourceOperationMask: .move)
            XCTAssertEqual(view.draggingEntered(sender), [])
            XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
            XCTAssertTrue(harness.model.jobs.isEmpty)
        }
    }

    @MainActor func testMouseDragFlagsSwitchModesWithoutSeparateModifierNotifications() async throws {
        try await withHarness { harness in
            harness.send(.mouseDown)
            harness.send(.dragged, flags: .shift)
            try harness.enterNativeDrag([harness.rotated], sequence: 910)
            let originalFrame = harness.controller.snapshot.frame
            // Mouse events carry their own modifier snapshot. Mode switching
            // must work even when no flagsChanged notification is delivered.
            for (flags, mode) in [(NSEvent.ModifierFlags.command, WheelMode.tools), (.control, .actions), (.shift, .convert)] {
                harness.send(.dragged, flags: flags)
                XCTAssertEqual(harness.controller.snapshot.mode, mode)
                XCTAssertTrue(harness.controller.snapshot.armed)
                XCTAssertEqual(harness.controller.snapshot.inputs, [harness.rotated])
                XCTAssertEqual(harness.controller.snapshot.nativeSequence, 910)
                XCTAssertEqual(harness.controller.snapshot.frame, originalFrame)
            }
            harness.releaseAndDrain()
            XCTAssertTrue(harness.controller.snapshot.picking)
        }
    }

    @MainActor private func withHarness(_ body: (Harness) throws -> Void) async rethrows {
        let harness = Harness()
        do { try body(harness) }
        catch {
            await harness.shutdown()
            throw error
        }
        await harness.shutdown()
    }
}

@MainActor private final class DeferredDragCallbacks {
    typealias Action = @MainActor @Sendable () -> Void
    private var actions: [Action] = []
    var count: Int { actions.count }
    func append(_ action: @escaping Action) { actions.append(action) }
    func drain() {
        while !actions.isEmpty { actions.removeFirst()() }
    }
}

@MainActor private final class Harness {
    let model: AppModel
    let callbacks: DeferredDragCallbacks
    let controller: DragWheelController
    let sample: URL
    let rotated: URL
    private var timestamp: TimeInterval = 0

    init() {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        sample = root.appendingPathComponent("build/verification/sample.png")
        rotated = root.appendingPathComponent("build/verification/sample-rotated.png")
        let model = AppModel(persistPreferences: false)
        model.soundFeedback = false
        model.wheelEnabled = true
        model.wheelDiameter = 252
        model.conversionShortcut = .shift
        model.toolsShortcut = .command
        model.actionsShortcut = .control
        self.model = model
        let callbacks = DeferredDragCallbacks()
        self.callbacks = callbacks
        controller = DragWheelController(model: model, capabilityLoader: { urls in
            SelectionCapabilities(formats: [.jpeg, .png, .pdf], tools: [.rotate],
                                  families: urls.map { _ in .image }, singleFileByteCount: 100)
        }, afterDragCallback: { callbacks.append($0) })
    }

    var wheelCenter: NSPoint {
        guard let frame = controller.snapshot.frame else { return NSPoint(x: 500, y: 500) }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    func send(_ kind: DragWheelInput.Kind, flags: NSEvent.ModifierFlags = [],
              at point: NSPoint? = NSPoint(x: 500, y: 500)) {
        timestamp += 1
        controller.receive(DragWheelInput(kind: kind, timestamp: timestamp, flags: flags, screenPoint: point))
    }

    @discardableResult func enterNativeDrag(_ urls: [URL], sequence: Int) throws -> NativeDragInfo {
        let view = try XCTUnwrap(controller.presentedWheel)
        let sender = NativeDragInfo(urls: urls, sequenceNumber: sequence, location: NSPoint(x: 186, y: 270))
        sender.draggingDestinationWindow = view.window
        XCTAssertEqual(view.draggingEntered(sender), .copy)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        return sender
    }

    func releaseAndDrain() {
        send(.mouseUp, at: wheelCenter)
        callbacks.drain()
    }

    func shutdown() async {
        await controller.stop()
        callbacks.drain()
        await model.shutdown()
    }
}
