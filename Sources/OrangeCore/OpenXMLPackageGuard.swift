import Compression
import Foundation

/// Preflights the package before handing it to AppKit's native Office importer.
/// No entry is extracted to disk. Actual expansion, not just ZIP size claims, is bounded.
enum OpenXMLPackageGuard {
    private static let maximumExpandedBytes = 128 * 1_024 * 1_024
    private static let maximumXMLBytes = 16 * 1_024 * 1_024
    private static let maximumDirectoryBytes = 8 * 1_024 * 1_024
    private static let maximumEntries = 10_000

    static func validate(_ input: URL) throws {
        let file = try FileHandle(forReadingFrom: input)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22, size <= UInt64(maximumExpandedBytes) else {
            throw rejected("The DOCX package is empty, invalid, or larger than 128 MiB.")
        }
        let entries = try readDirectory(file, size: size)
        let names = Set(entries.map(\.name))
        guard names.contains("[Content_Types].xml"), names.contains("word/document.xml") else {
            throw rejected("The DOCX package is missing its document or content types.")
        }
        let typeEntry = entries.first { $0.name == "[Content_Types].xml" }!
        guard typeEntry.expandedSize <= maximumXMLBytes else {
            throw rejected("The DOCX content types exceed the 16 MiB XML import limit.")
        }
        let types = try validateXML(validatePayload(file, entry: typeEntry, retain: true))
        for entry in entries {
            try Task.checkCancellation()
            try autoreleasepool {
                let xml = types.xmlExtensions.contains((entry.name as NSString).pathExtension.lowercased()) || types.xmlParts.contains(entry.name.lowercased())
                if xml && entry.expandedSize > maximumXMLBytes {
                    throw rejected("A DOCX XML part exceeds the 16 MiB import limit.")
                }
                let data = try validatePayload(file, entry: entry, retain: xml)
                if xml { _ = try validateXML(data) }
            }
        }
    }

    private struct Entry {
        let name: String
        let nameBytes: Data
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let expandedSize: Int
        let offset: UInt64
        var payloadOffset: UInt64 = 0
    }

