import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import OrangeCore
@testable import Orange

final class AppModelTests: XCTestCase {
    @MainActor func testToolsRouteThroughJobQueueAndProduceRealImageOutputs() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".cache/tests/app-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("fixture.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.58, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: input)
        let resizePresenter = TestResizePresenter()
        let model = AppModel(persistPreferences: false, resizePresenter: resizePresenter)
        // Only session values change. No real app preference or login setting is written.
        model.revealOnCompletion = false
        model.soundFeedback = false
        model.maxDimension = 16
        var panelsShown = 0
        model.onShowProgress = { panelsShown += 1 }
        for tool in [ToolKind.rotate, .resize, .stripMetadata] { model.perform(.tool(tool), urls: [input]) }
        resizePresenter.complete(.success(ResizeSelection(inputs: [input], maximumDimension: 16)))
        let deadline = Date().addingTimeInterval(10)
        while model.activeCount > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.activeCount, 0)
        XCTAssertEqual(model.jobs.count, 3)
        XCTAssertEqual(panelsShown, 3)
        for job in model.jobs {
            XCTAssertEqual(job.state, .complete, job.message ?? "No completion")
            let output = try XCTUnwrap(job.outputs.first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            if job.operation == .tool(.rotate) { XCTAssertEqual(image.width, 32); XCTAssertEqual(image.height, 64) }
            if job.operation == .tool(.resize) { XCTAssertEqual(image.width, 16); XCTAssertEqual(image.height, 8) }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        await model.shutdown()
    }
    @MainActor func testControlCopyPathAndFloatAreActuallyDispatched() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = FileActionCoordinator(pasteboard: board, makeAirDrop: { nil })
        let model = AppModel(persistPreferences: false, fileActionCoordinator: coordinator)
        let urls = [URL(fileURLWithPath: #filePath)]
        var feedbackShown = 0
        model.onShowActionFeedback = { feedbackShown += 1 }
        model.perform(.action(.copyPath), urls: urls)
        XCTAssertEqual(board.string(forType: .string), urls[0].path)
        XCTAssertEqual(feedbackShown, 1)
        XCTAssertEqual(model.actionFeedback, "Path copied")
        var floated: [URL] = []
        model.onFloat = { floated = $0 }
        model.perform(.action(.float), urls: urls)
        XCTAssertEqual(floated, urls)
        await model.shutdown()
    }

    @MainActor func testMixedFamilyCompressionRejectsEveryPairBeforePresentingOrQueuing() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".cache/tests/mixed-compression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [(String, FileFamily)] = [("image.jpg", .image), ("video.mp4", .video),
                                               ("audio.m4a", .audio), ("document.pdf", .pdf)]
        let urls = try fixtures.map { name, family in
            let url = root.appendingPathComponent(name)
            try Data("untouched source".utf8).write(to: url)
            XCTAssertEqual(FileFamily.detect(url), family)
            return url
        }
        let presenter = CompressionRouteSpy()
        let model = AppModel(persistPreferences: false, imagePresenter: presenter,
                             mediaPresenter: presenter, pdfPresenter: presenter)
        var progressRequests = 0
        var feedbackRequests = 0
        model.onShowProgress = { progressRequests += 1 }
        model.onShowActionFeedback = { feedbackRequests += 1 }

        for first in urls.indices {
            for second in urls.indices where first != second {
                model.perform(.tool(.compress), urls: [urls[first], urls[second]])
                XCTAssertTrue(model.jobs.isEmpty, "A mixed selection must not partially process files.")
                XCTAssertEqual(model.actionFeedback, "Select files of one type to choose compression quality: images, videos, audio or PDFs.")
            }
        }

        XCTAssertEqual(feedbackRequests, 12)
        XCTAssertEqual(progressRequests, 0)
        XCTAssertEqual(presenter.requestCount, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(fixtures.map(\.0)))
        for url in urls { XCTAssertEqual(try Data(contentsOf: url), Data("untouched source".utf8)) }
        await model.shutdown()
    }
}

@MainActor private final class CompressionRouteSpy: ImageOptionsPresenting, MediaOptionsPresenting, PDFOptionsPresenting {
    private(set) var requestCount = 0
    func choose(_ tool: ToolKind, urls: [URL], preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ImageEditSelection?, Error>) -> Void) { requestCount += 1 }
    func choose(_ urls: [URL], tool: ToolKind, settings: ConversionSettings,
                completion: @escaping @MainActor (Result<[MediaSelection]?, Error>) -> Void) { requestCount += 1 }
    func chooseSplit(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void) { requestCount += 1 }
    func chooseReduction(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void) { requestCount += 1 }
    func cancel() {}
    func shutdown() async { cancel() }
}

@MainActor final class TestResizePresenter: ResizeOptionsPresenting {
    private(set) var requestedURLs: [URL] = []
    private(set) var preferredMaximum: Int?
    private(set) var cancelCount = 0
    var shutdownCount = 0
    private var completion: (@MainActor (Result<ResizeSelection?, Error>) -> Void)?

    func choose(_ urls: [URL], preferredMaximum: Int, preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ResizeSelection?, Error>) -> Void) {
        requestedURLs = urls
        self.preferredMaximum = preferredMaximum
        self.completion = completion
    }
    func complete(_ result: Result<ResizeSelection?, Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }
    func cancel() { cancelCount += 1 }
    func shutdown() async { shutdownCount += 1 }
}
