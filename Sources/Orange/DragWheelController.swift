import AppKit
import ApplicationServices
import OrangeCore

/// A snapshot of an input event, rather than a mixture of an old event and live
/// mouse/button state. Global monitor delivery is asynchronous.
struct DragWheelInput {
    enum Kind { case mouseDown, dragged, mouseUp, moved, modifiers, rightMouseDown, cancel }
    let kind: Kind
    let timestamp: TimeInterval
    var flags: NSEvent.ModifierFlags = []
    var screenPoint: NSPoint?
    var origin = "injected"
    var windowNumber = 0
}

@MainActor final class DragWheelController {
    struct Snapshot {
        let generation: UInt64
        let armed: Bool
        let picking: Bool
        let receiverVisible: Bool
        let mode: WheelMode
        let inputs: [URL]
        let nativeSequence: Int?
        let frame: NSRect?
    }

    private let model: AppModel
    private let feedback = WheelFeedback()
    private let haptics = WheelHaptics()
    private let trace = WheelActivationTrace.makeIfEnabled()
    private let capabilityLoader: @Sendable ([URL]) -> SelectionCapabilities
    private let afterDragCallback: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var recoveryMonitor: Any?
    private var keyboardMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    private var renderedAppearance: WheelAppearance?
    private var renderedDiameter: Double?
    private var renderedReduceTransparency: Bool?
    private var panel: NSPanel?
    private var wheelView: WheelView?
    private var effectView: NSVisualEffectView?
    private var dragCapture = FileDragCapture()
    private var inputs: [URL] { dragCapture.inputs }
    private var generation: UInt64 = 0
    private var retiredSequences: [Int] = []
    private var lastTimestamp = -TimeInterval.infinity
    private var mouseIsDown = false
    private var hasDragged = false
    private var lastPoint = NSPoint.zero
    private var lastFlags: NSEvent.ModifierFlags = []
    private var dragActive = false
    private var suppressedUntilRelease = false
    private var currentMode: WheelMode = .convert
    private var capabilities = SelectionCapabilities()
    private var capabilitiesLoaded = false
    private var capabilityTasks: [UUID: Task<Void, Never>] = [:]