    private static func readDirectory(_ file: FileHandle, size: UInt64) throws -> [Entry] {
        let tailSize = min(Int(size), 65_557)
        let tail = try read(file, offset: size - UInt64(tailSize), count: tailSize)
        guard let end = (0...(tail.count - 22)).reversed().first(where: {
            tail.u32($0) == 0x06054b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }) else { throw rejected("The DOCX ZIP directory is invalid.") }
        let count = Int(tail.u16(end + 10))
        let directorySize = Int(tail.u32(end + 12))
        let directoryOffset = UInt64(tail.u32(end + 16))
        guard tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == count, count > 0, count <= maximumEntries,
              directorySize <= maximumDirectoryBytes,
              directoryOffset + UInt64(directorySize) == size - UInt64(tailSize) + UInt64(end) else {
            throw rejected("DOCX packages must use a single bounded ZIP directory without ZIP64.")
        }
        let directory = try read(file, offset: directoryOffset, count: directorySize)
        var cursor = 0, totalExpanded = 0
        var names = Set<String>()
        var entries: [Entry] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor + 46 <= directory.count, directory.u32(cursor) == 0x02014b50 else {
                throw rejected("The DOCX ZIP directory is truncated.")
            }
            let flags = directory.u16(cursor + 8), method = directory.u16(cursor + 10)
            let compressed = Int(directory.u32(cursor + 20)), expanded = Int(directory.u32(cursor + 24))
            let nameLength = Int(directory.u16(cursor + 28)), extraLength = Int(directory.u16(cursor + 30))
            let length = 46 + nameLength + extraLength + Int(directory.u16(cursor + 32))
            guard cursor + length <= directory.count, directory.u16(cursor + 34) == 0,
                  flags & 0x2041 == 0, method == 0 || method == 8,
                  compressed <= maximumExpandedBytes, expanded <= maximumExpandedBytes,
                  (directory.u32(cursor + 38) >> 16) & 0xf000 != 0xa000 else {
                throw rejected("Encrypted, linked, oversized, or unsupported DOCX ZIP entries cannot be imported.")
            }
            let bytes = directory.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: bytes, encoding: .utf8), validName(name), names.insert(name.lowercased()).inserted else {
                throw rejected("The DOCX ZIP contains an unsafe or duplicate entry name.")
            }
            try validateExtra(directory.subdata(in: (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength)))
            totalExpanded += expanded
            guard totalExpanded <= maximumExpandedBytes else {
                throw rejected("The DOCX package expands beyond the 128 MiB import limit.")
            }
            entries.append(Entry(name: name, nameBytes: bytes, flags: flags, method: method,
                                 crc: directory.u32(cursor + 16), compressedSize: compressed,
                                 expandedSize: expanded, offset: UInt64(directory.u32(cursor + 42))))
            cursor += length
        }
        guard cursor == directory.count else { throw rejected("The DOCX ZIP directory contains unsupported trailing data.") }
        // Match every local header and reject overlapping entry data before decoding anything.
        var previousEnd: UInt64 = 0
        for index in entries.indices.sorted(by: { entries[$0].offset < entries[$1].offset }) {
            var entry = entries[index]
            guard entry.offset >= previousEnd, entry.offset + 30 <= directoryOffset else {
                throw rejected("DOCX ZIP entry data overlaps or is outside the package.")
            }
            let header = try read(file, offset: entry.offset, count: 30)
            let nameLength = Int(header.u16(26)), extraLength = Int(header.u16(28))
            let payload = entry.offset + UInt64(30 + nameLength + extraLength)
            guard header.u32(0) == 0x04034b50, header.u16(6) == entry.flags, header.u16(8) == entry.method,
                  payload + UInt64(entry.compressedSize) <= directoryOffset,
                  try read(file, offset: entry.offset + 30, count: nameLength) == entry.nameBytes else {
                throw rejected("The DOCX local ZIP headers do not match its directory.")
            }
            if entry.flags & 8 == 0 {
                guard header.u32(14) == entry.crc, Int(header.u32(18)) == entry.compressedSize,
                      Int(header.u32(22)) == entry.expandedSize else {
                    throw rejected("The DOCX ZIP sizes do not match its directory.")
                }
            }
            var payloadEnd = payload + UInt64(entry.compressedSize)
            if entry.flags & 8 != 0 {
                guard payloadEnd + 12 <= directoryOffset else { throw rejected("A DOCX ZIP data descriptor is truncated.") }
                let signature = try read(file, offset: payloadEnd, count: 4).u32(0) == 0x08074b50
                let descriptorOffset = payloadEnd + (signature ? 4 : 0)
                guard descriptorOffset + 12 <= directoryOffset else { throw rejected("A DOCX ZIP data descriptor is truncated.") }
                let descriptor = try read(file, offset: descriptorOffset, count: 12)
                guard descriptor.u32(0) == entry.crc, Int(descriptor.u32(4)) == entry.compressedSize,
                      Int(descriptor.u32(8)) == entry.expandedSize,
                      [0, entry.crc].contains(header.u32(14)),
                      [0, UInt32(entry.compressedSize)].contains(header.u32(18)),
                      [0, UInt32(entry.expandedSize)].contains(header.u32(22)) else {
                    throw rejected("The DOCX ZIP data descriptor does not match its directory.")
                }
                payloadEnd = descriptorOffset + 12
            }
            try validateExtra(read(file, offset: entry.offset + UInt64(30 + nameLength), count: extraLength))
            entry.payloadOffset = payload
            entries[index] = entry
            previousEnd = payloadEnd
        }
        return entries
    }

    private static func validatePayload(_ file: FileHandle, entry: Entry, retain: Bool) throws -> Data {
        var retained = Data(), expanded = 0, crc = UInt32.max
        func consume(_ bytes: UnsafeRawBufferPointer) throws {
            expanded += bytes.count
            guard expanded <= entry.expandedSize else { throw rejected("A DOCX ZIP entry expands beyond its declared size.") }
            for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
            if retain { retained.append(contentsOf: bytes) }
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        if entry.method == 8 {
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
                throw rejected("The DOCX ZIP decoder could not be created.")
            }
        }
        defer { if entry.method == 8 { compression_stream_destroy(&stream) } }
        var remaining = entry.compressedSize, offset = entry.payloadOffset, ended = false
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try read(file, offset: offset, count: min(65_536, remaining))
            remaining -= chunk.count
            offset += UInt64(chunk.count)
            try chunk.withUnsafeBytes { input in
                if entry.method == 0 { try consume(input); return }
                stream.src_ptr = input.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = input.count
                repeat {
                    try Task.checkCancellation()
                    let previousInput = stream.src_size
                    stream.dst_ptr = buffer
                    stream.dst_size = 65_536
                    let status = compression_stream_process(&stream, remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    try consume(UnsafeRawBufferPointer(start: buffer, count: 65_536 - stream.dst_size))
                    guard status != COMPRESSION_STATUS_ERROR else { throw rejected("A DOCX ZIP entry is damaged.") }
                    if status == COMPRESSION_STATUS_END {
                        guard stream.src_size == 0, remaining == 0 else { throw rejected("A DOCX ZIP entry has trailing compressed data.") }
                        ended = true
                        break
                    }
                    guard stream.src_size < previousInput || stream.dst_size < 65_536 else {
                        throw rejected("The DOCX ZIP decoder made no progress.")
                    }
                    if stream.src_size == 0 && stream.dst_size > 0 { break }
                } while true
            }
            if ended { break }
        }
        guard (entry.method == 0 || ended), expanded == entry.expandedSize, ~crc == entry.crc else {
            throw rejected("A DOCX ZIP entry has invalid expanded size or checksum.")
        }
        return retained
    }

    private static func validateXML(_ data: Data) throws -> PackageXMLDelegate {
        // Scan ASCII declaration tokens with NULs ignored so UTF-8/16/32 encodings
        // receive the same policy before any XML parser can expand a DTD.
        for declaration in [Array("<!DOCTYPE".utf8), Array("<!ENTITY".utf8)] {
            var matched = 0
            for byte in data where byte != 0 {
                let upper = byte >= 97 && byte <= 122 ? byte - 32 : byte
                matched = upper == declaration[matched] ? matched + 1 : (upper == declaration[0] ? 1 : 0)
                if matched == declaration.count { throw rejected("DOCX XML declarations and entities cannot be imported.") }
            }
        }
        let delegate = PackageXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw rejected(delegate.failure ?? "The DOCX package contains invalid XML.")
        }
        return delegate
    }

    private static func validName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains(":") &&
        !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) &&
        parts.enumerated().allSatisfy { index, part in
            part != "." && part != ".." && (!part.isEmpty || index == parts.count - 1)
        }
    }

    private static func validateExtra(_ extra: Data) throws {
        var cursor = 0
        while cursor < extra.count {
            guard cursor + 4 <= extra.count else { throw rejected("The DOCX ZIP extra data is truncated.") }
            let length = Int(extra.u16(cursor + 2))
            guard extra.u16(cursor) != 1, cursor + 4 + length <= extra.count else {
                throw rejected("ZIP64 or invalid ZIP extra data is unsupported for DOCX import.")
            }
            cursor += 4 + length
        }
    }

    private static func read(_ file: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        var result = Data()
        while result.count < count {
            guard let chunk = try file.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw rejected("The DOCX ZIP is truncated.")
            }
            result.append(chunk)
        }
        return result
    }

    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func rejected(_ message: String) -> OrangeError { .unsupported(message) }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

