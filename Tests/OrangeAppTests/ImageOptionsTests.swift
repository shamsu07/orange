import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OrangeCore
@testable import Orange

final class ImageOptionsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        folder = root.appendingPathComponent(".cache/tests/image-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    @MainActor func testCropPresetsKeepPhysicalRatioAndDraggingStaysInsideImage() throws {
        let source = try fixture()
        let model = ImageOptionsModel(tool: .crop, sources: [source], thumbnail: nil, settings: ConversionSettings())
        model.applyAspect(.square)
        XCTAssertEqual(model.cropRect.width * Double(source.dimensions.width), model.cropRect.height * Double(source.dimensions.height), accuracy: 0.001)
        let square = model.cropRect
        model.move(from: square, dx: -5, dy: 5)
        XCTAssertEqual(model.cropRect.x, 0)
        XCTAssertEqual(model.cropRect.y + model.cropRect.height, 1, accuracy: 0.00001)
        XCTAssertTrue(model.cropRect.isValid)
        model.applyAspect(.wide)
        let wide = model.cropRect
        model.resize(.bottomRight, from: wide, dx: 0.2, dy: 0.1)
        let ratio = model.cropRect.width * Double(source.dimensions.width) / (model.cropRect.height * Double(source.dimensions.height))
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertTrue(model.cropRect.isValid)
    }

    @MainActor func testCompressionRequiresMeasuredSavingsAndSkipsLargerCopies() throws {
        let source = try fixture()
        let model = ImageOptionsModel(tool: .compress, sources: [source], thumbnail: nil, settings: ConversionSettings())
        XCTAssertNil(model.selection(estimates: [:]))
        let larger = ImageConverter.EncodingPreview(originalBytes: 1000, encodedBytes: 1001, dimensions: source.dimensions)
        XCTAssertNil(model.selection(estimates: [source.url: larger]))
        let smaller = ImageConverter.EncodingPreview(originalBytes: 1000, encodedBytes: 500, dimensions: source.dimensions)
        XCTAssertEqual(model.selection(estimates: [source.url: smaller])?.inputs, [source.url])
        XCTAssertNil(model.selection(estimates: [source.url: smaller])?.cropRect)
    }

    @MainActor func testDebounceDiscardsAnOlderEstimateAndCancelCannotPublish() async throws {
        let source = try fixture()
        let recorder = EstimateRecorder()
        let workers = PreviewTaskGroup()
        let preview = ImageEncodingPreviewModel(taskGroup: workers, debounce: .milliseconds(40)) { _, _, settings in
            recorder.record(settings.maxDimension)
            return ImageConverter.EncodingPreview(originalBytes: 1000, encodedBytes: Int64(settings.maxDimension), dimensions: source.dimensions)
        }
        var first = ConversionSettings(); first.maxDimension = 90
        var second = first; second.maxDimension = 45
        preview.schedule(.resize, urls: [source.url], settings: first)
        preview.schedule(.resize, urls: [source.url], settings: second)
        await workers.drain()
        XCTAssertEqual(recorder.values, [45])
        XCTAssertEqual(preview.estimates[source.url]?.encodedBytes, 45)
        preview.schedule(.resize, urls: [source.url], settings: first)
        preview.cancel()
        await workers.drain()
        XCTAssertEqual(recorder.values, [45])
        XCTAssertTrue(preview.estimates.isEmpty)
        XCTAssertFalse(preview.isEstimating)
    }

    @MainActor func testResizeEstimateSettingsMatchQualityAndMetadataChoice() throws {
        let source = try fixture()
        var settings = ConversionSettings(); settings.quality = 0.43; settings.stripMetadata = true
        let model = ResizeOptionsModel(sources: [source], preferredMaximum: 64, settings: settings)
        XCTAssertEqual(model.previewSettings?.quality, settings.quality)
        XCTAssertEqual(model.previewSettings?.stripMetadata, true)
        XCTAssertEqual(model.previewSettings?.maxDimension, 64)
    }

    @MainActor func testShutdownJoinsRetiredEncoderBeforeCleanupAndRejectsNewWork() async throws {
        let source = try fixture()
        let marker = folder.appendingPathComponent("in-progress-preview")
        let blocking = BlockingEstimateEncoder(marker: marker, dimensions: source.dimensions)
        let group = PreviewTaskGroup()
        var retired: ImageEncodingPreviewModel? = ImageEncodingPreviewModel(taskGroup: group, debounce: .zero) { _, _, _ in
            try blocking.encode()
        }
        retired?.schedule(.resize, urls: [source.url], settings: ConversionSettings())
        let deadline = Date().addingTimeInterval(2)
        while !blocking.hasStarted && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(blocking.hasStarted)
        guard blocking.hasStarted else { blocking.finish(); await retired?.shutdown(); return }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        retired?.cancel()
        retired = nil
        let newerCalls = EstimateRecorder()
        let current = ImageEncodingPreviewModel(taskGroup: group, debounce: .milliseconds(100)) { _, _, _ in
            newerCalls.record(1)
            return ImageConverter.EncodingPreview(originalBytes: 1000, encodedBytes: 500, dimensions: source.dimensions)
        }
        current.schedule(.resize, urls: [source.url], settings: ConversionSettings())
        var didFinish = false
        let shutdown = Task { await current.shutdown(); didFinish = true }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(didFinish, "Shutdown must join the cancelled encoder before returning.")
        XCTAssertFalse(blocking.hasCleanedUp)
        blocking.finish()
        await shutdown.value
        XCTAssertTrue(didFinish)
        XCTAssertTrue(blocking.hasCleanedUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(newerCalls.values, [])
        current.schedule(.resize, urls: [source.url], settings: ConversionSettings())
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(newerCalls.values, [], "Shutdown models must not start another encoder.")
        XCTAssertTrue(current.estimates.isEmpty)
    }

    private func fixture() throws -> ResizeSource {
        let input = folder.appendingPathComponent("image.png")
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try XCTUnwrap(ResizeSource.load([input]).first)
    }
}

private final class EstimateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ value: Int) { lock.lock(); recorded.append(value); lock.unlock() }
}

private final class BlockingEstimateEncoder: @unchecked Sendable {
    private let condition = NSCondition()
    private var allowedToFinish = false
    private var began = false
    private var cleaned = false
    private let marker: URL
    let dimensions: ImageConverter.Dimensions

    init(marker: URL, dimensions: ImageConverter.Dimensions) { self.marker = marker; self.dimensions = dimensions }
    var hasStarted: Bool { condition.lock(); defer { condition.unlock() }; return began }
    var hasCleanedUp: Bool { condition.lock(); defer { condition.unlock() }; return cleaned }
    func finish() { condition.lock(); allowedToFinish = true; condition.broadcast(); condition.unlock() }
    func encode() throws -> ImageConverter.EncodingPreview {
        try Data("temporary encoded bytes".utf8).write(to: marker)
        defer {
            try? FileManager.default.removeItem(at: marker)
            condition.lock(); cleaned = true; condition.unlock()
        }
        condition.lock()
        began = true
        condition.broadcast()
        // Deliberately ignores task cancellation until its synchronous encode
        // returns, matching the cancellation boundary of ImageIO.
        while !allowedToFinish { condition.wait() }
        condition.unlock()
        return ImageConverter.EncodingPreview(originalBytes: 1000, encodedBytes: 500, dimensions: dimensions)
    }
}
