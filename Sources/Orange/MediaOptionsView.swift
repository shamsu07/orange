import AppKit
import SwiftUI
import AVKit
import OrangeCore

struct MediaOptionsView: View {
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
