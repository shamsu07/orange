import XCTest
import ImageIO
import UniformTypeIdentifiers
import OrangeCore
@testable import Orange

final class ImageQueueTests: XCTestCase {
    @MainActor func testCropWaitsForConfirmationAndPreservesChosenRectangle() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".cache/tests/image-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: input)
        let presenter = QueueImagePresenter()
        let model = AppModel(persistPreferences: false, imagePresenter: presenter)
        model.revealOnCompletion = false; model.soundFeedback = false
        model.perform(.tool(.crop), urls: [input])
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(presenter.tool, .crop)
        presenter.complete(.success(ImageEditSelection(inputs: [input], quality: 0.82,
                                                       cropRect: NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 0.5))))
        let deadline = Date().addingTimeInterval(5)
        while model.activeCount > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.state, .complete, job.message ?? "No result")
        let dimensions = try ImageConverter.dimensions(of: XCTUnwrap(job.outputs.first))
        XCTAssertEqual(dimensions.width, 40); XCTAssertEqual(dimensions.height, 20)
        XCTAssertEqual(try Data(contentsOf: input), original)
        model.perform(.tool(.compress), urls: [input])
        presenter.complete(.success(nil))
        XCTAssertEqual(model.jobs.count, 1)
        await model.shutdown()
    }
}

@MainActor private final class QueueImagePresenter: ImageOptionsPresenting {
    var tool: ToolKind?
    var completion: (@MainActor (Result<ImageEditSelection?, Error>) -> Void)?
    func choose(_ tool: ToolKind, urls: [URL], preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ImageEditSelection?, Error>) -> Void) {
        self.tool = tool; self.completion = completion
    }
    func complete(_ result: Result<ImageEditSelection?, Error>) { let action = completion; completion = nil; action?(result) }
    func cancel() { completion = nil }
}
