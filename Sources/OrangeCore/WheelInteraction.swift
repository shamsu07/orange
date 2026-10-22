/// A drag opens the picker; it never confirms an operation. A fresh click on the
/// same option, or an explicit keyboard/accessibility action, is required.
public struct WheelInteraction: Sendable {
    public enum Phase: Sendable { case inactive, dragging, picking, preview }
    public private(set) var phase: Phase = .inactive
    private var pressedOption: Int?

    public init() {}
    public mutating func present(duringDrag: Bool, preview: Bool = false) {
        phase = preview ? .preview : duringDrag ? .dragging : .picking
        pressedOption = nil
    }
    public mutating func releaseDrag() {
        if phase == .dragging { phase = .picking; pressedOption = nil }
    }
    public mutating func cancel() { phase = .inactive; pressedOption = nil }
    public mutating func press(option: Int?) {
        pressedOption = (phase == .picking || phase == .preview) ? option.flatMap { $0 >= 0 ? $0 : nil } : nil
    }
    public mutating func release(option: Int?) -> Int? {
        defer { pressedOption = nil }
        guard (phase == .picking || phase == .preview), let option, option >= 0, option == pressedOption else { return nil }
        if phase != .preview { phase = .inactive }
        return option
    }
    public mutating func confirm(option: Int?) -> Int? {
        guard (phase == .picking || phase == .preview), let option, option >= 0 else { return nil }
        pressedOption = nil
        if phase != .preview { phase = .inactive }
        return option
    }
}