private final class PackageXMLDelegate: NSObject, XMLParserDelegate {
    var failure: String?
    var xmlExtensions: Set<String> = ["xml", "rels", "vml"]
    var xmlParts = Set<String>()

    private func reject(_ parser: XMLParser, _ message: String) {
        failure = message
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        reject(parser, "DOCX XML entity declarations cannot be imported.")
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        reject(parser, "DOCX external XML entities cannot be imported.")
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser, "DOCX external XML entities cannot be imported.")
        return nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let element = elementName.split(separator: ":").last
        if attributes["ContentType"]?.lowercased().contains("xml") == true {
            if element == "Default", let ext = attributes["Extension"] { xmlExtensions.insert(ext.lowercased()) }
            if element == "Override", let name = attributes["PartName"] { xmlParts.insert(String(name.drop(while: { $0 == "/" })).lowercased()) }
        }
        guard element == "Relationship", let target = attributes["Target"] else { return }
        let isExternal = attributes["TargetMode"]?.lowercased() == "external" || target.hasPrefix("//") || URLComponents(string: target)?.scheme != nil
        let hyperlinkTypes: Set<String> = ["http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                                           "http://purl.oclc.org/ooxml/officeDocument/relationships/hyperlink"]
        if isExternal && !hyperlinkTypes.contains(attributes["Type"] ?? "") {
            reject(parser, "DOCX files with external linked resources cannot be imported. Embed the resources first.")
        }
    }
}
