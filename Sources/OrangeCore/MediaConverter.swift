import Foundation

/// Media encoding is provided by a separately installed open-source FFmpeg build.
public enum MediaConverter {
    public static func formats(for input: URL) -> [OutputFormat] {
        guard let backend = try? backend(), let info = try? probe(input, backend: backend) else { return [] }
        return (info.video != nil ? videoFormats + audioFormats : audioFormats).filter {
            if videoFormats.contains($0) { return info.video != nil && videoCodec($0, encoders: backend.encoders) != nil && (info.audio == nil || audioCodec($0, encoders: backend.encoders) != nil) }
            return info.audio != nil && audioCodec($0, encoders: backend.encoders) != nil
        }
    }

    public static func tools(for input: URL) -> [ToolKind] {
        guard let backend = try? backend(), let info = try? probe(input, backend: backend) else { return [] }
        var tools: [ToolKind] = [.stripMetadata]
        let target: OutputFormat = info.video == nil ? .m4a : .mp4
        let canEncode = (info.video == nil || videoCodec(target, encoders: backend.encoders) != nil)
            && (info.audio == nil || audioCodec(target, encoders: backend.encoders) != nil)
        if canEncode { tools += [.compress, .trim, .changeSpeed] }
        if info.audio != nil, audioCodec(.m4a, encoders: backend.encoders) != nil {
            if info.video != nil { tools.append(.extractAudio) }
            if canEncode { tools.append(.normalizeAudio) }
        }
        if info.video != nil, backend.encoders.contains("png") { tools.append(.snapshot) }
        return tools
    }

    public static func convert(_ input: URL, to format: OutputFormat, settings: ConversionSettings) throws -> ConversionResult {
        try validate(settings)
        let backend = try backend()
        let info = try probe(input, backend: backend, useCache: false)
        let output = try transcode(input, to: format, settings: settings, backend: backend, info: info)
        let message = format == .ogg && audioCodec(format, encoders: backend.encoders) == "vorbis"
            ? "This FFmpeg build writes OGG as stereo audio." : nil
        return ConversionResult(outputs: [output], message: message)
    }

