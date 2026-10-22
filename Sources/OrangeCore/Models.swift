import Foundation
import UniformTypeIdentifiers

public enum FileFamily: String, CaseIterable, Sendable {
    case image, video, audio, pdf, document, spreadsheet, presentation, subtitle, archive, folder, unknown

    public static func detect(_ url: URL) -> FileFamily {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif", "avif", "svg": return .image
        case "mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm": return .video
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aif", "aiff", "wma", "aac": return .audio
        case "pdf": return .pdf
        case "txt", "md", "markdown", "rtf", "rtfd", "html", "htm", "doc", "docx", "pages", "epub", "textclipping": return .document
        case "csv", "tsv", "xlsx", "xls", "ods": return .spreadsheet
        case "ppt", "pptx", "key": return .presentation
        case "srt", "vtt": return .subtitle
        case "zip", "tar", "gz", "gzip", "tgz", "rar", "7z": return .archive
        default: return .unknown
        }
    }
}

public enum OutputFormat: String, CaseIterable, Codable, Sendable {
    case jpeg, png, heic, webp, tiff, bmp, gif, avif, pdf
    case mp4, mov, mkv, webm, avi, wmv
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case txt, md, html, rtf, docx, pages, epub, pptx, xlsx, ods, csv, tsv
    case srt, vtt, zip, tar, gzip

    public var label: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    public var fileExtension: String {
        switch self { case .jpeg: return "jpg"; case .tiff: return "tiff"; case .gzip: return "gz"; default: return rawValue }
    }
}

public enum ToolKind: String, CaseIterable, Sendable {
    case compress, stripMetadata, resize, rotate, extractText, mergePDF, splitPDF, qrCode
    case trim, changeSpeed, extractAudio, snapshot, normalizeAudio

    public var label: String {
        switch self {
        case .compress: return "Compress"
        case .stripMetadata: return "Remove metadata"
        case .resize: return "Resize image"
        case .rotate: return "Rotate 90°"
        case .extractText: return "Extract text"
        case .mergePDF: return "Merge PDFs"
        case .splitPDF: return "Split PDF"
        case .qrCode: return "Read QR codes"
        case .trim: return "Trim"
        case .changeSpeed: return "Change speed"
        case .extractAudio: return "Extract audio"
        case .snapshot: return "Video snapshot"
        case .normalizeAudio: return "Normalize audio"
        }
    }
    public var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .stripMetadata: return "eye.slash"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .rotate: return "rotate.right"
        case .extractText: return "text.alignleft"
        case .mergePDF: return "doc.on.doc"
        case .splitPDF: return "scissors"
        case .qrCode: return "qrcode.viewfinder"
        case .trim: return "crop.rotate"
        case .changeSpeed: return "speedometer"
        case .extractAudio: return "waveform"
        case .snapshot: return "camera"
        case .normalizeAudio: return "waveform.path"
        }
    }
}

public enum FileAction: String, CaseIterable, Sendable {
    case airDrop, float, copy, move, copyPath, terminal
    public var label: String {
        switch self { case .airDrop: return "AirDrop"; case .float: return "Float"; case .copy: return "Copy"; case .move: return "Move"; case .copyPath: return "Copy path"; case .terminal: return "Terminal" }
    }
    public var symbol: String {
        switch self { case .airDrop: return "airplayaudio"; case .float: return "rectangle.on.rectangle"; case .copy: return "doc.on.doc"; case .move: return "folder"; case .copyPath: return "link"; case .terminal: return "terminal" }
    }
}

public struct ConversionSettings: Sendable {
    public var quality: Double = 0.82
    public var stripMetadata: Bool = false
    public var maxDimension: Int = 1920
    public var pdfMaxDimension: Int = 10_000
    public var trimStart: Double = 0
    public var trimEnd: Double? = nil
    public var speed: Double = 1
    public init() {}
}

public enum OrangeError: LocalizedError {
    case unsupported(String), invalidInput(String), backendMissing(String), conversionFailed(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .unsupported(let text), .invalidInput(let text), .backendMissing(let text), .conversionFailed(let text): return text
        case .cancelled: return "Cancelled."
        }
    }
}

public struct ConversionResult: Sendable {
    public let outputs: [URL]
    public let message: String?
    public init(outputs: [URL], message: String? = nil) { self.outputs = outputs; self.message = message }
}
