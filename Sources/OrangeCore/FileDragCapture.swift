import Foundation

/// Binds files obtained from a native dragging destination to its session.
/// Gesture activation belongs to the caller; named pasteboard state is not used.
public struct FileDragCapture: Sendable {
    public private(set) var inputs: [URL] = []
    public private(set) var sequenceNumber: Int?
    private var isReleased = false

    public init() {}

    @discardableResult public mutating func capture(_ urls: [URL], sequenceNumber: Int) -> Bool {
        guard !isReleased, sequenceNumber >= 0, !urls.isEmpty,
              urls.allSatisfy(\.isFileURL) else { return false }
        if let boundSequence = self.sequenceNumber {
            return sequenceNumber == boundSequence && urls == inputs
        }
        inputs = urls
        self.sequenceNumber = sequenceNumber
        return true
    }

    /// Preserves the bound selection for picking and rejects further drag data.
    public mutating func releaseMouseGesture() { isReleased = true }

    public mutating func reset() {
        inputs = []
        sequenceNumber = nil
        isReleased = false
    }
}
