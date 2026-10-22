import SwiftUI
import OrangeCore

struct ResizeOptionsView: View {
    @ObservedObject var model: ResizeOptionsModel
    @ObservedObject var estimate: ImageEncodingPreviewModel
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
            Text("Keeps the aspect ratio. Smaller images are skipped. File size is estimated by encoding a temporary copy with these settings.")
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
                            if let preview = estimate.estimates[source.url] {
                                Text(ImageEncodingPreviewModel.summary(preview)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(preview.savesBytes ? Color.orange : Color.secondary)
                            } else {
                                Text("\(ImageEncodingPreviewModel.bytes(source.originalBytes)) · \(model.eligibleSources.contains(where: { $0.url == source.url }) ? "estimating…" : "unchanged")")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: CGFloat(min(4, model.sources.count)) * 64)
            if let error = estimate.errorMessage {
                Text("Size preview unavailable: \(error)").font(.system(size: 12)).foregroundStyle(.red)
            } else if estimate.isEstimating {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Measuring estimated file size…").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
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
                    .disabled(model.selection == nil || estimate.isEstimating || estimate.errorMessage != nil || estimate.estimates.count != model.eligibleSources.count)
            }
        }.padding(24).frame(width: 440)
            .onAppear { editingMaximum = true; refreshEstimate() }
            .onChange(of: model.maximumText) { _ in refreshEstimate() }
            .onDisappear { estimate.cancel() }
    }

    private func refreshEstimate() {
        guard let settings = model.previewSettings, model.selection != nil else { estimate.cancel(); return }
        estimate.schedule(.resize, urls: model.eligibleSources.map(\.url), settings: settings)
    }
}
