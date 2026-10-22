import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import OrangeCore
@testable import Orange

final class ResizeOptionsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        folder = root.appendingPathComponent(".cache/tests/resize-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    @MainActor func testSmallImageGetsMeaningfulDefaultAndLivePixelPreview() throws {
        let url = try fixture(width: 256, height: 128, name: "small.png")
        let source = try XCTUnwrap(ResizeSource.load([url]).first)
        let model = ResizeOptionsModel(sources: [source], preferredMaximum: 1920)
        XCTAssertEqual(model.maximumDimension, 128)
        XCTAssertEqual(model.outputDimensions(for: source)?.width, 128)
        XCTAssertEqual(model.outputDimensions(for: source)?.height, 64)
        XCTAssertEqual(model.selection?.inputs, [url])
        model.maximumText = "1920"
        XCTAssertNil(model.selection)
        XCTAssertTrue(try XCTUnwrap(model.validationMessage).contains("unchanged"))
        model.maximumText = "64"
        XCTAssertEqual(model.outputDimensions(for: source)?.width, 64)
        XCTAssertEqual(model.outputDimensions(for: source)?.height, 32)
    }

    @MainActor func testInvalidEditedTextCannotReuseAPreviousValidTarget() throws {
        let url = try fixture(width: 256, height: 128, name: "valid.png")
        let model = ResizeOptionsModel(sources: try ResizeSource.load([url]), preferredMaximum: 128)
        XCTAssertNotNil(model.selection)
        for invalid in ["", "1.5", "-1", "0", "16385", "hello", "128px"] {
            model.maximumText = invalid
            XCTAssertNil(model.maximumDimension, invalid)
            XCTAssertNil(model.selection, invalid)
            XCTAssertNotNil(model.validationMessage, invalid)
        }
    }

    @MainActor func testMixedBatchPreviewsAndSkipsImagesThatAlreadyFit() throws {
        let large = try fixture(width: 400, height: 200, name: "large.png")
        let small = try fixture(width: 64, height: 32, name: "small.png")
        let sources = try ResizeSource.load([large, small])
        let model = ResizeOptionsModel(sources: sources, preferredMaximum: 128)
        XCTAssertEqual(model.selection?.inputs, [large])
        XCTAssertEqual(model.unchangedCount, 1)
        XCTAssertEqual(model.outputDimensions(for: sources[0])?.width, 128)
        XCTAssertEqual(model.outputDimensions(for: sources[0])?.height, 64)
        XCTAssertEqual(model.outputDimensions(for: sources[1]), sources[1].dimensions)
        model.maximumText = "32"
        XCTAssertEqual(model.selection?.inputs, [large, small])
        XCTAssertEqual(model.unchangedCount, 0)
    }

    @MainActor func testMinimumPixelImageHasNoConfirmableTarget() throws {
        let url = try fixture(width: 1, height: 1, name: "minimum.png")
        let model = ResizeOptionsModel(sources: try ResizeSource.load([url]), preferredMaximum: 1920)
        XCTAssertEqual(model.maximumDimension, 1)
        XCTAssertNil(model.selection)
        XCTAssertTrue(try XCTUnwrap(model.validationMessage).contains("minimum"))
    }

    @MainActor func testResizeWaitsForConfirmationThenQueuesOnlyEligibleFiles() async throws {
        let large = try fixture(width: 400, height: 200, name: "large.png")
        let small = try fixture(width: 64, height: 32, name: "small.png")
        let presenter = TestResizePresenter()
        let model = AppModel(persistPreferences: false, resizePresenter: presenter)
        model.revealOnCompletion = false
        model.soundFeedback = false
        var progressCount = 0
        model.onShowProgress = { progressCount += 1 }
        model.perform(.tool(.resize), urls: [large, small])
        XCTAssertEqual(presenter.requestedURLs, [large, small])
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(progressCount, 0)
        let options = ResizeOptionsModel(sources: try ResizeSource.load([large, small]), preferredMaximum: 128)
        presenter.complete(.success(try XCTUnwrap(options.selection)))
        let deadline = Date().addingTimeInterval(5)
        while model.activeCount > 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.maxDimension, 128)
        XCTAssertEqual(progressCount, 1)
        XCTAssertEqual(model.jobs.count, 1)
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(job.state, .complete, job.message ?? "No result")
        XCTAssertEqual(job.inputs, [large])
        let output = try ImageConverter.dimensions(of: XCTUnwrap(job.outputs.first))
        XCTAssertEqual(output.width, 128)
        XCTAssertEqual(output.height, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("small-resized.png").path))
        await model.shutdown()
    }

    @MainActor func testCancelAndShutdownDoNotQueueResizeOrWriteCopies() async throws {
        let url = try fixture(width: 256, height: 128, name: "source.png")
        let presenter = TestResizePresenter()
        let model = AppModel(persistPreferences: false, resizePresenter: presenter)
        var progressCount = 0
        model.onShowProgress = { progressCount += 1 }
        model.perform(.tool(.resize), urls: [url])
        presenter.complete(.success(nil))
        XCTAssertTrue(model.jobs.isEmpty)
        model.perform(.tool(.resize), urls: [url])
        await model.shutdown()
        XCTAssertEqual(presenter.cancelCount, 1)
        XCTAssertEqual(presenter.shutdownCount, 1)
        // A delayed presentation callback is harmless after shutdown.
        presenter.complete(.success(ResizeSelection(inputs: [url], maximumDimension: 128)))
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(progressCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["source.png"])
    }

    private func fixture(width: Int, height: Int, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
