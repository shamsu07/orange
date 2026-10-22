import AppKit
import SwiftUI
import OrangeCore

struct ImageEditSelection {
    let inputs: [URL]
    let quality: Double
    let cropRect: NormalizedCropRect?
}

@MainActor protocol ImageOptionsPresenting: AnyObject {
    func choose(_ tool: ToolKind, urls: [URL], preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ImageEditSelection?, Error>) -> Void)
    func cancel()
    func shutdown() async
}

extension ImageOptionsPresenting {
    func shutdown() async { cancel() }
}

@MainActor final class ImageOptionsModel: ObservableObject {
    let tool: ToolKind
    let sources: [ResizeSource]
    let thumbnail: CGImage?
    let baseSettings: ConversionSettings
    @Published var quality: Double
    @Published var cropRect = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @Published var aspect: CropAspect = .free

    enum CropAspect: String, CaseIterable, Identifiable {
        case free = "Free", original = "Original", square = "1:1", fourThree = "4:3", wide = "16:9"
        var id: Self { self }
        func ratio(source: ImageConverter.Dimensions) -> Double? {
            switch self {
            case .free: return nil
            case .original: return Double(source.width) / Double(source.height)
            case .square: return 1
            case .fourThree: return 4 / 3
            case .wide: return 16 / 9
            }
        }
    }
    enum Corner: CaseIterable, Equatable { case topLeft, topRight, bottomLeft, bottomRight }

    init(tool: ToolKind, sources: [ResizeSource], thumbnail: CGImage?, settings: ConversionSettings) {
        self.tool = tool; self.sources = sources; self.thumbnail = thumbnail; self.baseSettings = settings
        self.quality = settings.quality.isFinite ? min(1, max(0.05, settings.quality)) : 0.82
    }
    var settings: ConversionSettings {
        var settings = baseSettings
        settings.quality = quality
        settings.cropRect = tool == .crop ? cropRect : nil
        return settings
    }
    func selection(estimates: [URL: ImageConverter.EncodingPreview]) -> ImageEditSelection? {
        guard !sources.isEmpty, estimates.count == sources.count else { return nil }
        let eligible = tool == .compress ? sources.filter { estimates[$0.url]?.savesBytes == true } : sources
        guard !eligible.isEmpty, tool != .crop || (cropRect.isValid && cropRect != .fullImage) else { return nil }
        return ImageEditSelection(inputs: eligible.map(\.url), quality: quality, cropRect: tool == .crop ? cropRect : nil)
    }
    func applyAspect(_ value: CropAspect) {
        aspect = value
        guard let size = sources.first?.dimensions, let ratio = value.ratio(source: size) else { return }
        let normalizedRatio = ratio * Double(size.height) / Double(size.width)
        let width = min(0.9, 0.9 * normalizedRatio), height = width / normalizedRatio
        cropRect = NormalizedCropRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
    func setCropWidth(_ width: Double) {
        let width = min(1, max(0.01, width))
        var height = cropRect.height
        if let size = sources.first?.dimensions, let ratio = aspect.ratio(source: size) {
            height = width / (ratio * Double(size.height) / Double(size.width))
        }
        let scale = min(1, 1 / max(width, height))
        let finalWidth = width * scale, finalHeight = height * scale
        cropRect = NormalizedCropRect(x: min(1 - finalWidth, max(0, cropRect.x + (cropRect.width - finalWidth) / 2)),
                                      y: min(1 - finalHeight, max(0, cropRect.y + (cropRect.height - finalHeight) / 2)),
                                      width: finalWidth, height: finalHeight)
    }
    func setCropHeight(_ height: Double) {
        guard aspect == .free else { return }
        let height = min(1, max(0.01, height))
        cropRect = NormalizedCropRect(x: cropRect.x, y: min(1 - height, max(0, cropRect.y + (cropRect.height - height) / 2)),
                                      width: cropRect.width, height: height)
    }
    func move(from start: NormalizedCropRect, dx: Double, dy: Double) {
        cropRect = NormalizedCropRect(x: min(1 - start.width, max(0, start.x + dx)),
                                      y: min(1 - start.height, max(0, start.y + dy)), width: start.width, height: start.height)
    }
    func resize(_ corner: Corner, from start: NormalizedCropRect, dx: Double, dy: Double) {
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let anchorX = left ? start.x + start.width : start.x
        let anchorY = top ? start.y + start.height : start.y
        let endX = min(1, max(0, (left ? start.x : start.x + start.width) + dx))
        let endY = min(1, max(0, (top ? start.y : start.y + start.height) + dy))
        var width = max(0.01, left ? anchorX - endX : endX - anchorX)
        var height = max(0.01, top ? anchorY - endY : endY - anchorY)
        if let size = sources.first?.dimensions, let ratio = aspect.ratio(source: size) {
            let normalizedRatio = ratio * Double(size.height) / Double(size.width)
            width = min(width, height * normalizedRatio)
            height = width / normalizedRatio
        }
        width = min(width, left ? anchorX : 1 - anchorX)
        height = min(height, top ? anchorY : 1 - anchorY)
        cropRect = NormalizedCropRect(x: left ? anchorX - width : anchorX, y: top ? anchorY - height : anchorY,
                                      width: width, height: height)
    }
}

// CGImage is immutable. It is decoded on the worker and only displayed on main.
private struct PreparedImageOptions: @unchecked Sendable {
    let sources: [ResizeSource]
    let thumbnail: CGImage?
}

@MainActor final class ImageOptionsCoordinator: NSObject, ImageOptionsPresenting, NSWindowDelegate {
    private var panel: NSPanel?
    private let workers = PreviewTaskGroup()
    private var stopped = false
    private var task: Task<Void, Never>?
    private var estimate: ImageEncodingPreviewModel?
    private var generation = UUID()
    private var completion: (@MainActor (Result<ImageEditSelection?, Error>) -> Void)?

