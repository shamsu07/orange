import AppKit
import CoreText
import ImageIO
import PDFKit
import XCTest
@testable import OrangeCore

final class PDFWorkflowTests: XCTestCase {
    private var directory: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".cache/tests/pdf-workflows-\(UUID().uuidString)", isDirectory: true)
        scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testLongPDFRequiresAnExplicitSplitBeforeWritingAnyCopies() throws {
        let source = try textPDF("long.pdf", pages: 5)
        let original = try Data(contentsOf: source)
        XCTAssertThrowsError(try DocumentConverter.apply(.splitPDF, to: source, settings: ConversionSettings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("Choose where"))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["long.pdf", "scratch"])
    }

    func testSplitPartitionsPreserveOrderedTextMetadataAndOriginal() throws {
        let source = try textPDF("chapters.pdf", pages: 5)
        let original = try Data(contentsOf: source)
        let originalDocument = try XCTUnwrap(PDFDocument(url: source))
        originalDocument.page(at: 2)?.rotation = 90
        let rotated = directory.appendingPathComponent("rotated.pdf")
        XCTAssertTrue(originalDocument.write(to: rotated))
        var settings = ConversionSettings()
        settings.pdfPageRanges = [[1, 2], [3, 4, 5]]
        let split = try DocumentConverter.apply(.splitPDF, to: rotated, settings: settings)
        XCTAssertEqual(split.outputs.count, 2)
        let first = try XCTUnwrap(PDFDocument(url: split.outputs[0]))
        let second = try XCTUnwrap(PDFDocument(url: split.outputs[1]))
        XCTAssertEqual(first.pageCount, 2)
        XCTAssertEqual(second.pageCount, 3)
        XCTAssertTrue(first.page(at: 0)?.string?.contains("Page 1") == true)
        XCTAssertTrue(first.page(at: 1)?.string?.contains("Page 2") == true)
        XCTAssertTrue(second.page(at: 0)?.string?.contains("Page 3") == true)
        XCTAssertTrue(second.page(at: 2)?.string?.contains("Page 5") == true)
        XCTAssertEqual(second.page(at: 0)?.rotation, 90)
        XCTAssertEqual(first.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Orange Test")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testInvalidPartitionsDoNotLoseDuplicateOmitOrReorderPages() throws {
        let invalid: [[[Int]]] = [[], [[]], [[1, 2, 3, 4]], [[1, 2], [2, 3, 4]], [[1], [3, 4]], [[2], [1, 3, 4]], [[0, 1], [2, 3, 4]], [[1, 2], [3, 4, 5]]]
        for groups in invalid { XCTAssertThrowsError(try DocumentConverter.validatedSplitGroups(groups, pageCount: 4), "\(groups)") }
        XCTAssertThrowsError(try DocumentConverter.validatedSplitGroups(nil, pageCount: 1))
        XCTAssertEqual(try DocumentConverter.validatedSplitGroups(nil, pageCount: 2), [[1], [2]])
    }

    func testReductionRequiresExplicitConsentAndDoesNotPublishOnDecline() throws {
        let source = try textPDF("searchable.pdf", pages: 2)
        XCTAssertThrowsError(try DocumentConverter.apply(.compress, to: source, settings: ConversionSettings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("Confirm image-based"))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["searchable.pdf", "scratch"])
        XCTAssertTrue(DocumentConverter.tools(for: source).contains(.compress))
    }

    func testMeasuredReductionProducesSmallerVerifiedPDFAndPreservesOriginal() throws {
        let source = try imagePDF("scan.pdf")
        let original = try Data(contentsOf: source)
        let preview = try DocumentConverter.previewReduction(source, dpi: 72, quality: 0.5, temporaryDirectory: scratch)
        XCTAssertTrue(preview.isSmaller, "\(preview.originalBytes) → \(preview.reducedBytes)")
        XCTAssertEqual(preview.originalBytes, Int64(original.count))
        XCTAssertEqual(preview.reducedBytes, Int64(try Data(contentsOf: preview.candidate).count))
        XCTAssertEqual(preview.pageCount, 2)
        XCTAssertTrue(preview.candidate.path.hasPrefix(scratch.path + "/"))
        let document = try XCTUnwrap(PDFDocument(url: preview.candidate))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 500, height: 300))
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 500))
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Image scan")
        preview.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.candidate.path))
        var settings = ConversionSettings()
        settings.pdfRasterDPI = 72
        settings.pdfRasterQuality = 0.5
        settings.pdfAllowsRasterization = true
        let result = try DocumentConverter.reducePDF(source, settings: settings, temporaryDirectory: scratch)
        XCTAssertEqual(result.outputs.count, 1)
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertLessThan(try Data(contentsOf: output).count, original.count)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        XCTAssertTrue(result.message?.contains("text became pixels") == true)
    }

    func testCompactVectorPDFNeverPublishesLargerRasterCopy() throws {
        let source = try textPDF("compact.pdf", pages: 1)
        let before = try Data(contentsOf: source)
        var settings = ConversionSettings()
        settings.pdfAllowsRasterization = true
        settings.pdfRasterDPI = 300
        settings.pdfRasterQuality = 1
        let preview = try DocumentConverter.previewReduction(source, dpi: 300, quality: 1, temporaryDirectory: scratch)
        XCTAssertFalse(preview.isSmaller)
        let imagePDF = try XCTUnwrap(PDFDocument(url: preview.candidate))
        XCTAssertTrue((imagePDF.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        preview.discard()
        XCTAssertThrowsError(try DocumentConverter.reducePDF(source, settings: settings, temporaryDirectory: scratch)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No larger copy"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["compact.pdf", "scratch"])
    }

    func testInvalidPDFReductionBoundsRejectBeforeCreatingCandidates() throws {
        let source = try textPDF("bounds.pdf", pages: 1)
        for (dpi, quality) in [(Double.nan, 0.7), (0, 0.7), (301, 0.7), (120, Double.infinity), (120, 0.09), (120, 1.1)] {
            XCTAssertThrowsError(try DocumentConverter.previewReduction(source, dpi: dpi, quality: quality, temporaryDirectory: scratch))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testCancelledPDFPreviewDoesNotLeaveTemporaryFiles() async throws {
        let source = try imagePDF("cancel.pdf")
        let scratch = try XCTUnwrap(scratch)
        let worker = Task.detached {
            try Task.checkCancellation()
            return try DocumentConverter.previewReduction(source, dpi: 300, quality: 0.85, temporaryDirectory: scratch)
        }
        worker.cancel()
        do { let preview = try await worker.value; preview.discard(); XCTFail("Cancelled preview should fail") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    private func textPDF(_ name: String, pages: Int) throws -> URL {
        let output = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 500, height: 300)
        let context = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &box, [kCGPDFContextAuthor: "Orange Test"] as CFDictionary))
        for index in 1...pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 120)
            let text = NSAttributedString(string: "Page \(index) · searchable content", attributes: [.font: NSFont.systemFont(ofSize: 20)])
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
            context.endPDFPage()
        }
        context.closePDF()
        return output
    }

    private func imagePDF(_ name: String) throws -> URL {
        let output = directory.appendingPathComponent(name)
        let width = 1_000, height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt32 = 42
        for index in stride(from: 0, to: pixels.count, by: 4) {
            random = 1_664_525 &* random &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: random >> 16)
            pixels[index + 1] = UInt8(truncatingIfNeeded: random >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: random)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var box = CGRect(x: 0, y: 0, width: 500, height: 300)
        let context = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Image scan"] as CFDictionary))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: output))
        document.page(at: 1)?.rotation = 90
        XCTAssertTrue(document.write(to: output))
        return output
    }
}
