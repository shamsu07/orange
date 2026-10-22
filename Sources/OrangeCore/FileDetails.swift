import Foundation
import UniformTypeIdentifiers
import ImageIO
import PDFKit

public struct FileDetails: Sendable {
    public struct Field: Sendable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
    }
    public struct Section: Sendable, Identifiable {
        public let title: String
        public let fields: [Field]
        public var id: String { title }
    }
    public let url: URL
    public let sections: [Section]
    public var text: String {
        sections.map { section in section.title + "\n" + section.fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// Reads metadata, without recursively enumerating directories or decoding
    /// image pixels. Native media probing runs on the caller's worker thread.
    public static func load(_ url: URL) throws -> FileDetails {
        try Task.checkCancellation()
        guard url.isFileURL else { throw OrangeError.invalidInput("Select a local file to inspect.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileAllocatedSizeKey, .isReadableKey])
        let type = attributes[.type] as? FileAttributeType
        var fields = [Field(label: "Name", value: url.lastPathComponent),
                      Field(label: "Location", value: url.deletingLastPathComponent().path),
                      Field(label: "Full path", value: url.path),
                      Field(label: "Kind", value: type == .typeDirectory ? "Folder" : type == .typeSymbolicLink ? "Symbolic link" : values.contentType?.localizedDescription ?? "File")]
        if let identifier = values.contentType?.identifier { fields.append(Field(label: "Type identifier", value: identifier)) }
        if type != .typeDirectory, let count = attributes[.size] as? NSNumber {
            fields.append(Field(label: "Size", value: "\(ByteCountFormatter.string(fromByteCount: count.int64Value, countStyle: .file)) (\(count.int64Value) bytes)"))
        }
        if let size = values.fileAllocatedSize { fields.append(Field(label: "Allocated on disk", value: "\(size) bytes")) }
        let dates: [(String, FileAttributeKey)] = [("Created", .creationDate), ("Modified", .modificationDate)]
        for (name, key) in dates {
            if let date = attributes[key] as? Date { fields.append(Field(label: name, value: date.formatted(date: .complete, time: .complete))) }
        }
        if let permissions = attributes[.posixPermissions] as? NSNumber { fields.append(Field(label: "Permissions", value: String(format: "%03o", permissions.intValue))) }
        fields.append(Field(label: "Readable", value: values.isReadable == true ? "Yes" : "No"))
        var sections = [Section(title: "File", fields: fields)]
        if type == .typeDirectory {
            sections.append(Section(title: "Folder", fields: [Field(label: "Contents", value: "Not scanned. Folder size is not calculated recursively.")]))
        } else if type == .typeSymbolicLink {
            sections.append(Section(title: "Link", fields: [Field(label: "Destination", value: try FileManager.default.destinationOfSymbolicLink(atPath: url.path))]))
        } else {
            switch FileFamily.detect(url) {
            case .image:
                if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                    var image = [Field(label: "Frames / pages", value: "\(CGImageSourceGetCount(source))")]
                    if let size = try? ImageConverter.dimensions(of: url) { image.append(Field(label: "Display dimensions", value: "\(size.width) × \(size.height) px")) }
                    image += flatten(properties)
                    sections.append(Section(title: "Image metadata", fields: image))
                }
            case .pdf:
                if let document = PDFDocument(url: url) {
                    var pdf = [Field(label: "Pages", value: "\(document.pageCount)"), Field(label: "Encrypted", value: document.isEncrypted ? "Yes" : "No"),
                               Field(label: "Locked", value: document.isLocked ? "Yes" : "No")]
                    if let page = document.page(at: 0) {
                        let bounds = page.bounds(for: .mediaBox)
                        let size = bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
                            ? String(format: "%.0f × %.0f pt", bounds.width, bounds.height) : "Invalid page dimensions"
                        pdf.append(Field(label: "First page", value: size))
                    }
                    if let attributes = document.documentAttributes { pdf += flatten(Dictionary(uniqueKeysWithValues: attributes.map { (String(describing: $0.key), $0.value) })) }
                    sections.append(Section(title: "PDF", fields: pdf))
                }
            case .video, .audio:
                do {
                    let info = try MediaConverter.inspect(url)
                    var media: [Field] = []
                    if let duration = info.duration { media.append(Field(label: "Duration", value: String(format: "%.3f seconds", duration))) }
                    if let width = info.width, let height = info.height { media.append(Field(label: "Dimensions", value: "\(width) × \(height) px")) }
                    if let rate = info.frameRate { media.append(Field(label: "Frame rate", value: String(format: "%.3f fps", rate))) }
                    if let codec = info.videoCodec { media.append(Field(label: "Video codec", value: codec)) }
                    if let codec = info.audioCodec { media.append(Field(label: "Audio codec", value: codec)) }
                    if let channels = info.audioChannels { media.append(Field(label: "Audio channels", value: "\(channels)")) }
                    if let rate = info.audioSampleRate { media.append(Field(label: "Audio sample rate", value: "\(rate) Hz")) }
                    sections.append(Section(title: "Media", fields: media))
                } catch is CancellationError { throw CancellationError() }
                catch { sections.append(Section(title: "Media", fields: [Field(label: "Details unavailable", value: error.localizedDescription)])) }
            default: break
            }
        }
        try Task.checkCancellation()
        return FileDetails(url: url, sections: sections)
    }

    private static func flatten(_ properties: [String: Any], prefix: String = "", depth: Int = 0) -> [Field] {
        guard depth < 8 else { return [Field(label: prefix, value: "Additional nested metadata is not displayed.")] }
        return properties.keys.sorted().flatMap { key -> [Field] in
            let name = prefix.isEmpty ? key : "\(prefix) · \(key)"
            let value = properties[key]!
            if let children = value as? [String: Any] { return flatten(children, prefix: name, depth: depth + 1) }
            let text: String
            if let data = value as? Data { text = "Binary data (\(data.count) bytes)" }
            else { text = String(describing: value) }
            return [Field(label: name, value: text.count > 2000 ? String(text.prefix(2000)) + "… (truncated)" : text)]
        }
    }
}