    public static func apply(_ tool: ToolKind, to input: URL, settings: ConversionSettings) throws -> ConversionResult {
        try validate(settings)
        let backend = try backend()
        let info = try probe(input, backend: backend, useCache: false)
        let defaultFormat: OutputFormat = info.video == nil ? .m4a : .mp4
        let output: URL
        switch tool {
        case .stripMetadata:
            let ext = input.pathExtension.lowercased()
            guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw OrangeError.invalidInput("This media file does not have a supported extension.")
            }
            output = try OutputWriter.write(beside: input, extension: ext, suffix: "-clean") { stage in
                var arguments = baseArguments + ["-i", input.path]
                // A metadata-only operation must preserve alternate audio, subtitle,
                // cover-art, and data tracks instead of silently keeping the first two.
                arguments += ["-map", "0"]
                arguments += ["-c", "copy", "-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1", stage.path]
                if ext == "m4v" { arguments.insert(contentsOf: ["-f", "mp4"], at: arguments.count - 1) }
                _ = try ProcessRunner.run(backend.ffmpeg, arguments: arguments)
            }
        case .compress:
            output = try transcode(input, to: defaultFormat, settings: settings, backend: backend, info: info, suffix: "-compressed")
        case .trim:
            guard settings.trimStart.isFinite, settings.trimStart >= 0,
                  let end = settings.trimEnd, end.isFinite, end > settings.trimStart else {
                throw OrangeError.invalidInput("Set a trim start of zero or later and an end greater than the start.")
            }
            if let duration = info.duration, settings.trimStart >= duration || end > duration + 0.05 {
                throw OrangeError.invalidInput("The trim range extends beyond the media's duration of \(String(format: "%.2f", duration)) seconds.")
            }
            output = try transcode(input, to: defaultFormat, settings: settings, backend: backend, info: info, suffix: "-trimmed",
                                   beforeInput: ["-ss", number(settings.trimStart)], extra: ["-t", number(end - settings.trimStart)])
        case .changeSpeed:
            guard settings.speed.isFinite, (0.25...4).contains(settings.speed) else {
                throw OrangeError.invalidInput("Speed must be between 0.25× and 4×.")
            }
            var extra: [String] = []
            if info.video != nil { extra += ["-filter:v", "setpts=PTS/\(number(settings.speed)),pad=ceil(iw/2)*2:ceil(ih/2)*2"] }
            if info.audio != nil { extra += ["-filter:a", tempoFilter(settings.speed)] }
            output = try transcode(input, to: defaultFormat, settings: settings, backend: backend, info: info, suffix: "-speed", extra: extra, customVideoFilter: true)
        case .extractAudio:
            guard info.audio != nil else { throw OrangeError.invalidInput("This media file has no audio stream.") }
            output = try transcode(input, to: .m4a, settings: settings, backend: backend, info: info, suffix: "-audio")
        case .snapshot:
            guard info.video != nil, backend.encoders.contains("png") else { throw OrangeError.unsupported("A video stream and FFmpeg's PNG encoder are required for snapshots.") }
            guard settings.trimStart.isFinite, settings.trimStart >= 0 else { throw OrangeError.invalidInput("The snapshot time must be zero or later.") }
            if let duration = info.duration, settings.trimStart >= duration { throw OrangeError.invalidInput("The snapshot time is beyond the end of the video.") }
            output = try OutputWriter.write(beside: input, extension: "png", suffix: "-snapshot") { stage in
                let arguments = baseArguments + ["-ss", number(settings.trimStart), "-i", input.path, "-map", "0:\(info.video!)",
                                                "-frames:v", "1", "-c:v", "png", "-threads", String(workerCount), "-update", "1", stage.path]
                _ = try ProcessRunner.run(backend.ffmpeg, arguments: arguments)
            }
        case .normalizeAudio:
            guard info.audio != nil else { throw OrangeError.invalidInput("This media file has no audio stream.") }
            output = try transcode(input, to: defaultFormat, settings: settings, backend: backend, info: info,
                                   suffix: "-normalized", extra: ["-filter:a", "loudnorm=I=-16:TP=-1.5:LRA=11"])
        default:
            throw OrangeError.unsupported("\(tool.label) is not supported for media files.")
        }
        let message: String? = tool == .stripMetadata ? "Descriptive metadata removed. The container can retain technical fields required for playback."
            : tool == .compress ? "Compression re-encodes at your selected quality; file size depends on the source." : nil
        return ConversionResult(outputs: [output], message: message)
    }

    private static let videoFormats: [OutputFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv]
    private static let audioFormats: [OutputFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    private static let workerCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    // Standalone media only: a disguised playlist must not fetch network resources.
    private static let inputFormats = "mov,matroska,webm,avi,asf,mp3,wav,flac,ogg,aiff,aac"
    private static let baseArguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-max_alloc", "268435456", "-threads", String(workerCount), "-filter_threads", "2",
                                        "-protocol_whitelist", "file,pipe", "-format_whitelist", inputFormats]

    private struct Backend { let ffmpeg: URL; let ffprobe: URL; let encoders: Set<String> }
    private struct EncodingBackend { let ffmpeg: URL; let encoders: Set<String> }
    private static let cacheLock = NSLock()
    private static var cachedEncoders: [String: Set<String>] = [:]
    private static var cachedMedia: [String: MediaInfo] = [:]

    private static func backend() throws -> Backend {
        let encoding = try encodingBackend()
        let sibling = encoding.ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let ffprobe = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : ProcessRunner.executable(named: "ffprobe")
        guard let ffprobe else { throw OrangeError.backendMissing("FFmpeg was found, but ffprobe is missing. Install the complete FFmpeg package and restart Orange.") }
        return Backend(ffmpeg: encoding.ffmpeg, ffprobe: ffprobe, encoders: encoding.encoders)
    }

    /// Shares verified, bounded encoder discovery with still-image fallbacks.
    /// A still-image encode does not require a separate ffprobe installation.
    static func encoderExecutable(named name: String) throws -> URL? {
        let encoding = try encodingBackend()
        return encoding.encoders.contains(name) ? encoding.ffmpeg : nil
    }

    private static func encodingBackend() throws -> EncodingBackend {
        guard let ffmpeg = ProcessRunner.executable(named: "ffmpeg") else {
            throw OrangeError.backendMissing("Media conversion requires FFmpeg. Install the open-source FFmpeg package with your package manager, then restart Orange. Orange does not download or install converters.")
        }
        let modified = (try? ffmpeg.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = ffmpeg.path + ":" + String(modified)
        cacheLock.lock()
        let cached = cachedEncoders[key]
        cacheLock.unlock()
        let encoders: Set<String>
        if let cached { encoders = cached }
        else {
            let listing = try ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-encoders"], timeout: 10)
            encoders = Set(listing.split(separator: "\n").compactMap { line in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2, columns[0].count == 6, ["V", "A", "S"].contains(String(columns[0].prefix(1))), columns[1] != "=" else { return nil }
                return String(columns[1])
            })
            cacheLock.lock()
            cachedEncoders[key] = encoders
            cacheLock.unlock()
        }
        return EncodingBackend(ffmpeg: ffmpeg, encoders: encoders)
    }

    private struct MediaInfo { let video: Int?; let audio: Int?; let duration: Double? }

    private static func probe(_ input: URL, backend: Backend, useCache: Bool = true) throws -> MediaInfo {
        guard input.isFileURL, let values = try? input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw OrangeError.invalidInput("Select a non-empty media file.")
        }
        let key = input.path + ":" + String(values.fileSize ?? 0) + ":" + String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            + ":" + String(describing: values.fileResourceIdentifier)
        if useCache {
            cacheLock.lock()
            let cached = cachedMedia[key]
            cacheLock.unlock()
            if let cached { return cached }
        }
        let json = try ProcessRunner.run(backend.ffprobe, arguments: ["-v", "error", "-protocol_whitelist", "file,pipe", "-format_whitelist", inputFormats, "-show_entries",
            "stream=index,codec_type,width,height:stream_disposition=attached_pic:format=duration", "-of", "json", input.path], timeout: 10)
        guard let data = json.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]] else {
            throw OrangeError.invalidInput("FFmpeg could not identify this media file.")
        }
        let video = streams.first { ($0["codec_type"] as? String) == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }
        let audio = streams.first { ($0["codec_type"] as? String) == "audio" }
        guard video != nil || audio != nil else { throw OrangeError.invalidInput("This file contains no supported audio or video streams.") }
        if let video {
            guard let width = video["width"] as? Int, let height = video["height"] as? Int,
                  width > 0, height > 0, width <= 32_768, height <= 32_768, width <= 40_000_000 / height else {
                throw OrangeError.invalidInput("This video's frame size exceeds Orange's safety limit of 40 million pixels.")
            }
        }
        let rawDuration = (object["format"] as? [String: Any])?["duration"] as? String
        let duration = rawDuration.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let info = MediaInfo(video: video?["index"] as? Int, audio: audio?["index"] as? Int, duration: duration)
        cacheLock.lock()
        if cachedMedia.count >= 128 { cachedMedia.removeAll(keepingCapacity: true) }
        cachedMedia[key] = info
        cacheLock.unlock()
        return info
    }

    private static func firstEncoder(_ candidates: [String], _ encoders: Set<String>) -> String? {
        candidates.first(where: encoders.contains)
    }

    private static func videoCodec(_ format: OutputFormat, encoders: Set<String>) -> String? {
        switch format {
        case .mp4, .mov, .mkv: return firstEncoder(["libx264", "h264_videotoolbox", "mpeg4"], encoders)
        case .webm: return firstEncoder(["libvpx-vp9", "libvpx"], encoders)
        case .avi: return firstEncoder(["mpeg4"], encoders)
        case .wmv: return firstEncoder(["wmv2"], encoders)
        default: return nil
        }
    }

    private static func audioCodec(_ format: OutputFormat, encoders: Set<String>) -> String? {
        let candidates: [String]
        switch format {
        case .mp4, .mov, .mkv, .m4a: candidates = ["aac"]
        case .webm, .opus: candidates = ["libopus"]
        case .mp3, .avi: candidates = ["libmp3lame", "mp3"]
        case .wav: candidates = ["pcm_s16le"]
        case .flac: candidates = ["flac"]
        case .ogg: candidates = ["libvorbis", "vorbis"]
        case .aiff: candidates = ["pcm_s16be"]
        case .wmv, .wma: candidates = ["wmav2"]
        default: candidates = []
        }
        return firstEncoder(candidates, encoders)
    }

    private static func transcode(_ input: URL, to format: OutputFormat, settings: ConversionSettings, backend: Backend,
                                  info: MediaInfo, suffix: String = "", beforeInput: [String] = [], extra: [String] = [], customVideoFilter: Bool = false) throws -> URL {
        let videoOutput = videoFormats.contains(format)
        guard videoOutput || audioFormats.contains(format) else { throw OrangeError.unsupported("\(format.label) is not a media output format.") }
        guard !videoOutput || info.video != nil else { throw OrangeError.invalidInput("This file has no video stream.") }
        guard videoOutput || info.audio != nil else { throw OrangeError.invalidInput("This file has no audio stream to convert.") }
        let video = videoOutput ? videoCodec(format, encoders: backend.encoders) : nil
        let audio = info.audio != nil ? audioCodec(format, encoders: backend.encoders) : nil
        guard (!videoOutput || video != nil) && (info.audio == nil || audio != nil) else {
            throw OrangeError.backendMissing("This FFmpeg build does not include the encoders required for \(format.label). Install an FFmpeg build with that codec enabled.")
        }
        return try OutputWriter.write(beside: input, extension: format.fileExtension, suffix: suffix) { stage in
            var arguments = baseArguments + beforeInput + ["-i", input.path]
            arguments += streamArguments(info, includeVideo: videoOutput, includeAudio: info.audio != nil)
            arguments += ["-threads", String(workerCount)]
            if let video {
                arguments += ["-c:v", video, "-pix_fmt", "yuv420p"]
                if !customVideoFilter { arguments += ["-filter:v", "pad=ceil(iw/2)*2:ceil(ih/2)*2"] }
                switch video {
                case "libx264": arguments += ["-preset", "medium", "-crf", String(Int((35 - settings.quality * 17).rounded()))]
                case "libvpx-vp9": arguments += ["-b:v", "0", "-crf", String(Int((48 - settings.quality * 20).rounded())), "-deadline", "good", "-cpu-used", "2"]
                case "libvpx": arguments += ["-b:v", "\(Int(1_000 + settings.quality * 5_000))k", "-crf", String(Int((30 - settings.quality * 20).rounded())), "-deadline", "good", "-cpu-used", "2"]
                case "mpeg4", "wmv2": arguments += ["-q:v", String(max(2, Int((31 - settings.quality * 29).rounded()))) ]
                default: arguments += ["-b:v", "\(Int(1_000 + settings.quality * 7_000))k"]
                }
                if [.mp4, .mov].contains(format) { arguments += ["-movflags", "+faststart"] }
            } else { arguments += ["-vn"] }
            if let audio {
                arguments += ["-c:a", audio]
                if ["libvorbis", "vorbis"].contains(audio) {
                    arguments += ["-q:a", number(settings.quality * 10)]
                } else if !["pcm_s16le", "pcm_s16be", "flac"].contains(audio) {
                    arguments += ["-b:a", "\(Int(96 + settings.quality * 160))k"]
                }
                if audio == "vorbis" { arguments += ["-ac", "2", "-strict", "experimental"] }
            }
            if settings.stripMetadata { arguments += ["-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1"] }
            arguments += extra + [stage.path]
            _ = try ProcessRunner.run(backend.ffmpeg, arguments: arguments)
        }
    }

    private static func streamArguments(_ info: MediaInfo, includeVideo: Bool, includeAudio: Bool) -> [String] {
        var arguments: [String] = []
        if includeVideo, let index = info.video { arguments += ["-map", "0:\(index)"] }
        if includeAudio, let index = info.audio { arguments += ["-map", "0:\(index)"] }
        return arguments
    }

    private static func validate(_ settings: ConversionSettings) throws {
        guard settings.quality.isFinite, (0...1).contains(settings.quality) else { throw OrangeError.invalidInput("Quality must be a finite number between 0 and 1.") }
    }

    private static func number(_ value: Double) -> String { String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value) }

    private static func tempoFilter(_ speed: Double) -> String {
        var remainder = speed, factors: [Double] = []
        while remainder > 2 { factors.append(2); remainder /= 2 }
        while remainder < 0.5 { factors.append(0.5); remainder /= 0.5 }
        factors.append(remainder)
        return factors.map { "atempo=\(number($0))" }.joined(separator: ",")
    }
}
