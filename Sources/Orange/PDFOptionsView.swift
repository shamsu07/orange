import SwiftUI
import OrangeCore

struct PDFSplitOptionsView: View {
    @ObservedObject var model: PDFSplitOptionsModel
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Split PDF").font(.system(size: 22, weight: .semibold))
            Text("Choose where the first PDF ends. The remaining pages become the second PDF.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach($model.plans) { $plan in
                        VStack(alignment: .leading, spacing: 12) {
                            PDFSourceHeader(source: plan.source)
                            PDFSplitPlanEditor(plan: $plan, focusInitially: plan.id == model.plans.first?.id)
                            if let groups = try? PDFSplitOptionsModel.groups(plan.effectiveExpression, pageCount: plan.source.pageCount) {
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
                                }.frame(height: 118)
                            } else {
                                Text(validation(plan)).font(.system(size: 12)).foregroundStyle(.red)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: scrollHeight)
            HStack {
                Text("Every page included. Original preserved.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Create \(model.selections?.reduce(0) { $0 + ($1.settings.pdfPageRanges?.count ?? 0) } ?? 0) PDFs", action: confirm)
                    .keyboardShortcut(.defaultAction).disabled(model.selections == nil)
            }
        }.padding(24).frame(width: 550).tint(.orange)
    }
    private var scrollHeight: CGFloat {
        let preferred: CGFloat = model.plans.count == 1 ? 240 : 390
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 210
        return max(120, min(preferred, available))
    }
    private func validation(_ plan: PDFSplitPlan) -> String {
        if !plan.usesCustomRanges, plan.source.pageCount >= 2, plan.splitAfterPage == nil {
            return "Enter a whole page number from 1 to \(plan.source.pageCount - 1)."
        }
        do { _ = try PDFSplitOptionsModel.groups(plan.effectiveExpression, pageCount: plan.source.pageCount); return "" }
        catch { return error.localizedDescription }
    }
}

private struct PDFSplitPlanEditor: View {
    @Binding var plan: PDFSplitPlan
    let focusInitially: Bool
    @FocusState private var editingSplitPage: Bool

    var body: some View {
        if plan.source.pageCount >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Split after page").font(.system(size: 13, weight: .medium))
                    if plan.source.pageCount == 2 {
                        Text("1").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text("of 2").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        TextField("Page", text: $plan.splitAfterText)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            .frame(width: 64).focused($editingSplitPage)
                            .accessibilityLabel("Split after page for \(plan.source.url.lastPathComponent)")
                        Text("of \(plan.source.pageCount)").font(.system(size: 12)).foregroundStyle(.secondary)
                        Stepper("Split after page", value: stepperValue, in: 1...(plan.source.pageCount - 1))
                            .labelsHidden().fixedSize()
                            .accessibilityLabel("Adjust split page for \(plan.source.url.lastPathComponent)")
                    }
                    Spacer()
                }.disabled(plan.usesCustomRanges)
                if plan.source.pageCount > 2 {
                    DisclosureGroup("Custom page ranges", isExpanded: $plan.usesCustomRanges) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("1–3, 4–8", text: $plan.expression)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Custom page ranges for \(plan.source.url.lastPathComponent)")
                            Text("Need more parts? Use a comma between ranges, such as 1–3, 4–6, 7–8.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.top, 6)
                    }.font(.system(size: 12))
                }
            }.onAppear { if focusInitially && plan.source.pageCount > 2 { editingSplitPage = true } }
        }
    }

    private var stepperValue: Binding<Int> {
        Binding(get: { plan.splitAfterPage ?? max(1, plan.source.pageCount / 2) },
                set: { plan.splitAfterText = String($0) })
    }
}

struct PDFReductionOptionsView: View {
    @ObservedObject var model: PDFReductionOptionsModel
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reduce PDF size").font(.system(size: 22, weight: .semibold))
            Text("Best for scans and image-heavy documents. Each page becomes an image; the page dimensions stay the same.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            qualityPicker
            Text(model.preset.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            previewList
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            flatteningConsent
            actions
        }.padding(24).frame(width: 550).tint(.orange)
            .onChange(of: model.preset) { _ in model.prepare() }
    }

    private var qualityPicker: some View {
        Picker("Quality", selection: $model.preset) {
            ForEach(PDFReductionPreset.allCases) { preset in
                Text(preset.rawValue).tag(preset)
            }
        }.pickerStyle(.segmented).accessibilityLabel("PDF reduction quality")
    }

    private var previewList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.sources) { source in
                    PDFReductionPreviewRow(
                        source: source,
                        preview: model.previews.first { $0.input == source.url },
                        isPreparing: model.isPreparing
                    )
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: scrollHeight)
    }

    private var flatteningConsent: some View {
        Toggle(isOn: $model.acceptsFlattening) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create an image-based copy").font(.system(size: 13, weight: .semibold))
                Text("Text and vectors become pixels. Links, forms, annotations, accessibility tags and signatures are removed. Keep the original for editing and accessibility.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(.checkbox).accessibilityIdentifier("pdf.reduction.consent")
    }

    private var actions: some View {
        HStack {
            Text("Only smaller copies are saved.").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button(saveTitle, action: confirm)
                .keyboardShortcut(.defaultAction).disabled(model.selections == nil)
        }
    }

    private var saveTitle: String {
        model.sources.count == 1 ? "Save smaller PDF" : "Save \(model.smallerCount) smaller PDFs"
    }

    private var scrollHeight: CGFloat {
        let preferred: CGFloat = model.sources.count == 1 ? 140 : 390
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 390
        return max(120, min(preferred, available))
    }
}

private struct PDFReductionPreviewRow: View {
    let source: PDFSourceSummary
    let preview: DocumentConverter.ReductionPreview?
    let isPreparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PDFSourceHeader(source: source)
            if let preview {
                PDFReductionSizeComparison(preview: preview)
                Text(preview.isSmaller ? "Measured preview · final size may vary slightly when saved." : "Already compact at this quality. This file will be skipped.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if isPreparing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Measuring a real PDF preview…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PDFReductionSizeComparison: View {
    let preview: DocumentConverter.ReductionPreview

    var body: some View {
        HStack(spacing: 10) {
            Text(size(preview.originalBytes)).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(size(preview.reducedBytes)).fontWeight(.semibold)
                .foregroundStyle(preview.isSmaller ? Color.orange : Color.secondary)
            Spacer()
            if preview.isSmaller {
                Text("\(reductionPercentage)% smaller").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 20)).monospacedDigit()
    }

    private var reductionPercentage: Int {
        Int((1 - Double(preview.reducedBytes) / Double(preview.originalBytes)) * 100)
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
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
