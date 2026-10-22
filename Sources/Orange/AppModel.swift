import AppKit
import SwiftUI
import OrangeCore

enum WheelAppearance: String, CaseIterable { case glass = "Glass", solid = "Solid" }

enum DragShortcut: String, CaseIterable, Identifiable {
    case shift, command, control, option, optionShift, commandShift, controlShift, optionCommand
    var id: String { rawValue }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .optionShift: return [.option, .shift]
        case .commandShift: return [.command, .shift]
        case .controlShift: return [.control, .shift]
        case .optionCommand: return [.option, .command]
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧"; case .command: return "⌘"; case .control: return "⌃"; case .option: return "⌥"
        case .optionShift: return "⌥⇧"; case .commandShift: return "⌘⇧"; case .controlShift: return "⌃⇧"; case .optionCommand: return "⌥⌘"
        }
    }
    var label: String {
        switch self {
        case .shift: return "⇧  Shift"; case .command: return "⌘  Command"; case .control: return "⌃  Control"; case .option: return "⌥  Option"
        case .optionShift: return "⌥⇧  Option + Shift"; case .commandShift: return "⌘⇧  Command + Shift"
        case .controlShift: return "⌃⇧  Control + Shift"; case .optionCommand: return "⌥⌘  Option + Command"
        }
    }
}

enum WheelMode: String, CaseIterable {
    case convert = "Convert", tools = "Tools", actions = "Actions"
    var symbol: String { switch self { case .convert: return "arrow.triangle.2.circlepath"; case .tools: return "slider.horizontal.3"; case .actions: return "cursorarrow.and.square.on.square.dashed" } }
    var shortcut: String { switch self { case .convert: return "⇧"; case .tools: return "⌘"; case .actions: return "⌃" } }
}

private struct ShortcutBindings {
    var conversion: DragShortcut = .shift
    var tools: DragShortcut = .command
    var actions: DragShortcut = .control

    subscript(mode: WheelMode) -> DragShortcut {
        get { switch mode { case .convert: return conversion; case .tools: return tools; case .actions: return actions } }
        set { switch mode { case .convert: conversion = newValue; case .tools: tools = newValue; case .actions: actions = newValue } }
    }
}

enum WheelChoice: Hashable, Identifiable {
    case format(OutputFormat), tool(ToolKind), action(FileAction)
    var id: String { label }
    var label: String {
        switch self { case .format(let format): return format == .jpeg ? "JPG" : format.label; case .tool(let tool): return tool.label; case .action(let action): return action.label }
    }
    var symbol: String {
        switch self { case .format: return "doc"; case .tool(let tool): return tool.symbol; case .action(let action): return action.symbol }
    }
    var operation: ConversionOperation? {
        switch self { case .format(let format): return .convert(format); case .tool(let tool): return .tool(tool); case .action: return nil }
    }
}

struct ConversionJob: Identifiable {
    enum State { case queued, running, complete, failed, cancelled }
    let id: UUID
    let inputs: [URL]
    let operation: ConversionOperation
    var state: State = .queued
    var outputs: [URL] = []
    var message: String?
    var started: Date?
    var elapsed: TimeInterval?
}

