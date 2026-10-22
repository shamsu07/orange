import Foundation
import OrangeCore

/// One serial worker per panel. Editing cancels pending work; generation checks
/// keep a slow encoder from publishing an estimate for an older slider value.
@MainActor final class ImageEncodingPreviewModel: ObservableObject {
    typealias Encoder = @Sendable (ToolKind, URL, ConversionSettings) throws -> ImageConverter.EncodingPreview
    @Published private(set) var estimates: [URL: ImageConverter.EncodingPreview] = [:]
    @Published private(set) var isEstimating = false
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let encoder: Encoder
    private let queue = ImagePreviewEncoderQueue()
    private let debounce: Duration

    init(debounce: Duration = .milliseconds(250), encoder: @escaping Encoder = {
        try ImageConverter.preview($0, input: $1, settings: $2)
    }) {
        self.debounce = debounce
        self.encoder = encoder
    }

    func schedule(_ tool: ToolKind, urls: [URL], settings: ConversionSettings) {
        cancel()
        guard !urls.isEmpty else { return }
        let request = generation
        isEstimating = true
        let encoder = encoder, delay = debounce, queue = queue
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                let worker = Task.detached(priority: .userInitiated) {
                    try await queue.encode(tool, urls: urls, settings: settings, encoder: encoder)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.estimates = result
                self.isEstimating = false
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.errorMessage = error.localizedDescription
                self.isEstimating = false
                self.task = nil
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        estimates = [:]
        errorMessage = nil
        isEstimating = false
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func summary(_ estimate: ImageConverter.EncodingPreview) -> String {
        let change = estimate.originalBytes > 0 ? (1 - Double(estimate.encodedBytes) / Double(estimate.originalBytes)) * 100 : 0
        let savings = change > 0 ? (change < 1 ? " · less than 1% smaller" : " · \(Int(change.rounded()))% smaller") : ""
        return "\(bytes(estimate.originalBytes)) → about \(bytes(estimate.encodedBytes))\(savings)"
    }
}

/// Cancellation can arrive during a synchronous ImageIO encode. Keep subsequent
/// requests serial until that encode reaches its cancellation boundary.
private actor ImagePreviewEncoderQueue {
    func encode(_ tool: ToolKind, urls: [URL], settings: ConversionSettings,
                encoder: ImageEncodingPreviewModel.Encoder) throws -> [URL: ImageConverter.EncodingPreview] {
        var result: [URL: ImageConverter.EncodingPreview] = [:]
        for url in urls {
            try Task.checkCancellation()
            result[url] = try encoder(tool, url, settings)
        }
        try Task.checkCancellation()
        return result
    }
}
