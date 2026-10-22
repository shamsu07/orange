import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import OrangeCore

final class MediaInspectionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".cache/tests/media-inspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testInspectionReturnsVideoMetadataAndPreviewUsesSelectedTime() throws {
        let input = try clip()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let original = try Data(contentsOf: input)
        let info = try MediaConverter.inspect(input)
        XCTAssertEqual(info.width, 64)
        XCTAssertEqual(info.height, 48)
        XCTAssertEqual(info.duration ?? 0, 2, accuracy: 0.05)
        XCTAssertEqual(info.frameRate ?? 0, 1, accuracy: 0.01)
        XCTAssertTrue(info.hasVideo)
        XCTAssertFalse(info.hasAudio)
        XCTAssertEqual(info.videoCodec, "mpeg4")
        XCTAssertEqual(info.byteCount, Int64(original.count))

        let start = try previewPixel(MediaConverter.previewFrame(input, at: 0))
        let selected = try previewPixel(MediaConverter.previewFrame(input, at: 1))
        XCTAssertGreaterThan(start[0], 200)
        XCTAssertLessThan(start[2], 20)
        XCTAssertLessThan(selected[0], 20)
        XCTAssertGreaterThan(selected[2], 200)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)

        var settings = ConversionSettings()
        settings.trimStart = 1
        let output = try XCTUnwrap(MediaConverter.apply(.snapshot, to: input, settings: settings).outputs.first)
        let snapshot = try previewPixel(Data(contentsOf: output))
        XCTAssertGreaterThan(snapshot[2], 200, "Export must use the chosen frame rather than the first one.")
    }

    func testPreviewRejectsInvalidTimeWithoutCreatingAnOutputBesideSource() throws {
        let input = try clip()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for time in [-1, Double.nan, Double.infinity, 2] {
            XCTAssertThrowsError(try MediaConverter.previewFrame(input, at: time))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
    }

    func testCompressionReportsMeasuredBeforeAndAfterSizesEvenIfLarger() throws {
        let input = try clip()
        guard MediaConverter.tools(for: input).contains(.compress) else { throw XCTSkip("FFmpeg lacks an MP4 encoder.") }
        let result = try MediaConverter.apply(.compress, to: input, settings: ConversionSettings())
        let output = try XCTUnwrap(result.outputs.first)
        let sourceBytes = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let outputBytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: Int64(sourceBytes), countStyle: .file)))
        XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: Int64(outputBytes), countStyle: .file)))
        XCTAssertTrue(message.contains(outputBytes < sourceBytes ? "smaller" : "larger"))
    }

    private func clip() throws -> URL {
        guard let ffmpeg = ProcessRunner.executable(named: "ffmpeg"), ProcessRunner.executable(named: "ffprobe") != nil else {
            throw XCTSkip("FFmpeg and FFprobe are required for media checks.")
        }
        for index in 0...1 {
            let url = directory.appendingPathComponent(String(format: "frame%02d.png", index))
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(index == 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let output = directory.appendingPathComponent("clip.mkv")
        _ = try ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-framerate", "1", "-i", directory.appendingPathComponent("frame%02d.png").path,
            "-c:v", "mpeg4", "-threads", "2", "-t", "2", output.path], timeout: 10)
        return output
    }

    private func previewPixel(_ data: Data) throws -> [UInt8] {
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertLessThanOrEqual(image.width, 960)
        XCTAssertLessThanOrEqual(image.height, 540)
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
