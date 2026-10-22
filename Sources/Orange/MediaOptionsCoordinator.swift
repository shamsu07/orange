import AppKit
import SwiftUI
import AVKit
import OrangeCore

struct MediaSource: Identifiable, Sendable {
    let url: URL
    let duration: Double
    let hasVideo: Bool
    let hasAudio: Bool
    let byteCount: Int64
    let frameRate: Double?
    var id: URL { url }
    var lastFrameTime: Double { max(0, duration - max(0.001, 1 / (frameRate ?? 30))) }

    static func load(_ urls: [URL]) throws -> [MediaSource] {
        var seen = Set<URL>()
        return try urls.filter { seen.insert($0.standardizedFileURL).inserted }.map { url in
            try Task.checkCancellation()
            let info = try MediaConverter.inspect(url)
            guard let duration = info.duration, duration.isFinite, duration > 0 else {
                throw OrangeError.invalidInput("Orange could not read the duration of \(url.lastPathComponent). This file cannot use a timeline.")
            }
            return MediaSource(url: url, duration: duration, hasVideo: info.hasVideo, hasAudio: info.hasAudio,
                               byteCount: info.byteCount, frameRate: info.frameRate)
        }
    }
}

struct MediaSelection {
    let input: URL
    let settings: ConversionSettings
}

@MainActor protocol MediaOptionsPresenting: AnyObject {
    func choose(_ urls: [URL], tool: ToolKind, settings: ConversionSettings,
                completion: @escaping @MainActor (Result<[MediaSelection]?, Error>) -> Void)
    func cancel()
    func shutdown() async
}

extension MediaOptionsPresenting {
    func shutdown() async { cancel() }
}

struct MediaDraft {
    var snapshotText: String
    var startText: String
    var endText: String
    var speed: Double
    var quality: Double
    var snapshot: Double? { Double(snapshotText) }
    var start: Double? { Double(startText) }
    var end: Double? { Double(endText) }
}

/// Each file has its own range and frame selection. Export becomes available only
/// after every file has been reviewed; nothing queues while navigating the panel.
@MainActor final class MediaOptionsModel: ObservableObject {
    let sources: [MediaSource]
    let tool: ToolKind
    let baseSettings: ConversionSettings
    @Published private(set) var drafts: [MediaDraft]
    @Published private(set) var currentIndex = 0
    @Published private(set) var reviewed = Set<Int>()

    init(sources: [MediaSource], tool: ToolKind, settings: ConversionSettings) {
        self.sources = sources
        self.tool = tool
        baseSettings = settings
        drafts = sources.map { source in
            MediaDraft(snapshotText: Self.number(min(source.lastFrameTime, source.duration / 2)),
                       startText: "0", endText: Self.number(source.duration),
                       speed: settings.speed.isFinite && (0.25...4).contains(settings.speed) && settings.speed != 1 ? settings.speed : 1.5,
                       quality: settings.quality.isFinite && (0...1).contains(settings.quality) ? settings.quality : 0.65)
        }
    }

    var source: MediaSource { sources[currentIndex] }
    var draft: MediaDraft { drafts[currentIndex] }
    var isLastReview: Bool { sources.indices.allSatisfy { $0 == currentIndex || reviewed.contains($0) } }
    var exportLabel: String {
        if !isLastReview { return "Use selection & next" }
        switch tool {
        case .snapshot: return sources.count == 1 ? "Save snapshot" : "Save \(sources.count) snapshots"
        case .trim: return sources.count == 1 ? "Save trimmed copy" : "Save \(sources.count) trimmed copies"
        case .changeSpeed: return "Save \(sources.count == 1 ? "copy" : "\(sources.count) copies")"
        case .compress: return sources.count == 1 ? "Compress copy" : "Compress \(sources.count) copies"
        case .extractAudio: return "Extract audio"
        case .normalizeAudio: return "Normalize audio"
        default: return "Save copies"
        }
    }

    var validationMessage: String? { validationMessage(at: currentIndex) }
    private func validationMessage(at index: Int) -> String? {
        let item = sources[index], value = drafts[index]
        switch tool {
        case .snapshot:
            guard item.hasVideo else { return "Snapshots require a video track." }
            guard let time = value.snapshot, time.isFinite, time >= 0, time <= item.lastFrameTime + 0.00051 else {
                return "Choose a frame between 0 and \(Self.number(item.lastFrameTime)) seconds."
            }
        case .trim:
            guard let start = value.start, let end = value.end, start.isFinite, end.isFinite,
                  start >= 0, end > start, end <= item.duration + 0.00051 else {
                return "The end must be after the start and within this file's duration."
            }
            guard start > 0.00051 || end < item.duration - 0.00051 else {
                return "Move either trim handle to shorten this file."
            }
        case .changeSpeed:
            guard value.speed.isFinite, (0.25...4).contains(value.speed), value.speed != 1 else {
                return "Choose a speed other than 1×, from 0.25× to 4×."
            }
        case .compress:
            guard value.quality.isFinite, (0...1).contains(value.quality) else { return "Choose a quality between 0 and 100%." }
        case .extractAudio, .normalizeAudio:
            guard item.hasAudio else { return "This file does not contain an audio track." }
        default: return "This tool does not have media options."
        }
        return nil
    }

