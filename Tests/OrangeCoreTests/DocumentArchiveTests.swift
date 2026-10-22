import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import OrangeCore

final class DocumentArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path) else {
            throw XCTSkip("Run tests from the Orange workspace so fixtures stay inside the project.")
        }
        directory = workspace.appendingPathComponent(".cache/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func textFile(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func makePDF(_ name: String, pages: [String], pageSize: CGSize = CGSize(width: 240, height: 120)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box,
                                      [kCGPDFContextAuthor: "Private Author", kCGPDFContextTitle: "Private Title"] as CFDictionary) else {
            throw OrangeError.conversionFailed("The test PDF context could not be created.")
        }
        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 60)
            let value = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16)])
            CTLineDraw(CTLineCreateWithAttributedString(value as CFAttributedString), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Paint the text into pixels before embedding it: the PDF itself has no text layer.
    private func makeScannedPDF(_ name: String, pages: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 600, height: 300)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1_200, height: 600,
                                                 bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
            if !text.isEmpty {
                bitmap.textPosition = CGPoint(x: 70, y: 260)
                let value = NSAttributedString(string: text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 96, weight: .bold),
                    .foregroundColor: NSColor.black
                ])
                CTLineDraw(CTLineCreateWithAttributedString(value as CFAttributedString), bitmap)
            }
            let image = try XCTUnwrap(bitmap.makeImage())
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }

    func testVTTConvertsLongTimestampsAndCueSettingsWithoutTreatingHeaderAsCue() throws {
        let input = try textFile("subtitles.vtt", "WEBVTT\nKind: captions\n\nNOTE generated fixture\n\ncue-one\n125:02:03.456 --> 125:02:06.789 align:start position:10%\n<v Sam>Hello &amp; welcome</v>\nsecond line\n\n00:09.000 --> 00:10.000\nNext\n")
        let srt = try DocumentConverter.convert(input, to: .srt, settings: ConversionSettings())
        let output = try read(XCTUnwrap(srt.outputs.first))
        XCTAssertTrue(output.contains("1\n125:02:03,456 --> 125:02:06,789\n<v Sam>Hello &amp; welcome</v>\nsecond line"))
        XCTAssertTrue(output.contains("2\n00:00:09,000 --> 00:00:10,000\nNext"))
        XCTAssertFalse(output.contains("WEBVTT"))
        XCTAssertFalse(output.contains("align:start"))
        XCTAssertTrue(srt.message?.contains("positioning") == true)
        let plain = try DocumentConverter.convert(input, to: .txt, settings: ConversionSettings())
        XCTAssertEqual(try read(XCTUnwrap(plain.outputs.first)), "Hello & welcome\nsecond line\n\nNext\n")
    }

    func testSRTProducesVTTHeaderAndPreservesPayloadAndSettings() throws {
        let input = try textFile("captions.srt", "\u{FEFF}1\r\n01:02:03,004 --> 01:02:05,006 align:start\r\n<b>First</b>\r\nSecond\r\n")
        let result = try DocumentConverter.convert(input, to: .vtt, settings: ConversionSettings())
        XCTAssertEqual(try read(XCTUnwrap(result.outputs.first)), "WEBVTT\n\n1\n01:02:03.004 --> 01:02:05.006 align:start\n<b>First</b>\nSecond\n")
    }

    func testMalformedSubtitleDoesNotProduceAnOutput() throws {
        let input = try textFile("invalid.srt", "1\n00:00:08,000 --> 00:00:01,000\nReversed\n")
        XCTAssertThrowsError(try DocumentConverter.convert(input, to: .vtt, settings: ConversionSettings()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["invalid.srt"])
    }

    func testCSVAndTSVRoundTripQuotedFieldsAndEmbeddedNewlines() throws {
        let input = try textFile("table.csv", "name,note,empty\r\n\"A, B\",\"line 1\r\nline 2 and \"\"quote\"\"\tend\",\r\n")
        let tsv = try DocumentConverter.convert(input, to: .tsv, settings: ConversionSettings())
        XCTAssertEqual(try read(XCTUnwrap(tsv.outputs.first)), "name\tnote\tempty\nA, B\t\"line 1\r\nline 2 and \"\"quote\"\"\tend\"\t\n")
        let csv = try DocumentConverter.convert(XCTUnwrap(tsv.outputs.first), to: .csv, settings: ConversionSettings())
        XCTAssertEqual(try read(XCTUnwrap(csv.outputs.first)), try read(input))
        XCTAssertNotEqual(csv.outputs.first, input)
    }

    func testMalformedQuotedTableIsRejected() throws {
        let input = try textFile("invalid.csv", "name,value\n\"unterminated,value\n")
        XCTAssertThrowsError(try DocumentConverter.convert(input, to: .tsv, settings: ConversionSettings()))
    }

    func testOversizedTextAndNativeDocumentsAreRejectedBeforeLoading() throws {
        let fixtures: [(String, OutputFormat)] = [("txt", .md), ("csv", .tsv), ("rtf", .txt), ("docx", .txt)]
        for (ext, format) in fixtures {
            let input = directory.appendingPathComponent("oversized.\(ext)")
            XCTAssertTrue(FileManager.default.createFile(atPath: input.path, contents: nil))
            let handle = try FileHandle(forWritingTo: input)
            do {
                // A sparse fixture exercises preflight without allocating or writing 128 MiB.
                try handle.truncate(atOffset: 128 * 1_024 * 1_024 + 1)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            XCTAssertThrowsError(try DocumentConverter.convert(input, to: format, settings: ConversionSettings())) { error in
                XCTAssertTrue(error.localizedDescription.contains("128 MiB"))
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), Set(fixtures.map { "oversized.\($0.0)" }))
    }

    func testPDFTextAllPagesAndSplitMerge() throws {
        let input = try makePDF("sample.pdf", pages: ["First page", "Second page"])
        let text = try DocumentConverter.convert(input, to: .txt, settings: ConversionSettings())
        let extracted = try read(XCTUnwrap(text.outputs.first))
        XCTAssertTrue(extracted.contains("First page"))
        XCTAssertTrue(extracted.contains("Second page"))
        let split = try DocumentConverter.apply(.splitPDF, to: input, settings: ConversionSettings())
        XCTAssertEqual(split.outputs.count, 2)
        XCTAssertTrue(split.outputs.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
        let merged = try DocumentConverter.mergePDFs(split.outputs)
        let document = try XCTUnwrap(PDFDocument(url: XCTUnwrap(merged.outputs.first)))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("First page") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Second page") == true)
        XCTAssertEqual(PDFDocument(url: input)?.pageCount, 2)
    }

    func testPDFRendersEveryPageWithinDimensionLimit() throws {
        let input = try makePDF("pages.pdf", pages: ["One", "Two"])
        var settings = ConversionSettings()
        settings.pdfMaxDimension = 600
        let result = try DocumentConverter.convert(input, to: .png, settings: settings)
        XCTAssertEqual(result.outputs.count, 2)
        for output in result.outputs {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 600)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 300)
        }
    }

    func testDefaultA4PDFImageExportRetains300DPI() throws {
        let input = try makePDF("a4.pdf", pages: ["A4 page"], pageSize: CGSize(width: 595.28, height: 841.89))
        let result = try DocumentConverter.convert(input, to: .png, settings: ConversionSettings())
        let output = try XCTUnwrap(result.outputs.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2_481)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 3_508)
        let dpiWidth = try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? Double)
        let dpiHeight = try XCTUnwrap(properties[kCGImagePropertyDPIHeight] as? Double)
        XCTAssertEqual(dpiWidth, 300, accuracy: 0.01)
        XCTAssertEqual(dpiHeight, 300, accuracy: 0.01)
    }

    func testScannedPDFExportsRecognizedTextInPageOrder() throws {
        let input = try makeScannedPDF("scanned.pdf", pages: ["ORANGE123", "APPLE456"])
        let sourceData = try Data(contentsOf: input)
        let document = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertEqual(document.pageCount, 2)
        for index in 0..<document.pageCount {
            XCTAssertTrue((document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        let markdown = try DocumentConverter.convert(input, to: .md, settings: ConversionSettings())
        let extracted = try read(XCTUnwrap(markdown.outputs.first))
        let first = try XCTUnwrap(extracted.range(of: "ORANGE123"))
        let second = try XCTUnwrap(extracted.range(of: "APPLE456"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertTrue(markdown.message?.contains("local OCR for 2 pages") == true)

        let plain = try DocumentConverter.apply(.extractText, to: input, settings: ConversionSettings())
        XCTAssertEqual(try read(XCTUnwrap(plain.outputs.first)), extracted)
        XCTAssertEqual(try Data(contentsOf: input), sourceData)
    }

    func testPDFRenderingHonorsPageRotation() throws {
        let input = try makeScannedPDF("rotated.pdf", pages: ["ORANGE123"])
        let document = try XCTUnwrap(PDFDocument(url: input))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        let rotated = directory.appendingPathComponent("rotated-copy.pdf")
        XCTAssertTrue(document.write(to: rotated))
        var settings = ConversionSettings()
        settings.pdfMaxDimension = 600
        let result = try DocumentConverter.convert(rotated, to: .png, settings: settings)
        let output = try XCTUnwrap(result.outputs.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 600)
    }

    func testPDFTextExportCombinesTextLayersScansAndBlankPages() throws {
        let digital = try makePDF("digital.pdf", pages: ["Original text layer"])
        let scanned = try makeScannedPDF("mixed-scans.pdf", pages: ["", "APPLE456"])
        let merged = try DocumentConverter.mergePDFs([digital, scanned])
        let result = try DocumentConverter.convert(XCTUnwrap(merged.outputs.first), to: .txt, settings: ConversionSettings())
        let extracted = try read(XCTUnwrap(result.outputs.first))
        let first = try XCTUnwrap(extracted.range(of: "Original text layer"))
        let last = try XCTUnwrap(extracted.range(of: "APPLE456"))
        XCTAssertLessThan(first.lowerBound, last.lowerBound)
        XCTAssertTrue(extracted.contains("\n\n\n\n"), "The blank middle page keeps its place in the page separators.")
        XCTAssertTrue(result.message?.contains("local OCR for 2 pages") == true)
    }

    func testBlankScannedPDFReportsNoReadableTextWithoutPublishingOutput() throws {
        let input = try makeScannedPDF("blank.pdf", pages: [""])
        XCTAssertThrowsError(try DocumentConverter.convert(input, to: .txt, settings: ConversionSettings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("No readable text"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["blank.pdf"])
    }

    func testPDFInformationRemovalVerifiesPrivateFields() throws {
        let input = try makePDF("private.pdf", pages: ["Contents remain"])
        let original = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertEqual(original.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Private Author")
        let result = try DocumentConverter.apply(.stripMetadata, to: input, settings: ConversionSettings())
        let cleaned = try XCTUnwrap(PDFDocument(url: XCTUnwrap(result.outputs.first)))
        XCTAssertNil(cleaned.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        XCTAssertNil(cleaned.documentAttributes?[PDFDocumentAttribute.titleAttribute])
        XCTAssertEqual(cleaned.pageCount, 1)
        XCTAssertTrue(cleaned.string?.contains("Contents remain") == true)
        XCTAssertEqual(original.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Private Author")
        XCTAssertTrue(result.message?.contains("can remain") == true)
    }

    func testNativeTextRTFAndDOCXRoundTrip() throws {
        let input = try textFile("document.txt", "Orange café\nA second line.")
        for format in [OutputFormat.rtf, .docx] {
            let rich = try DocumentConverter.convert(input, to: format, settings: ConversionSettings())
            let plain = try DocumentConverter.convert(XCTUnwrap(rich.outputs.first), to: .txt, settings: ConversionSettings())
            XCTAssertEqual(try read(XCTUnwrap(plain.outputs.first)).trimmingCharacters(in: .newlines), try read(input))
        }
        XCTAssertTrue(DocumentConverter.formats(for: directory.appendingPathComponent("unsupported.pages")).isEmpty)
        XCTAssertTrue(DocumentConverter.formats(for: directory.appendingPathComponent("unsupported.xlsx")).isEmpty)
        XCTAssertTrue(DocumentConverter.formats(for: directory.appendingPathComponent("offline-unsafe.html")).isEmpty)
    }

    func testZIPAndTARStoreRelativePathsAndPreserveOriginals() throws {
        let input = try textFile("-option-looking.txt", "archive fixture")
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        for format in [OutputFormat.zip, .tar] {
            let result = try ArchiveConverter.create([input, folder], to: format)
            let output = try XCTUnwrap(result.outputs.first)
            let executable = try XCTUnwrap(ProcessRunner.executable(named: format == .zip ? "unzip" : "tar"))
            let listing = try ProcessRunner.run(executable, arguments: format == .zip ? ["-Z1", output.path] : ["-tf", output.path], currentDirectory: directory)
            XCTAssertTrue(listing.contains("-option-looking.txt"))
            XCTAssertTrue(listing.contains("folder/inside.txt"))
            XCTAssertFalse(listing.contains(directory.path))
            XCTAssertEqual(try read(input), "archive fixture")
        }
    }

    func testGZIPIsValidAndDoesNotOverwriteSource() throws {
        let input = try textFile("source.txt", "gzip fixture\n")
        let result = try ArchiveConverter.create([input], to: .gzip)
        let output = try XCTUnwrap(result.outputs.first)
        let executable = try XCTUnwrap(ProcessRunner.executable(named: "gzip"))
        let decoded = try ProcessRunner.run(executable, arguments: ["-dc", "--", output.path], currentDirectory: directory)
        XCTAssertEqual(decoded, "gzip fixture") // ProcessRunner trims command diagnostics/output.
        XCTAssertEqual(try read(input), "gzip fixture\n")
        XCTAssertThrowsError(try ArchiveConverter.create([directory], to: .gzip))
        XCTAssertTrue(ArchiveConverter.formats(for: output).isEmpty)
    }
}
