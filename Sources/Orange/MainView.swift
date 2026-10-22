import AppKit
import SwiftUI
import OrangeCore

private let orange = Color(red: 1, green: 0.584, blue: 0)

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var tab = "Convert"
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: OrangeArtwork.appIcon(size: 48)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orange").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Your files. A little more useful.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("On this Mac", systemImage: "lock.shield").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.quaternary.opacity(0.5), in: Capsule())
            }
            .padding(.horizontal, 30).padding(.top, 38).padding(.bottom, 22)

            HStack(spacing: 5) {
                ForEach(["Convert", "Activity", "Settings", "Backends"], id: \.self) { title in
                    Button { tab = title } label: {
                        HStack(spacing: 5) {
                            Text(title)
                            if title == "Activity", model.activeCount > 0 {
                                Text("\(model.activeCount)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).background(orange.opacity(0.15), in: Capsule())
                            }
                        }
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 8)
                        .background(tab == title ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 30).padding(.bottom, 16)
            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case "Activity": activity
                    case "Settings": settings
                    case "Backends": backends
                    default: converter
                    }
                }.padding(30)
            }
            Divider()
            HStack {
                Circle().fill(model.wheelEnabled ? Color.green : .secondary).frame(width: 5, height: 5)
                Text(model.wheelEnabled ? "Ready in your menu bar" : "Finder wheels paused")
                Spacer()
                Text("Open source · No uploads · No paywall")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 30).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(orange)
        .frame(minWidth: 720, minHeight: 610)
        .onChange(of: model.mode) { _ in model.selectedChoice = model.choices.first }
        .onChange(of: model.jobs.count) { _ in if model.activeCount > 0 { tab = "Activity" } }
        .alert("Orange", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var converter: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Less clicking. More doing.").font(.system(size: 27, weight: .semibold, design: .rounded))
                Text("Drop your files here, or drag in Finder and tap a key.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(spacing: 13) {
                Image(systemName: model.inputs.isEmpty ? "square.and.arrow.down" : "doc.on.doc")
                    .font(.system(size: 31, weight: .light)).foregroundStyle(orange)
                if model.inputs.isEmpty {
                    Text("Drop something in").font(.system(size: 16, weight: .medium))
                    Text("Images, video, audio, PDFs, documents & more").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Choose files…") { model.chooseFiles() }.controlSize(.large)
                } else {
                    Text(model.inputs.count == 1 ? model.inputs[0].lastPathComponent : "\(model.inputs.count) files ready")
                        .font(.system(size: 16, weight: .medium)).lineLimit(2)
                    Text(model.inputs.prefix(3).map(\.lastPathComponent).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Button("Choose other files…") { model.chooseFiles() }
                        Button("Clear") { model.select([]) }.foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity).frame(minHeight: 192)
            .padding(20)
            .background(orange.opacity(dropTarget ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(orange.opacity(dropTarget ? 0.8 : 0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                readDroppedURLs(providers) { model.select($0) }
                return true
            }

            if !model.inputs.isEmpty {
                Picker("Operation", selection: $model.mode) {
                    ForEach(WheelMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented)
                if model.loadingCapabilities && model.mode != .actions {
                    HStack { ProgressView().controlSize(.small); Text("Checking available formats…").font(.system(size: 12)).foregroundStyle(.secondary) }
                } else if model.choices.isEmpty {
                    Text("No tools are available for this selection. Try Actions, or check optional Backends.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(model.choices) { choice in
                            Button { model.selectedChoice = choice } label: {
                                Label(choice.label, systemImage: choice.symbol)
                                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 36)
                                    .background(model.selectedChoice == choice ? orange.opacity(0.13) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selectedChoice == choice ? orange.opacity(0.6) : .clear))
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Text("Output is saved beside the original.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.selectedChoice.map { model.mode == .convert ? "Convert to \($0.label)" : $0.label } ?? "Choose an option") {
                            model.performSelected()
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selectedChoice == nil)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    shortcutCard(model.conversionShortcut.symbol, title: "Convert", detail: "Pick a format")
                    shortcutCard(model.toolsShortcut.symbol, title: "Tools", detail: "Make an adjustment")
                    shortcutCard(model.actionsShortcut.symbol, title: "Actions", detail: "Send it somewhere")
                }
                Text("Start dragging, then tap a key. Release the key and mouse over the wheel, then click an option. Switch wheels with another key. Escape cancels.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcutCard(_ key: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 22, weight: .light)).foregroundStyle(orange).frame(width: 35, height: 40)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Activity").font(.system(size: 25, weight: .semibold, design: .rounded))
                Spacer()
                Button("Clear finished") { model.clearFinished() }.disabled(model.jobs.isEmpty)
            }
            Text("Two jobs at a time. Originals stay in place.").font(.system(size: 12)).foregroundStyle(.secondary)
            if model.jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                    Text("A fresh start").font(.system(size: 18, weight: .medium))
                    Text("Your conversions will appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 70)
            }
            ForEach(model.jobs) { job in JobRow(job: job, cancel: { model.cancel(job.id) }) }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Make yourself at home.").font(.system(size: 25, weight: .semibold, design: .rounded))
            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    Toggle("Enable Finder drag wheels", isOn: $model.wheelEnabled)
                    Toggle("Reveal finished files in Finder", isOn: $model.revealOnCompletion)
                    Toggle("Remove metadata during image conversion", isOn: $model.stripMetadata)
                    Text("Metadata removal applies to image conversion. Dedicated removal tools have their own format limits.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Conversion defaults") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Quality").frame(width: 110, alignment: .leading)
                        Slider(value: $model.quality, in: 0.1...1)
                        Text("\(Int(model.quality * 100))%").monospacedDigit().frame(width: 38)
                    }
                    HStack {
                        Text("Default long edge").frame(width: 110, alignment: .leading)
                        TextField("Pixels", value: $model.maxDimension, format: .number).frame(width: 90)
                        Text("px · Confirmed each resize").foregroundStyle(.secondary)
                    }
                    Text("Resize asks for a target, preserves the aspect ratio, and never enlarges smaller images.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Text("Trim range").frame(width: 110, alignment: .leading)
                        TextField("Start", value: $model.trimStart, format: .number).frame(width: 70)
                        Text("to")
                        TextField("End", value: $model.trimEnd, format: .number).frame(width: 70)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Playback speed").frame(width: 110, alignment: .leading)
                        Picker("Speed", selection: $model.speed) {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text("\($0.formatted())×").tag($0) }
                        }.labelsHidden().frame(width: 100)
                    }
                }.font(.system(size: 12)).padding(12)
            }
            GroupBox("Privacy & storage") {
                Text("Orange processes files locally. There are no accounts, uploads, analytics, or paid unlocks. Outputs are written alongside their inputs with a numbered name when needed. Activity is kept only for this session.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var backends: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A native core. Room to grow.").font(.system(size: 25, weight: .semibold, design: .rounded))
            Text("Orange offers formats your installed converters can actually write.").font(.system(size: 12)).foregroundStyle(.secondary)
            backendRow("Images", detail: "ImageIO & Core Graphics · Installed macOS encoders", available: true)
            backendRow("PDFs", detail: "PDFKit & Vision · Local OCR, page images, merge & split", available: true)
            backendRow("Documents & subtitles", detail: "Native text formats, DOCX import, SRT/VTT, CSV/TSV", available: true)
            backendRow("Archives", detail: "macOS archive tools · ZIP, TAR, GZIP creation", available: true)
            backendRow("Audio & video", detail: ProcessRunner.executable(named: "ffmpeg")?.path ?? "FFmpeg is not installed. Install it to enable audio and video conversion.", available: ProcessRunner.executable(named: "ffmpeg") != nil)
            GroupBox("Optional FFmpeg setup") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("If you use Homebrew, install the open source media backend:").font(.system(size: 12))
                    HStack {
                        Text("brew install ffmpeg").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install ffmpeg", forType: .string) }
                    }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    Text("Restart Orange after installing a backend. No downloads run automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(12)
            }
            Text("This is an early implementation. Advanced document export, full media editing, configurable shortcuts and complete Tangerine parity are tracked in the project’s reference matrix.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func backendRow(_ title: String, detail: String, available: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: available ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(available ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Text(available ? "Available" : "Optional").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct JobRow: View {
    let job: ConversionJob
    let cancel: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if job.state == .running { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).foregroundStyle(job.state == .failed ? Color.red : job.state == .complete ? .green : .secondary) }
            }.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.inputs.count == 1 ? job.inputs[0].lastPathComponent : "\(job.inputs.count) files")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(job.operation.label) · \(status)").font(.system(size: 11)).foregroundStyle(.secondary)
                if let message = job.message { Text(message).font(.system(size: 11)).foregroundStyle(job.state == .failed ? Color.red : .secondary).textSelection(.enabled) }
                if !job.outputs.isEmpty {
                    Text(job.outputs.map(\.lastPathComponent).joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if job.state == .running || job.state == .queued { Button("Cancel", action: cancel).controlSize(.small) }
            if !job.outputs.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) } label: { Image(systemName: "folder") }.help("Reveal in Finder")
            }
        }.padding(15).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }
    private var symbol: String {
        switch job.state { case .queued: return "clock"; case .running: return "arrow.triangle.2.circlepath"; case .complete: return "checkmark.circle.fill"; case .failed: return "exclamationmark.circle.fill"; case .cancelled: return "xmark.circle" }
    }
    private var status: String {
        switch job.state { case .queued: return "Queued"; case .running: return "Working…"; case .complete: return job.elapsed.map { "Done in \($0.formatted(.number.precision(.fractionLength(1))))s" } ?? "Done"; case .failed: return "Failed"; case .cancelled: return "Cancelled" }
    }
}

struct FloatView: View {
    let urls: [URL]
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
                        Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(2)
                        Spacer()
                        Image(systemName: "hand.draw").foregroundStyle(.secondary)
                    }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        .onDrag { NSItemProvider(object: url as NSURL) }
                }
                Text("Drag a file from here into another app.").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12)
        }.frame(minWidth: 240, minHeight: 110)
    }
}

@MainActor private func readDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    Task {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: NSURL.self) { object, _ in continuation.resume(returning: object as? URL) }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        completion(urls)
    }
}
