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
    var id: URL { source.url }
}

@MainActor final class PDFSplitOptionsModel: ObservableObject {
    @Published var plans: [PDFSplitPlan]
    init(sources: [PDFSourceSummary]) {
        plans = sources.map { source in
            let half = max(1, source.pageCount / 2)
            let left = half == 1 ? "1" : "1–\(half)"
            let right = half + 1 == source.pageCount ? "\(source.pageCount)" : "\(half + 1)–\(source.pageCount)"
            return PDFSplitPlan(source: source, expression: source.pageCount > 1 ? "\(left), \(right)" : "1")
        }
    }

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
            guard let groups = try? Self.groups(plan.expression, pageCount: plan.source.pageCount) else { return nil }
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

    init(sources: [PDFSourceSummary], temporaryDirectory: URL? = nil) {
        self.sources = sources
        self.temporaryDirectory = temporaryDirectory
    }

    func prepare() {
        cancel()
        let request = UUID()
        generation = request
        error = nil
        isPreparing = true
        let urls = sources.map(\.url)
        let dpi = preset.dpi
        let quality = preset.quality
        let temporaryDirectory = temporaryDirectory
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () throws -> [DocumentConverter.ReductionPreview] in
                var results: [DocumentConverter.ReductionPreview] = []
                do {
                    for input in urls {
                        try Task.checkCancellation()
                        results.append(try DocumentConverter.previewReduction(input, dpi: dpi, quality: quality, temporaryDirectory: temporaryDirectory))
                    }
                    try Task.checkCancellation()
                    return results
                } catch {
                    results.forEach { $0.discard() }
                    throw error
                }
            }
            do {
                let results = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
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
            let model = PDFReductionOptionsModel(sources: sources)
            self?.reductionModel = model
            let view = PDFReductionOptionsView(model: model, cancel: { [weak self] in self?.finish(.success(nil)) },
                                               confirm: { [weak self] in self?.finish(.success(model.selections)) })
            self?.show(view, title: "Orange · Reduce PDF size", identifier: "orange.pdf.reduce")
            model.prepare()
        }
    }

    private func prepare(_ urls: [URL], completion: @escaping @MainActor (Result<[PDFEditSelection]?, Error>) -> Void,
                         present: @escaping @MainActor ([PDFSourceSummary]) -> Void) {
        cancel()
        let request = UUID()
        generation = request
        self.completion = completion
        prepareTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try PDFSourceSummary.load(urls) }
            do {
                let sources = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
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
        finish(.success(nil))
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

private struct PDFSplitOptionsView: View {
    @ObservedObject var model: PDFSplitOptionsModel
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Split where it makes sense").font(.system(size: 22, weight: .semibold))
            Text("Choose the pages for each new PDF. A comma starts the next part.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach($model.plans) { $plan in
                        VStack(alignment: .leading, spacing: 12) {
                            PDFSourceHeader(source: plan.source)
                            HStack {
                                Text("Page ranges").font(.system(size: 13, weight: .medium))
                                TextField("1–3, 4–8", text: $plan.expression)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Page ranges for \(plan.source.url.lastPathComponent)")
                            }
                            if let groups = try? PDFSplitOptionsModel.groups(plan.expression, pageCount: plan.source.pageCount) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(groups.enumerated()), id: \.offset) { index, pages in
                                            VStack(alignment: .leading, spacing: 6) {
                                                Image(systemName: "doc.text").font(.system(size: 23)).foregroundStyle(.orange)
                                                Text("Part \(index + 1)").font(.system(size: 12, weight: .semibold))
                                                Text(pages.count == 1 ? "Page \(pages[0])" : "Pages \(pages[0])–\(pages.last!)")
                                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                                Text("\(pages.count) page\(pages.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                                            }.padding(12).frame(minWidth: 90, alignment: .leading)
                                                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                        }
                                    }
                                }
                            } else {
                                Text(validation(plan)).font(.system(size: 12)).foregroundStyle(.red)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 390)
            HStack {
                Text("Every page included. Original preserved.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Create \(model.selections?.reduce(0) { $0 + ($1.settings.pdfPageRanges?.count ?? 0) } ?? 0) PDFs", action: confirm)
                    .keyboardShortcut(.defaultAction).disabled(model.selections == nil)
            }
        }.padding(24).frame(width: 550)
    }
    private func validation(_ plan: PDFSplitPlan) -> String {
        do { _ = try PDFSplitOptionsModel.groups(plan.expression, pageCount: plan.source.pageCount); return "" }
        catch { return error.localizedDescription }
    }
}

private struct PDFReductionOptionsView: View {
    @ObservedObject var model: PDFReductionOptionsModel
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A smaller PDF, with a clear trade-off").font(.system(size: 22, weight: .semibold))
            Text("Best for scans and image-heavy documents. Each page becomes an image; the page dimensions stay the same.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Picker("Quality", selection: $model.preset) {
                ForEach(PDFReductionPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
            }.pickerStyle(.segmented).accessibilityLabel("PDF reduction quality")
            Text(model.preset.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.sources) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            PDFSourceHeader(source: source)
                            if let preview = model.previews.first(where: { $0.input == source.url }) {
                                HStack(spacing: 10) {
                                    Text(Self.size(preview.originalBytes)).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(Self.size(preview.reducedBytes)).fontWeight(.semibold)
                                        .foregroundStyle(preview.isSmaller ? Color.orange : Color.secondary)
                                    Spacer()
                                    if preview.isSmaller {
                                        Text("\(Int((1 - Double(preview.reducedBytes) / Double(preview.originalBytes)) * 100))% smaller")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }.font(.system(size: 20)).monospacedDigit()
                                Text(preview.isSmaller ? "Measured preview · final size may vary slightly when saved." : "Already compact at this quality. This file will be skipped.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            } else if model.isPreparing {
                                HStack { ProgressView().controlSize(.small); Text("Measuring a real PDF preview…").font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320)
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            Toggle(isOn: $model.acceptsFlattening) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create an image-based copy").font(.system(size: 13, weight: .semibold))
                    Text("Text and vectors become pixels. Links, forms, annotations, accessibility tags and signatures are removed. Keep the original for editing and accessibility.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.checkbox).accessibilityIdentifier("pdf.reduction.consent")
            HStack {
                Text("Only smaller copies are saved.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(model.sources.count == 1 ? "Save smaller PDF" : "Save \(model.smallerCount) smaller PDFs", action: confirm)
                    .keyboardShortcut(.defaultAction).disabled(model.selections == nil)
            }
        }.padding(24).frame(width: 550)
            .onChange(of: model.preset) { _ in model.prepare() }
    }
    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private struct PDFSourceHeader: View {
    let source: PDFSourceSummary
    var body: some View {
        HStack(spacing: 12) {
            if let data = source.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 42)
                    .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(true)
            } else { Image(systemName: "doc.richtext").font(.system(size: 28)).foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 3) {
                Text(source.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(source.pageCount) page\(source.pageCount == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: source.bytes, countStyle: .file))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
