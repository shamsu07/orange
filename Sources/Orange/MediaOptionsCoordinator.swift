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
    private var generation = UUID()
    private var completion: (@MainActor (Result<[MediaSelection]?, Error>) -> Void)?

    func choose(_ urls: [URL], tool: ToolKind, settings: ConversionSettings,
                completion: @escaping @MainActor (Result<[MediaSelection]?, Error>) -> Void) {
        cancel()
        guard !urls.isEmpty else { completion(.failure(OrangeError.invalidInput("Select at least one media file."))); return }
        let request = UUID()
        generation = request
        self.completion = completion
        prepareTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try MediaSource.load(urls) }
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
        finish(.success(nil))
    }

    private func present(_ model: MediaOptionsModel) {
        let preview = MediaPreviewModel()
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

/// Playback and frame decoding are scoped to the retained inspector. Slow seeks
/// are cancelled and generation-checked before replacing a newer frame.
@MainActor final class MediaPreviewModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var frame: NSImage?
    @Published private(set) var loadingFrame = false
    @Published private(set) var frameError: String?
    @Published private(set) var playbackAvailable = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    private var source: MediaSource?
    private var assetTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var generation = UUID()
    private var frameGeneration = UUID()
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var boundary: Double?
    private var onPause: (@MainActor (Double) -> Void)?

    func load(_ source: MediaSource, time: Double) {
        stop()
        self.source = source
        let request = UUID()
        generation = request
        let asset = AVURLAsset(url: source.url)
        assetTask = Task { [weak self] in
            do {
                let playable = try await asset.load(.isPlayable)
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.playbackAvailable = playable
                if playable {
                    let item = AVPlayerItem(asset: asset)
                    item.audioTimePitchAlgorithm = .timeDomain
                    self.player.replaceCurrentItem(with: item)
                    self.itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                        Task { @MainActor in
                            guard let self, self.generation == request, item.status == .failed else { return }
                            self.pause()
                            self.playbackAvailable = false
                        }
                    }
                    self.player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero,
                                     toleranceAfter: .zero, completionHandler: { _ in })
                    self.installTimeObserver()
                }
                self.assetTask = nil
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.playbackAvailable = false
                self.assetTask = nil
            }
        }
        seek(to: time)
    }

    func seek(to time: Double) {
        guard let source, time.isFinite else { return }
        pause()
        currentTime = min(source.lastFrameTime, max(0, time))
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        frameTask?.cancel()
        frameTask = nil
        frameError = nil
        guard source.hasVideo else { frame = nil; loadingFrame = false; return }
        let request = UUID(), seconds = currentTime
        frameGeneration = request
        loadingFrame = true
        frameTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
                let worker = Task.detached(priority: .userInitiated) { try MediaConverter.previewFrame(source.url, at: seconds) }
                let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.frameGeneration == request else { return }
                self.frame = NSImage(data: data)
                self.loadingFrame = false
                self.frameTask = nil
                if self.frame == nil { self.frameError = "The selected frame could not be displayed." }
            } catch {
                guard let self, !Task.isCancelled, self.frameGeneration == request else { return }
                self.frame = nil
                self.loadingFrame = false
                self.frameTask = nil
                self.frameError = error.localizedDescription
            }
        }
    }

    func play(from start: Double, to end: Double, speed: Double = 1,
              onPause: @escaping @MainActor (Double) -> Void) {
        guard playbackAvailable, let source, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= source.duration,
              speed.isFinite, (0.25...4).contains(speed) else { return }
        if isPlaying { pause(); return }
        frameTask?.cancel()
        frameTask = nil
        loadingFrame = false
        self.onPause = onPause
        boundary = end
        currentTime = start
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: Float(speed))
        isPlaying = true
    }

    func pause() {
        player.pause()
        let wasPlaying = isPlaying
        isPlaying = false
        boundary = nil
        if wasPlaying { onPause?(currentTime) }
        onPause = nil
        if wasPlaying { seek(to: currentTime) }
    }

    func stop() {
        generation = UUID()
        frameGeneration = UUID()
        onPause = nil
        pause()
        assetTask?.cancel(); assetTask = nil
        frameTask?.cancel(); frameTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        itemObservation?.invalidate(); itemObservation = nil
        player.replaceCurrentItem(with: nil)
        source = nil
        frame = nil
        frameError = nil
        loadingFrame = false
        playbackAvailable = false
        currentTime = 0
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.isPlaying, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
                if let end = self.boundary, time.seconds >= end - 0.025 { self.pause() }
            }
        }
    }
}

private struct MediaOptionsView: View {
    @ObservedObject var model: MediaOptionsModel
    @ObservedObject var preview: MediaPreviewModel
    let cancel: () -> Void
    let confirm: ([MediaSelection]) -> Void

