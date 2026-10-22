import Foundation

public enum ConversionOperation: Hashable, Sendable {
    case convert(OutputFormat)
    case tool(ToolKind)

    public var label: String {
        switch self { case .convert(let format): return "Convert to \(format.label)"; case .tool(let tool): return tool.label }
    }
}

public enum ConversionEngine {
    public static func formats(for input: URL) -> [OutputFormat] {
        let primary: [OutputFormat]
        switch FileFamily.detect(input) {
        case .image: primary = ImageConverter.formats(for: input)
        case .audio, .video: primary = MediaConverter.formats(for: input)
        case .archive: return []
        case .folder: primary = []
        default: primary = DocumentConverter.formats(for: input)
        }
        return primary + ArchiveConverter.formats(for: input).filter { !primary.contains($0) }
    }

    public static func commonFormats(for inputs: [URL]) -> [OutputFormat] {
        guard let first = inputs.first else { return [] }
        let formats = formats(for: first)
        let remaining = inputs.dropFirst().map { Set(self.formats(for: $0)) }
        return formats.filter { format in
            if format == .gzip && inputs.count > 1 { return false }
            return remaining.allSatisfy { $0.contains(format) }
        }
    }

    public static func tools(for input: URL) -> [ToolKind] {
        switch FileFamily.detect(input) {
        case .image: return ImageConverter.tools(for: input)
        case .video, .audio: return MediaConverter.tools(for: input)
        default: return DocumentConverter.tools(for: input)
        }
    }

    public static func commonTools(for inputs: [URL]) -> [ToolKind] {
        guard let first = inputs.first else { return [] }
        let remaining = inputs.dropFirst().map { Set(self.tools(for: $0)) }
        var tools = tools(for: first).filter { tool in remaining.allSatisfy { $0.contains(tool) } }
        if inputs.count > 1 && inputs.allSatisfy({ FileFamily.detect($0) == .pdf }) { tools.append(.mergePDF) }
        return tools
    }

    public static func run(_ operation: ConversionOperation, inputs: [URL], settings: ConversionSettings) throws -> ConversionResult {
        try Task.checkCancellation()
        guard !inputs.isEmpty else { throw OrangeError.invalidInput("Choose at least one file.") }
        for input in inputs {
            guard input.isFileURL, FileManager.default.fileExists(atPath: input.path) else {
                throw OrangeError.invalidInput("The input file no longer exists: \(input.lastPathComponent)")
            }
        }
        if operation == .tool(.mergePDF) { return try DocumentConverter.mergePDFs(inputs) }
        if case .convert(let format) = operation, [.zip, .tar, .gzip].contains(format) {
            guard format != .gzip || inputs.allSatisfy({ ArchiveConverter.formats(for: $0).contains(format) }) else {
                throw OrangeError.unsupported("Archive transcoding is unavailable. Choose files or folders to create a new archive.")
            }
            return try ArchiveConverter.create(inputs, to: format)
        }
        guard inputs.count == 1, let input = inputs.first else {
            throw OrangeError.invalidInput("This operation processes one file per job.")
        }
        switch operation {
        case .convert(let format):
            guard formats(for: input).contains(format) else { throw OrangeError.unsupported("\(format.label) is unavailable for this file. Check the Backends tab for optional converters.") }
            switch FileFamily.detect(input) {
            case .image: return try ImageConverter.convert(input, to: format, settings: settings)
            case .video, .audio: return try MediaConverter.convert(input, to: format, settings: settings)
            case .archive, .folder: return try ArchiveConverter.convert(input, to: format, settings: settings)
            default: return try DocumentConverter.convert(input, to: format, settings: settings)
            }
        case .tool(let tool):
            guard tools(for: input).contains(tool) else { throw OrangeError.unsupported("\(tool.label) is unavailable for this file.") }
            switch FileFamily.detect(input) {
            case .image: return try ImageConverter.apply(tool, to: input, settings: settings)
            case .video, .audio: return try MediaConverter.apply(tool, to: input, settings: settings)
            default: return try DocumentConverter.apply(tool, to: input, settings: settings)
            }
        }
    }
}

public struct SelectionCapabilities: Sendable {
    public let formats: [OutputFormat]
    public let tools: [ToolKind]
    public let families: [FileFamily]
    public let singleFileByteCount: Int64?
    public init(formats: [OutputFormat] = [], tools: [ToolKind] = [], families: [FileFamily] = [], singleFileByteCount: Int64? = nil) {
        self.formats = formats; self.tools = tools; self.families = families; self.singleFileByteCount = singleFileByteCount
    }
    /// May probe files or installed encoders. Always call away from the UI thread.
    public static func load(_ inputs: [URL]) -> SelectionCapabilities {
        let bytes = inputs.count == 1 ? (try? inputs[0].resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) : nil
        return SelectionCapabilities(formats: ConversionEngine.commonFormats(for: inputs), tools: ConversionEngine.commonTools(for: inputs),
                                     families: inputs.map(FileFamily.detect), singleFileByteCount: bytes)
    }
}
