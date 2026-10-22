import AppKit
import SwiftUI
import OrangeCore

@MainActor final class FileDetailsCoordinator: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var onError: ((String) -> Void)?

    func show(_ urls: [URL]) {
        close()
        let token = UUID()
        generation = token
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try urls.map { try FileDetails.load($0) } }
            do {
                let details = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.task = nil
                let view = FileDetailsView(files: details, close: { [weak self] in self?.close() })
                let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
                panel.title = "Orange · File details"
                panel.styleMask = [.titled, .closable, .resizable]
                panel.minSize = NSSize(width: 540, height: 420)
                panel.setContentSize(NSSize(width: 640, height: 580))
                panel.isReleasedWhenClosed = false
                panel.delegate = self
                panel.center()
                self.panel = panel
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.task = nil
                self.onError?(error.localizedDescription)
            }
        }
    }
    func close() {
        generation = UUID()
        task?.cancel(); task = nil
        let closing = panel
        panel = nil
        closing?.delegate = nil
        closing?.close()
    }
    func windowWillClose(_ notification: Notification) { close() }
}

private struct FileDetailsView: View {
    let files: [FileDetails]
    let close: () -> Void
    @State private var selection = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if files.count > 1 {
                Picker("File", selection: $selection) {
                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in Text(file.url.lastPathComponent).tag(index) }
                }
            }
            if files.indices.contains(selection) {
                let file = files[selection]
                Label(file.url.lastPathComponent, systemImage: "doc.text.magnifyingglass").font(.title2).lineLimit(2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(file.sections) { section in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(section.title).font(.headline)
                                ForEach(section.fields) { field in
                                    HStack(alignment: .top, spacing: 16) {
                                        Text(field.label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                                        Text(field.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.system(size: 12))
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copy details") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.text, forType: .string) }
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.cancelAction)
                }
            }
        }.padding(24).frame(minWidth: 520, minHeight: 400)
    }
}
