import XCTest
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import OrangeCore

final class ImageMediaTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".cache/tests/images-media-%03d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testPNGToJPEGCompositesTransparencyOnWhiteAndDoesNotOverwrite() throws {
        let input = try writeImage(makeImage(width: 8, height: 6, transparent: true), name: "alpha.png")
        let existing = directory.appendingPathComponent("alpha.jpg")
        let sentinel = Data("existing file".utf8)
        try sentinel.write(to: existing)
        let result = try ImageConverter.convert(input, to: .jpeg, settings: ConversionSettings())
        XCTAssertEqual(result.outputs.first?.lastPathComponent, "alpha 1.jpg")
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let image = try decoded(XCTUnwrap(result.outputs.first))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 6)
        let pixel = try pixelRGBA(image, x: 0, y: 0)
        XCTAssertGreaterThan(pixel[0], 245)
        XCTAssertGreaterThan(pixel[1], 245)
        XCTAssertGreaterThan(pixel[2], 245)
        XCTAssertEqual(pixel[3], 255)
    }

    func testPNGPreservesTransparency() throws {
        let input = try writeImage(makeImage(width: 8, height: 6, transparent: true), name: "alpha.png")
        let output = try XCTUnwrap(ImageConverter.convert(input, to: .png, settings: ConversionSettings()).outputs.first)
        XCTAssertNotEqual(output, input)
        let pixel = try pixelRGBA(decoded(output), x: 0, y: 0)
        XCTAssertEqual(pixel[3], 0)
    }

    func testWebPConversionPreservesAlphaAndNeverOverwrites() throws {
        try requireWebPEncoder()
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.clear(CGRect(x: 0, y: 0, width: 64, height: 32))
        canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        canvas.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        let input = try writeImage(XCTUnwrap(canvas.makeImage()), name: "transparency.png")
        let original = try Data(contentsOf: input)
        let existing = directory.appendingPathComponent("transparency.webp")
        let sentinel = Data("existing output".utf8)
        try sentinel.write(to: existing)
        XCTAssertTrue(ImageConverter.formats(for: input).contains(.webp))
        let output = try XCTUnwrap(ImageConverter.convert(input, to: .webp, settings: ConversionSettings()).outputs.first)
        XCTAssertEqual(output.lastPathComponent, "transparency 1.webp")
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try decoded(output)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 32)
        XCTAssertEqual(try pixelRGBA(image, x: 8, y: 16)[3], 0)
        XCTAssertEqual(Double(try pixelRGBA(image, x: 24, y: 16)[3]), 128, accuracy: 1)
        XCTAssertEqual(try pixelRGBA(image, x: 48, y: 16)[3], 255)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".orange-") })
    }

    func testWebPQualityControlsRealEncodedOutput() throws {
        try requireWebPEncoder()
        var bytes = [UInt8](repeating: 255, count: 128 * 96 * 4)
        var state: UInt32 = 73
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[index + channel] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 128, height: 96, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try writeImage(image, name: "noise.png")
        var settings = ConversionSettings()
        settings.quality = 0.1
        let low = try XCTUnwrap(ImageConverter.convert(input, to: .webp, settings: settings).outputs.first)
        settings.quality = 0.95
        let high = try XCTUnwrap(ImageConverter.convert(input, to: .webp, settings: settings).outputs.first)
        XCTAssertGreaterThan(try Data(contentsOf: high).count, try Data(contentsOf: low).count)
        XCTAssertEqual(try decoded(low).width, 128)
        XCTAssertEqual(try decoded(high).height, 96)
    }

    func testWebPSizeLimitIsNotAdvertisedOrSilentlyResized() throws {
        try requireWebPEncoder()
        let input = try writeImage(makeImage(width: 16_384, height: 1), name: "webp-too-wide.png")
        XCTAssertFalse(ImageConverter.formats(for: input).contains(.webp))
        XCTAssertThrowsError(try ImageConverter.convert(input, to: .webp, settings: ConversionSettings()))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".orange-") })
    }

    func testWebPBackendFailureRemovesBothTemporaryFiles() throws {
        let native = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.webP.identifier)
        guard !native else { throw XCTSkip("This Mac uses the native WebP writer rather than the FFmpeg fallback.") }
        let backend = directory.appendingPathComponent("failing-backend", isDirectory: true)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        let executable = backend.appendingPathComponent("ffmpeg")
        let script = """
        #!/bin/sh
        case "$*" in
          *-encoders*) printf ' V....D libwebp Fixture encoder\\n'; exit 0 ;;
        esac
        for output in "$@"; do :; done
        printf 'partial' > "$output"
        exit 42
        """
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let previous = ProcessInfo.processInfo.environment["ORANGE_BACKEND_DIR"]
        setenv("ORANGE_BACKEND_DIR", backend.path, 1)
        defer {
            if let previous { setenv("ORANGE_BACKEND_DIR", previous, 1) }
            else { unsetenv("ORANGE_BACKEND_DIR") }
        }
        let input = try writeImage(makeImage(width: 8, height: 8, transparent: true), name: "failure.png")
        XCTAssertTrue(ImageConverter.formats(for: input).contains(.webp))
        XCTAssertThrowsError(try ImageConverter.convert(input, to: .webp, settings: ConversionSettings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("42"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("failure.webp").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".orange-") })
    }

    func testResizeAndRotateHaveExpectedDimensions() throws {
        let input = try writeImage(makeImage(width: 80, height: 40), name: "landscape.png")
        var settings = ConversionSettings()
        settings.maxDimension = 20
        let resized = try decoded(XCTUnwrap(ImageConverter.apply(.resize, to: input, settings: settings).outputs.first))
        XCTAssertEqual(resized.width, 20)
        XCTAssertEqual(resized.height, 10)
        let rotated = try decoded(XCTUnwrap(ImageConverter.apply(.rotate, to: input, settings: settings).outputs.first))
        XCTAssertEqual(rotated.width, 40)
        XCTAssertEqual(rotated.height, 80)
    }

    func testResizeDoesNotWriteAFileWhenTheRequestedLimitDoesNotChangeDimensions() throws {
        let input = try writeImage(makeImage(width: 256, height: 128), name: "small.png")
        let original = try Data(contentsOf: input)
        for limit in [1920, 256] {
            var settings = ConversionSettings()
            settings.maxDimension = limit
            XCTAssertThrowsError(try ImageConverter.apply(.resize, to: input, settings: settings)) { error in
                XCTAssertTrue(error.localizedDescription.contains("No copy was created"))
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["small.png"])
    }

    func testResizePixelRoundingMatchesPreviewAndKeepsVeryShortEdgeAtOnePixel() throws {
        for (width, height, outputWidth, outputHeight) in [(101, 67, 31, 21), (1, 101, 1, 31)] {
            let input = try writeImage(makeImage(width: width, height: height), name: "\(width)-\(height).png")
            let size = try ImageConverter.dimensions(of: input)
            let expected = try size.fitting(maximumDimension: 31)
            XCTAssertEqual(expected.width, outputWidth)
            XCTAssertEqual(expected.height, outputHeight)
            var settings = ConversionSettings()
            settings.maxDimension = 31
            let image = try decoded(XCTUnwrap(ImageConverter.apply(.resize, to: input, settings: settings).outputs.first))
            XCTAssertEqual(image.width, expected.width)
            XCTAssertEqual(image.height, expected.height)
        }
    }

    func testResizePreviewAndOutputRespectEXIFOrientation() throws {
        let input = directory.appendingPathComponent("camera.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try makeImage(width: 120, height: 80),
                                  [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let size = try ImageConverter.dimensions(of: input)
        XCTAssertEqual(size.width, 80)
        XCTAssertEqual(size.height, 120)
        let expected = try size.fitting(maximumDimension: 45)
        XCTAssertEqual(expected.width, 30)
        XCTAssertEqual(expected.height, 45)
        var settings = ConversionSettings()
        settings.maxDimension = 45
        let image = try decoded(XCTUnwrap(ImageConverter.apply(.resize, to: input, settings: settings).outputs.first))
        XCTAssertEqual(image.width, expected.width)
        XCTAssertEqual(image.height, expected.height)
    }

    func testOnePixelImageCannotProduceAResizedCopy() throws {
        let input = try writeImage(makeImage(width: 1, height: 1), name: "minimum.png")
        var settings = ConversionSettings()
        settings.maxDimension = 1
        XCTAssertThrowsError(try ImageConverter.apply(.resize, to: input, settings: settings))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["minimum.png"])
    }

    func testRotateMovesLeftPixelToTopForClockwiseRotation() throws {
        let bytes = Data([UInt8(255), 0, 0, 255, 0, 255, 0, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try writeImage(image, name: "two-pixels.png")
        let rotated = try decoded(XCTUnwrap(ImageConverter.apply(.rotate, to: input, settings: ConversionSettings()).outputs.first))
        XCTAssertEqual(try pixelRGBA(rotated, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(try pixelRGBA(rotated, x: 0, y: 1), [0, 255, 0, 255])
    }

    func testPDFOutputIsAReadableSinglePagePDF() throws {
        let input = try writeImage(makeImage(width: 20, height: 10), name: "picture.png")
        let output = try XCTUnwrap(ImageConverter.convert(input, to: .pdf, settings: ConversionSettings()).outputs.first)
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).width, 20)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).height, 10)
    }

    func testStripMetadataRemovesGPSAndDescription() throws {
        let input = directory.appendingPathComponent("private.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 25.0, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 55.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Private description"]
        ]
        CGImageDestinationAddImage(destination, try makeImage(width: 10, height: 10), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let output = try XCTUnwrap(ImageConverter.apply(.stripMetadata, to: input, settings: ConversionSettings()).outputs.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription])
    }

    func testAnimatedGIFIsExplicitlyRejected() throws {
        let input = directory.appendingPathComponent("animation.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let image = try makeImage(width: 8, height: 8)
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertTrue(ImageConverter.formats(for: input).isEmpty)
        XCTAssertTrue(ImageConverter.tools(for: input).isEmpty)
        XCTAssertThrowsError(try ImageConverter.convert(input, to: .png, settings: ConversionSettings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("additional frames"))
        }
    }

    func testQRDetectionWritesDecodedPayload() throws {
        // Version 1-L QR, byte-mode payload ORANGE, mask 0. A fixed bitmap avoids
        // depending on a GPU or Core Image's generator inside a headless test runner.
        let matrix = [
            "111111100010101111111", "100000100000101000001", "101110101010001011101",
            "101110100000101011101", "101110100101101011101", "100000100111001000001",
            "111111101010101111111", "000000001010000000000", "111011111010111000100",
            "000101010001010101000", "001110110101011100011", "111110010011110110001",
            "011100101111011100110", "000000001110001101010", "111111101010100011111",
            "100000101110001000011", "101110101000101110111", "101110100011010100110",
            "101110101011011110001", "100000101111110010010", "111111101111011110111"
        ]
        let side = 290, scale = 10, quiet = 4
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for (row, line) in matrix.enumerated() {
            for (column, module) in line.enumerated() where module == "1" {
                for y in ((row + quiet) * scale)..<((row + quiet + 1) * scale) {
                    for x in ((column + quiet) * scale)..<((column + quiet + 1) * scale) {
                        let index = (y * side + x) * 4
                        bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
                    }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try writeImage(image, name: "qr.png")
        let result = try ImageConverter.apply(.qrCode, to: input, settings: ConversionSettings())
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(result.outputs.first), encoding: .utf8), "ORANGE\n")
    }

    func testOCRWritesRecognizedText() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 120, bitsPerComponent: 8, bytesPerRow: 600 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 120))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 60, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "ORANGE 123", attributes: attributes))
        context.textPosition = CGPoint(x: 20, y: 35)
        CTLineDraw(line, context)
        let input = try writeImage(XCTUnwrap(context.makeImage()), name: "text.png")
        let output = try XCTUnwrap(ImageConverter.apply(.extractText, to: input, settings: ConversionSettings()).outputs.first)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("ORANGE"), "Recognized: \(text)")
        XCTAssertTrue(text.contains("123"), "Recognized: \(text)")
    }

    func testUnsafeDimensionsAndInvalidQualityAreRejected() throws {
        let huge = try writeImage(makeImage(width: 33_000, height: 1), name: "wide.png")
        XCTAssertTrue(ImageConverter.formats(for: huge).isEmpty)
        XCTAssertThrowsError(try ImageConverter.convert(huge, to: .png, settings: ConversionSettings()))
        let input = try writeImage(makeImage(width: 8, height: 8), name: "valid.png")
        var settings = ConversionSettings()
        settings.quality = .nan
        XCTAssertThrowsError(try ImageConverter.convert(input, to: .jpeg, settings: settings))
        settings.quality = 0.8
        settings.maxDimension = 0
        XCTAssertThrowsError(try ImageConverter.apply(.resize, to: input, settings: settings))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".orange-") })
    }

    func testFFmpegAudioConversionAndTrimWhenInstalled() throws {
        let ffmpeg = try XCTUnwrapOrSkip(ProcessRunner.executable(named: "ffmpeg"), "FFmpeg is not installed.")
        guard ProcessRunner.executable(named: "ffprobe") != nil else { throw XCTSkip("ffprobe is not installed.") }
        _ = ffmpeg
        let input = try writeTone()
        let formats = MediaConverter.formats(for: input)
        XCTAssertTrue(formats.contains(.m4a))
        XCTAssertFalse(formats.contains(.mp4))
        let output = try XCTUnwrap(MediaConverter.convert(input, to: .m4a, settings: ConversionSettings()).outputs.first)
        XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
        var settings = ConversionSettings()
        settings.trimStart = 0.1
        settings.trimEnd = 0.5
        if formats.contains(.m4a) {
            let trimmed = try XCTUnwrap(MediaConverter.apply(.trim, to: input, settings: settings).outputs.first)
            let ffprobe = try XCTUnwrap(ProcessRunner.executable(named: "ffprobe"))
            let duration = try ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", trimmed.path])
            XCTAssertEqual(try XCTUnwrap(Double(duration)), 0.4, accuracy: 0.08)
        }
    }

    func testProcessRunnerDrainsBothPipesAndBoundsOutput() throws {
        let awk = try XCTUnwrap(ProcessRunner.executable(named: "awk"))
        let fixture = directory.appendingPathComponent("both-pipes.awk")
        let line = String(repeating: "A", count: 64)
        try "BEGIN { for (i=0;i<20000;i++) { print \"\(line)\"; print \"\(line)\" > \"/dev/stderr\" } }\n".write(to: fixture, atomically: false, encoding: .utf8)
        let output = try ProcessRunner.run(awk, arguments: ["-f", fixture.path], timeout: 10)
        XCTAssertFalse(output.isEmpty)
        XCTAssertLessThanOrEqual(output.count, 262_144)
    }

    func testFFmpegVideoConversionSnapshotAndSpeedWhenInstalled() throws {
        let ffmpeg = try XCTUnwrapOrSkip(ProcessRunner.executable(named: "ffmpeg"), "FFmpeg is not installed.")
        let ffprobe = try XCTUnwrapOrSkip(ProcessRunner.executable(named: "ffprobe"), "ffprobe is not installed.")
        let input = directory.appendingPathComponent("clip.mkv")
        let imageInput = try writeImage(makeImage(width: 64, height: 48), name: "video-frame.png")
        let audioInput = try writeTone()
        _ = try ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-loop", "1", "-framerate", "10", "-i", imageInput.path, "-i", audioInput.path,
            "-map", "0:v:0", "-map", "1:a:0", "-map", "1:a:0",
            "-c:v", "mpeg4", "-threads", "2", "-c:a", "pcm_s16le", "-t", "1", "-shortest", input.path], timeout: 10)
        let formats = MediaConverter.formats(for: input)
        guard formats.contains(.mp4) else { throw XCTSkip("This FFmpeg build lacks compatible MP4/AAC encoders.") }
        let output = try XCTUnwrap(MediaConverter.convert(input, to: .mp4, settings: ConversionSettings()).outputs.first)
        XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
        let cleaned = try XCTUnwrap(MediaConverter.apply(.stripMetadata, to: input, settings: ConversionSettings()).outputs.first)
        let tracks = try ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", cleaned.path], timeout: 10)
        XCTAssertEqual(tracks.split(separator: "\n").filter { $0 == "audio" }.count, 2)
        let m4v = directory.appendingPathComponent("apple.m4v")
        try FileManager.default.copyItem(at: output, to: m4v)
        let cleanM4v = try XCTUnwrap(MediaConverter.apply(.stripMetadata, to: m4v, settings: ConversionSettings()).outputs.first)
        let container = try ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-show_entries", "format=format_name", "-of", "default=noprint_wrappers=1:nokey=1", cleanM4v.path], timeout: 10)
        XCTAssertTrue(container.contains("mp4"))
        let snapshot = try XCTUnwrap(MediaConverter.apply(.snapshot, to: input, settings: ConversionSettings()).outputs.first)
        let image = try decoded(snapshot)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        var settings = ConversionSettings()
        settings.speed = 2
        let spedUp = try XCTUnwrap(MediaConverter.apply(.changeSpeed, to: input, settings: settings).outputs.first)
        let duration = try ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", spedUp.path], timeout: 10)
        XCTAssertEqual(try XCTUnwrap(Double(duration)), 0.5, accuracy: 0.2)
    }

    func testProcessRunnerStopsTimedOutBackend() throws {
        let awk = try XCTUnwrap(ProcessRunner.executable(named: "awk"))
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ProcessRunner.run(awk, arguments: ["BEGIN { while (1) {} }"], timeout: 0.2)) { error in
            XCTAssertTrue(error.localizedDescription.contains("time limit"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testProcessRunnerStopsAnAlreadyRunningCancelledTask() async throws {
        let awk = try XCTUnwrap(ProcessRunner.executable(named: "awk"))
        let marker = directory.appendingPathComponent("started")
        let operation = Task.detached(priority: .utility) {
            try ProcessRunner.run(awk, arguments: ["-v", "marker=\(marker.path)",
                "BEGIN { print \"ready\" > marker; close(marker); while (1) {} }"], timeout: 3)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("A cancelled running backend must throw.")
        } catch OrangeError.cancelled {
            // Expected after the running process has been terminated and its pipes drained.
        } catch { XCTFail("Expected cancellation, received \(error)") }
    }

    private func makeImage(width: Int, height: Int, transparent: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: transparent ? width / 2 : 0, y: 0, width: transparent ? width / 2 : width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func requireWebPEncoder() throws {
        let native = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.webP.identifier)
        guard native || (try? MediaConverter.encoderExecutable(named: "libwebp")) != nil else {
            throw XCTSkip("A native WebP writer or FFmpeg with libwebp is required.")
        }
    }

    private func writeTone() throws -> URL {
        let url = directory.appendingPathComponent("tone.wav")
        let sampleRate = 44_100, sampleBytes = sampleRate * 2
        var data = Data("RIFF".utf8)
        func append16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func append32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        append32(UInt32(36 + sampleBytes)); data.append(Data("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(Data("data".utf8)); append32(UInt32(sampleBytes))
        for index in 0..<sampleRate {
            let sample = Int16((sin(Double(index) * 2 * .pi * 440 / Double(sampleRate)) * 8_000).rounded())
            append16(UInt16(bitPattern: sample))
        }
        try data.write(to: url)
        return url
    }

    @discardableResult private func writeImage(_ image: CGImage, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func decoded(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixelRGBA(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 4))
    }
}

private extension XCTestCase {
    func XCTUnwrapOrSkip<T>(_ value: T?, _ reason: String) throws -> T {
        guard let value else { throw XCTSkip(reason) }
        return value
    }
}
