import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OrangeCore

final class EngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path) else {
            throw XCTSkip("Run tests from the Orange workspace so fixtures stay inside the project.")
        }
        directory = workspace.appendingPathComponent(".cache/tests/engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testMergePDFIsAbsentForSingleInput() throws {
        let input = try pdf("single.pdf")
        XCTAssertFalse(ConversionEngine.tools(for: input).contains(.mergePDF))
        XCTAssertFalse(ConversionEngine.commonTools(for: [input]).contains(.mergePDF))
    }

    func testMergePDFIsListedExactlyOnceForMultiplePDFs() throws {
        let inputs = try [pdf("first.pdf"), pdf("second.pdf"), pdf("third.pdf")]
        let tools = ConversionEngine.commonTools(for: inputs)
        XCTAssertEqual(tools.filter { $0 == .mergePDF }.count, 1)
        XCTAssertEqual(Set(tools).count, tools.count)
    }

    func testMergePDFIsAbsentForMixedInputs() throws {
        let input = try pdf("document.pdf")
        let text = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: text)
        XCTAssertFalse(ConversionEngine.commonTools(for: [input, text]).contains(.mergePDF))
    }

    func testCompressionRemainsAvailableWithinAFamilyButNotAcrossImageAndPDF() throws {
        let document = try pdf("document.pdf")
        let image = directory.appendingPathComponent("image.jpg")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertTrue(ConversionEngine.commonTools(for: [image]).contains(.compress))
        XCTAssertTrue(ConversionEngine.commonTools(for: [document, document]).contains(.compress))

        for selection in [[image, document], [document, image]] {
            let tools = ConversionEngine.commonTools(for: selection)
            XCTAssertFalse(tools.contains(.compress))
            XCTAssertTrue(tools.contains(.stripMetadata))
            XCTAssertTrue(tools.contains(.extractText))
        }
    }

    private func pdf(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
