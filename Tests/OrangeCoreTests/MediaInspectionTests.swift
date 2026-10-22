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

    func testSpeedAtOneFPSChangesRealDurationAndPreservesEveryFrameAtAllPresetRates() throws {
        let input = try speedClip()
        guard MediaConverter.tools(for: input).contains(.changeSpeed) else { throw XCTSkip("FFmpeg lacks an MP4 encoder.") }
        let original = try Data(contentsOf: input)
        for speed in [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4] {
            var settings = ConversionSettings()
            settings.speed = speed
            let output = try XCTUnwrap(MediaConverter.apply(.changeSpeed, to: input, settings: settings).outputs.first)
            let duration = try XCTUnwrap(MediaConverter.inspect(output).duration)
            XCTAssertEqual(duration, 4 / speed, accuracy: 0.003, "\(speed)× must change playback duration, not just metadata in the UI.")
            let timestamps = try videoTimestamps(output)
            XCTAssertEqual(timestamps.count, 4, "The four distinct source frames must all survive at \(speed)×.")
            for (index, time) in timestamps.sorted().enumerated() {
                XCTAssertEqual(time, Double(index) / speed, accuracy: 0.003, "Incorrect frame time at \(speed)×.")
            }
            if speed == 2 {
                let finalFrame = try previewPixel(MediaConverter.previewFrame(output, at: 1.5))
                XCTAssertGreaterThan(finalFrame[0], 200)
                XCTAssertGreaterThan(finalFrame[1], 200)
                XCTAssertLessThan(finalFrame[2], 20)
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testSpeedKeepsLowFPSVideoAndAudioTimelinesInSync() throws {
        let input = try speedClip(withAudio: true)
        guard MediaConverter.tools(for: input).contains(.changeSpeed) else { throw XCTSkip("FFmpeg lacks MP4/AAC encoders.") }
        for speed in [0.5, 2, 4] {
            var settings = ConversionSettings()
            settings.speed = speed
            let output = try XCTUnwrap(MediaConverter.apply(.changeSpeed, to: input, settings: settings).outputs.first)
            let probe = try XCTUnwrap(ProcessRunner.executable(named: "ffprobe"))
            let json = try ProcessRunner.run(probe, arguments: ["-v", "error", "-show_entries", "stream=codec_type,duration:format=duration", "-of", "json", output.path], timeout: 10)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let streams = try XCTUnwrap(object["streams"] as? [[String: Any]])
            let video = try XCTUnwrap(streams.first { $0["codec_type"] as? String == "video" })
            let audio = try XCTUnwrap(streams.first { $0["codec_type"] as? String == "audio" })
            let videoDuration = try XCTUnwrap((video["duration"] as? String).flatMap(Double.init))
            let audioDuration = try XCTUnwrap((audio["duration"] as? String).flatMap(Double.init))
            XCTAssertEqual(videoDuration, 4 / speed, accuracy: 0.003)
            // Tempo processing and AAC packet padding introduce a small audio tail.
            XCTAssertEqual(audioDuration, 4 / speed, accuracy: 0.12)
            XCTAssertEqual(audioDuration, videoDuration, accuracy: 0.12)
        }
    }

    private func speedClip(withAudio: Bool = false) throws -> URL {
        guard let ffmpeg = ProcessRunner.executable(named: "ffmpeg"), ProcessRunner.executable(named: "ffprobe") != nil else {
            throw XCTSkip("FFmpeg and FFprobe are required for media checks.")
        }
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        for (index, color) in colors.enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let url = directory.appendingPathComponent("speed-\(index).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let output = directory.appendingPathComponent(withAudio ? "speed-av.mkv" : "speed-video.mkv")
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-framerate", "1", "-i", directory.appendingPathComponent("speed-%d.png").path]
        if withAudio {
            let audio = directory.appendingPathComponent("speed-tone.wav")
            try tone(duration: 4).write(to: audio)
            arguments += ["-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-c:a", "pcm_s16le"]
        }
        arguments += ["-c:v", "mpeg4", "-threads", "2", "-t", "4", output.path]
        _ = try ProcessRunner.run(ffmpeg, arguments: arguments, timeout: 10)
        return output
    }

    private func tone(duration: Int) -> Data {
        let sampleRate = 44_100, sampleCount = sampleRate * duration, sampleBytes = sampleCount * 2
        var data = Data("RIFF".utf8)
        func append16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func append32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        append32(UInt32(36 + sampleBytes)); data.append(Data("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(Data("data".utf8)); append32(UInt32(sampleBytes))
        for index in 0..<sampleCount {
            let sample = Int16((sin(Double(index) * 2 * .pi * 440 / Double(sampleRate)) * 8_000).rounded())
            append16(UInt16(bitPattern: sample))
        }
        return data
    }

    private func videoTimestamps(_ url: URL) throws -> [Double] {
        let probe = try XCTUnwrap(ProcessRunner.executable(named: "ffprobe"))
        let json = try ProcessRunner.run(probe, arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time", "-of", "json", url.path], timeout: 10)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let packets = try XCTUnwrap(object["packets"] as? [[String: Any]])
        return packets.compactMap { ($0["pts_time"] as? String).flatMap(Double.init) }
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
