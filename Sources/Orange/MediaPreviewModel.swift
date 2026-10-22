import AppKit
import AVFoundation
import OrangeCore

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
    private let tasks: PreviewTaskGroup
    private let frameRenderer: @Sendable (URL, Double) async throws -> Data

    init(tasks: PreviewTaskGroup? = nil,
         frameRenderer: @escaping @Sendable (URL, Double) async throws -> Data = { try await MediaPreviewModel.renderFrame($0, $1) }) {
        self.tasks = tasks ?? PreviewTaskGroup()
        self.frameRenderer = frameRenderer
    }

    nonisolated private static func renderFrame(_ url: URL, _ seconds: Double) async throws -> Data {
        let worker = Task.detached(priority: .userInitiated) { try MediaConverter.previewFrame(url, at: seconds) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    func load(_ source: MediaSource, time: Double) {
        guard !tasks.isShutdown else { return }
        stop()
        self.source = source
        let request = UUID()
        generation = request
        let asset = AVURLAsset(url: source.url)
        assetTask = tasks.spawn { [weak self] in
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
        guard !tasks.isShutdown, let source, time.isFinite else { return }
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
        let render = frameRenderer
        frameTask = tasks.spawn { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
                let data = try await WorkLimiter.shared.withPermit { try await render(source.url, seconds) }
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
        guard !tasks.isShutdown, playbackAvailable, let source, start.isFinite, end.isFinite,
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
        installTimeObserver()
        player.playImmediately(atRate: Float(speed))
        isPlaying = true
    }

    func pause() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
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
        player.pause()
        isPlaying = false
        boundary = nil
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
