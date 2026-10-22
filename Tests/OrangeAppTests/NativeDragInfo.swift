import AppKit

/// A native destination sender backed by an isolated test pasteboard.
@MainActor final class NativeDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop: Int
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(urls: [URL], sequenceNumber: Int, location: NSPoint = .zero,
         sourceOperationMask: NSDragOperation = .copy) {
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingSequenceNumber = sequenceNumber
        draggingLocation = location
        draggingSourceOperationMask = sourceOperationMask
        numberOfValidItemsForDrop = urls.count
        super.init()
        setFiles(urls)
    }

    deinit { draggingPasteboard.releaseGlobally() }

    /// Allows a test to simulate a changed payload in the same native session.
    func setFiles(_ urls: [URL]) {
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
        numberOfValidItemsForDrop = urls.count
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
