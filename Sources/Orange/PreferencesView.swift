import AppKit
import SwiftUI
import OrangeCore

@MainActor
struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var login: LaunchAtLogin
    @State private var mediaBackend: MediaBackendState = .checking

    private let tint = Color(red: 1, green: 0.584, blue: 0)

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            formats
                .tabItem { Label("Formats", systemImage: "doc.on.doc") }
            compatibility
                .tabItem { Label("Compatibility", systemImage: "checkmark.shield") }
            about
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .tint(tint)
        .padding(12)
        .frame(minWidth: 620, idealWidth: 640, minHeight: 650, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await checkMediaBackend() }
    }

    private var general: some View {
        Form {
            Section {
                Picker("Wheel appearance", selection: $model.wheelAppearance) {
                    ForEach(WheelAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.rawValue.capitalized).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Wheel size")
                    Slider(value: $model.wheelDiameter, in: Double(WheelGeometry.minimumDiameter)...Double(WheelGeometry.maximumDiameter), step: 2)
                        .accessibilityLabel("Wheel diameter")
                    Text("\(Int(model.wheelDiameter)) pt").monospacedDigit().frame(width: 56)
                }
                HStack {
                    Button("Reset size") { model.wheelDiameter = Double(WheelGeometry.defaultDiameter) }
                    Spacer()
                    Button("Preview wheel") { model.onPreviewWheel?() }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Default 252 pt. Minimum 220 pt. Options stay fixed while highlighting. Press Escape to close the preview.")
            }

            Section("General") {
                Toggle("Enable Finder drag wheels", isOn: $model.wheelEnabled)
                Toggle("Launch Orange when I log in", isOn: Binding(get: { login.enabled || login.requiresApproval }, set: { login.setEnabled($0) }))
                Toggle("Soft selection sounds", isOn: $model.soundFeedback)
                Toggle("Reveal finished files in Finder", isOn: $model.revealOnCompletion)
                if login.requiresApproval {
                    Button("Approve in Login Items Settings") { login.openLoginItemsSettings() }
                }
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                    HStack {
                        Button("Retry launch at login") { login.retry() }
                        Button("Open Login Items Settings") { login.openLoginItemsSettings() }
                    }
                    if let diagnostics = login.diagnostics {
                        DisclosureGroup("Registration details") {
                            Text(diagnostics).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                shortcutPicker("Conversion wheel", selection: $model.conversionShortcut)
                shortcutPicker("Tools wheel", selection: $model.toolsShortcut)
                shortcutPicker("Actions wheel", selection: $model.actionsShortcut)
            } header: {
                Text("Drag shortcuts")
            } footer: {
                Text("Drag a file in Finder and tap a modifier. Release the key and mouse over the wheel, then click an option. Hovering never runs an operation. Escape cancels. Use a different modifier for each wheel.")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }

    private func shortcutPicker(_ title: String, selection: Binding<DragShortcut>) -> some View {
        Picker(title, selection: selection) {
            ForEach(DragShortcut.allCases) { shortcut in
                Text(shortcut.label).tag(shortcut)
                    .disabled(shortcut != selection.wrappedValue && [model.conversionShortcut, model.toolsShortcut, model.actionsShortcut].contains(shortcut))
            }
        }
        .pickerStyle(.menu)
    }

    private var formats: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Text("Quality")
                    Spacer(minLength: 16)
                    Slider(value: $model.quality, in: 0.1...1)
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Conversion quality")
                    Text(model.quality, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("Remove metadata during image conversion", isOn: $model.stripMetadata)
            } header: {
                Text("Conversion")
            } footer: {
                Text("Quality applies to supported lossy encoders. Compression does not guarantee a smaller file. Dedicated metadata tools have their own format limits.")
            }

            Section {
                HStack {
                    Text("Default maximum long edge")
                    Spacer()
                    TextField("Pixels", value: $model.maxDimension, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                        .accessibilityLabel("Maximum long edge in pixels")
                    Text("px").foregroundStyle(.secondary)
                }
            } header: {
                Text("Image resizing")
            } footer: {
                Text("Resize shows the original and output pixel dimensions and asks you to confirm the target each time. It preserves the aspect ratio and never enlarges smaller images. PDF page images export at 300 DPI, within separate size limits.")
            }

            Section {
                HStack {
                    Text("Trim range")
                    Spacer()
                    TextField("Start", value: $model.trimStart, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 74)
                        .accessibilityLabel("Trim start in seconds")
                    Text("to").foregroundStyle(.secondary)
                    TextField("End", value: $model.trimEnd, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 74)
                        .accessibilityLabel("Trim end in seconds")
                    Text("sec").foregroundStyle(.secondary)
                }
                Picker("Playback speed", selection: $model.speed) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Audio & video")
            } footer: {
                Text("Requires optional FFmpeg. Snapshot uses the trim start as its frame time. These conversion values apply for this session and reset when Orange restarts.")
            }
        }
        .formStyle(.grouped)
    }

    private var compatibility: some View {
        Form {
            Section("Built into macOS") {
                backendRow("Images", symbol: "photo", status: "Native",
                           detail: "ImageIO, Core Graphics and Vision. Output formats depend on the encoders available on this Mac.")
                backendRow("PDFs", symbol: "doc.richtext", status: "Native",
                           detail: "Text extraction with local OCR for scanned pages, page images, merge, split and limited document-information removal.")
                backendRow("Documents & subtitles", symbol: "text.alignleft", status: "Native",
                           detail: "Plain text, RTF, DOC/DOCX, SRT/VTT and CSV/TSV. Complex document layouts can change.")
                backendRow("Archives", symbol: "archivebox", status: "Native",
                           detail: "ZIP and TAR creation; GZIP for one file. Archive extraction is unavailable.")
            }

            Section {
                backendRow("Audio & video", symbol: "play.rectangle", status: mediaBackend.label,
                           detail: "Uses bundled or separately installed ffmpeg and ffprobe. Available outputs depend on their encoders.")
                Text("brew install ffmpeg")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Optional FFmpeg")
            } footer: {
                Text("For an existing Homebrew installation. Restart Orange after installation. Orange does not download converters; FFmpeg retains its own upstream licenses.")
            }

            Section("Not available yet") {
                Text("Pages, EPUB, PowerPoint and XLS/XLSX/ODS conversion; PDF compression; animated-image conversion; full Tangerine feature parity.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func backendRow(_ title: String, symbol: String, status: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 17))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private var about: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: OrangeArtwork.appIcon(size: 120))
                .resizable()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            Text("Orange")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("Version 0.1.4")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open-source file conversion for macOS.")
                .font(.body)
            Text("Files are processed locally. No accounts, uploads, analytics or automatic downloads.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Link("MIT License", destination: URL(string: "https://opensource.org/license/mit/")!)
                .padding(.top, 4)
            if mediaBackend == .detected {
                Link("FFmpeg · LGPL 2.1 or later", destination: URL(string: "https://ffmpeg.org/")!)
                    .font(.caption)
                Text("Bundled backend sources and licenses are included in Orange.app/Contents/Resources/Tools.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            Text("Orange is in development. Full Tangerine parity has not been established.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 10)
            Spacer()
            Text("© 2026 Orange contributors")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private enum MediaBackendState {
        case checking, detected, missing
        var label: String {
            switch self {
            case .checking: return "Checking…"
            case .detected: return "Detected"
            case .missing: return "Not installed"
            }
        }
    }

    private func checkMediaBackend() async {
        let detected = await Task.detached(priority: .utility) {
            guard let ffmpeg = ProcessRunner.executable(named: "ffmpeg") else { return false }
            let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
            return FileManager.default.isExecutableFile(atPath: sibling.path) || ProcessRunner.executable(named: "ffprobe") != nil
        }.value
        guard !Task.isCancelled else { return }
        mediaBackend = detected ? .detected : .missing
    }
}