    var outputDuration: Double? {
        switch tool {
        case .trim:
            guard let start = draft.start, let end = draft.end else { return nil }
            return max(0, end - start)
        case .changeSpeed: return source.duration / draft.speed
        case .snapshot: return nil
        default: return source.duration
        }
    }

    func setText(_ keyPath: WritableKeyPath<MediaDraft, String>, _ text: String) {
        drafts[currentIndex][keyPath: keyPath] = text
        reviewed.remove(currentIndex)
    }
    func setSpeed(_ value: Double) { drafts[currentIndex].speed = value; reviewed.remove(currentIndex) }
    func setQuality(_ value: Double) { drafts[currentIndex].quality = value; reviewed.remove(currentIndex) }
    func move(to index: Int) { guard sources.indices.contains(index) else { return }; currentIndex = index }

    func confirmCurrent() -> [MediaSelection]? {
        guard validationMessage == nil else { return nil }
        reviewed.insert(currentIndex)
        if let next = sources.indices.first(where: { !reviewed.contains($0) }) {
            currentIndex = next
            return nil
        }
        guard sources.indices.allSatisfy({ validationMessage(at: $0) == nil }) else { return nil }
        return sources.indices.map { index in
            let value = drafts[index]
            var settings = baseSettings
            switch tool {
            case .snapshot: settings.trimStart = min(sources[index].lastFrameTime, value.snapshot!)
            case .trim: settings.trimStart = value.start!; settings.trimEnd = min(sources[index].duration, value.end!)
            case .changeSpeed: settings.speed = value.speed
            case .compress: settings.quality = value.quality
            default: break
            }
            return MediaSelection(input: sources[index].url, settings: settings)
        }
    }

    static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        let total = Int(value)
        let fraction = Int((value - Double(total)) * 100)
        if total >= 3600 { return String(format: "%d:%02d:%02d.%02d", total / 3600, (total / 60) % 60, total % 60, fraction) }
        return String(format: "%d:%02d.%02d", total / 60, total % 60, fraction)
    }
}

@MainActor final class MediaOptionsCoordinator: NSObject, MediaOptionsPresenting, NSWindowDelegate {
    private var panel: NSPanel?
    private var prepareTask: Task<Void, Never>?
    private var preview: MediaPreviewModel?
    private let previewTasks: PreviewTaskGroup
    private var stopped = false
    private var generation = UUID()
    private var completion: (@MainActor (Result<[MediaSelection]?, Error>) -> Void)?

    init(tasks: PreviewTaskGroup? = nil) {
        self.previewTasks = tasks ?? PreviewTaskGroup()
        super.init()
    }

    func choose(_ urls: [URL], tool: ToolKind, settings: ConversionSettings,
                completion: @escaping @MainActor (Result<[MediaSelection]?, Error>) -> Void) {
        guard !stopped else { completion(.success(nil)); return }
        cancel()
        guard !urls.isEmpty else { completion(.failure(OrangeError.invalidInput("Select at least one media file."))); return }
        let request = UUID()
        generation = request
        self.completion = completion
        prepareTask = previewTasks.spawn { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await WorkLimiter.shared.withPermit { try MediaSource.load(urls) }
            }
            do {
                let sources = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.prepareTask = nil
                self.present(MediaOptionsModel(sources: sources, tool: tool, settings: settings))
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.prepareTask = nil
                self.finish(.failure(error))
            }
        }
    }

    func cancel() {
        generation = UUID()
        prepareTask?.cancel()
        prepareTask = nil
        previewTasks.cancelAll()
        finish(.success(nil))
    }

    func shutdown() async {
        stopped = true
        cancel()
        await previewTasks.shutdown()
    }

    private func present(_ model: MediaOptionsModel) {
        let preview = MediaPreviewModel(tasks: previewTasks)
        self.preview = preview
        let view = MediaOptionsView(model: model, preview: preview,
                                    cancel: { [weak self] in self?.finish(.success(nil)) },
                                    confirm: { [weak self] selection in self?.finish(.success(selection)) })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable]
        panel.title = "Orange · \(model.tool.label)"
        panel.identifier = NSUserInterfaceItemIdentifier("orange.media.options")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: Result<[MediaSelection]?, Error>) {
        let callback = completion
        completion = nil
        preview?.stop()
        preview = nil
        let closing = panel
        panel = nil
        closing?.close()
        callback?(result)
    }
    func windowWillClose(_ notification: Notification) { finish(.success(nil)) }
}
