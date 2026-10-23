import AppKit
import SwiftUI
import OrangeCore

@MainActor
struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var login: LaunchAtLogin
    @ObservedObject var updates: UpdateController
    @State private var mediaBackend: MediaBackendState = .checking

    private let tint = Color(red: 1, green: 0.584, blue: 0)

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            formats
                .tabItem { Label("Formats", systemImage: "doc.on.doc") }
            menus
                .tabItem { Label("Menus", systemImage: "circle.grid.2x2") }
            updateSettings
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
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
                Toggle("Subtle hover haptics", isOn: $model.hapticFeedback)
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

    private var menus: some View {
        Form {
            Section {
                Text("Choose which tools appear when you tap Command. Available tools still depend on the selected file and installed converters.")
                    .foregroundStyle(.secondary)
                ForEach(WheelMenuPreferences.families, id: \.self) { family in
                    DisclosureGroup(family == .pdf ? "PDF" : family.rawValue.capitalized) {
                        ForEach(WheelMenuPreferences.tools(for: family), id: \.self) { tool in
                            Toggle(tool.label, isOn: Binding(
                                get: { model.menuPreferences.isEnabled(tool, for: family) },
                                set: { model.menuPreferences.setEnabled($0, tool: tool, family: family) }))
                        }
                    }
                }
            } header: { Text("Command · tools by file type") }
            Section {
                ForEach(FileAction.allCases, id: \.self) { action in
                    Toggle(action.label, isOn: Binding(
                        get: { model.menuPreferences.isEnabled(action) },
                        set: { model.menuPreferences.setEnabled($0, action: action) }))
                }
            } header: { Text("Control · actions for all files") }
              footer: { Text("Create ZIP appears when multiple items are selected. Shift always offers supported conversions; it has no visibility filters.") }
            Section {
                Button("Show all tools and actions") { model.menuPreferences = WheelMenuPreferences() }
            }
        }.formStyle(.grouped)
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
                Text("Timeline tools open a preview before export. These values are starting preferences for the session; confirm each file's time range or speed in its tool window.")
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
                Text("Pages, EPUB, PowerPoint and XLS/XLSX/ODS conversion; animated-image conversion; full Tangerine feature parity.")
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
            Text("Version \(AppVersion.current)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open-source file conversion for macOS.")
                .font(.body)
            Text("Files are processed on this Mac. Optional update checks contact GitHub. Updates download only when you choose to install them. No accounts or analytics.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Link("MIT License", destination: URL(string: "https://opensource.org/license/mit/")!)
                .padding(.top, 4)
            Link("Sparkle · MIT License", destination: URL(string: "https://sparkle-project.org/")!)
                .font(.caption)
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

    private var updateSettings: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(updates.availableVersion.map { "Orange \($0) is available" } ?? "Orange \(AppVersion.current)")
                            .fontWeight(.medium)
                        if let date = updates.lastChecked {
                            Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(updates.buttonTitle) { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates || updates.installationWaitingForWork)
                }
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.setAutomaticallyChecks($0) }))
                    .disabled(!model.setupCompleted)
                if updates.installationWaitingForWork {
                    Text("The update will restart Orange after the current operations finish.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = updates.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: { Text("Keep Orange up to date") }
              footer: {
                Text("Checks run at most daily while Orange is open. A new version adds an Update button; background checks never open a window. You choose when to download, install and restart. Updates and their feed are verified with Orange's update signing key.")
            }
            Section("Privacy") {
                Text("Update checks contact shamsu07.github.io. Downloads come from GitHub Releases. GitHub receives ordinary connection information such as your IP address. Your selected files stay on this Mac. System profiling is disabled.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("Release notes on GitHub", destination: URL(string: "https://github.com/shamsu07/orange/releases")!)
            }
        }.formStyle(.grouped)
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
