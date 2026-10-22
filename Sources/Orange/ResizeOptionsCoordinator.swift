import AppKit
import SwiftUI
import OrangeCore

struct ResizeSource: Identifiable, Sendable {
    let url: URL
    let dimensions: ImageConverter.Dimensions
    let originalBytes: Int64
    var id: URL { url }

    static func load(_ urls: [URL]) throws -> [ResizeSource] {
        var seen = Set<URL>()
        return try urls.filter { seen.insert($0.standardizedFileURL).inserted }.map { url in
            try Task.checkCancellation()
            return ResizeSource(url: url, dimensions: try ImageConverter.dimensions(of: url),
                                originalBytes: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        }
    }
}

struct ResizeSelection {
    let inputs: [URL]
    let maximumDimension: Int
}

@MainActor protocol ResizeOptionsPresenting: AnyObject {
    func choose(_ urls: [URL], preferredMaximum: Int, preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ResizeSelection?, Error>) -> Void)
    func cancel()
    func shutdown() async
}

extension ResizeOptionsPresenting {
    func shutdown() async { cancel() }
}

@MainActor final class ResizeOptionsModel: ObservableObject {
    let sources: [ResizeSource]
    @Published var maximumText: String
    let baseSettings: ConversionSettings

    init(sources: [ResizeSource], preferredMaximum: Int, settings: ConversionSettings = ConversionSettings()) {
        self.baseSettings = settings
        self.sources = sources
        let largest = sources.map(\.dimensions.longEdge).max() ?? 1
        let preferred = (1...16_384).contains(preferredMaximum) ? preferredMaximum : 1920
        // The default must actually resize something, including a small image.
        maximumText = String(largest > preferred ? preferred : max(1, largest / 2))
    }

    var previewSettings: ConversionSettings? {
        guard let maximumDimension else { return nil }
        var settings = baseSettings
        settings.maxDimension = maximumDimension
        return settings
    }
    var maximumDimension: Int? {
        guard let value = Int(maximumText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...16_384).contains(value) else { return nil }
        return value
    }
    var eligibleSources: [ResizeSource] {
        guard let maximumDimension else { return [] }
        return sources.filter { $0.dimensions.longEdge > maximumDimension }
    }
    var unchangedCount: Int { sources.count - eligibleSources.count }
    var validationMessage: String? {
        guard maximumDimension != nil else { return "Enter a whole number from 1 to 16,384 pixels." }
        guard !eligibleSources.isEmpty else {
            if sources.allSatisfy({ $0.dimensions.longEdge == 1 }) { return "These images are already at the minimum of 1 × 1 pixel." }
            return "Choose a smaller long edge. This limit would leave every image unchanged."
        }
        return nil
    }
    var selection: ResizeSelection? {
        guard validationMessage == nil, let maximumDimension else { return nil }
        return ResizeSelection(inputs: eligibleSources.map(\.url), maximumDimension: maximumDimension)
    }
    func outputDimensions(for source: ResizeSource) -> ImageConverter.Dimensions? {
        guard let maximumDimension else { return nil }
        return try? source.dimensions.fitting(maximumDimension: maximumDimension)
    }
}

/// A retained, nonmodal panel: choosing Resize never runs a nested event loop
/// inside Finder's drag. Source metadata loads on a worker before presentation.
@MainActor final class ResizeOptionsCoordinator: NSObject, ResizeOptionsPresenting, NSWindowDelegate {
    private var panel: NSPanel?
    private let workers = PreviewTaskGroup()
    private var stopped = false
    private var prepareTask: Task<Void, Never>?
    private var generation = UUID()
    private var estimate: ImageEncodingPreviewModel?
    private var completion: (@MainActor (Result<ResizeSelection?, Error>) -> Void)?

    func choose(_ urls: [URL], preferredMaximum: Int, preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ResizeSelection?, Error>) -> Void) {
        guard !stopped else { completion(.success(nil)); return }
        cancel()
        let request = UUID()
        generation = request
        self.completion = completion
        prepareTask = workers.spawn { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await WorkLimiter.shared.withPermit { try ResizeSource.load(urls) }
            }
            do {
                let sources = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.prepareTask = nil
                self.present(ResizeOptionsModel(sources: sources, preferredMaximum: preferredMaximum, settings: preferredSettings))
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

    func shutdown() async {
        stopped = true
        cancel()
        await workers.shutdown()
    }

    private func present(_ model: ResizeOptionsModel) {
        let estimate = ImageEncodingPreviewModel(taskGroup: workers)
        self.estimate = estimate
        let view = ResizeOptionsView(model: model, estimate: estimate, cancel: { [weak self] in self?.finish(.success(nil)) },
                                     confirm: { [weak self] selection in self?.finish(.success(selection)) })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable]
        panel.title = "Orange · Resize image"
        panel.identifier = NSUserInterfaceItemIdentifier("orange.resize.options")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: Result<ResizeSelection?, Error>) {
        estimate?.cancel()
        estimate = nil
        let callback = completion
        completion = nil
        let closing = panel
        panel = nil
        closing?.close()
        callback?(result)
    }

    func windowWillClose(_ notification: Notification) { finish(.success(nil)) }
}
