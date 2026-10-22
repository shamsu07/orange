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
    private var task: Task<Void, Never>?
    private var estimate: ImageEncodingPreviewModel?
    private var generation = UUID()
    private var completion: (@MainActor (Result<ImageEditSelection?, Error>) -> Void)?

    func choose(_ tool: ToolKind, urls: [URL], preferredSettings: ConversionSettings,
                completion: @escaping @MainActor (Result<ImageEditSelection?, Error>) -> Void) {
        cancel()
        self.completion = completion
        let request = generation
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                guard tool == .crop || tool == .compress else { throw OrangeError.unsupported("Choose Crop or Compress for this image.") }
                let sources = try ResizeSource.load(urls)
                guard !sources.isEmpty else { throw OrangeError.invalidInput("Select an image first.") }
                let thumbnail = tool == .crop ? try ImageConverter.thumbnail(of: sources[0].url) : nil
                return PreparedImageOptions(sources: sources, thumbnail: thumbnail)
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
    private func present(_ model: ImageOptionsModel) {
        let estimate = ImageEncodingPreviewModel()
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

private struct ImageOptionsView: View {
    @ObservedObject var model: ImageOptionsModel
    @ObservedObject var estimate: ImageEncodingPreviewModel
    let cancel: () -> Void
    let confirm: (ImageEditSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.tool == .crop ? "Choose what to keep" : "Smaller file, same dimensions")
                .font(.system(size: 21, weight: .semibold))
            if model.tool == .crop {
                if let image = model.thumbnail { CropSurface(model: model, image: image).frame(height: 300) }
                HStack {
                    Text("Aspect ratio").foregroundStyle(.secondary)
                    Picker("Aspect ratio", selection: $model.aspect) {
                        ForEach(ImageOptionsModel.CropAspect.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)
                }
                DisclosureGroup("Fine adjustments") {
                    VStack(spacing: 8) {
                        cropAdjustment("Horizontal position", value: Binding(get: { model.cropRect.x }, set: { model.move(from: model.cropRect, dx: $0 - model.cropRect.x, dy: 0) }), maximum: max(0.01, 1 - model.cropRect.width))
                        cropAdjustment("Vertical position", value: Binding(get: { model.cropRect.y }, set: { model.move(from: model.cropRect, dx: 0, dy: $0 - model.cropRect.y) }), maximum: max(0.01, 1 - model.cropRect.height))
                        cropAdjustment("Crop width", value: Binding(get: { model.cropRect.width }, set: { model.setCropWidth($0) }), maximum: 1)
                        if model.aspect == .free {
                            cropAdjustment("Crop height", value: Binding(get: { model.cropRect.height }, set: { model.setCropHeight($0) }), maximum: 1)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                Text(model.sources.count > 1 ? "Drag the frame or its corners. This relative crop applies to all \(model.sources.count) images; the preview shows the first." : "Drag the frame to move it. Drag a corner to change the crop.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Image quality")
                        Spacer()
                        Text("\(Int((model.quality * 100).rounded()))%").monospacedDigit().foregroundStyle(.orange)
                    }
                    Slider(value: $model.quality, in: 0.05...1, step: 0.01).tint(.orange)
                        .accessibilityLabel("Compression quality")
                    HStack { Text("Smaller file"); Spacer(); Text("More detail") }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Compression trades some fine detail for fewer bytes. Resize changes pixel dimensions. Already compressed images can have little left to save.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if let result = estimate.estimates[source.url] {
                                Text(ImageEncodingPreviewModel.summary(result)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(result.savesBytes ? Color.orange : Color.secondary)
                                Text("\(source.dimensions.width) × \(source.dimensions.height) → \(result.dimensions.width) × \(result.dimensions.height) px\(model.tool == .compress && !result.savesBytes ? " · no reduction; skipped" : "")")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Text("\(ImageEncodingPreviewModel.bytes(source.originalBytes)) · estimating…").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: CGFloat(min(model.sources.count, 3)) * 66)
            if let error = estimate.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            } else if estimate.isEstimating {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Measuring estimated file size…").font(.system(size: 12)).foregroundStyle(.secondary) }
            } else if model.tool == .compress && model.selection(estimates: estimate.estimates) == nil {
                Text("No reduction at this quality. Lower the slider to try a smaller file.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Originals stay in place.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(model.tool == .crop ? "Save crop" : "Compress") {
                    if let selection = model.selection(estimates: estimate.estimates) { confirm(selection) }
                }.keyboardShortcut(.defaultAction)
                    .disabled(estimate.isEstimating || estimate.errorMessage != nil || model.selection(estimates: estimate.estimates) == nil)
            }
        }.padding(24).frame(width: model.tool == .crop ? 540 : 460)
            .onAppear { refresh() }
            .onChange(of: model.quality) { _ in refresh() }
            .onChange(of: model.cropRect) { _ in refresh() }
            .onChange(of: model.aspect) { model.applyAspect($0) }
            .onDisappear { estimate.cancel() }
    }
    private func cropAdjustment(_ label: String, value: Binding<Double>, maximum: Double) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            Slider(value: value, in: 0...maximum).tint(.orange).accessibilityLabel(label)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
    private func refresh() { estimate.schedule(model.tool, urls: model.sources.map(\.url), settings: model.settings) }
}

private struct CropSurface: View {
    @ObservedObject var model: ImageOptionsModel
    let image: CGImage
    @State private var dragStart: NormalizedCropRect?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let rect = CGRect(x: model.cropRect.x * size.width, y: model.cropRect.y * size.height,
                              width: model.cropRect.width * size.width, height: model.cropRect.height * size.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                Path { path in path.addRect(CGRect(origin: .zero, size: size)); path.addRect(rect) }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if dragStart == nil { dragStart = model.cropRect }
                        if let start = dragStart { model.move(from: start, dx: value.translation.width / size.width, dy: value.translation.height / size.height) }
                    }.onEnded { _ in dragStart = nil })
                Path { path in
                    path.addRect(rect)
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                    }
                }.stroke(Color.white.opacity(0.8), lineWidth: 1).allowsHitTesting(false)
                ForEach(Array(ImageOptionsModel.Corner.allCases.enumerated()), id: \.offset) { _, corner in
                    let left = corner == .topLeft || corner == .bottomLeft
                    let top = corner == .topLeft || corner == .topRight
                    RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1))
                        .padding(6).contentShape(Rectangle())
                        .position(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if dragStart == nil { dragStart = model.cropRect }
                            if let start = dragStart { model.resize(corner, from: start, dx: value.translation.width / size.width, dy: value.translation.height / size.height) }
                        }.onEnded { _ in dragStart = nil })
                }
            }.frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Crop preview. Drag the frame to move, or a corner to resize.")
    }
}