    private var source: MediaSource { model.source }
    private var snapshotTime: Double { finite(model.draft.snapshot) ?? 0 }
    private var trimStart: Double { finite(model.draft.start) ?? 0 }
    private var trimEnd: Double { finite(model.draft.end) ?? source.duration }
    private var previewTime: Double { model.tool == .snapshot ? snapshotTime : trimStart }
    private var canPreview: Bool {
        guard preview.playbackAvailable else { return false }
        if model.tool == .trim {
            guard let start = finite(model.draft.start), let end = finite(model.draft.end) else { return false }
            return start >= 0 && end > start && end <= source.duration
        }
        return model.validationMessage == nil
    }
    private func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.tool.label).font(.system(size: 23, weight: .semibold))
                    Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                Spacer()
                if model.sources.count > 1 {
                    HStack(spacing: 8) {
                        Button { model.move(to: model.currentIndex - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(model.currentIndex == 0).accessibilityLabel("Previous file")
                        Text("\(model.currentIndex + 1) of \(model.sources.count)").font(.system(size: 12)).monospacedDigit()
                        Button { model.move(to: model.currentIndex + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(model.currentIndex == model.sources.count - 1).accessibilityLabel("Next file")
                    }
                }
            }
            previewArea
            switch model.tool {
            case .snapshot: snapshotControls
            case .trim: trimControls
            case .changeSpeed: speedControls
            case .compress: qualityControls
            case .extractAudio:
                Text("Saves the audio track as M4A. Preview this file before extracting.").font(.system(size: 12)).foregroundStyle(.secondary)
            case .normalizeAudio:
                Text("Balances loudness to −16 LUFS. Preview plays the original; normalization is applied when saving.").font(.system(size: 12)).foregroundStyle(.secondary)
            default: EmptyView()
            }
            if let output = model.outputDuration {
                HStack {
                    Text("Duration").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(MediaOptionsModel.time(source.duration)) → \(MediaOptionsModel.time(output))")
                        .monospacedDigit()
                }.font(.system(size: 12))
            }
            if let message = model.validationMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).accessibilityIdentifier("media.validation")
            }
            HStack {
                Text(model.sources.count > 1 ? "Review each file. Nothing saves until the last confirmation." : "Saves a new copy. The original stays in place.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(model.exportLabel) { if let selection = model.confirmCurrent() { confirm(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.validationMessage != nil || model.tool == .snapshot &&
                              (preview.loadingFrame || preview.isPlaying || preview.frame == nil || preview.frameError != nil))
            }
        }
        .padding(24).frame(width: 560).tint(.orange)
        .onAppear { preview.load(source, time: previewTime) }
        .onChange(of: model.currentIndex) { _ in preview.load(source, time: previewTime) }
        .onChange(of: model.draft.snapshotText) { _ in
            if model.tool == .snapshot, let time = model.draft.snapshot, time.isFinite { preview.seek(to: time) }
        }
        .onChange(of: model.draft.startText) { _ in
            if model.tool == .trim, let time = model.draft.start, time.isFinite { preview.seek(to: time) }
        }
        .onChange(of: model.draft.endText) { _ in
            if model.tool == .trim, let time = model.draft.end, time.isFinite { preview.seek(to: min(source.lastFrameTime, time)) }
        }
        .onChange(of: model.draft.speed) { _ in preview.pause() }
    }

    private var previewArea: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.88))
                if source.hasVideo {
                    PlayerSurface(player: preview.player).clipShape(RoundedRectangle(cornerRadius: 14))
                    if !preview.isPlaying, !preview.loadingFrame || !preview.playbackAvailable, let frame = preview.frame {
                        Image(nsImage: frame).resizable().scaledToFit().padding(1)
                    }
                    if preview.loadingFrame && !preview.isPlaying && !preview.playbackAvailable {
                        ProgressView().controlSize(.small).padding(10).background(.ultraThinMaterial, in: Capsule())
                    }
                    if let error = preview.frameError, !preview.isPlaying {
                        Text(error).font(.system(size: 12)).foregroundStyle(.white).multilineTextAlignment(.center).padding(20)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform").font(.system(size: 56, weight: .light)).foregroundStyle(.orange)
                        Text("Audio preview").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }.frame(height: source.hasVideo ? 280 : 130)
                .accessibilityLabel("Selected media preview")
            HStack {
                Button {
                    if preview.isPlaying { preview.pause(); return }
                    let start: Double
                    if model.tool == .snapshot { start = snapshotTime }
                    else if model.tool == .trim {
                        start = preview.currentTime >= trimStart && preview.currentTime < trimEnd - 0.025 ? preview.currentTime : trimStart
                    } else { start = preview.currentTime < source.lastFrameTime ? preview.currentTime : 0 }
                    let end = model.tool == .trim ? trimEnd : source.duration
                    preview.play(from: start, to: end, speed: model.tool == .changeSpeed ? model.draft.speed : 1) { time in
                        if model.tool == .snapshot {
                            model.setText(\.snapshotText, MediaOptionsModel.number(min(source.lastFrameTime, time)))
                        }
                    }
                } label: {
                    Label(preview.isPlaying ? "Pause preview" : "Play preview", systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                }.disabled(!canPreview)
                Spacer()
                Text("\(MediaOptionsModel.time(preview.currentTime)) / \(MediaOptionsModel.time(source.duration))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.tool != .snapshot {
                Slider(value: Binding(get: { min(source.lastFrameTime, max(0, preview.currentTime)) },
                                      set: { preview.seek(to: $0) }), in: 0...max(0.001, source.lastFrameTime))
                    .accessibilityLabel("Preview position")
            }
            if !preview.playbackAvailable {
                Text(source.hasVideo ? "Frame preview is available. This format cannot play in macOS's preview player." : "This audio format cannot play in macOS's preview player.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var snapshotControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Choose a frame").font(.system(size: 13, weight: .semibold))
                Spacer()
                TextField("Seconds", text: textBinding(\.snapshotText)).frame(width: 80).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Snapshot time in seconds")
                Text("s").foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(source.lastFrameTime, max(0, snapshotTime)) },
                                  set: { model.setText(\.snapshotText, MediaOptionsModel.number($0)) }),
                   in: 0...max(0.001, source.lastFrameTime)).accessibilityLabel("Snapshot frame")
            HStack {
                Text("0:00")
                Spacer()
                Text("PNG · full source resolution")
                Spacer()
                Text(MediaOptionsModel.time(source.duration))
            }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var trimControls: some View {
        VStack(spacing: 12) {
            HStack {
                timeField("Start", keyPath: \.startText)
                Spacer()
                Text("Keep highlighted section").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                timeField("End", keyPath: \.endText)
            }
            RangeTimeline(start: Binding(get: { max(0, min(source.duration, trimStart)) },
                                         set: { model.setText(\.startText, MediaOptionsModel.number($0)) }),
                          end: Binding(get: { max(0, min(source.duration, trimEnd)) },
                                       set: { model.setText(\.endText, MediaOptionsModel.number($0)) }),
                          duration: source.duration)
            HStack {
                Text("0:00")
                Spacer()
                Text(MediaOptionsModel.time(source.duration))
            }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback speed").font(.system(size: 13, weight: .semibold))
            Picker("Speed", selection: Binding(get: { model.draft.speed }, set: { model.setSpeed($0) })) {
                ForEach([0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4], id: \.self) { value in Text("\(value, specifier: "%g")×").tag(value) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("Preview plays at the selected speed. Audio pitch is preserved in the saved copy.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Encoding quality").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int((model.draft.quality * 100).rounded()))%")
            }
            Slider(value: Binding(get: { model.draft.quality }, set: { model.setQuality($0) }), in: 0...1)
                .accessibilityLabel("Encoding quality")
            HStack { Text("Smaller file"); Spacer(); Text("Higher quality") }.font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Original: \(ByteCountFormatter.string(fromByteCount: source.byteCount, countStyle: .file)). \(source.hasVideo ? "Re-encoding controls quality without scaling the video." : "Re-encoding controls audio quality.") Final size depends on the source and can be larger; the completed result reports the actual size.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func textBinding(_ keyPath: WritableKeyPath<MediaDraft, String>) -> Binding<String> {
        Binding(get: { model.draft[keyPath: keyPath] }, set: { model.setText(keyPath, $0) })
    }
    private func timeField(_ title: String, keyPath: WritableKeyPath<MediaDraft, String>) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Seconds", text: textBinding(keyPath)).frame(width: 76).multilineTextAlignment(.trailing)
                .accessibilityLabel("\(title) time in seconds")
            Text("s").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

/// Two direct manipulation handles share one track. Keyboard and assistive
/// controls expose the same start/end values instead of requiring a drag.
private struct RangeTimeline: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 20)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.18)).frame(height: 14)
                Capsule().fill(.orange.opacity(0.8)).frame(width: max(0, (end - start) / duration * width), height: 14)
                    .offset(x: start / duration * width + 10)
                handle("Trim start", value: $start, limit: 0...max(0, end - 0.001), width: width)
                    .offset(x: start / duration * width)
                handle("Trim end", value: $end, limit: min(duration, start + 0.001)...duration, width: width)
                    .offset(x: end / duration * width)
            }.frame(height: 32).coordinateSpace(name: "orange.trim.track")
        }.frame(height: 32)
    }
    private func handle(_ label: String, value: Binding<Double>, limit: ClosedRange<Double>, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(.orange)
            .overlay { Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(90)).foregroundStyle(.white) }
            .frame(width: 20, height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("orange.trim.track")).onChanged { event in
                // A named coordinate space avoids a handle-relative location jumping
                // as the handle itself moves under the pointer.
                let seconds = (event.location.x - 10) / width * duration
                value.wrappedValue = min(limit.upperBound, max(limit.lowerBound, seconds))
            })
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue(MediaOptionsModel.time(value.wrappedValue))
            .accessibilityAdjustableAction { direction in
                let step = max(0.01, min(1, duration / 100))
                let delta = direction == .increment ? step : -step
                value.wrappedValue = min(limit.upperBound, max(limit.lowerBound, value.wrappedValue + delta))
            }
    }
}
