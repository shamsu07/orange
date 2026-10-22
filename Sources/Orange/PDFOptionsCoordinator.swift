import AppKit
import PDFKit
import SwiftUI
import OrangeCore

struct PDFEditSelection: Sendable {
    let input: URL
    let settings: ConversionSettings
}

@MainActor protocol PDFOptionsPresenting: AnyObject {
    func chooseSplit(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void)
    func chooseReduction(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void)
    func cancel()
    func shutdown() async
}

extension PDFOptionsPresenting {
    func shutdown() async { cancel() }
}

struct PDFSourceSummary: Identifiable, Sendable {
    let url: URL
    let pageCount: Int
    let bytes: Int64
    let thumbnail: Data?
    var id: URL { url }

    static func load(_ urls: [URL]) throws -> [PDFSourceSummary] {
        var seen = Set<URL>()
        return try urls.filter { seen.insert($0.standardizedFileURL).inserted }.map { url in
            try Task.checkCancellation()
            guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw OrangeError.invalidInput("Select a readable PDF to continue.")
            }
            guard !document.isLocked, document.allowsCopying else {
                throw OrangeError.unsupported("Unlock the PDF and allow copying before editing it.")
            }
            let bytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let thumbnail = document.page(at: 0)?.thumbnail(of: NSSize(width: 104, height: 136), for: .cropBox).tiffRepresentation
            return PDFSourceSummary(url: url, pageCount: document.pageCount, bytes: bytes, thumbnail: thumbnail)
        }
    }
}

struct PDFSplitPlan: Identifiable {
    let source: PDFSourceSummary
    var expression: String
    var usesCustomRanges = false
    var splitAfterText: String {
        didSet {
            if !usesCustomRanges { expression = simpleExpression ?? "" }
        }
    }
    var id: URL { source.url }

    init(source: PDFSourceSummary) {
        self.source = source
        let midpoint = max(1, source.pageCount / 2)
        splitAfterText = String(midpoint)
        expression = Self.expression(after: midpoint, pageCount: source.pageCount) ?? ""
    }

    var splitAfterPage: Int? {
        guard source.pageCount >= 2,
              let value = Int(splitAfterText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1..<source.pageCount).contains(value) else { return nil }
        return value
    }
    var simpleExpression: String? {
        guard let splitAfterPage else { return nil }
        return Self.expression(after: splitAfterPage, pageCount: source.pageCount)
    }
    var effectiveExpression: String { usesCustomRanges ? expression : simpleExpression ?? "" }
    private static func expression(after point: Int, pageCount: Int) -> String? {
        guard pageCount >= 2, (1..<pageCount).contains(point) else { return nil }
        let left = point == 1 ? "1" : "1–\(point)"
        let right = point + 1 == pageCount ? "\(pageCount)" : "\(point + 1)–\(pageCount)"
        return "\(left), \(right)"
    }
}

@MainActor final class PDFSplitOptionsModel: ObservableObject {
    @Published var plans: [PDFSplitPlan]
    init(sources: [PDFSourceSummary]) { plans = sources.map(PDFSplitPlan.init(source:)) }

    static func groups(_ expression: String, pageCount: Int) throws -> [[Int]] {
        guard pageCount >= 2 else { throw OrangeError.invalidInput("This PDF has only one page to split.") }
        guard expression.count <= 32_768 else { throw OrangeError.invalidInput("Use a shorter list of page ranges.") }
        let tokens = expression.replacingOccurrences(of: "–", with: "-").split(separator: ",", omittingEmptySubsequences: false)
        var nextPage = 1
        let groups: [[Int]] = try tokens.map { raw in
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count), let first = Int(pieces[0].trimmingCharacters(in: .whitespaces)),
                  (1...pageCount).contains(first) else {
                throw OrangeError.invalidInput("Use page ranges such as 1–3, 4–8. Each comma starts a new PDF.")
            }
            let last: Int
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1].trimmingCharacters(in: .whitespaces)), (first...pageCount).contains(parsed) else {
                    throw OrangeError.invalidInput("Page ranges must run forward and stay inside this PDF.")
                }
                last = parsed
            } else { last = first }
            guard first == nextPage else {
                throw OrangeError.invalidInput("Include every page once, in order. The next part must start at page \(nextPage).")
            }
            nextPage = last + 1
            return Array(first...last)
        }
        return try DocumentConverter.validatedSplitGroups(groups, pageCount: pageCount)
    }

    var selections: [PDFEditSelection]? {
        guard !plans.isEmpty else { return nil }
        var result: [PDFEditSelection] = []
        for plan in plans {
            guard let groups = try? Self.groups(plan.effectiveExpression, pageCount: plan.source.pageCount) else { return nil }
            var settings = ConversionSettings()
            settings.pdfPageRanges = groups
            result.append(PDFEditSelection(input: plan.source.url, settings: settings))
        }
        return result
    }
}

enum PDFReductionPreset: String, CaseIterable, Identifiable, Sendable {
    case compact = "Smallest", balanced = "Balanced", clear = "Clearer"
    var id: String { rawValue }
    var dpi: Double { switch self { case .compact: return 72; case .balanced: return 120; case .clear: return 180 } }
    var quality: Double { switch self { case .compact: return 0.5; case .balanced: return 0.72; case .clear: return 0.85 } }
    var detail: String { "\(Int(dpi)) DPI · image-based PDF" }
}

typealias PDFReductionRenderer = @Sendable (URL, Double, Double, URL?) async throws -> DocumentConverter.ReductionPreview

