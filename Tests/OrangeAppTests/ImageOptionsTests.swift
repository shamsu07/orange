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
        let preview = ImageEncodingPreviewModel(debounce: .milliseconds(40)) { _, _, settings in
            recorder.record(settings.maxDimension)
            return ImageConverter.EncodingPreview(originalBytes: 1000, encodedBytes: Int64(settings.maxDimension), dimensions: source.dimensions)
        }
        var first = ConversionSettings(); first.maxDimension = 90
        var second = first; second.maxDimension = 45
        preview.schedule(.resize, urls: [source.url], settings: first)
        preview.schedule(.resize, urls: [source.url], settings: second)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.values, [45])
        XCTAssertEqual(preview.estimates[source.url]?.encodedBytes, 45)
        preview.schedule(.resize, urls: [source.url], settings: first)
        preview.cancel()
        try await Task.sleep(for: .milliseconds(100))
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
