import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreML

public enum ImageConverter {
    public struct Dimensions: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public var longEdge: Int { max(width, height) }

        /// Pixel dimensions after an aspect-preserving downsample. The shorter
        /// edge is rounded to the nearest whole pixel; images are never enlarged.
        public func fitting(maximumDimension: Int) throws -> Dimensions {
            guard (1...16_384).contains(maximumDimension) else {
                throw OrangeError.invalidInput("The maximum image dimension must be between 1 and 16,384 pixels.")
            }
            guard longEdge > maximumDimension else { return self }
            let scale = Double(maximumDimension) / Double(longEdge)
            return Dimensions(width: max(1, Int((Double(width) * scale).rounded())),
                              height: max(1, Int((Double(height) * scale).rounded())))
        }
    }

    /// Display-oriented dimensions, read from metadata without decoding pixels.
    public static func dimensions(of input: URL) throws -> Dimensions { try open(input).dimensions }

    /// A static image only: animated GIFs, image sequences, and multipage TIFFs are rejected.
    public static func formats(for input: URL) -> [OutputFormat] {
        guard let opened = try? open(input) else { return [] }
        let encoders = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return imageFormats.filter {
            if $0 == .webp {
                return opened.width <= 16_383 && opened.height <= 16_383 && encoderAvailable(.webp)
            }
            return $0 == .pdf || encoders.contains(identifier(for: $0))
        }
    }

    public static func tools(for input: URL) -> [ToolKind] {
        guard (try? open(input)) != nil else { return [] }
        var result: [ToolKind] = [.resize, .rotate, .qrCode, .extractText]
        if let format = originalFormat(input), formats(for: input).contains(format) {
            result.insert(.stripMetadata, at: 0)
            if [.jpeg, .heic].contains(format) { result.insert(.compress, at: 0) }
        }
        return result
    }

    public static func convert(_ input: URL, to format: OutputFormat, settings: ConversionSettings) throws -> ConversionResult {
        try validate(settings)
        let opened = try open(input)
        defer { CGImageSourceRemoveCacheAtIndex(opened.source, 0) }
        guard imageFormats.contains(format), format == .pdf || encoderAvailable(format) else {
            if format == .webp {
                throw OrangeError.backendMissing("WebP export requires an FFmpeg build with libwebp enabled. Build Orange's included backend or select a compatible FFmpeg installation.")
            }
            throw OrangeError.unsupported("macOS does not provide a \(format.label) image encoder on this computer.")
        }
        let image = try decode(opened)
        let output = try save(image, source: opened.source, input: input, format: format, settings: settings)
        return ConversionResult(outputs: [output], message: format == .webp && !nativeEncoderAvailable(.webp)
            ? "Descriptive metadata is removed during WebP conversion." : nil)
    }

    public static func apply(_ tool: ToolKind, to input: URL, settings: ConversionSettings) throws -> ConversionResult {
        try validate(settings)
        let opened = try open(input)
        defer { CGImageSourceRemoveCacheAtIndex(opened.source, 0) }
        let resizeDimensions: Dimensions?
        if tool == .resize {
            let target = try opened.dimensions.fitting(maximumDimension: settings.maxDimension)
            guard target != opened.dimensions else {
                throw OrangeError.invalidInput("This image is already \(target.width) × \(target.height) pixels, within the selected \(settings.maxDimension)-pixel limit. Choose a smaller long edge to resize it. No copy was created.")
            }
            resizeDimensions = target
        } else {
            resizeDimensions = nil
        }
        // Ask ImageIO to downsample during decode instead of allocating a full-size
        // bitmap and a second resized bitmap for a large camera photograph.
        let image = try decode(opened, maximumDimension: tool == .resize ? settings.maxDimension : nil)
        if tool == .qrCode || tool == .extractText {
            let text: String
            if tool == .qrCode {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try performVision(request, on: image)
                let values = request.results?.compactMap(\.payloadStringValue) ?? []
                guard !values.isEmpty else { throw OrangeError.invalidInput("No readable QR codes were found in this image.") }
                text = values.joined(separator: "\n") + "\n"
            } else {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try performVision(request, on: image)
                let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                guard !lines.isEmpty else { throw OrangeError.invalidInput("No readable text was found in this image.") }
                text = lines.joined(separator: "\n") + "\n"
            }
            try Task.checkCancellation()
            let output = try OutputWriter.write(beside: input, extension: "txt", suffix: tool == .qrCode ? "-qr" : "-text") {
                try text.write(to: $0, atomically: false, encoding: .utf8)
            }
            return ConversionResult(outputs: [output])
        }

        let format = originalFormat(input) ?? .png
        guard encoderAvailable(format) else {
            throw OrangeError.unsupported("macOS cannot rewrite this image format. Convert it to PNG or JPEG first.")
        }
        var adjusted = settings
        var result = image
        let suffix: String
        switch tool {
        case .resize:
            if let size = resizeDimensions, image.width != size.width || image.height != size.height {
                // ImageIO's thumbnail rounding varies by source encoder. Match
                // the dimensions shown in the resize confirmation exactly.
                result = try render(image, width: size.width, height: size.height)
            }
            suffix = "-resized"
        case .rotate:
            result = try rotateClockwise(image)
            suffix = "-rotated"
        case .stripMetadata:
            adjusted.stripMetadata = true
            suffix = "-clean"
        case .compress:
            guard [.jpeg, .heic].contains(format) else {
                throw OrangeError.unsupported("Image compression is available for JPEG and HEIC. Convert this image to either format first.")
            }
            suffix = "-compressed"
        default:
            throw OrangeError.unsupported("\(tool.label) is not supported for images.")
        }
        try Task.checkCancellation()
        let output = try save(result, source: opened.source, input: input, format: format, settings: adjusted, suffix: suffix)
        return ConversionResult(outputs: [output], message: tool == .compress ? "Compression uses your selected quality; file size depends on the source image." : nil)
    }

    private static let imageFormats: [OutputFormat] = [.jpeg, .png, .heic, .webp, .tiff, .bmp, .gif, .avif, .pdf]

    /// Prefer the system's accelerated implementation, but remain usable when the
    /// Neural Engine/GPU is unavailable (including headless and remote sessions).
    static func performVision(_ request: VNRequest, on image: CGImage) throws {
        do { try VNImageRequestHandler(cgImage: image).perform([request]); return }
        catch { try Task.checkCancellation() }
        preferCPU(request)
        do { try VNImageRequestHandler(cgImage: image).perform([request]); return }
        catch {
            try Task.checkCancellation()
            // Newer Vision revisions can remove CPU support on Neural Engine Macs.
            // Revision 1 still provides QR/OCR when the accelerated model cannot load.
            guard request.revision != 1, request is VNDetectBarcodesRequest || request is VNRecognizeTextRequest else { throw error }
            request.revision = 1
            preferCPU(request)
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
    }

    private static func preferCPU(_ request: VNRequest) {
        // This legacy hint also covers stages that do not enumerate compute devices.
        request.usesCPUOnly = true
        if #available(macOS 14.0, *), let stages = try? request.supportedComputeStageDevices {
            for (stage, devices) in stages {
                if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
    }

    private static func identifier(for format: OutputFormat) -> String {
        switch format {
        case .jpeg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .webp: return UTType.webP.identifier
        case .tiff: return UTType.tiff.identifier
        case .bmp: return UTType.bmp.identifier
        case .gif: return UTType.gif.identifier
        case .avif: return "public.avif"
        default: return ""
        }
    }

    private static func encoderAvailable(_ format: OutputFormat) -> Bool {
        nativeEncoderAvailable(format) || (format == .webp && (try? MediaConverter.encoderExecutable(named: "libwebp")) != nil)
    }

    private static func nativeEncoderAvailable(_ format: OutputFormat) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(identifier(for: format))
    }

    private static func originalFormat(_ input: URL) -> OutputFormat? {
        switch input.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        default: return OutputFormat(rawValue: input.pathExtension.lowercased()).flatMap { imageFormats.contains($0) && $0 != .pdf ? $0 : nil }
        }
    }

    private struct OpenedImage {
        let source: CGImageSource
        let width: Int
        let height: Int
        let orientation: Int
        var dimensions: Dimensions {
            (5...8).contains(orientation) ? Dimensions(width: height, height: width) : Dimensions(width: width, height: height)
        }
    }

    private static func open(_ input: URL) throws -> OpenedImage {
        try Task.checkCancellation()
        guard input.isFileURL, let values = try? input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0,
              let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw OrangeError.invalidInput("This file is not a readable image.")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw OrangeError.unsupported("Animated images and multipage image files are not supported. Orange will not discard their additional frames.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              width <= 40_000_000 / height else {
            throw OrangeError.invalidInput("The image is invalid or exceeds Orange's safety limit of 40 million pixels and 32,768 pixels per side.")
        }
        return OpenedImage(source: source, width: width, height: height,
                           orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
    }

    private static func validate(_ settings: ConversionSettings) throws {
        guard settings.quality.isFinite, (0...1).contains(settings.quality) else {
            throw OrangeError.invalidInput("Image quality must be a finite number between 0 and 1.")
        }
    }

    private static func decode(_ opened: OpenedImage, maximumDimension: Int? = nil) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: min(max(opened.width, opened.height), maximumDimension ?? max(opened.width, opened.height)),
                                      kCGImageSourceShouldCache: false,
                                      kCGImageSourceShouldCacheImmediately: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(opened.source, 0, options as CFDictionary) else {
            throw OrangeError.conversionFailed("macOS could not decode this image.")
        }
        try Task.checkCancellation()
        return image
    }

    private static func context(width: Int, height: Int, opaque: Bool = false) throws -> CGContext {
        guard width > 0, height > 0, width <= 40_000_000 / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue) else {
            throw OrangeError.conversionFailed("There is not enough memory to process this image.")
        }
        context.interpolationQuality = .high
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context
    }

    private static func render(_ image: CGImage, width: Int, height: Int, opaque: Bool = false) throws -> CGImage {
        let canvas = try context(width: width, height: height, opaque: opaque)
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = canvas.makeImage() else { throw OrangeError.conversionFailed("Could not render the image.") }
        return result
    }

    private static func rotateClockwise(_ image: CGImage) throws -> CGImage {
        let canvas = try context(width: image.height, height: image.width)
        canvas.translateBy(x: 0, y: CGFloat(image.width))
        canvas.rotate(by: -.pi / 2)
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = canvas.makeImage() else { throw OrangeError.conversionFailed("Could not rotate the image.") }
        return result
    }

    private static func save(_ image: CGImage, source: CGImageSource, input: URL, format: OutputFormat,
                             settings: ConversionSettings, suffix: String = "") throws -> URL {
        try OutputWriter.write(beside: input, extension: format.fileExtension, suffix: suffix) { stage in
            if format == .webp && !nativeEncoderAvailable(.webp) {
                try saveWebP(image, beside: input, to: stage, settings: settings)
                return
            }
            if format == .pdf {
                var bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                guard let document = CGContext(stage as CFURL, mediaBox: &bounds, nil) else {
                    throw OrangeError.conversionFailed("Could not create the PDF document.")
                }
                document.beginPDFPage(nil)
                document.draw(image, in: bounds)
                document.endPDFPage()
                document.closePDF()
                return
            }
            guard let destination = CGImageDestinationCreateWithURL(stage as CFURL, identifier(for: format) as CFString, 1, nil) else {
                throw OrangeError.unsupported("macOS could not create a \(format.label) image encoder.")
            }
            var properties: [CFString: Any] = settings.stripMetadata ? [:] : (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:])
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = image.width
            properties[kCGImagePropertyPixelHeight] = image.height
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
            // JPEG cannot represent transparency. Composite onto white instead of leaving black holes.
            let hasAlpha: Bool
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
            default: hasAlpha = true
            }
            let encoded = format == .jpeg && hasAlpha ? try render(image, width: image.width, height: image.height, opaque: true) : image
            CGImageDestinationAddImage(destination, encoded, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw OrangeError.conversionFailed("macOS could not finish writing the \(format.label) image.")
            }
        }
    }

    private static func saveWebP(_ image: CGImage, beside input: URL, to output: URL, settings: ConversionSettings) throws {
        guard image.width <= 16_383, image.height <= 16_383 else {
            throw OrangeError.invalidInput("WebP supports at most 16,383 pixels per side. Resize this image before converting it.")
        }
        guard let ffmpeg = try MediaConverter.encoderExecutable(named: "libwebp") else {
            throw OrangeError.backendMissing("This FFmpeg build has no libwebp encoder. Build Orange's included backend or select a compatible FFmpeg installation.")
        }
        // Decode/orientation checks happen in ImageIO first. FFmpeg sees one trusted,
        // normalized PNG rather than an arbitrary image container or external links.
        let intermediate = input.deletingLastPathComponent().appendingPathComponent(".orange-\(UUID().uuidString)-webp.png")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        guard let destination = CGImageDestinationCreateWithURL(intermediate as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OrangeError.conversionFailed("Could not stage the image for WebP conversion.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw OrangeError.conversionFailed("Could not stage the image for WebP conversion.") }
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        let quality = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), settings.quality * 100)
        _ = try ProcessRunner.run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-max_alloc", "268435456",
            "-threads", String(workers), "-filter_threads", "2", "-protocol_whitelist", "file,pipe",
            "-f", "image2", "-pattern_type", "none", "-i", intermediate.path, "-map", "0:v:0", "-frames:v", "1",
            "-c:v", "libwebp", "-threads", String(workers), "-pix_fmt", "yuva420p",
            "-lossless", "0", "-quality", quality, "-compression_level", "4",
            "-map_metadata", "-1", "-map_chapters", "-1", "-f", "webp", output.path
        ])
    }
}
