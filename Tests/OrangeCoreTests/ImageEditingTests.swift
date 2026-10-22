import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import OrangeCore

final class ImageEditingTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        folder = root.appendingPathComponent(".cache/tests/image-edits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testResizePreviewUsesTheFinalEncoderAndCleansItsIsolatedDirectory() throws {
        let input = try writeNoise(name: "image.png", type: UTType.png.identifier, quality: 1)
        let previews = folder.appendingPathComponent("previews")
        var settings = ConversionSettings(); settings.maxDimension = 64
        let original = try Data(contentsOf: input)
        let estimate = try ImageConverter.preview(.resize, input: input, settings: settings, temporaryRoot: previews)
        XCTAssertEqual(estimate.dimensions.width, 64)
        XCTAssertEqual(estimate.dimensions.height, 48)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previews.path), [])
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["previews", "image.png"])
        let output = try XCTUnwrap(ImageConverter.apply(.resize, to: input, settings: settings).outputs.first)
        XCTAssertEqual(estimate.encodedBytes, Int64(try Data(contentsOf: output).count))
    }

    func testCompressionPreviewMatchesFinalBytesAndKeepsPixelDimensions() throws {
        let input = try writeNoise(name: "photo.jpg", type: UTType.jpeg.identifier, quality: 1)
        var settings = ConversionSettings(); settings.quality = 0.2
        let estimate = try ImageConverter.preview(.compress, input: input, settings: settings, temporaryRoot: folder)
        XCTAssertTrue(estimate.savesBytes)
        XCTAssertEqual(estimate.dimensions.width, 128)
        XCTAssertEqual(estimate.dimensions.height, 96)
        let output = try XCTUnwrap(ImageConverter.apply(.compress, to: input, settings: settings).outputs.first)
        XCTAssertEqual(estimate.encodedBytes, Int64(try Data(contentsOf: output).count))
        XCTAssertEqual(try ImageConverter.dimensions(of: output), estimate.dimensions)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("orange-image-preview-") || $0.hasPrefix(".orange-") })
    }

    func testCompressionThatWouldGrowTheFileCreatesNothing() throws {
        let input = try writeNoise(name: "small.jpg", type: UTType.jpeg.identifier, quality: 0.05)
        var settings = ConversionSettings(); settings.quality = 1
        let estimate = try ImageConverter.preview(.compress, input: input, settings: settings, temporaryRoot: folder)
        XCTAssertFalse(estimate.savesBytes)
        XCTAssertThrowsError(try ImageConverter.apply(.compress, to: input, settings: settings)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No copy was created"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["small.jpg"])
    }

    func testCropUsesDisplayOrientationAndTopLeftCoordinates() throws {
        let input = folder.appendingPathComponent("oriented.tiff")
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var settings = ConversionSettings()
        settings.cropRect = NormalizedCropRect(x: 0, y: 0, width: 1, height: 0.5)
        let preview = try ImageConverter.preview(.crop, input: input, settings: settings, temporaryRoot: folder)
        let output = try XCTUnwrap(ImageConverter.apply(.crop, to: input, settings: settings).outputs.first)
        XCTAssertEqual(preview.dimensions.width, 20)
        XCTAssertEqual(preview.dimensions.height, 20)
        XCTAssertEqual(try ImageConverter.dimensions(of: output), preview.dimensions)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixel = try rgba(image)
        XCTAssertGreaterThan(pixel[0], 245)
        XCTAssertLessThan(pixel[1], 10)
        settings.cropRect = NormalizedCropRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let bottom = try XCTUnwrap(ImageConverter.apply(.crop, to: input, settings: settings).outputs.first)
        let bottomSource = try XCTUnwrap(CGImageSourceCreateWithURL(bottom as CFURL, nil))
        let bottomImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(bottomSource, 0, nil))
        let bottomPixel = try rgba(bottomImage)
        XCTAssertLessThan(bottomPixel[0], 10)
        XCTAssertGreaterThan(bottomPixel[1], 245)
    }

    func testInvalidCropAndCancelledPreviewLeaveOnlyOriginal() async throws {
        let input = try writeNoise(name: "image.png", type: UTType.png.identifier, quality: 1)
        for rect in [NormalizedCropRect.fullImage, NormalizedCropRect(x: -0.1, y: 0, width: 0.5, height: 0.5),
                     NormalizedCropRect(x: 0.5, y: 0.5, width: 0.6, height: 0.6),
                     NormalizedCropRect(x: 0, y: 0, width: .nan, height: 1),
                     NormalizedCropRect(x: 0, y: 0, width: 0, height: 1)] {
            var settings = ConversionSettings(); settings.cropRect = rect
            XCTAssertThrowsError(try ImageConverter.apply(.crop, to: input, settings: settings))
            XCTAssertThrowsError(try ImageConverter.preview(.crop, input: input, settings: settings, temporaryRoot: folder))
        }
        let previewRoot = folder!
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            var settings = ConversionSettings(); settings.maxDimension = 64
            return try ImageConverter.preview(.resize, input: input, settings: settings, temporaryRoot: previewRoot)
        }
        do { _ = try await task.value; XCTFail("Cancelled preview succeeded") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, received \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["image.png"])
    }

    private func writeNoise(name: String, type: String, quality: Double) throws -> URL {
        var state: UInt32 = 37
        var bytes = [UInt8](repeating: 255, count: 128 * 96 * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 { state = state &* 1_664_525 &+ 1_013_904_223; bytes[index + channel] = UInt8(truncatingIfNeeded: state >> 24) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 128, height: 96, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let centerOffset = ((image.height / 2) * image.width + image.width / 2) * 4
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(canvas.data).assumingMemoryBound(to: UInt8.self).advanced(by: centerOffset), count: 4))
    }
}
