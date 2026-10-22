import AppKit
import SwiftUI
import OrangeCore

private struct ShortcutBindings {
    var conversion: DragShortcut = .shift
    var tools: DragShortcut = .command
    var actions: DragShortcut = .control

    subscript(mode: WheelMode) -> DragShortcut {
        get { switch mode { case .convert: return conversion; case .tools: return tools; case .actions: return actions } }
        set { switch mode { case .convert: conversion = newValue; case .tools: tools = newValue; case .actions: actions = newValue } }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var inputs: [URL] = []
    @Published var jobs: [ConversionJob] = []
    @Published var mode: WheelMode = .convert
    @Published var selectedChoice: WheelChoice?
    @Published var error: String?
    @Published var quality: Double = 0.82
    @Published var stripMetadata = false
    @Published var maxDimension = 1920
    @Published var trimStart = 0.0
    @Published var trimEnd = 10.0
    @Published var speed = 1.0
    @Published private(set) var capabilities = SelectionCapabilities()
    @Published private(set) var loadingCapabilities = false
    @Published private var dragShortcuts = ShortcutBindings()
    var conversionShortcut: DragShortcut { get { dragShortcuts.conversion } set { setShortcut(newValue, for: .convert) } }
    var toolsShortcut: DragShortcut { get { dragShortcuts.tools } set { setShortcut(newValue, for: .tools) } }
    var actionsShortcut: DragShortcut { get { dragShortcuts.actions } set { setShortcut(newValue, for: .actions) } }
    @Published var wheelAppearance = WheelAppearance(rawValue: UserDefaults.standard.string(forKey: "wheelAppearance") ?? "Glass") ?? .glass {
        didSet {
            if persistsPreferences { UserDefaults.standard.set(wheelAppearance.rawValue, forKey: "wheelAppearance") }
            onVisualPreferencesChange?()
        }
    }
    @Published var soundFeedback = UserDefaults.standard.object(forKey: "soundFeedback") as? Bool ?? true {
        didSet { if persistsPreferences { UserDefaults.standard.set(soundFeedback, forKey: "soundFeedback") } }
    }
    @Published var hapticFeedback = UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true {
        didSet { if persistsPreferences { UserDefaults.standard.set(hapticFeedback, forKey: "hapticFeedback") } }
    }
    @Published var menuPreferences = WheelMenuPreferences() {
        didSet {
            if persistsPreferences, let data = try? JSONEncoder().encode(menuPreferences) {
                UserDefaults.standard.set(data, forKey: "wheelMenuPreferences")
            }
            if let selectedChoice, !choices.contains(selectedChoice) { self.selectedChoice = choices.first }
        }
    }
    @Published var wheelEnabled: Bool = UserDefaults.standard.object(forKey: "wheelEnabled") as? Bool ?? true {
        didSet { if persistsPreferences { UserDefaults.standard.set(wheelEnabled, forKey: "wheelEnabled") } }
    }
    @Published var revealOnCompletion: Bool = UserDefaults.standard.object(forKey: "revealOnCompletion") as? Bool ?? true {
        didSet { if persistsPreferences { UserDefaults.standard.set(revealOnCompletion, forKey: "revealOnCompletion") } }
    }
    @Published var setupCompleted = UserDefaults.standard.bool(forKey: "setupCompleted") {
        didSet { if persistsPreferences { UserDefaults.standard.set(setupCompleted, forKey: "setupCompleted") } }
    }
    @Published private var storedWheelDiameter: Double = {
        let saved = UserDefaults.standard.object(forKey: "wheelDiameter") as? Double ?? Double(WheelGeometry.defaultDiameter)
        return Double(WheelGeometry(preferredDiameter: CGFloat(saved)).diameter)
    }()
    var wheelDiameter: Double {
        get { storedWheelDiameter }
        set {
            storedWheelDiameter = Double(WheelGeometry(preferredDiameter: CGFloat(newValue)).diameter)
            if persistsPreferences { UserDefaults.standard.set(storedWheelDiameter, forKey: "wheelDiameter") }
            onVisualPreferencesChange?()
        }
    }
    @Published var actionFeedback: String?
    var onShowActionFeedback: (() -> Void)?
    private var actionCoordinatorOverride: FileActionCoordinator?
    private var resizePresenterOverride: (any ResizeOptionsPresenting)?
    private lazy var resizeOptions: any ResizeOptionsPresenting = resizePresenterOverride ?? ResizeOptionsCoordinator()
    private var imagePresenterOverride: (any ImageOptionsPresenting)?
    private var mediaPresenterOverride: (any MediaOptionsPresenting)?
    private var pdfPresenterOverride: (any PDFOptionsPresenting)?
    private lazy var imageOptions: any ImageOptionsPresenting = imagePresenterOverride ?? ImageOptionsCoordinator()
    private lazy var mediaOptions: any MediaOptionsPresenting = mediaPresenterOverride ?? MediaOptionsCoordinator()
    private lazy var pdfOptions: any PDFOptionsPresenting = pdfPresenterOverride ?? PDFOptionsCoordinator()
    private lazy var fileDetails: FileDetailsCoordinator = {
        let coordinator = FileDetailsCoordinator()
        coordinator.onError = { [weak self] in self?.showFeedback($0) }
        return coordinator
    }()
    private var persistsPreferences = true
    private lazy var fileActions: FileActionCoordinator = {
        let coordinator = actionCoordinatorOverride ?? FileActionCoordinator()
        coordinator.onFeedback = { [weak self] message in self?.showFeedback(message) }
        coordinator.onError = { [weak self] message in self?.error = message; self?.showFeedback(message) }
        return coordinator
    }()

    func showFeedback(_ message: String) { actionFeedback = message; onShowActionFeedback?() }

    var onShowWindow: (() -> Void)?
    var onBeginFinderInteraction: (() -> Void)?
    var onVisualPreferencesChange: (() -> Void)?
    var onShowProgress: (() -> Void)?
    var onPreviewWheel: (() -> Void)?
    var onFloat: (([URL]) -> Void)?
    private let limiter = WorkLimiter.shared
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var moveTasks: [UUID: Task<Void, Never>] = [:]
    private var capabilityTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(persistPreferences: Bool = true, fileActionCoordinator: FileActionCoordinator? = nil,
         resizePresenter: (any ResizeOptionsPresenting)? = nil,
         imagePresenter: (any ImageOptionsPresenting)? = nil,
         mediaPresenter: (any MediaOptionsPresenting)? = nil,
         pdfPresenter: (any PDFOptionsPresenting)? = nil) {
        self.persistsPreferences = persistPreferences
        self.actionCoordinatorOverride = fileActionCoordinator
        self.resizePresenterOverride = resizePresenter
        self.imagePresenterOverride = imagePresenter
        self.mediaPresenterOverride = mediaPresenter
        self.pdfPresenterOverride = pdfPresenter
        if persistPreferences, let data = UserDefaults.standard.data(forKey: "wheelMenuPreferences"),
           let saved = try? JSONDecoder().decode(WheelMenuPreferences.self, from: data) { menuPreferences = saved }
        let defaults = ShortcutBindings()
        var restored = defaults
        var used = Set<DragShortcut>()
        // Old preference versions allowed duplicate keys. Repair them in a
        // deterministic order before publishing one coherent binding set.
        for mode in WheelMode.allCases {
            let key = Self.shortcutPreferenceKey(for: mode)
            let requested = UserDefaults.standard.string(forKey: key).flatMap(DragShortcut.init(rawValue:)) ?? defaults[mode]
            let available = [requested, defaults[mode]] + DragShortcut.allCases
            let chosen = available.first { !used.contains($0) } ?? defaults[mode]
            restored[mode] = chosen
            used.insert(chosen)
        }
        dragShortcuts = restored
        persistShortcuts()
    }

    /// Existing SwiftUI writable-property bindings remain valid. Publish the
    /// entire swap once so two modes never share the same active shortcut.
    func setShortcut(_ shortcut: DragShortcut, for mode: WheelMode) {
        let previous = dragShortcuts[mode]
        guard previous != shortcut else { return }
        var updated = dragShortcuts
        if let displaced = WheelMode.allCases.first(where: { $0 != mode && updated[$0] == shortcut }) {
            updated[displaced] = previous
        }
        updated[mode] = shortcut
        dragShortcuts = updated
        persistShortcuts()
    }

    private static func shortcutPreferenceKey(for mode: WheelMode) -> String {
        switch mode { case .convert: return "conversionShortcut"; case .tools: return "toolsShortcut"; case .actions: return "actionsShortcut" }
    }

    private func persistShortcuts() {
        guard persistsPreferences else { return }
        for mode in WheelMode.allCases {
            UserDefaults.standard.set(dragShortcuts[mode].rawValue, forKey: Self.shortcutPreferenceKey(for: mode))
        }
    }

    var settings: ConversionSettings {
        var settings = ConversionSettings()
        settings.quality = quality
        settings.stripMetadata = stripMetadata
        settings.maxDimension = maxDimension
        settings.trimStart = trimStart
        settings.trimEnd = trimEnd
        settings.speed = speed
        return settings
    }
    var choices: [WheelChoice] { inputs.isEmpty ? [] : choices(from: capabilities, mode: mode) }
    var activeCount: Int { jobs.filter { $0.state == .running || $0.state == .queued }.count }
    func shortcut(for mode: WheelMode) -> DragShortcut {
        dragShortcuts[mode]
    }

    func choices(from capabilities: SelectionCapabilities, mode: WheelMode, selectionCount: Int? = nil) -> [WheelChoice] {
        switch mode {
        case .convert:
            return capabilities.formats.map(WheelChoice.format)
        case .tools:
            return capabilities.tools.filter { tool in
                capabilities.families.allSatisfy { menuPreferences.isEnabled(tool, for: $0) }
            }.map(WheelChoice.tool)
        case .actions:
            return FileAction.allCases.filter { action in
                menuPreferences.isEnabled(action) && (action != .createZip || (selectionCount ?? inputs.count) > 1)
            }.map(WheelChoice.action)
        }
    }

    /// Keep the image wheel's observed clockwise order and omit its source
    /// format. The manual converter retains every supported output.
    func wheelChoices(from capabilities: SelectionCapabilities, inputs: [URL], mode: WheelMode) -> [WheelChoice] {
        guard mode == .convert, !inputs.isEmpty, capabilities.families.count == inputs.count, capabilities.families.allSatisfy({ $0 == .image }) else {
            return choices(from: capabilities, mode: mode, selectionCount: inputs.count)
        }
        func normalized(_ url: URL) -> String {
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": return "jpeg"
            case "tif", "tiff": return "tiff"
            case "heif", "heic": return "heic"
            default: return url.pathExtension.lowercased()
            }
        }
        let sourceFormats = Set(inputs.map(normalized))
        let order: [OutputFormat] = [.jpeg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
        let all = order + capabilities.formats.filter { !order.contains($0) }
        return all.filter { capabilities.formats.contains($0) && !(sourceFormats.count == 1 && sourceFormats.contains($0.rawValue)) }.map(WheelChoice.format)
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add files"
        if panel.runModal() == .OK { select(panel.urls) }
    }
    func select(_ urls: [URL]) {
        guard !isShuttingDown else { return }
        capabilityTask?.cancel()
        inputs = Array(NSOrderedSet(array: urls.filter(\.isFileURL))) as? [URL] ?? []
        capabilities = SelectionCapabilities()
        selectedChoice = nil
        guard !inputs.isEmpty else { loadingCapabilities = false; return }
        loadingCapabilities = true
        let snapshot = inputs
        capabilityTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { SelectionCapabilities.load(snapshot) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, self.inputs == snapshot else { return }
            self.capabilities = result
            self.loadingCapabilities = false
            self.selectedChoice = self.choices.first
        }
    }
    func performSelected() {
        guard let selectedChoice else { return }
        guard choices.contains(selectedChoice) else {
            self.selectedChoice = choices.first
            showFeedback("Choose an available option.")
            return
        }
        perform(selectedChoice, urls: inputs)
    }

    func perform(_ choice: WheelChoice, urls: [URL]) {
        guard !isShuttingDown, !urls.isEmpty else { return }
        if case .action(let action) = choice { performAction(action, urls: urls); return }
        guard let operation = choice.operation else { return }
        if operation == .tool(.resize) {
            let base = settings
            resizeOptions.choose(urls, preferredMaximum: maxDimension, preferredSettings: base) { [weak self] result in
                guard let self, !self.isShuttingDown else { return }
                switch result {
                case .success(let selection):
                    guard let selection, !selection.inputs.isEmpty else { return }
                    self.maxDimension = selection.maximumDimension
                    var chosen = base
                    chosen.maxDimension = selection.maximumDimension
                    self.enqueue(operation, urls: selection.inputs, settings: chosen)
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.showFeedback(error.localizedDescription)
                }
            }
            return
        }
        if case .tool(let tool) = operation {
            let families = Set(urls.map(FileFamily.detect))
            if tool == .compress, families.count > 1 {
                showFeedback("Select files of one type to choose compression quality: images, videos, audio or PDFs.")
                return
            }
            if families == [.image], [.compress, .crop].contains(tool) {
                let base = settings
                imageOptions.choose(tool, urls: urls, preferredSettings: base) { [weak self] result in
                    guard let self, !self.isShuttingDown else { return }
                    switch result {
                    case .success(let selection):
                        guard let selection else { return }
                        var chosen = base
                        chosen.quality = selection.quality
                        chosen.cropRect = selection.cropRect
                        self.enqueue(operation, urls: selection.inputs, settings: chosen)
                    case .failure(let error): self.showFeedback(error.localizedDescription)
                    }
                }
                return
            }
            if families.isSubset(of: [.video, .audio]), [.snapshot, .trim, .changeSpeed, .compress].contains(tool) {
                mediaOptions.choose(urls, tool: tool, settings: settings) { [weak self] result in
                    guard let self, !self.isShuttingDown else { return }
                    switch result {
                    case .success(let selections):
                        for selection in selections ?? [] { self.enqueue(operation, urls: [selection.input], settings: selection.settings) }
                    case .failure(let error): self.showFeedback(error.localizedDescription)
                    }
                }
                return
            }
            if families == [.pdf], [.splitPDF, .compress].contains(tool) {
                let complete: @MainActor (Result<[PDFEditSelection]?, Error>) -> Void = { [weak self] result in
                    guard let self, !self.isShuttingDown else { return }
                    switch result {
                    case .success(let selections):
                        for selection in selections ?? [] { self.enqueue(operation, urls: [selection.input], settings: selection.settings) }
                    case .failure(let error): self.showFeedback(error.localizedDescription)
                    }
                }
                if tool == .splitPDF { pdfOptions.chooseSplit(urls, completion: complete) }
                else { pdfOptions.chooseReduction(urls, completion: complete) }
                return
            }
        }
        enqueue(operation, urls: urls, settings: settings)
    }

    private func enqueue(_ operation: ConversionOperation, urls: [URL], settings snapshot: ConversionSettings) {
        onShowProgress?()
        let grouped: Bool
        switch operation {
        case .tool(.mergePDF), .convert(.zip), .convert(.tar), .convert(.gzip): grouped = true
        default: grouped = false
        }
        for batch in grouped ? [urls] : urls.map({ [$0] }) {
            let id = UUID()
            jobs.insert(ConversionJob(id: id, inputs: batch, operation: operation), at: 0)
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                guard await limiter.acquire(id) else { update(id, state: .cancelled); tasks[id] = nil; return }
                if Task.isCancelled { await limiter.release(); update(id, state: .cancelled); tasks[id] = nil; return }
                update(id, state: .running)
                let started = Date()
                let worker = Task.detached(priority: .userInitiated) {
                    try autoreleasepool { try ConversionEngine.run(operation, inputs: batch, settings: snapshot) }
                }
                do {
                    let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    if let index = jobs.firstIndex(where: { $0.id == id }) {
                        // Outputs already published are kept visible even when cancellation races completion.
                        jobs[index].state = .complete
                        jobs[index].outputs = result.outputs
                        jobs[index].message = result.message
                        jobs[index].elapsed = Date().timeIntervalSince(started)
                    }
                    if soundFeedback { NSSound(named: NSSound.Name("Glass"))?.play() }
                    if revealOnCompletion && !result.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
                } catch is CancellationError { update(id, state: .cancelled) }
                catch { update(id, state: Task.isCancelled ? .cancelled : .failed, message: error.localizedDescription) }
                await limiter.release()
                tasks[id] = nil
            }
        }
    }