/// Global bound across batches, so simultaneous drops cannot spawn unlimited encoders.
actor WorkLimiter {
    private var active = 0
    private let limit = 2
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire(_ id: UUID) async -> Bool {
        if Task.isCancelled { return false }
        if active < limit { active += 1; return true }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in waiters.append((id, continuation)) }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().1.resume(returning: true) }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(returning: false) }
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
        didSet { if persistsPreferences { UserDefaults.standard.set(wheelAppearance.rawValue, forKey: "wheelAppearance") } }
    }
    @Published var soundFeedback = UserDefaults.standard.object(forKey: "soundFeedback") as? Bool ?? true {
        didSet { if persistsPreferences { UserDefaults.standard.set(soundFeedback, forKey: "soundFeedback") } }
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
        }
    }
    @Published var actionFeedback: String?
    var onShowActionFeedback: (() -> Void)?
    private var actionCoordinatorOverride: FileActionCoordinator?
    private var resizePresenterOverride: (any ResizeOptionsPresenting)?
    private lazy var resizeOptions: any ResizeOptionsPresenting = resizePresenterOverride ?? ResizeOptionsCoordinator()
    private var persistsPreferences = true
    private lazy var fileActions: FileActionCoordinator = {
        let coordinator = actionCoordinatorOverride ?? FileActionCoordinator()
        coordinator.onFeedback = { [weak self] message in self?.showFeedback(message) }
        coordinator.onError = { [weak self] message in self?.error = message; self?.onShowWindow?() }
        return coordinator
    }()

    func showFeedback(_ message: String) { actionFeedback = message; onShowActionFeedback?() }

    var onShowWindow: (() -> Void)?
    var onBeginFinderInteraction: (() -> Void)?
    var onShowProgress: (() -> Void)?
    var onPreviewWheel: (() -> Void)?
    var onFloat: (([URL]) -> Void)?
    private let limiter = WorkLimiter()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var moveTasks: [UUID: Task<Void, Never>] = [:]
    private var capabilityTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(persistPreferences: Bool = true, fileActionCoordinator: FileActionCoordinator? = nil,
         resizePresenter: (any ResizeOptionsPresenting)? = nil) {
        self.persistsPreferences = persistPreferences
        self.actionCoordinatorOverride = fileActionCoordinator
        self.resizePresenterOverride = resizePresenter
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

    func choices(from capabilities: SelectionCapabilities, mode: WheelMode) -> [WheelChoice] {
        switch mode {
        case .convert:
            return capabilities.formats.map(WheelChoice.format)
        case .tools: return capabilities.tools.map(WheelChoice.tool)
        case .actions: return FileAction.allCases.map(WheelChoice.action)
        }
    }

    /// Keep the image wheel's observed clockwise order and omit its source
    /// format. The manual converter retains every supported output.
    func wheelChoices(from capabilities: SelectionCapabilities, inputs: [URL], mode: WheelMode) -> [WheelChoice] {
        guard mode == .convert, !inputs.isEmpty, capabilities.families.count == inputs.count, capabilities.families.allSatisfy({ $0 == .image }) else {
            return choices(from: capabilities, mode: mode)
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
        return order.filter { capabilities.formats.contains($0) && !(sourceFormats.count == 1 && sourceFormats.contains($0.rawValue)) }.map(WheelChoice.format)
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
    func performSelected() { if let selectedChoice { perform(selectedChoice, urls: inputs) } }

    func perform(_ choice: WheelChoice, urls: [URL]) {
        guard !isShuttingDown, !urls.isEmpty else { return }
        if case .action(let action) = choice { performAction(action, urls: urls); return }
        guard let operation = choice.operation else { return }
        if operation == .tool(.resize) {
            resizeOptions.choose(urls, preferredMaximum: maxDimension) { [weak self] result in
                guard let self, !self.isShuttingDown else { return }
                switch result {
                case .success(let selection):
                    guard let selection, !selection.inputs.isEmpty else { return }
                    self.maxDimension = selection.maximumDimension
                    self.enqueue(operation, urls: selection.inputs, settings: self.settings)
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.onShowWindow?()
                }
            }
            return
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
        fileActions.shutdown()
        capabilityTask?.cancel()
        let pending = Array(tasks.values)
        let pendingMoves = Array(moveTasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        // A filesystem move can be copying across volumes. Let it finish rather
        // than terminating the process partway through that file operation.
        for task in pendingMoves { await task.value }
        await capabilityTask?.value
    }
    func clearFinished() { jobs.removeAll { $0.state != .running && $0.state != .queued } }

    private func performAction(_ action: FileAction, urls: [URL]) {
        switch action {
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
            onShowWindow?()
            guard panel.runModal() == .OK, let destination = panel.url, !isShuttingDown else { return }
            // A multi-file move is intentionally preflighted to reject all name collisions.
            let targets = urls.map { destination.appendingPathComponent($0.lastPathComponent) }
            guard Set(targets).count == targets.count, targets.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
                error = "Move stopped: a file with the same name already exists in that folder."
                onShowWindow?()
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
                } catch { self.error = "Move stopped: \(error.localizedDescription). Some files may already have moved."; self.onShowWindow?() }
            }
        case .terminal:
            fileActions.openTerminal(urls)
        }
    }
}
