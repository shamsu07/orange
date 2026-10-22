import AppKit
import SwiftUI
import OrangeCore

struct ResizeSource: Identifiable, Sendable {
    let url: URL
    let dimensions: ImageConverter.Dimensions
    var id: URL { url }

    static func load(_ urls: [URL]) throws -> [ResizeSource] {
        var seen = Set<URL>()
        return try urls.filter { seen.insert($0.standardizedFileURL).inserted }.map { url in
            try Task.checkCancellation()
            return ResizeSource(url: url, dimensions: try ImageConverter.dimensions(of: url))
        }
    }
}

struct ResizeSelection {
    let inputs: [URL]
    let maximumDimension: Int
}

@MainActor protocol ResizeOptionsPresenting: AnyObject {
    func choose(_ urls: [URL], preferredMaximum: Int,
                completion: @escaping @MainActor (Result<ResizeSelection?, Error>) -> Void)
    func cancel()
}

@MainActor final class ResizeOptionsModel: ObservableObject {
    let sources: [ResizeSource]
    @Published var maximumText: String

    init(sources: [ResizeSource], preferredMaximum: Int) {
        self.sources = sources
        let largest = sources.map(\.dimensions.longEdge).max() ?? 1
        let preferred = (1...16_384).contains(preferredMaximum) ? preferredMaximum : 1920
        // The default must actually resize something, including a small image.
        maximumText = String(largest > preferred ? preferred : max(1, largest / 2))
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
    private var prepareTask: Task<Void, Never>?
    private var generation = UUID()
    private var completion: (@MainActor (Result<ResizeSelection?, Error>) -> Void)?

    func choose(_ urls: [URL], preferredMaximum: Int,
                completion: @escaping @MainActor (Result<ResizeSelection?, Error>) -> Void) {
        cancel()
        let request = UUID()
        generation = request
        self.completion = completion
        prepareTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try ResizeSource.load(urls) }
            do {
                let sources = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.prepareTask = nil
                self.present(ResizeOptionsModel(sources: sources, preferredMaximum: preferredMaximum))
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

    private func present(_ model: ResizeOptionsModel) {
        let view = ResizeOptionsView(model: model, cancel: { [weak self] in self?.finish(.success(nil)) },
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
        let callback = completion
        completion = nil
        let closing = panel
        panel = nil
        closing?.close()
        callback?(result)
    }

    func windowWillClose(_ notification: Notification) { finish(.success(nil)) }
}

private struct ResizeOptionsView: View {
    @ObservedObject var model: ResizeOptionsModel
    let cancel: () -> Void
    let confirm: (ResizeSelection) -> Void
    @FocusState private var editingMaximum: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.sources.count == 1 ? "Resize image" : "Resize \(model.sources.count) images")
                .font(.system(size: 21, weight: .semibold))
            HStack {
                Text("Maximum long edge")
                Spacer()
                TextField("Pixels", text: $model.maximumText)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($editingMaximum)
                    .accessibilityLabel("Maximum long edge in pixels")
                Text("px").foregroundStyle(.secondary)
            }
            Text("Keeps the aspect ratio. Smaller images stay unchanged; they are skipped. Pixel dimensions do not guarantee a particular file size.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if let output = model.outputDimensions(for: source) {
                                Text("\(source.dimensions.width) × \(source.dimensions.height) → \(output.width) × \(output.height) px\(output == source.dimensions ? " · unchanged" : "")")
                                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                            } else {
                                Text("\(source.dimensions.width) × \(source.dimensions.height) px")
                                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: CGFloat(min(4, model.sources.count)) * 44)
            if let message = model.validationMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).accessibilityIdentifier("resize.validation")
            } else if model.unchangedCount > 0 {
                Text("\(model.eligibleSources.count) will resize. \(model.unchangedCount) already fit and will be skipped.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Originals stay in place.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Resize") { if let selection = model.selection { confirm(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection == nil)
            }
        }.padding(24).frame(width: 440)
            .onAppear { editingMaximum = true }
    }
}
