import SwiftUI
import AppKit

/// Small, nonactivating progress surface for operations started in Finder.
struct ActivityPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.activeCount > 0 ? "Working on your files" : "Activity")
                    .font(.headline)
                Spacer()
                Button("Clear") { model.clearFinished() }
                    .disabled(model.activeCount == model.jobs.count)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.jobs) { job in
                        HStack(alignment: .top, spacing: 10) {
                            indicator(job.state)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.inputs.count == 1 ? job.inputs[0].lastPathComponent : "\(job.inputs.count) files")
                                    .font(.callout.weight(.medium)).lineLimit(1)
                                Text(detail(job)).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 2)
                            if job.state == .running || job.state == .queued {
                                Button { model.cancel(job.id) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.plain).help("Cancel conversion")
                            } else if !job.outputs.isEmpty {
                                Button { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.plain).help("Show in Finder")
                            }
                        }
                        Divider()
                    }
                }
            }
            Text("Originals stay in place.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 390, height: 270)
    }

    @ViewBuilder private func indicator(_ state: ConversionJob.State) -> some View {
        if state == .running { ProgressView().controlSize(.small).frame(width: 16) }
        else {
            Image(systemName: state == .complete ? "checkmark.circle.fill" : state == .failed ? "exclamationmark.circle" : state == .cancelled ? "xmark.circle" : "clock")
                .foregroundStyle(state == .complete ? .green : state == .failed ? .red : .secondary)
                .frame(width: 16)
        }
    }

    private func detail(_ job: ConversionJob) -> String {
        switch job.state {
        case .queued: return "Waiting…"
        case .running: return "Converting…"
        case .complete: return job.message ?? job.outputs.map(\.lastPathComponent).joined(separator: ", ")
        case .failed: return job.message ?? "Conversion failed."
        case .cancelled: return "Cancelled"
        }
    }
}
