import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Native document conversion. Unsupported office containers are deliberately not advertised.
public enum DocumentConverter {
    private static let textExtensions: Set<String> = ["txt", "md", "markdown"]
    private static let richExtensions: Set<String> = ["rtf", "doc", "docx"]
    private static let maximumTextInputBytes = 128 * 1_024 * 1_024

    public static func formats(for input: URL) -> [OutputFormat] {
        let ext = input.pathExtension.lowercased()
        if ext == "pdf" { return [.txt, .md, .png, .jpeg] }
        if ext == "srt" { return [.vtt, .txt] }
        if ext == "vtt" { return [.srt, .txt] }
        if ext == "csv" { return [.tsv] }
        if ext == "tsv" { return [.csv] }
        if textExtensions.contains(ext) || richExtensions.contains(ext) {
            return [.txt, .md, .html, .rtf, .docx].filter { $0.rawValue != ext }
        }
        return []
    }

    public static func tools(for input: URL) -> [ToolKind] {
        guard input.pathExtension.lowercased() == "pdf" else { return [] }
        return [.compress, .extractText, .splitPDF, .stripMetadata]
    }

    public static func convert(_ input: URL, to format: OutputFormat, settings: ConversionSettings) throws -> ConversionResult {
        try Task.checkCancellation()
        guard formats(for: input).contains(format) else {
            throw OrangeError.unsupported("Native conversion from \(input.pathExtension.uppercased()) to \(format.label) is not supported.")
        }
        switch input.pathExtension.lowercased() {
        case "pdf": return try convertPDF(input, to: format, settings: settings)
        case "srt", "vtt": return try convertSubtitles(input, to: format)
        case "csv", "tsv": return try convertDelimitedText(input, to: format)
        default: return try convertRichText(input, to: format)
        }
    }

    public static func apply(_ tool: ToolKind, to input: URL, settings: ConversionSettings) throws -> ConversionResult {
        guard input.pathExtension.lowercased() == "pdf" else {
            throw OrangeError.unsupported("This document tool requires a PDF.")
        }
        switch tool {
        case .extractText: return try convertPDF(input, to: .txt, settings: settings)
        case .splitPDF: return try splitPDF(input, settings: settings)
        case .stripMetadata: return try stripPDFInformation(input)
        case .mergePDF:
            throw OrangeError.invalidInput("Select at least two PDFs to merge.")
        case .compress:
            return try reducePDF(input, settings: settings)
        default: throw OrangeError.unsupported("This tool is unavailable for PDF files.")
        }
    }