    func choose(_ tool: ToolKind, urls: [URL], preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ImageEditSelection?, Error>) -> Void) {
        guard !stopped else { completion(.success(nil)); return }
        cancel()
        self.completion = completion
        let request = generation
        task = workers.spawn { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await WorkLimiter.shared.withPermit {
                    guard tool == .crop || tool == .compress else { throw OrangeError.unsupported("Choose Crop or Compress for this image.") }
                    let sources = try ResizeSource.load(urls)
                    guard !sources.isEmpty else { throw OrangeError.invalidInput("Select an image first.") }
                    let thumbnail = tool == .crop ? try ImageConverter.thumbnail(of: sources[0].url) : nil
                    return PreparedImageOptions(sources: sources, thumbnail: thumbnail)
                }
            }
            do {
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.task = nil
                self.present(ImageOptionsModel(tool: tool, sources: prepared.sources, thumbnail: prepared.thumbnail, settings: preferredSettings))
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.finish(.failure(error))
            }
        }
    }
    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        finish(.success(nil))
    }
    func shutdown() async {
        stopped = true
        cancel()
        await workers.shutdown()
    }
    private func present(_ model: ImageOptionsModel) {
        let estimate = ImageEncodingPreviewModel(taskGroup: workers)
        self.estimate = estimate
        let view = ImageOptionsView(model: model, estimate: estimate,
                                    cancel: { [weak self] in self?.finish(.success(nil)) },
                                    confirm: { [weak self] in self?.finish(.success($0)) })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable]
        panel.title = model.tool == .crop ? "Orange · Crop image" : "Orange · Compress image"
        panel.identifier = NSUserInterfaceItemIdentifier("orange.image.\(model.tool.rawValue).options")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    private func finish(_ result: Result<ImageEditSelection?, Error>) {
        estimate?.cancel(); estimate = nil
        let callback = completion; completion = nil
        let closing = panel; panel = nil
        closing?.close()
        callback?(result)
    }
    func windowWillClose(_ notification: Notification) { finish(.success(nil)) }
}