    init(model: AppModel,
         capabilityLoader: @escaping @Sendable ([URL]) -> SelectionCapabilities = { SelectionCapabilities.load($0) },
         afterDragCallback: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
             DispatchQueue.main.async(execute: action)
         }) {
        self.model = model
        self.capabilityLoader = capabilityLoader
        self.afterDragCallback = afterDragCallback
        model.onVisualPreferencesChange = { [weak self] in self?.refreshVisualPreferences() }
        record("controller.created", fields: ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "test"])
    }

    var snapshot: Snapshot {
        Snapshot(generation: generation, armed: dragActive, picking: wheelView?.isPicking == true,
                 receiverVisible: panel?.isVisible == true, mode: currentMode, inputs: inputs,
                 nativeSequence: dragCapture.sequenceNumber, frame: panel?.frame)
    }

    var presentedWheel: WheelView? { wheelView }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                          .flagsChanged, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, origin: "global") }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask.union([.mouseMoved, .keyDown])) { [weak self] event in
            let cancel = MainActor.assumeIsolated {
                let cancel = event.type == .keyDown && event.keyCode == 53 && self?.panel?.isVisible == true
                self?.handle(event, origin: "local")
                return cancel
            }
            return cancel ? nil : event
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidDeactivate() }
        }
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshVisualPreferences() } }
        record("monitors.started", fields: ["global": globalMonitor != nil, "local": localMonitor != nil,
                                            "accessibilityTrusted": AXIsProcessTrusted(),
                                            "listenEventAccess": CGPreflightListenEventAccess()])
    }

    func stop() async {
        endDrag(reason: "stop")
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver); self.deactivationObserver = nil }
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver); self.displayObserver = nil }
        model.onVisualPreferencesChange = nil
        let pending = Array(capabilityTasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        capabilityTasks.removeAll()
        record("controller.stopped")
        await trace?.flush()
    }

    func preview() {
        endDrag(reason: "preview")
        NSApp.activate(ignoringOtherApps: true)
        show(mode: .convert, at: NSEvent.mouseLocation, preview: true)
    }

    func applicationDidDeactivate() {
        record("application.deactivated")
        // Do not cancel a Finder-owned drag just because Orange is inactive.
        if wheelView?.isPicking == true || wheelView?.isPreview == true { endDrag(reason: "application_deactivated_picker") }
    }

    private func handle(_ event: NSEvent, origin: String) {
        let kind: DragWheelInput.Kind
        switch event.type {
        case .leftMouseDown: kind = .mouseDown
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .mouseUp
        case .mouseMoved: kind = .moved
        case .flagsChanged: kind = .modifiers
        case .rightMouseDown: kind = .rightMouseDown
        case .keyDown where event.keyCode == 53: kind = .cancel
        default: return
        }
        let isMouse = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .rightMouseDown].contains(event.type)
        let point = isMouse ? (event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow) : nil
        receive(DragWheelInput(kind: kind, timestamp: event.timestamp, flags: event.modifierFlags,
                              screenPoint: point, origin: origin, windowNumber: event.windowNumber))
    }

    func receive(_ input: DragWheelInput) {
        record("input.received", input: input, sample: input.kind == .dragged || input.kind == .moved)
        guard input.timestamp >= lastTimestamp else {
            record("input.rejected", fields: ["reason": "old_timestamp"], input: input)
            return
        }
        lastTimestamp = input.timestamp
        if let point = input.screenPoint { lastPoint = point }
        let flags = input.flags.intersection([.shift, .command, .control, .option])
        let pressed = flags.subtracting(lastFlags)

        switch input.kind {
        case .cancel, .rightMouseDown:
            endDrag(reason: "cancel_or_right_mouse")
            suppressedUntilRelease = mouseIsDown
            return
        case .mouseDown:
            if wheelView?.isPreview == true, panel?.frame.contains(lastPoint) != true { return }
            if wheelView?.isPicking == true || wheelView?.isPreview == true {
                if panel?.frame.contains(lastPoint) == true {
                    record("input.rejected", fields: ["reason": "click_inside_picker"], input: input)
                    return
                }
            }
            endDrag(reason: "new_mouse_down")
            mouseIsDown = true
            hasDragged = false
            suppressedUntilRelease = false
            lastFlags = flags
            return
        case .mouseUp:
            mouseIsDown = false
            hasDragged = false
            suppressedUntilRelease = false
            guard dragActive else { return }
            let token = generation
            let point = lastPoint
            record("finish.scheduled", fields: ["capturedGeneration": token, "source": "mouse_up"])
            afterDragCallback { [weak self] in self?.finishDrag(generation: token, releasePoint: point) }
            return
        case .moved:
            // Some native window drags consume mouse-up. A later free-pointer
            // event proves that the held gesture ended; no live button poll is
            // needed, and an unbound transparent receiver cannot linger.
            mouseIsDown = false
            hasDragged = false
            suppressedUntilRelease = false
            if dragActive { finishDrag(generation: generation, releasePoint: lastPoint) }
            return
        case .dragged:
            guard wheelView?.isPicking != true, wheelView?.isPreview != true else {
                record("input.rejected", fields: ["reason": "drag_while_picker_or_preview"], input: input, sample: true)
                return
            }
            if !mouseIsDown {
                // A monitor can attach mid-gesture or miss an activation click.
                // The dragged event itself establishes a held mouse gesture.
                endDrag(reason: "infer_missed_mouse_down")
                mouseIsDown = true
            }
            hasDragged = true
        case .modifiers: break
        }

        lastFlags = flags
        guard model.wheelEnabled else { endDrag(reason: "disabled"); return }
        guard !suppressedUntilRelease, wheelView?.isPreview != true else {
            record("input.rejected", fields: ["reason": "suppressed_or_preview"], input: input, sample: true)
            return
        }
        guard let mode = WheelMode.allCases.first(where: { model.shortcut(for: $0).flags == flags }) else {
            record("input.rejected", fields: ["reason": "no_shortcut_match"], input: input, sample: true)
            return
        }

        if wheelView?.isPicking == true {
            guard !pressed.isEmpty else { return }
            if mode == currentMode { wheelView?.advancePage() }
            else { show(mode: mode, at: lastPoint) }
        } else if mouseIsDown && hasDragged {
            if !dragActive {
                dragActive = true
                observeMissingMouseUp()
                show(mode: mode, at: lastPoint)
            } else if mode != currentMode {
                // Mouse events carry modifiers too, even if a separate global
                // keyboard notification is unavailable or arrives later.
                show(mode: mode, at: lastPoint)
            } else if !pressed.isEmpty && input.kind == .modifiers {
                wheelView?.advancePage()
            }
        } else {
            record("input.rejected", fields: ["reason": "no_held_drag"], input: input)
        }
    }

    private func observeMissingMouseUp() {
        guard globalMonitor != nil, recoveryMonitor == nil else { return }
        recoveryMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, origin: "recovery") }
        }
        record("recovery.started", fields: ["installed": recoveryMonitor != nil])
    }

    private func stopRecoveryMonitor() {
        if let recoveryMonitor {
            NSEvent.removeMonitor(recoveryMonitor)
            self.recoveryMonitor = nil
            record("recovery.stopped")
        }
    }

    /// Only NSDraggingInfo supplies file identity. A named drag pasteboard is
    /// neither an activation gate nor a fallback for a missing native payload.
    @discardableResult func bindNativeDrag(_ urls: [URL], sequenceNumber: Int, generation token: UInt64) -> Bool {
        record("binding.request", fields: ["sequence": sequenceNumber, "urlCount": urls.count, "capturedGeneration": token])
        guard token == generation, dragActive, !retiredSequences.contains(sequenceNumber) else {
            record("binding.rejected", fields: ["reason": token != generation ? "stale_generation" : !dragActive ? "not_armed" : "retired_sequence",
                                                 "sequence": sequenceNumber, "capturedGeneration": token])
            return false
        }
        let wasEmpty = inputs.isEmpty
        guard dragCapture.capture(urls, sequenceNumber: sequenceNumber) else {
            record("binding.rejected", fields: ["reason": "invalid_or_changed_payload", "sequence": sequenceNumber, "urlCount": urls.count])
            if dragCapture.sequenceNumber != nil { endDrag(reason: "invalid_native_payload") }
            return false
        }
        if wasEmpty {
            model.onBeginFinderInteraction?()
            loadCapabilities(urls, generation: token)
            show(mode: currentMode, at: lastPoint)
        }
        record("binding.accepted", fields: ["sequence": sequenceNumber, "firstBinding": wasEmpty])
        return true
    }

    private func loadCapabilities(_ urls: [URL], generation token: UInt64) {
        for task in capabilityTasks.values { task.cancel() }
        capabilities = SelectionCapabilities()
        capabilitiesLoaded = false
        let loader = capabilityLoader
        let id = UUID()
        record("capabilities.requested", fields: ["request": id.uuidString, "capturedGeneration": token, "urlCount": urls.count])
        capabilityTasks[id] = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { loader(urls) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self else { return }
            defer { self.capabilityTasks[id] = nil }
            guard !Task.isCancelled, self.generation == token, self.inputs == urls,
                  self.dragActive || self.wheelView?.isPicking == true else {
                self.record("capabilities.discarded", fields: ["request": id.uuidString, "capturedGeneration": token, "cancelled": Task.isCancelled])
                return
            }
            self.capabilities = result
            self.capabilitiesLoaded = true
            self.record("capabilities.loaded", fields: ["request": id.uuidString, "formats": result.formats.count, "tools": result.tools.count])
            if self.panel?.isVisible == true { self.show(mode: self.currentMode, at: self.lastPoint) }
        }
    }

    private func finishDrag(generation token: UInt64, releasePoint: NSPoint? = nil) {
        record("finish.executing", fields: ["capturedGeneration": token, "hasReleasePoint": releasePoint != nil,
                                            "releaseInside": releasePoint.map({ panel?.frame.contains($0) == true }) ?? true])
        guard token == generation, dragActive else { record("finish.discarded"); return }
        guard !inputs.isEmpty, panel?.isVisible == true, wheelView?.isPreview != true,
              releasePoint.map({ panel?.frame.contains($0) == true }) ?? true else { endDrag(reason: "release_without_valid_receiver"); return }
        dragActive = false
        stopRecoveryMonitor()
        dragCapture.releaseMouseGesture()
        wheelView?.releaseDrag()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        panel?.makeFirstResponder(wheelView)
        record("finish.picker_ready")
    }

    private func show(mode: WheelMode, at location: NSPoint, preview: Bool = false, preserveFocus: Bool = false) {
        record("presentation.requested", fields: ["requestedMode": mode.rawValue, "previewRequested": preview, "point": [location.x, location.y]])
        currentMode = mode
        let choices: [WheelChoice] = preview
            ? [.jpeg, .webp, .heic, .tiff, .avif, .bmp, .pdf].map(WheelChoice.format)
            : model.wheelChoices(from: capabilities, inputs: inputs, mode: mode)
        if panel == nil {
            let view = WheelView()
            view.onDrop = { [weak self] choice, urls in
                guard let self else { return }
                self.endDrag(reason: "choice_committed")
                self.afterDragCallback { [weak self] in self?.model.perform(choice, urls: urls) }
            }
            view.onCancel = { [weak self] in self?.endDrag(reason: "view_cancelled") }
            if trace != nil {
                view.onDiagnostic = { [weak self] event, fields in self?.record(event, fields: fields) }
            }
            view.onHighlight = { [weak self] in
                guard let self else { return }
                if self.model.soundFeedback { self.feedback.selection() }
                if self.model.hapticFeedback { self.haptics.selection() }
            }
            let panel = WheelPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.onClose = { [weak self] in self?.endDrag(reason: "panel_closed") }
            panel.delegate = panel
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.acceptsMouseMovedEvents = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let content = NSView()
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            content.addSubview(effect)
            content.addSubview(view)
            panel.contentView = content
            view.onMaskChange = { [weak self] path in
                let mask = CAShapeLayer()
                mask.path = path
                self?.effectView?.layer?.mask = mask
            }
            effectView = effect
            self.panel = panel
            wheelView = view
        }
        let token = generation
        wheelView?.onNativeDrag = { [weak self] urls, sequence in
            self?.bindNativeDrag(urls, sequenceNumber: sequence, generation: token) ?? false
        }
        wheelView?.onDragReleased = { [weak self] in
            self?.record("finish.scheduled", fields: ["capturedGeneration": token, "source": "native_drop"])
            self?.afterDragCallback { [weak self] in self?.finishDrag(generation: token) }
        }
        wheelView?.onNativeDragEnded = { [weak self] sequence in
            self?.record("native.ended_controller", fields: ["sequence": sequence, "capturedGeneration": token])
            guard let self, self.generation == token, self.dragActive,
                  self.dragCapture.sequenceNumber == sequence else { return }
            // A native session ending while its mouse button is still held is
            // a cancellation (for example Escape), not an accepted mouse-up.
            if NSEvent.pressedMouseButtons & 1 != 0 { self.endDrag(reason: "native_ended_while_button_held") }
        }
        let awaitingFiles = !preview && inputs.isEmpty
        // Fully transparent windows can be excluded by native hit testing.
        // Keep the short-lived receiver hit-testable until the session arrives.
        panel?.backgroundColor = awaitingFiles ? NSColor(calibratedWhite: 0.5, alpha: 0.02) : .clear
        panel?.hasShadow = !awaitingFiles
        if !awaitingFiles && model.soundFeedback { feedback.prepare() }
        else { feedback.stop() }
        let side = CGFloat(model.wheelDiameter) + 120
        let wasVisible = panel?.isVisible == true
        let previousFrame = panel?.frame
        if !preserveFocus {
            panel?.styleMask = preview ? [.titled, .closable] : [.borderless, .nonactivatingPanel]
        }
        panel?.title = preview ? "Orange wheel preview" : "Orange file wheel"
        panel?.setContentSize(NSSize(width: side, height: side))
        panel?.contentView?.frame.size = NSSize(width: side, height: side)
        effectView?.frame = NSRect(x: 0, y: 0, width: side, height: side)
        wheelView?.frame = NSRect(x: 0, y: 0, width: side, height: side)
        if !wasVisible || previousFrame?.width != side {
            let anchor = wasVisible ? previousFrame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? location : location
            let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel?.setFrameOrigin(NSPoint(x: max(visible.minX, min(anchor.x - side / 2, visible.maxX - side)),
                                         y: max(visible.minY, min(anchor.y - side / 2, visible.maxY - side))))
        }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        renderedAppearance = model.wheelAppearance
        renderedDiameter = model.wheelDiameter
        renderedReduceTransparency = reduceTransparency
        effectView?.isHidden = awaitingFiles || model.wheelAppearance == .solid || reduceTransparency
        wheelView?.configure(choices: choices, mode: mode, inputs: inputs, appearance: model.wheelAppearance,
                             diameter: CGFloat(model.wheelDiameter), preview: preview,
                             byteCount: capabilities.singleFileByteCount, duringDrag: dragActive,
                             loading: !preview && !awaitingFiles && !capabilitiesLoaded,
                             reduceTransparency: reduceTransparency)
        // Keep the native drop receiver present without showing an empty wheel
        // over unrelated window/text drags. File data makes the artwork visible.
        wheelView?.layer?.opacity = awaitingFiles ? 0 : 1
        wheelView?.refreshAccessibility()
        if preview && !preserveFocus {
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(wheelView)
        } else if !preserveFocus {
            panel?.orderFrontRegardless()
            if !dragActive {
                panel?.makeKey()
                panel?.makeFirstResponder(wheelView)
            }
        }
        observeWheelKeyboard()
        record("presentation.completed", fields: ["awaitingFiles": awaitingFiles, "choices": choices.count,
                                                   "receiverWindowAtPoint": NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)])
    }

    private func refreshVisualPreferences() {
        guard panel?.isVisible == true,
              renderedAppearance != model.wheelAppearance || renderedDiameter != model.wheelDiameter
                || renderedReduceTransparency != NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
        show(mode: currentMode, at: lastPoint, preview: wheelView?.isPreview == true, preserveFocus: true)
    }

    private func observeWheelKeyboard() {
        guard globalMonitor != nil, keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, origin: "wheel_keyboard") }
        }
    }

    private func endDrag(reason: String) {
        record("gesture.ended", fields: ["reason": reason])
        generation &+= 1
        stopRecoveryMonitor()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        if let sequence = dragCapture.sequenceNumber {
            retiredSequences.append(sequence)
            if retiredSequences.count > 64 { retiredSequences.removeFirst() }
        }
        feedback.stop()
        haptics.reset()
        panel?.orderOut(nil)
        wheelView?.reset()
        dragActive = false
        dragCapture.reset()
        for task in capabilityTasks.values { task.cancel() }
        capabilities = SelectionCapabilities()
        capabilitiesLoaded = false
        lastFlags = []
    }

    private func record(_ event: String, fields: @autoclosure () -> [String: Any] = [:],
                        input: DragWheelInput? = nil, sample: Bool = false) {
        guard let trace else { return }
        let sampleKey = sample ? "\(event).\(String(describing: input?.kind)).\(input?.origin ?? "none").\(input?.flags.rawValue ?? 0).\(generation)" : nil
        trace.record(event, fields: traceFields(fields: fields(), input: input), sample: sampleKey)
    }

    private func traceFields(fields: [String: Any], input: DragWheelInput?) -> [String: Any] {
        let livePoint = NSEvent.mouseLocation
        var values: [String: Any] = ["generation": generation, "armed": dragActive, "mouseDown": mouseIsDown,
            "hasDragged": hasDragged, "suppressed": suppressedUntilRelease, "picking": wheelView?.isPicking == true,
            "preview": wheelView?.isPreview == true, "visible": panel?.isVisible == true, "mode": currentMode.rawValue,
            "boundCount": inputs.count, "boundSequence": dragCapture.sequenceNumber ?? -1,
            "appActive": NSApp.isActive, "liveButtons": NSEvent.pressedMouseButtons,
            "liveModifiers": NSEvent.modifierFlags.rawValue, "window": panel?.windowNumber ?? -1,
            "viewOpacity": wheelView?.layer?.opacity ?? -1, "lastEventTimestamp": lastTimestamp.isFinite ? lastTimestamp : -1,
            "recordedPoint": [lastPoint.x, lastPoint.y], "livePoint": [livePoint.x, livePoint.y],
            "recordedModifiers": lastFlags.rawValue,
            "shortcuts": Dictionary(uniqueKeysWithValues: WheelMode.allCases.map { ($0.rawValue, model.shortcut(for: $0).flags.rawValue) }),
            "viewAlpha": wheelView?.alphaValue ?? -1, "occlusionState": panel?.occlusionState.rawValue ?? 0]
        if let panel { values["frame"] = [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height] }
        if let input {
            values["kind"] = String(describing: input.kind)
            values["eventTimestamp"] = input.timestamp
            values["eventModifiers"] = input.flags.rawValue
            values["eventWindow"] = input.windowNumber
            values["origin"] = input.origin
            if let point = input.screenPoint { values["eventPoint"] = [point.x, point.y] }
        }
        values.merge(fields, uniquingKeysWith: { _, new in new })
        return values
    }
}

@MainActor private final class WheelPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
