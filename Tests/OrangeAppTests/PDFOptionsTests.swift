import AppKit
import CoreText
import PDFKit
import XCTest
import OrangeCore
@testable import Orange

final class PDFOptionsTests: XCTestCase {
    private var directory: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".cache/tests/pdf-options-\(UUID().uuidString)")
        scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor func testSplitDefaultsToTwoUsefulPartsAndEditsEveryPDFIndependently() throws {
        let first = try fixture("eight.pdf", pages: 8)
        let second = try fixture("three.pdf", pages: 3)
        let model = PDFSplitOptionsModel(sources: try PDFSourceSummary.load([first, second, first]))
        XCTAssertEqual(model.plans.count, 2)
        let selections = try XCTUnwrap(model.selections)
        XCTAssertEqual(selections[0].settings.pdfPageRanges, [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(selections[1].settings.pdfPageRanges, [[1], [2, 3]])
        model.plans[0].expression = "1–2, 3-6, 7–8"
        XCTAssertEqual(model.selections?[0].settings.pdfPageRanges, [[1, 2], [3, 4, 5, 6], [7, 8]])
        XCTAssertEqual(model.selections?[1].settings.pdfPageRanges, [[1], [2, 3]])
    }

    @MainActor func testInvalidEditedRangesCannotReusePreviousSelection() throws {
        let source = try fixture("ranges.pdf", pages: 8)
        let model = PDFSplitOptionsModel(sources: try PDFSourceSummary.load([source]))
        XCTAssertNotNil(model.selections)
        for invalid in ["", "1-8", "1-3,5-8", "1-3,3-8", "2-4,1,5-8", "0,1-8", "1-4,5-9", "1-4,", "1.5,2-8", "4-1,5-8"] {
            model.plans[0].expression = invalid
            XCTAssertNil(model.selections, invalid)
        }
        model.plans[0].expression = "1-7,8"
        XCTAssertEqual(model.selections?.first?.settings.pdfPageRanges, [Array(1...7), [8]])
    }

    @MainActor func testSinglePageCannotProduceAConfirmableSplit() throws {
        let source = try fixture("single.pdf", pages: 1)
        let model = PDFSplitOptionsModel(sources: try PDFSourceSummary.load([source]))
        XCTAssertNil(model.selections)
    }

    @MainActor func testPDFReductionStartsWithoutConsentAndCancelRemovesMeasuredCandidates() async throws {
        let source = try fixture("searchable.pdf", pages: 2)
        let model = PDFReductionOptionsModel(sources: try PDFSourceSummary.load([source]), temporaryDirectory: scratch)
        XCTAssertFalse(model.acceptsFlattening)
        XCTAssertNil(model.selections)
        model.prepare()
        XCTAssertTrue(model.isPreparing)
        XCTAssertNil(model.selections)
        let deadline = Date().addingTimeInterval(10)
        while model.isPreparing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isPreparing)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.previews.count, 1)
        XCTAssertEqual(model.previews.first?.originalBytes, Int64(try Data(contentsOf: source).count))
        XCTAssertNil(model.selections)
        let candidate = try XCTUnwrap(model.previews.first?.candidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        model.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        XCTAssertTrue(model.previews.isEmpty)
    }

    @MainActor func testReplacementPresetDiscardsOldPreviewAndCannotSaveStaleSettings() async throws {
        let source = try fixture("preset.pdf", pages: 1)
        let model = PDFReductionOptionsModel(sources: try PDFSourceSummary.load([source]), temporaryDirectory: scratch)
        model.prepare()
        let deadline = Date().addingTimeInterval(10)
        while model.isPreparing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let previous = try XCTUnwrap(model.previews.first?.candidate)
        model.acceptsFlattening = true
        model.preset = .compact
        model.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertNil(model.selections)
        while model.isPreparing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.previews.count, 1)
        XCTAssertNotEqual(model.previews.first?.candidate, previous)
        model.cancel()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    private func fixture(_ name: String, pages: Int) throws -> URL {
        let output = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &box, nil))
        for index in 1...pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 100)
            let value = NSAttributedString(string: "PDF page \(index)", attributes: [.font: NSFont.systemFont(ofSize: 20)])
            CTLineDraw(CTLineCreateWithAttributedString(value as CFAttributedString), context)
            context.endPDFPage()
        }
        context.closePDF()
        return output
    }
}