@MainActor final class PDFReductionOptionsModel: ObservableObject {
    let sources: [PDFSourceSummary]
    @Published var preset: PDFReductionPreset = .balanced
    @Published var acceptsFlattening = false
    @Published private(set) var previews: [DocumentConverter.ReductionPreview] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let temporaryDirectory: URL?
    private let workers: PreviewTaskGroup
    private let renderer: PDFReductionRenderer

    init(sources: [PDFSourceSummary], temporaryDirectory: URL? = nil,
         workers: PreviewTaskGroup? = nil, renderer: PDFReductionRenderer? = nil) {
        self.sources = sources
        self.temporaryDirectory = temporaryDirectory
        self.workers = workers ?? PreviewTaskGroup()
        self.renderer = renderer ?? { input, dpi, quality, scratch in
            try DocumentConverter.previewReduction(input, dpi: dpi, quality: quality, temporaryDirectory: scratch)
        }
    }

    func prepare() {
        guard !workers.isShutdown else { return }
        cancel()
        let request = UUID()
        generation = request
        error = nil
        isPreparing = true
        let urls = sources.map(\.url)
        let dpi = preset.dpi
        let quality = preset.quality
        let temporaryDirectory = temporaryDirectory
        let renderer = renderer
        task = workers.spawn { [weak self] in
            do {
                let results = try await WorkLimiter.shared.withPermit {
                    let worker = Task.detached(priority: .userInitiated) { () async throws -> [DocumentConverter.ReductionPreview] in
                        var results: [DocumentConverter.ReductionPreview] = []
                        do {
                            for input in urls {
                                try Task.checkCancellation()
                                results.append(try await renderer(input, dpi, quality, temporaryDirectory))
                            }
                            try Task.checkCancellation()
                            return results
                        } catch {
                            results.forEach { $0.discard() }
                            throw error
                        }
                    }
                    return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                }
                guard let self, !Task.isCancelled, self.generation == request else {
                    results.forEach { $0.discard() }; return
                }
                self.previews = results
                self.isPreparing = false
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.error = error.localizedDescription
                self.isPreparing = false
                self.task = nil
            }
        }
    }

    var smallerCount: Int { previews.filter(\.isSmaller).count }
    var selections: [PDFEditSelection]? {
        guard !isPreparing, error == nil, acceptsFlattening, smallerCount > 0 else { return nil }
        return previews.filter(\.isSmaller).map { preview in
            var settings = ConversionSettings()
            settings.pdfRasterDPI = preset.dpi
            settings.pdfRasterQuality = preset.quality
            settings.pdfAllowsRasterization = true
            return PDFEditSelection(input: preview.input, settings: settings)
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        previews.forEach { $0.discard() }
        previews = []
        isPreparing = false
    }
}

/// Retained panels and worker preparation keep Finder's drag loop free of modal dialogs.
@MainActor final class PDFOptionsCoordinator: NSObject, PDFOptionsPresenting, NSWindowDelegate {
    private var panel: NSPanel?
    private var prepareTask: Task<Void, Never>?
    private var reductionModel: PDFReductionOptionsModel?
    private var generation = UUID()
    private var completion: (@MainActor (Result<[PDFEditSelection]?, Error>) -> Void)?
    private let workers: PreviewTaskGroup
    private var stopped = false

    init(workers: PreviewTaskGroup? = nil) {
        self.workers = workers ?? PreviewTaskGroup()
        super.init()
    }

    func chooseSplit(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void) {
        prepare(urls, completion: completion) { [weak self] sources in
            let model = PDFSplitOptionsModel(sources: sources)
            let view = PDFSplitOptionsView(model: model, cancel: { [weak self] in self?.finish(.success(nil)) },
                                           confirm: { [weak self] in self?.finish(.success(model.selections)) })
            self?.show(view, title: "Orange · Split PDF", identifier: "orange.pdf.split")
        }
    }

    func chooseReduction(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void) {
        prepare(urls, completion: completion) { [weak self] sources in
            let model = PDFReductionOptionsModel(sources: sources, workers: self?.workers)
            self?.reductionModel = model
            let view = PDFReductionOptionsView(model: model, cancel: { [weak self] in self?.finish(.success(nil)) },
                                               confirm: { [weak self] in self?.finish(.success(model.selections)) })
            self?.show(view, title: "Orange · Reduce PDF size", identifier: "orange.pdf.reduce")
            model.prepare()
        }
    }

    private func prepare(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void,
                         present: @escaping @MainActor ([PDFSourceSummary]) -> Void) {
        guard !stopped else { completion(.success(nil)); return }
        cancel()
        let request = UUID()
        generation = request
        self.completion = completion
        prepareTask = workers.spawn { [weak self] in
            do {
                let sources = try await WorkLimiter.shared.withPermit {
                    let worker = Task.detached(priority: .userInitiated) { try PDFSourceSummary.load(urls) }
                    return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                }
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.prepareTask = nil
                guard !sources.isEmpty else { throw OrangeError.invalidInput("Select at least one PDF.") }
                present(sources)
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
        workers.cancelAll()
        finish(.success(nil))
    }

    func shutdown() async {
        stopped = true
        cancel()
        await workers.shutdown()
    }

    private func show<Content: View>(_ view: Content, title: String, identifier: String) {
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable]
        panel.title = title
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: Result<[PDFEditSelection]?, Error>) {
        let callback = completion
        completion = nil
        reductionModel?.cancel()
        reductionModel = nil
        let closing = panel
        panel = nil
        closing?.close()
        callback?(result)
    }

    func windowWillClose(_ notification: Notification) { finish(.success(nil)) }
}