    private func update(_ id: UUID, state: ConversionJob.State, message: String? = nil) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].state = state
            jobs[index].message = message
            if state == .running { jobs[index].started = Date() }
        }
    }
    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    func cancelAll() { for task in tasks.values { task.cancel() } }
    func shutdown() async {
        isShuttingDown = true
        resizeOptions.cancel()
        imageOptions.cancel()
        mediaOptions.cancel()
        pdfOptions.cancel()
        fileDetails.close()
        fileActions.shutdown()
        capabilityTask?.cancel()
        let pending = Array(tasks.values)
        let pendingMoves = Array(moveTasks.values)
        for task in pending { task.cancel() }
        await resizeOptions.shutdown()
        await imageOptions.shutdown()
        await mediaOptions.shutdown()
        await pdfOptions.shutdown()
        await fileDetails.shutdown()
        for task in pending { await task.value }
        // A filesystem move can be copying across volumes. Let it finish rather
        // than terminating the process partway through that file operation.
        for task in pendingMoves { await task.value }
        await capabilityTask?.value
    }
    func clearFinished() { jobs.removeAll { $0.state != .running && $0.state != .queued } }

    private func performAction(_ action: FileAction, urls: [URL]) {
        switch action {
        case .details: fileDetails.show(urls)
        case .createZip:
            guard urls.count > 1 else { return }
            enqueue(.convert(.zip), urls: urls, settings: settings)
        case .copy:
            fileActions.copyFiles(urls)
        case .copyPath:
            fileActions.copyPaths(urls)
        case .float: onFloat?(urls)
        case .airDrop:
            fileActions.airDrop(urls)
        case .move:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Move here"
            guard panel.runModal() == .OK, let destination = panel.url, !isShuttingDown else { return }
            // A multi-file move is intentionally preflighted to reject all name collisions.
            let targets = urls.map { destination.appendingPathComponent($0.lastPathComponent) }
            guard Set(targets).count == targets.count, targets.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
                error = "Move stopped: a file with the same name already exists in that folder."
                showFeedback(error ?? "Move stopped")
                return
            }
            let id = UUID()
            moveTasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { moveTasks[id] = nil }
                do {
                    try await Task.detached {
                        for (source, target) in zip(urls, targets) { try FileManager.default.moveItem(at: source, to: target) }
                    }.value
                    NSWorkspace.shared.activateFileViewerSelecting(targets)
                } catch { self.error = "Move stopped: \(error.localizedDescription). Some files may already have moved."; self.showFeedback(self.error ?? "Move stopped") }
            }
        case .terminal:
            fileActions.openTerminal(urls)
        }
    }
}