    public static func mergePDFs(_ inputs: [URL]) throws -> ConversionResult {
        guard inputs.count >= 2, let first = inputs.first else {
            throw OrangeError.invalidInput("Select at least two PDFs to merge.")
        }
        let merged = PDFDocument()
        for input in inputs {
            try Task.checkCancellation()
            guard input.pathExtension.lowercased() == "pdf" else {
                throw OrangeError.invalidInput("Every selected file must be a PDF.")
            }
            let document = try openPDF(input)
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index)?.copy() as? PDFPage else {
                    throw OrangeError.conversionFailed("A PDF page could not be copied.")
                }
                merged.insert(page, at: merged.pageCount)
            }
        }
        let output = try writePDF(merged, beside: first, suffix: "-merged")
        return ConversionResult(outputs: [output], message: "Merged \(inputs.count) PDFs into \(merged.pageCount) pages.")
    }

    private static func openPDF(_ input: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw OrangeError.invalidInput("The PDF is empty, damaged, or unreadable.")
        }
        guard !document.isLocked else {
            throw OrangeError.unsupported("Password-protected PDFs must be unlocked before conversion.")
        }
        guard document.allowsCopying else {
            throw OrangeError.unsupported("This PDF does not permit copying or extraction.")
        }
        return document
    }

    private static func writePDF(_ document: PDFDocument, beside input: URL, suffix: String) throws -> URL {
        try OutputWriter.write(beside: input, extension: "pdf", suffix: suffix) { stage in
            guard document.write(to: stage), let verification = PDFDocument(url: stage),
                  verification.pageCount == document.pageCount else {
                throw OrangeError.conversionFailed("The PDF could not be written and verified.")
            }
        }
    }

    private static func convertPDF(_ input: URL, to format: OutputFormat, settings: ConversionSettings) throws -> ConversionResult {
        let document = try openPDF(input)
        if format == .txt || format == .md {
            var pages: [String] = []
            var ocrPages = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let text = try autoreleasepool {
                    guard let page = document.page(at: index) else {
                        throw OrangeError.conversionFailed("PDF page \(index + 1) could not be read.")
                    }
                    let textLayer = page.string ?? ""
                    if !textLayer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return textLayer }
                    // A bounded page raster avoids allocating a full-resolution scanned document.
                    let image = try renderPDFPage(page, maximumDPI: 150, maximumDimension: 2_400)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    try ImageConverter.performVision(request, on: image)
                    try Task.checkCancellation()
                    ocrPages += 1
                    return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                }
                pages.append(text)
            }
            guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw OrangeError.invalidInput("No readable text was found in this PDF's text layers or scanned pages.")
            }
            let output = try writeText(pages.joined(separator: "\n\n"), beside: input, format: format)
            let message = ocrPages > 0
                ? "Extracted text in page order, using local OCR for \(ocrPages) page\(ocrPages == 1 ? "" : "s") without a text layer. OCR can contain errors; visual layout is not reconstructed."
                : "Extracted the PDF text layer in page order. Visual layout is not reconstructed."
            return ConversionResult(outputs: [output], message: message)
        }
        guard format == .png || format == .jpeg else {
            throw OrangeError.unsupported("This PDF output format is unavailable.")
        }
        guard settings.pdfMaxDimension > 0 else {
            throw OrangeError.invalidInput("The maximum PDF page image dimension must be positive.")
        }
        var outputs: [URL] = []
        do {
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else {
                    throw OrangeError.conversionFailed("PDF page \(index + 1) could not be rendered.")
                }
                let image = try renderPDFPage(page, maximumDPI: 300, maximumDimension: settings.pdfMaxDimension)
                let bounds = page.bounds(for: .cropBox)
                let dpi = min(300, Double(min(settings.pdfMaxDimension, 10_000)) / max(bounds.width, bounds.height) * 72)
                let output = try OutputWriter.write(beside: input, extension: format.fileExtension,
                                                    suffix: String(format: "-page-%03d", index + 1)) { stage in
                    let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
                    guard let destination = CGImageDestinationCreateWithURL(stage as CFURL, type as CFString, 1, nil) else {
                        throw OrangeError.conversionFailed("The image writer could not be opened.")
                    }
                    let quality = settings.quality.isFinite ? max(0, min(1, settings.quality)) : 0.82
                    CGImageDestinationAddImage(destination, image, [
                        kCGImageDestinationLossyCompressionQuality: quality,
                        kCGImagePropertyDPIWidth: dpi,
                        kCGImagePropertyDPIHeight: dpi
                    ] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else {
                        throw OrangeError.conversionFailed("The PDF page image could not be saved.")
                    }
                }
                outputs.append(output)
            }
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        return ConversionResult(outputs: outputs, message: "Rendered all \(outputs.count) pages at up to 300 DPI.")
    }

    /// Shared by image export and OCR; CGPDF's drawing transform applies page rotation.
    private static func renderPDFPage(_ page: PDFPage, maximumDPI: Double, maximumDimension: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard maximumDimension > 0, maximumDPI.isFinite, maximumDPI > 0 else {
            throw OrangeError.invalidInput("PDF rendering requires a positive image size and resolution.")
        }
        guard let reference = page.pageRef else {
            throw OrangeError.conversionFailed("The PDF page could not be rendered.")
        }
        let bounds = reference.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw OrangeError.invalidInput("A PDF page has invalid dimensions.")
        }
        let dimension = Double(min(maximumDimension, 10_000))
        let rotated = page.rotation % 180 != 0
        let pageWidth = rotated ? bounds.height : bounds.width
        let pageHeight = rotated ? bounds.width : bounds.height
        let scale = min(maximumDPI / 72, dimension / max(pageWidth, pageHeight))
        let width = max(1, min(Int(dimension), Int(ceil(pageWidth * scale))))
        let height = max(1, min(Int(dimension), Int(ceil(pageHeight * scale))))
        guard width * height <= 40_000_000 else {
            throw OrangeError.invalidInput("The requested PDF page image exceeds the 40 megapixel rendering limit.")
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OrangeError.conversionFailed("Memory could not be allocated for the PDF page image.")
        }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else {
            throw OrangeError.conversionFailed("The PDF page image could not be created.")
        }
        return image
    }

    /// Groups are 1-based page numbers. Each page must appear exactly once, in order.
    /// Requiring an explicit partition prevents a long document silently becoming hundreds of files.
    public static func validatedSplitGroups(_ requested: [[Int]]?, pageCount: Int) throws -> [[Int]] {
        guard pageCount >= 2 else { throw OrangeError.invalidInput("This PDF has only one page to split.") }
        let groups: [[Int]]
        if let requested { groups = requested }
        else if pageCount == 2 { groups = [[1], [2]] }
        else { throw OrangeError.invalidInput("Choose where to split this PDF before continuing.") }
        guard groups.count >= 2, groups.count <= pageCount,
              groups.allSatisfy({ !$0.isEmpty }), groups.flatMap({ $0 }) == Array(1...pageCount) else {
            throw OrangeError.invalidInput("Split ranges must include every page once, in order, across at least two PDFs.")
        }
        return groups
    }

    private static func splitPDF(_ input: URL, settings: ConversionSettings) throws -> ConversionResult {
        let document = try openPDF(input)
        let groups = try validatedSplitGroups(settings.pdfPageRanges, pageCount: document.pageCount)
        var outputs: [URL] = []
        do {
            for (part, numbers) in groups.enumerated() {
                try Task.checkCancellation()
                let section = PDFDocument()
                section.documentAttributes = document.documentAttributes
                for number in numbers {
                    try Task.checkCancellation()
                    guard let page = document.page(at: number - 1)?.copy() as? PDFPage else {
                        throw OrangeError.conversionFailed("PDF page \(number) could not be copied.")
                    }
                    section.insert(page, at: section.pageCount)
                }
                let suffix = numbers.count == 1
                    ? String(format: "-page-%03d", numbers[0])
                    : String(format: "-part-%02d-pages-%03d-%03d", part + 1, numbers[0], numbers.last!)
                outputs.append(try writePDF(section, beside: input, suffix: suffix))
            }
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        return ConversionResult(outputs: outputs, message: "Split \(document.pageCount) pages into \(outputs.count) PDFs. Original preserved.")
    }

    public struct ReductionPreview: Sendable {
        public let input: URL
        public let candidate: URL
        public let originalBytes: Int64
        public let reducedBytes: Int64
        public let pageCount: Int
        public var isSmaller: Bool { reducedBytes > 0 && reducedBytes < originalBytes }
        public func discard() { try? FileManager.default.removeItem(at: candidate) }
    }

    /// Builds a real, temporary PDF for a byte-size preview. It never publishes a user-visible copy.
    /// Rasterization is deliberately explicit: text/vectors become pixels; links, forms and annotations are omitted.
    public static func previewReduction(_ input: URL, dpi: Double, quality: Double, temporaryDirectory: URL? = nil) throws -> ReductionPreview {
        try Task.checkCancellation()
        guard dpi.isFinite, (36...300).contains(dpi), quality.isFinite, (0.1...1).contains(quality) else {
            throw OrangeError.invalidInput("PDF reduction requires 36–300 DPI and image quality from 0.1 to 1.")
        }
        let document = try openPDF(input)
        let originalBytes = Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard originalBytes > 0 else { throw OrangeError.invalidInput("The PDF is empty or unreadable.") }
        let scratch = temporaryDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("Orange/PDFPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let candidate = scratch.appendingPathComponent("orange-pdf-preview-\(UUID().uuidString).pdf")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: candidate) } }
        var initialBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let attributes = document.documentAttributes ?? [:]
        var information: [CFString: Any] = [kCGPDFContextCreator: "Orange"]
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { information[kCGPDFContextAuthor] = author }
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String { information[kCGPDFContextTitle] = title }
        if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String { information[kCGPDFContextSubject] = subject }
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] { information[kCGPDFContextKeywords] = keywords }
        guard let context = CGContext(candidate as CFURL, mediaBox: &initialBox, information as CFDictionary) else {
            throw OrangeError.conversionFailed("The reduced PDF could not be prepared.")
        }
        do {
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let page = document.page(at: index), let reference = page.pageRef else {
                        throw OrangeError.conversionFailed("PDF page \(index + 1) could not be read.")
                    }
                    let bounds = reference.getBoxRect(.cropBox)
                    let rotated = page.rotation % 180 != 0
                    var pageBox = CGRect(x: 0, y: 0, width: rotated ? bounds.height : bounds.width,
                                         height: rotated ? bounds.width : bounds.height)
                    let rendered = try renderPDFPage(page, maximumDPI: dpi, maximumDimension: 6_000)
                    let encoded = NSMutableData()
                    guard let writer = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
                        throw OrangeError.conversionFailed("The PDF image encoder could not be opened.")
                    }
                    CGImageDestinationAddImage(writer, rendered, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    guard CGImageDestinationFinalize(writer), let provider = CGDataProvider(data: encoded),
                          let compressed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                        throw OrangeError.conversionFailed("A PDF page image could not be encoded.")
                    }
                    let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
                    context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                    context.draw(compressed, in: pageBox)
                    context.endPDFPage()
                }
            }
            context.closePDF()
        } catch {
            context.closePDF()
            throw error
        }
        try Task.checkCancellation()
        guard let verified = PDFDocument(url: candidate), verified.pageCount == document.pageCount,
              let bytes = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else {
            throw OrangeError.conversionFailed("The reduced PDF could not be verified.")
        }
        succeeded = true
        return ReductionPreview(input: input, candidate: candidate, originalBytes: originalBytes,
                                reducedBytes: Int64(bytes), pageCount: document.pageCount)
    }

    public static func reducePDF(_ input: URL, settings: ConversionSettings, temporaryDirectory: URL? = nil) throws -> ConversionResult {
        guard settings.pdfAllowsRasterization else {
            throw OrangeError.invalidInput("Confirm image-based PDF reduction first. Text becomes pixels; links, forms and annotations are removed.")
        }
        let preview = try previewReduction(input, dpi: settings.pdfRasterDPI, quality: settings.pdfRasterQuality, temporaryDirectory: temporaryDirectory)
        defer { preview.discard() }
        guard preview.isSmaller else {
            throw OrangeError.unsupported("This PDF is already compact at the selected quality. No larger copy was saved. Try a smaller quality preset or keep the original.")
        }
        let output = try OutputWriter.write(beside: input, extension: "pdf", suffix: "-reduced") { stage in
            try FileManager.default.copyItem(at: preview.candidate, to: stage)
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return ConversionResult(outputs: [output], message: "Reduced \(formatter.string(fromByteCount: preview.originalBytes)) → \(formatter.string(fromByteCount: preview.reducedBytes)). Image-based PDF; text became pixels and interactive content was removed. Original preserved.")
    }

    private static func stripPDFInformation(_ input: URL) throws -> ConversionResult {
        let document = try openPDF(input)
        let fields: [PDFDocumentAttribute] = [.authorAttribute, .titleAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute]
        let present = fields.contains { document.documentAttributes?[$0] != nil }
        guard present else {
            throw OrangeError.unsupported("This PDF has no supported document-information fields to remove. Embedded content metadata is not inspected.")
        }
        document.documentAttributes = [:]
        let output = try OutputWriter.write(beside: input, extension: "pdf", suffix: "-cleaned") { stage in
            guard document.write(to: stage), let checked = PDFDocument(url: stage), checked.pageCount == document.pageCount else {
                throw OrangeError.conversionFailed("The PDF could not be written and verified.")
            }
            if fields.contains(where: { checked.documentAttributes?[$0] != nil }) {
                throw OrangeError.unsupported("The native PDF writer retained document-information fields; metadata removal could not be verified.")
            }
        }
        return ConversionResult(outputs: [output], message: "Removed and verified PDF author, title, subject, keywords, and creator fields. System-generated dates, embedded XMP, attachments, and image metadata can remain.")
    }

    private static func convertRichText(_ input: URL, to format: OutputFormat) throws -> ConversionResult {
        let ext = input.pathExtension.lowercased()
        let attributed: NSAttributedString
        if textExtensions.contains(ext) {
            attributed = NSAttributedString(string: try readText(input))
        } else {
            try validateTextInputSize(input)
            if ext == "docx" { try OpenXMLPackageGuard.validate(input) }
            let type: NSAttributedString.DocumentType
            switch ext {
            case "rtf": type = .rtf
            case "doc": type = .docFormat
            case "docx": type = .officeOpenXML
            default: throw OrangeError.unsupported("A native importer is unavailable for this document.")
            }
            do {
                attributed = try NSAttributedString(url: input, options: [.documentType: type], documentAttributes: nil)
            } catch {
                throw OrangeError.invalidInput("The native document importer could not read this file: \(error.localizedDescription)")
            }
        }
        if format == .txt || format == .md {
            let output = try writeText(attributed.string, beside: input, format: format)
            return ConversionResult(outputs: [output], message: "Exported plain text. Rich formatting is not represented in TXT or Markdown.")
        }
        let type: NSAttributedString.DocumentType
        switch format {
        case .html: type = .html
        case .rtf: type = .rtf
        case .docx: type = .officeOpenXML
        default: throw OrangeError.unsupported("This native document export format is unavailable.")
        }
        let output = try OutputWriter.write(beside: input, extension: format.fileExtension) { stage in
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue])
            try data.write(to: stage)
        }
        let message = textExtensions.contains(ext)
            ? "Exported the source as plain text inside \(format.label). Markdown syntax is preserved as text, not rendered."
            : "Converted with the macOS document importer and exporter. Complex office layouts can change."
        return ConversionResult(outputs: [output], message: message)
    }

    private static func readText(_ input: URL) throws -> String {
        try validateTextInputSize(input)
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        guard data.count <= maximumTextInputBytes else {
            throw OrangeError.unsupported("Text and native document inputs are limited to 128 MiB.")
        }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) }
        guard var text else {
            throw OrangeError.unsupported("The text must use UTF-8 or UTF-16 with a byte-order mark.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return text
    }

    private static func validateTextInputSize(_ input: URL) throws {
        let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw OrangeError.invalidInput("Select a regular text or document file.")
        }
        guard let size = values.fileSize, size >= 0, size <= maximumTextInputBytes else {
            throw OrangeError.unsupported("Text and native document inputs are limited to 128 MiB.")
        }
    }

    private static func writeText(_ text: String, beside input: URL, format: OutputFormat) throws -> URL {
        guard !text.isEmpty else { throw OrangeError.invalidInput("The document contains no text to export.") }
        return try OutputWriter.write(beside: input, extension: format.fileExtension) { stage in
            try Data(text.utf8).write(to: stage)
        }
    }

    private struct Cue {
        var identifier: String?
        var start: Int
        var end: Int
        var settings: String
        var text: String
    }

    private static func convertSubtitles(_ input: URL, to format: OutputFormat) throws -> ConversionResult {
        let isVTT = input.pathExtension.lowercased() == "vtt"
        let source = try readText(input).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let cues = try parseSubtitles(source, isVTT: isVTT)
        let result: String
        if format == .txt {
            result = cues.map { plainSubtitleText($0.text) }.joined(separator: "\n\n") + "\n"
        } else if format == .vtt {
            result = "WEBVTT\n\n" + cues.enumerated().map { index, cue in
                let identifier = cue.identifier ?? String(index + 1)
                return "\(identifier)\n\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\(cue.settings.isEmpty ? "" : " " + cue.settings)\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        } else {
            result = cues.enumerated().map { index, cue in
                "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        }
        let output = try writeText(result, beside: input, format: format)
        let message = format == .srt && isVTT
            ? "Converted \(cues.count) cues. SRT cannot represent WebVTT cue identifiers, positioning, regions, or style blocks."
            : "Exported \(cues.count) subtitle cues."
        return ConversionResult(outputs: [output], message: message)
    }

    private static func parseSubtitles(_ source: String, isVTT: Bool) throws -> [Cue] {
        let blocks = source.components(separatedBy: try NSRegularExpression(pattern: "\\n[ \\t]*\\n"))
        var cues: [Cue] = []
        var first = true
        for block in blocks {
            try Task.checkCancellation()
            let block = block.trimmingCharacters(in: .newlines)
            if block.isEmpty { continue }
            let lines = block.components(separatedBy: "\n")
            if first && isVTT {
                guard lines[0] == "WEBVTT" || lines[0].hasPrefix("WEBVTT ") || lines[0].hasPrefix("WEBVTT\t") else {
                    throw OrangeError.invalidInput("A WebVTT subtitle must begin with a WEBVTT header.")
                }
                first = false
                continue
            }
            first = false
            if isVTT && (lines[0] == "STYLE" || lines[0] == "REGION" || lines[0] == "NOTE" || lines[0].hasPrefix("NOTE ") || lines[0].hasPrefix("NOTE\t")) { continue }
            let timingIndex: Int
            if lines[0].contains("-->") { timingIndex = 0 }
            else if lines.count > 1 && lines[1].contains("-->") { timingIndex = 1 }
            else { throw OrangeError.invalidInput("A subtitle cue has no valid timing line.") }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2 else { throw OrangeError.invalidInput("A subtitle cue has an invalid timing line.") }
            let left = timing[0].trimmingCharacters(in: .whitespaces)
            let right = timing[1].trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let endText = right.first else { throw OrangeError.invalidInput("A subtitle cue has no end timestamp.") }
            let start = try parseTimestamp(left)
            let end = try parseTimestamp(String(endText))
            guard end >= start else { throw OrangeError.invalidInput("A subtitle cue ends before it starts.") }
            let settings = right.count > 1 ? String(right[1]).trimmingCharacters(in: .whitespaces) : ""
            cues.append(Cue(identifier: timingIndex == 1 ? lines[0] : nil, start: start, end: end, settings: settings,
                            text: lines.dropFirst(timingIndex + 1).joined(separator: "\n")))
        }
        guard !cues.isEmpty else { throw OrangeError.invalidInput("The subtitle file contains no valid cues.") }
        return cues
    }

    private static func parseTimestamp(_ value: String) throws -> Int {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3 else { throw OrangeError.invalidInput("Invalid subtitle timestamp: \(value)") }
        let secondsParts = pieces.last!.split(separator: ".", omittingEmptySubsequences: false)
        let minuteText = pieces[pieces.count - 2]
        let hourText = pieces.count == 3 ? pieces[0] : "0"
        guard secondsParts.count == 2, secondsParts[0].count == 2, secondsParts[1].count == 3,
              minuteText.count == 2,
              [String(hourText), String(minuteText), String(secondsParts[0]), String(secondsParts[1])].allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let hours = Int(hourText), let minutes = Int(minuteText), let seconds = Int(secondsParts[0]),
              let millis = Int(secondsParts[1]), minutes < 60, seconds < 60, hours <= 1_000_000 else {
            throw OrangeError.invalidInput("Invalid subtitle timestamp: \(value)")
        }
        return ((hours * 60 + minutes) * 60 + seconds) * 1_000 + millis
    }

    private static func timestamp(_ milliseconds: Int, separator: String) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, milliseconds % 1_000)
    }

    private static func plainSubtitleText(_ source: String) -> String {
        var result = source.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let named = ["nbsp": " ", "lt": "<", "gt": ">", "lrm": "\u{200E}", "rlm": "\u{200F}", "quot": "\"", "apos": "'", "amp": "&"]
        if let entities = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|nbsp|lt|gt|lrm|rlm|quot|apos|amp);") {
            let matches = entities.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: result), let fullRange = Range(match.range, in: result) else { continue }
                let encoded = String(result[range])
                if let replacement = named[encoded] {
                    result.replaceSubrange(fullRange, with: replacement)
                } else {
                    let hexadecimal = encoded.hasPrefix("#x")
                    let digits = String(encoded.dropFirst(hexadecimal ? 2 : 1))
                    if let value = UInt32(digits, radix: hexadecimal ? 16 : 10), let scalar = UnicodeScalar(value) {
                        result.replaceSubrange(fullRange, with: String(scalar))
                    }
                }
            }
        }
        return result
    }

    private static func convertDelimitedText(_ input: URL, to format: OutputFormat) throws -> ConversionResult {
        let delimiter: Character = input.pathExtension.lowercased() == "csv" ? "," : "\t"
        let rows = try parseDelimitedText(try readText(input), delimiter: delimiter)
        let outputDelimiter = format == .csv ? "," : "\t"
        let lineEnding = format == .csv ? "\r\n" : "\n"
        let encoded = rows.map { row in
            row.map { value in
                if value.contains(outputDelimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: outputDelimiter)
        }.joined(separator: lineEnding) + lineEnding
        let output = try writeText(encoded, beside: input, format: format)
        return ConversionResult(outputs: [output], message: "Converted \(rows.count) rows, preserving quoted fields and embedded line breaks.")
    }

    private static func parseDelimitedText(_ source: String, delimiter: Character) throws -> [[String]] {
        guard !source.isEmpty else { throw OrangeError.invalidInput("The delimited text file is empty.") }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var endedRow = false
        var index = source.startIndex
        var scanned = 0
        while index < source.endIndex {
            if scanned % 16_384 == 0 { try Task.checkCancellation() }
            scanned += 1
            let character = source[index]
            let next = source.index(after: index)
            endedRow = false
            if quoted {
                if character == "\"" {
                    if next < source.endIndex && source[next] == "\"" {
                        field.append("\"")
                        index = source.index(after: next)
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else { field.append(character) }
            } else if character == delimiter {
                row.append(field); field = ""; closedQuote = false
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""; closedQuote = false; endedRow = true
                if character == "\r" && next < source.endIndex && source[next] == "\n" {
                    index = source.index(after: next)
                    continue
                }
            } else if character == "\"" && field.isEmpty && !closedQuote {
                quoted = true
            } else {
                guard !closedQuote && character != "\"" else {
                    throw OrangeError.invalidInput("A quoted field is malformed. Quotes must enclose the entire field and embedded quotes must be doubled.")
                }
                field.append(character)
            }
            index = next
        }
        guard !quoted else { throw OrangeError.invalidInput("A quoted field is missing its closing quote.") }
        if !endedRow { row.append(field); rows.append(row) }
        return rows
    }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..<endIndex, in: self)
        var pieces: [String] = []
        var cursor = startIndex
        for match in expression.matches(in: self, range: range) {
            guard let matchRange = Range(match.range, in: self) else { continue }
            pieces.append(String(self[cursor..<matchRange.lowerBound]))
            cursor = matchRange.upperBound
        }
        pieces.append(String(self[cursor...]))
        return pieces
    }
}
