import AppKit
import OrangeCore

@MainActor final class WheelView: NSView {
    var onDrop: ((WheelChoice, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    var onDragReleased: (() -> Void)?
    var onNativeDrag: (([URL], Int) -> Bool)?
    var onNativeDragEnded: ((Int) -> Void)?
    var onDiagnostic: ((String, [String: Any]) -> Void)?
    var onHighlight: (() -> Void)?
    var onMaskChange: ((CGPath) -> Void)?
    private(set) var isPreview = false
    private var interaction = WheelInteraction()
    private var nativeSequence: Int?
    private var nativePasteboardChangeCount: Int?
    private var isLoading = false
    var isPicking: Bool { interaction.phase == .picking }
    private var allChoices: [WheelChoice] = []
    private var choices: [WheelChoice] { Array(allChoices.dropFirst(page * 8).prefix(8)) }
    private var page = 0
    private var pageCount: Int { max(1, (allChoices.count + 7) / 8) }
    private var inputs: [URL] = []
    private var mode: WheelMode = .convert
    private var wheelStyle: WheelAppearance = .glass
    private var diameter = WheelGeometry.defaultDiameter
    private var highlighted: Int?
    private var sectors: [(root: CALayer, color: CAGradientLayer, border: CAShapeLayer, text: CATextLayer, path: CGPath)] = []
    private let centerText = CATextLayer()
    private let hintText = CATextLayer()
    private var centerLabel = "—"
    private var tracking: NSTrackingArea?
    private var geometry: WheelGeometry {
        WheelGeometry(center: CGPoint(x: bounds.midX, y: bounds.midY), preferredDiameter: diameter,
                      startAngle: .pi / 2 + .pi / CGFloat(max(choices.count, 1)))
    }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Orange file wheel")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(choices: [WheelChoice], mode: WheelMode, inputs: [URL], appearance: WheelAppearance,
                   diameter: CGFloat, preview: Bool, byteCount: Int64?, duringDrag: Bool = false,
                   loading: Bool = false) {
        let changed = self.allChoices != choices || self.mode != mode || self.inputs != inputs
            || self.wheelStyle != appearance || self.diameter != diameter || isPreview != preview || isLoading != loading
        // Rendering can be reused during capability refreshes, but a dismissed
        // picker must begin a new interaction even for the same selection.
        guard changed || sectors.isEmpty || interaction.phase == .inactive else { return }
        self.allChoices = choices
        self.page = 0
        self.mode = mode
        self.inputs = inputs
        self.wheelStyle = appearance
        self.diameter = diameter
        self.isPreview = preview
        self.isLoading = loading
        interaction.present(duringDrag: duringDrag, preview: preview)
        highlighted = nil
        if preview { centerLabel = "65 KB" }
        else if let byteCount {
            centerLabel = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        } else { centerLabel = inputs.isEmpty ? "…" : "\(inputs.count) files" }
        setAccessibilityValue(choices.map(\.label).joined(separator: ", "))
        rebuild()
    }

    func reset() {
        interaction.cancel()
        select(nil, feedback: false)
        isPreview = false
        isLoading = false
        nativeSequence = nil
        nativePasteboardChangeCount = nil
    }
    func releaseDrag() {
        interaction.releaseDrag()
        // Do not carry the drag's last hovered item into a confirming click.
        select(nil, feedback: false)
        updateHint()
        refreshAccessibility()
    }
    func advancePage() {
        guard pageCount > 1 else { return }
        page = (page + 1) % pageCount
        highlighted = nil
        rebuild()
    }
    override func scrollWheel(with event: NSEvent) { if abs(event.scrollingDeltaY) > 3 { advancePage() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) { if isPreview || isPicking { updateHighlight(event.locationInWindow) } }
    override func mouseDragged(with event: NSEvent) { if interaction.phase != .inactive { updateHighlight(event.locationInWindow) } }
    override func mouseExited(with event: NSEvent) { if isPreview || isPicking { select(nil, feedback: false) } }
    override func mouseDown(with event: NSEvent) {
        guard isPreview || isPicking else { return }
        updateHighlight(event.locationInWindow)
        interaction.press(option: highlighted)
    }
    override func mouseUp(with event: NSEvent) {
        guard isPreview || isPicking else { return }
        updateHighlight(event.locationInWindow)
        if let index = interaction.release(option: highlighted) { commit(index) }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); if !sectors.isEmpty { rebuild() } }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); if !sectors.isEmpty { rebuild() } }

    func refreshAccessibility() {
        let children: [WheelAccessibilityItem] = choices.enumerated().map { index, choice in
            let item = WheelAccessibilityItem()
            item.setAccessibilityRole(.menuItem)
            item.setAccessibilityEnabled(true)
            item.setAccessibilityLabel(choice.label)
            item.setAccessibilityParent(self)
            if sectors.indices.contains(index), let window {
                item.setAccessibilityFrame(window.convertToScreen(convert(sectors[index].path.boundingBox, to: nil)))
            }
            item.onPress = { [weak self] in self?.activate(index) }
            return item
        }
        setAccessibilityChildren(children)
        setAccessibilityHelp(isPreview ? "Use arrow keys or click an option to preview. Press Escape to close." : "Release the mouse and modifier, then click an option. Hovering and releasing the drag do not perform an operation. Press Escape to cancel.")
    }

    private func activate(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        guard let index = interaction.confirm(option: index) else { return }
        commit(index)
    }

    private func commit(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        select(index)
        if !isPreview, !inputs.isEmpty { onDrop?(choices[index], inputs) }
    }

    private func rebuild() {
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.sublayers = nil
        sectors = []
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let foreground: NSColor = dark ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
        let mask = CGMutablePath()
        let geometry = self.geometry
        for (index, choice) in choices.enumerated() {
            guard let angles = geometry.sectorAngle(index: index, count: choices.count) else { continue }
            let path = roundedSector(angles: angles, geometry: geometry)
            mask.addPath(path)
            let root = CALayer()
            root.frame = bounds
            let sectorBounds = path.boundingBox
            var localTransform = CGAffineTransform(translationX: -sectorBounds.minX, y: -sectorBounds.minY)
            let localPath = path.copy(using: &localTransform) ?? path
            let base = CAGradientLayer()
            base.frame = sectorBounds
            let opacity: CGFloat = wheelStyle == .solid ? 1 : 0.88
            base.colors = dark
                ? [NSColor(calibratedWhite: 0.29, alpha: opacity).cgColor, NSColor(calibratedWhite: 0.21, alpha: opacity).cgColor]
                : [NSColor(calibratedWhite: 0.99, alpha: opacity).cgColor, NSColor(calibratedWhite: 0.85, alpha: opacity).cgColor]
            base.startPoint = CGPoint(x: 0.5, y: 1); base.endPoint = CGPoint(x: 0.5, y: 0)
            let baseMask = CAShapeLayer(); baseMask.path = localPath; base.mask = baseMask
            root.addSublayer(base)
            let color = CAGradientLayer()
            color.frame = sectorBounds
            color.colors = [NSColor(calibratedRed: 1, green: 0.70, blue: 0.18, alpha: 1).cgColor,
                            NSColor(calibratedRed: 1, green: 0.48, blue: 0, alpha: 1).cgColor]
            color.startPoint = CGPoint(x: 0.45, y: 1); color.endPoint = CGPoint(x: 0.55, y: 0)
            let colorMask = CAShapeLayer(); colorMask.path = localPath; color.mask = colorMask
            color.opacity = 0
            root.addSublayer(color)
            let border = CAShapeLayer()
            border.path = path
            border.fillColor = nil
            border.strokeColor = NSColor.white.withAlphaComponent(dark ? 0.24 : 0.64).cgColor
            border.lineWidth = 0.6
            root.addSublayer(border)
            let angle = (angles.lowerBound + angles.upperBound) / 2
            let radius = geometry.outerRadius * 0.67
            let point = CGPoint(x: geometry.center.x + cos(angle) * radius, y: geometry.center.y + sin(angle) * radius)
            let isFormat: Bool = { if case .format = choice { return true }; return false }()
            let fontSize: CGFloat = isFormat ? 12.5 : 9
            let text = CATextLayer()
            let label = choice.label.uppercased()
            text.string = label
            text.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            text.fontSize = fontSize
            text.alignmentMode = .center
            text.contentsScale = scale
            text.foregroundColor = foreground.cgColor
            text.frame = CGRect(x: point.x - 37, y: point.y - (isFormat ? 8 : 21), width: 74, height: isFormat ? 18 : 24)
            text.isWrapped = true
            root.addSublayer(text)
            if !isFormat, let image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil) {
                let icon = CALayer()
                icon.frame = CGRect(x: point.x - 9, y: point.y + 5, width: 18, height: 18)
                let tinted = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                    foreground.setFill(); rect.fill(); image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1); return true
                }
                icon.contents = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
                icon.contentsScale = scale
                root.addSublayer(icon)
            }
            layer.addSublayer(root)
            sectors.append((root, color, border, text, path))
        }
        let pillWidth: CGFloat = min(82, max(68, geometry.innerRadius * 1.68))
        let pill = CGRect(x: bounds.midX - pillWidth / 2, y: bounds.midY - 17, width: pillWidth, height: 34)
        let pillPath = CGPath(roundedRect: pill, cornerWidth: 17, cornerHeight: 17, transform: nil)
        mask.addPath(pillPath)
        let center = CAShapeLayer()
        center.path = pillPath
        center.fillColor = (dark ? NSColor(calibratedWhite: 0.40, alpha: 0.50) : NSColor.white.withAlphaComponent(0.55)).cgColor
        center.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        center.lineWidth = 0.6
        layer.addSublayer(center)
        centerText.frame = pill.insetBy(dx: 4, dy: 8)
        centerText.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        centerText.fontSize = 11
        centerText.alignmentMode = .center
        centerText.contentsScale = scale
        centerText.foregroundColor = foreground.cgColor
        centerText.string = choices.isEmpty ? "…" : centerLabel
        layer.addSublayer(centerText)
        hintText.frame = CGRect(x: 10, y: 20, width: bounds.width - 20, height: 20)
        hintText.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hintText.fontSize = 11
        hintText.alignmentMode = .center
        hintText.contentsScale = scale
        hintText.foregroundColor = foreground.withAlphaComponent(0.8).cgColor
        layer.addSublayer(hintText)
        updateHint()
        onMaskChange?(mask)
        refreshAccessibility()
        CATransaction.commit()
        if let highlighted { select(highlighted, feedback: false) }
    }

    /// Rounded annular wedges leave a constant-width seam at both radii.
    private func roundedSector(angles: ClosedRange<CGFloat>, geometry: WheelGeometry) -> CGPath {
        let path = CGMutablePath()
        let outer = geometry.outerRadius - 1
        let inner = geometry.innerRadius + 1
        let gap: CGFloat = 1.35
        let outerCorner: CGFloat = min(13, outer * (angles.upperBound - angles.lowerBound) * 0.16)
        let innerCorner: CGFloat = min(5, inner * (angles.upperBound - angles.lowerBound) * 0.16)
        let top = angles.upperBound
        let bottom = angles.lowerBound
        let outerGap = gap / outer
        let innerGap = gap / inner
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: geometry.center.x + cos(angle) * radius, y: geometry.center.y + sin(angle) * radius)
        }
        path.move(to: point(outer, top - outerGap - outerCorner / outer))
        path.addArc(center: geometry.center, radius: outer, startAngle: top - outerGap - outerCorner / outer,
                    endAngle: bottom + outerGap + outerCorner / outer, clockwise: true)
        path.addQuadCurve(to: point(outer - outerCorner, bottom + outerGap), control: point(outer, bottom + outerGap))
        path.addLine(to: point(inner + innerCorner, bottom + innerGap))
        path.addQuadCurve(to: point(inner, bottom + innerGap + innerCorner / inner), control: point(inner, bottom + innerGap))
        path.addArc(center: geometry.center, radius: inner, startAngle: bottom + innerGap + innerCorner / inner,
                    endAngle: top - innerGap - innerCorner / inner, clockwise: false)
        path.addQuadCurve(to: point(inner + innerCorner, top - innerGap), control: point(inner, top - innerGap))
        path.addLine(to: point(outer - outerCorner, top - outerGap))
        path.addQuadCurve(to: point(outer, top - outerGap - outerCorner / outer), control: point(outer, top - outerGap))
        path.closeSubpath()
        return path
    }

    private func select(_ index: Int?, feedback: Bool = true) {
        let previous = highlighted
        highlighted = index
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduced ? 0 : 0.12)
        for (offset, sector) in sectors.enumerated() {
            let active = offset == index
            sector.color.opacity = active ? 1 : 0
            sector.border.lineWidth = active ? 1 : 0.6
            sector.text.foregroundColor = (active || dark ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)).cgColor
            // Keep drawing and hit geometry identical. Selection fades without
            // moving or resizing the targets under the pointer.
        }
        centerText.string = index.flatMap { choices.indices.contains($0) ? choices[$0].label.uppercased() : nil } ?? centerLabel
        CATransaction.commit()
        if feedback, previous != index, index != nil { onHighlight?() }
    }

    private func updateHint() {
        if isLoading { hintText.string = "Checking files…" }
        else if choices.isEmpty { hintText.string = "No compatible options · Esc to cancel" }
        else { hintText.string = interaction.phase == .dragging ? "Release, then click an option" : isPreview ? "Preview · Esc to close" : "Click an option · Esc to cancel" }
    }

    private func updateHighlight(_ location: NSPoint) {
        let point = convert(location, from: nil)
        let candidate = geometry.hitTest(point: point, itemCount: choices.count)
        let next = candidate.flatMap { sectors.indices.contains($0) && sectors[$0].path.contains(point) ? $0 : nil }
        if highlighted != next { select(next) }
    }
    private var acceptsFileDrag: Bool { interaction.phase == .dragging && !inputs.isEmpty }
    private func receiveNativeDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard interaction.phase == .dragging else { return [] }
        let sequence = sender.draggingSequenceNumber
        let count = sender.draggingPasteboard.changeCount
        if nativeSequence != sequence || nativePasteboardChangeCount != count {
            let urls = files(from: sender)
            if let onNativeDrag {
                guard onNativeDrag(urls, sequence) else { return [] }
            } else {
                guard !urls.isEmpty, urls == inputs else {
                    if nativeSequence != nil { reset(); onCancel?() }
                    return []
                }
            }
            guard !urls.isEmpty else { return [] }
            nativeSequence = sequence
            nativePasteboardChangeCount = count
        }
        guard acceptsFileDrag else { return [] }
        updateHighlight(sender.draggingLocation)
        // Never tell Finder to move/delete its original. If its current mask
        // disallows copy, the explicit picker can still latch on mouse release.
        if sender.draggingSourceOperationMask.contains(.copy) { return .copy }
        if sender.draggingSourceOperationMask.contains(.generic) { return .generic }
        return []
    }
    private func files(from sender: NSDraggingInfo) -> [URL] {
        let board = sender.draggingPasteboard
        let before = board.changeCount
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let after = board.changeCount
        nativeDiagnostic("native.payload_read", sender, fields: ["readBefore": before, "readAfter": after,
                         "readCount": urls.count, "extensions": urls.map { $0.pathExtension.lowercased() }])
        return before == after ? urls : []
    }
    private func validateNativeDrop(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsFileDrag else { return false }
        guard nativeSequence == sender.draggingSequenceNumber, files(from: sender) == inputs else {
            reset()
            onCancel?()
            return false
        }
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        nativeDiagnostic("native.entered", sender)
        let result = receiveNativeDrag(sender)
        nativeDiagnostic("native.enter_result", sender, fields: ["operation": result.rawValue])
        return result
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        nativeDiagnostic("native.updated", sender, sample: true)
        return receiveNativeDrag(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender { nativeDiagnostic("native.exited", sender) }
        select(nil, feedback: false)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        nativeDiagnostic("native.prepare", sender)
        return validateNativeDrop(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        nativeDiagnostic("native.perform", sender)
        guard validateNativeDrop(sender) else { return false }
        return completeDrag(with: inputs)
    }
    @discardableResult func completeDrag(with urls: [URL]) -> Bool {
        // Once released, the picker owns a fixed file selection. A later drag
        // must not replace its inputs while keeping the old capabilities.
        guard acceptsFileDrag else { return false }
        guard !urls.isEmpty, urls == inputs else {
            reset()
            onCancel?()
            return false
        }
        releaseDrag()
        onDragReleased?()
        return true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        nativeDiagnostic("native.ended", sender)
        if interaction.phase == .dragging { onNativeDragEnded?(sender.draggingSequenceNumber) }
    }

    private var lastDiagnosticSample: TimeInterval = 0
    private func nativeDiagnostic(_ event: String, _ sender: NSDraggingInfo,
                                  fields: [String: Any] = [:], sample: Bool = false) {
        guard let onDiagnostic else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if sample && now - lastDiagnosticSample < 0.025 { return }
        if sample { lastDiagnosticSample = now }
        var values: [String: Any] = ["sequence": sender.draggingSequenceNumber,
            "pasteboardChangeCount": sender.draggingPasteboard.changeCount,
            "pasteboardTypes": sender.draggingPasteboard.types?.map(\.rawValue) ?? [],
            "sourceOperations": sender.draggingSourceOperationMask.rawValue,
            "dragPoint": [sender.draggingLocation.x, sender.draggingLocation.y],
            "destinationWindow": sender.draggingDestinationWindow?.windowNumber ?? -1,
            "viewPhase": String(describing: interaction.phase), "viewBoundSequence": nativeSequence ?? -1]
        values.merge(fields, uniquingKeysWith: { _, new in new })
        onDiagnostic(event, values)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if (isPreview || isPicking), !choices.isEmpty, [123, 124, 125, 126].contains(event.keyCode) {
            let delta = [123, 126].contains(event.keyCode) ? -1 : 1
            select(((highlighted ?? (delta > 0 ? -1 : 0)) + delta + choices.count) % choices.count)
        } else if (isPreview || isPicking), [36, 49, 76].contains(event.keyCode), let highlighted {
            activate(highlighted)
        } else { super.keyDown(with: event) }
    }
}

@MainActor private final class WheelAccessibilityItem: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}
