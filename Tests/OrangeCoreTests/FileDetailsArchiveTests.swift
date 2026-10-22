import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import OrangeCore

final class FileDetailsArchiveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".cache/tests/details-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testDetailsReadsExactBytesAndFolderWithoutRecursing() throws {
        let input = root.appendingPathComponent("sample.txt")
        try Data("sample".utf8).write(to: input)
        let detail = try FileDetails.load(input)
        XCTAssertTrue(detail.text.contains("6 bytes"))
        XCTAssertTrue(detail.text.contains(input.path))
        XCTAssertTrue(detail.text.contains("Modified"))
        let folder = try FileDetails.load(root)
        XCTAssertTrue(folder.text.contains("Not scanned"))
        XCTAssertFalse(folder.text.contains("sample.txt"))
    }

    func testDetailsShowsImagePixelsAndMetadataWithoutChangingSource() throws {
        let input = root.appendingPathComponent("image.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: input)
        let detail = try FileDetails.load(input)
        XCTAssertTrue(detail.text.contains("80 × 40 px"))
        XCTAssertTrue(detail.text.contains("public.png"))
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testSelectedFilesFromDifferentFoldersCreateOneZipWithIntactContents() throws {
        let firstFolder = root.appendingPathComponent("one")
        let otherFolder = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let first = firstFolder.appendingPathComponent("first.txt")
        let second = otherFolder.appendingPathComponent("-second.txt")
        try Data("first content".utf8).write(to: first)
        try Data("second content".utf8).write(to: second)
        let result = try ConversionEngine.run(.convert(.zip), inputs: [first, second], settings: ConversionSettings())
        let output = try XCTUnwrap(result.outputs.first)
        let unzip = try XCTUnwrap(ProcessRunner.executable(named: "unzip"))
        let listing = try ProcessRunner.run(unzip, arguments: ["-Z1", output.path], currentDirectory: root)
        XCTAssertTrue(listing.contains("first.txt"))
        XCTAssertTrue(listing.contains("-second.txt"))
        XCTAssertFalse(listing.contains(root.path))
        XCTAssertEqual(try ProcessRunner.run(unzip, arguments: ["-p", output.path, "first.txt"], currentDirectory: root), "first content")
        XCTAssertEqual(try ProcessRunner.run(unzip, arguments: ["-p", output.path, "-second.txt"], currentDirectory: root), "second content")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second content")
    }

    func testArchiveRejectsCollidingNamesBeforeWritingOutput() throws {
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("same.txt"), second = child.appendingPathComponent("same.txt")
        try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
        XCTAssertThrowsError(try ArchiveConverter.create([first, second], to: .zip))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".zip") })
    }
}
