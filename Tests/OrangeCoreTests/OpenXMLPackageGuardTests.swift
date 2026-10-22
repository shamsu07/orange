import AppKit
import Compression
import XCTest
@testable import OrangeCore

final class OpenXMLPackageGuardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path) else {
            throw XCTSkip("Run tests from Orange so fixtures stay inside the project.")
        }
        directory = workspace.appendingPathComponent(".cache/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testNativeDOCXExportPassesGuardAndImportsText() throws {
        let input = directory.appendingPathComponent("native.docx")
        let text = NSAttributedString(string: "Orange document fixture")
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: input)
        try OpenXMLPackageGuard.validate(input)
        let output = try XCTUnwrap(DocumentConverter.convert(input, to: .txt, settings: ConversionSettings()).outputs.first)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), text.string)
        XCTAssertEqual(try Data(contentsOf: input), data)
    }

    func testStoredAndDeflatedPackagesAreValidatedWithoutExtraction() throws {
        for deflated in [false, true] {
            var parts = standardParts(deflated: deflated)
            // Enough incompressible input to cross input and output buffer boundaries.
            var state: UInt32 = 123
            let payload = Data((0..<200_000).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 16)
            })
            parts.append(Part(name: "word/media/data.bin", bytes: payload, deflated: deflated))
            let input = try package(parts: parts)
            try OpenXMLPackageGuard.validate(input)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testExpandedSizeLimitAndLyingDeflateSizeAreRejected() throws {
        var parts = standardParts()
        parts.append(Part(name: "word/media/large.bin", bytes: Data(), declaredSize: 128 * 1_024 * 1_024 + 1))
        XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: parts)))
        parts = standardParts()
        parts.append(Part(name: "word/media/bomb.bin", bytes: Data(repeating: 0x41, count: 100_000), declaredSize: 1, deflated: true))
        XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: parts))) { error in
            XCTAssertTrue(error.localizedDescription.contains("beyond its declared size"))
        }
    }

    func testTraversalDuplicateSymlinkAndEncryptedEntriesAreRejected() throws {
        for part in [Part(name: "../outside", bytes: Data()),
                     Part(name: "WORD/DOCUMENT.XML", bytes: Data()),
                     Part(name: "word/linked", bytes: Data("target".utf8), attributes: 0xa1ff0000),
                     Part(name: "word/encrypted", bytes: Data(), flags: 1)] {
            XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: standardParts() + [part])))
        }
    }

    func testInvalidChecksumAndMismatchedLocalHeaderAreRejected() throws {
        var parts = standardParts()
        parts.append(Part(name: "word/media/data.bin", bytes: Data([1, 2, 3]), checksum: 0))
        XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: parts)))
        parts = standardParts()
        parts[1].localName = "word/other.xml"
        XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: parts)))
    }

    func testExternalImageRelationshipIsRejectedButHyperlinkIsAllowed() throws {
        for kind in ["image", "hyperlink"] {
            let xml = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(kind)\" Target=\"https://example.invalid/content\" TargetMode=\"External\"/></Relationships>"
            let input = try package(parts: standardParts() + [Part(name: "word/_rels/document.xml.rels", bytes: Data(xml.utf8))])
            if kind == "image" {
                XCTAssertThrowsError(try OpenXMLPackageGuard.validate(input)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("external linked resources"))
                }
            } else { try OpenXMLPackageGuard.validate(input) }
        }
    }

    func testDTDAndEntitiesAreRejectedInUTF8AndUTF16BeforeImport() throws {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE document [<!ENTITY secret SYSTEM \"file:///not-read\">]><document>&secret;</document>"
        for encoding in [String.Encoding.utf8, .utf16] {
            var parts = standardParts()
            parts[1].bytes = try XCTUnwrap(xml.data(using: encoding))
            let input = try package(parts: parts)
            XCTAssertThrowsError(try DocumentConverter.convert(input, to: .txt, settings: ConversionSettings())) { error in
                XCTAssertTrue(error.localizedDescription.contains("XML declarations and entities"))
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testTruncatedAndMissingRequiredPartsAreRejected() throws {
        let input = try package(parts: standardParts())
        let complete = try Data(contentsOf: input)
        try complete.dropLast().write(to: input)
        XCTAssertThrowsError(try OpenXMLPackageGuard.validate(input))
        XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: [standardParts()[0]])))
    }

    func testContentTypeXMLWithNonstandardExtensionReceivesEntityChecks() throws {
        var parts = standardParts()
        parts[0].bytes = Data("<Types><Override PartName=\"/word/unusual.bin\" ContentType=\"application/xml\"/></Types>".utf8)
        parts.append(Part(name: "word/unusual.bin", bytes: Data("<!DOCTYPE document SYSTEM \"file:///not-read\"><document/>".utf8)))
        XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: parts))) { error in
            XCTAssertTrue(error.localizedDescription.contains("XML declarations and entities"))
        }
    }

    func testDataDescriptorsMustMatchVerifiedPayloadAndDirectory() throws {
        for signature in [false, true] {
            var parts = standardParts(deflated: true)
            parts[1].flags = 8
            parts[1].descriptorSignature = signature
            try OpenXMLPackageGuard.validate(package(parts: parts))
            parts[1].descriptorSize = 128 * 1_024 * 1_024
            XCTAssertThrowsError(try OpenXMLPackageGuard.validate(package(parts: parts))) { error in
                XCTAssertTrue(error.localizedDescription.contains("data descriptor"))
            }
        }
    }

    private struct Part {
        var name: String
        var bytes: Data
        var declaredSize: Int? = nil
        var deflated = false
        var attributes: UInt32 = 0
        var flags: UInt16 = 0
        var checksum: UInt32? = nil
        var localName: String? = nil
        var descriptorSignature = true
        var descriptorSize: Int? = nil
    }

    private func standardParts(deflated: Bool = false) -> [Part] {
        [Part(name: "[Content_Types].xml", bytes: Data("<Types/>".utf8), deflated: deflated),
         Part(name: "word/document.xml", bytes: Data("<document><body>Fixture</body></document>".utf8), deflated: deflated)]
    }

    private func package(parts: [Part]) throws -> URL {
        var data = Data(), directory = Data()
        for part in parts {
            let offset = data.count, name = Data(part.name.utf8), localName = Data((part.localName ?? part.name).utf8)
            let payload: Data
            if part.deflated {
                var output = [UInt8](repeating: 0, count: max(256, part.bytes.count + 256))
                let count = part.bytes.withUnsafeBytes { input in
                    output.withUnsafeMutableBytes { destination in
                        compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                                                  input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                    }
                }
                XCTAssertGreaterThan(count, 0)
                payload = Data(output.prefix(count))
            } else { payload = part.bytes }
            let method: UInt16 = part.deflated ? 8 : 0
            let crc = part.checksum ?? checksum(part.bytes)
            let expanded = UInt32(part.declaredSize ?? part.bytes.count)
            data.append32(0x04034b50); data.append16(20); data.append16(part.flags); data.append16(method)
            data.append32(0)
            data.append32(part.flags & 8 == 0 ? crc : 0)
            data.append32(part.flags & 8 == 0 ? UInt32(payload.count) : 0)
            data.append32(part.flags & 8 == 0 ? expanded : 0)
            data.append16(UInt16(localName.count)); data.append16(0); data.append(localName); data.append(payload)
            if part.flags & 8 != 0 {
                if part.descriptorSignature { data.append32(0x08074b50) }
                data.append32(crc); data.append32(UInt32(payload.count)); data.append32(UInt32(part.descriptorSize ?? Int(expanded)))
            }
            directory.append32(0x02014b50); directory.append16(0x0314); directory.append16(20)
            directory.append16(part.flags); directory.append16(method); directory.append32(0); directory.append32(crc)
            directory.append32(UInt32(payload.count)); directory.append32(expanded); directory.append16(UInt16(name.count))
            directory.append16(0); directory.append16(0); directory.append16(0); directory.append16(0)
            directory.append32(part.attributes); directory.append32(UInt32(offset)); directory.append(name)
        }
        let directoryOffset = data.count
        data.append(directory); data.append32(0x06054b50); data.append32(0)
        data.append16(UInt16(parts.count)); data.append16(UInt16(parts.count))
        data.append32(UInt32(directory.count)); data.append32(UInt32(directoryOffset)); data.append16(0)
        let url = self.directory.appendingPathComponent("\(UUID().uuidString).docx")
        try data.write(to: url)
        return url
    }

    private func checksum(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        }
        return ~value
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func append32(_ value: UInt32) { append16(UInt16(truncatingIfNeeded: value)); append16(UInt16(truncatingIfNeeded: value >> 16)) }
}
