import SwiftUI
import UniformTypeIdentifiers
import StrandDesign

/// Read locally, explicitly send document text for extraction, review, then save to the food library.
struct NutritionDocumentImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @State private var chooseFile = false
    @State private var brand = ""
    @State private var market = ""
    @State private var document: NutritionDocument?
    @State private var rows: [NutritionDocumentRow] = []
    @State private var working = false
    @State private var status = ""
    @State private var error: String?
    @State private var worker: Task<Void, Never>?
    @State private var reviewed = false
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Text("Import nutrition PDF").font(StrandFont.headline)
                            Text("Read on device. Extract sends document text to your AI provider. Review before saving.")
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                            TextField("Restaurant or brand", text: $brand)
                            TextField("Market or country", text: $market)
                            Text("Values vary by country and serving size.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            Button("Choose PDF") { chooseFile = true }
                            if let document {
                                Text(document.title).font(StrandFont.subhead)
                                Text("\(document.pages.count) readable pages").font(StrandFont.caption)
                                Button("Extract with AI") { extract(document) }
                                    .disabled(working || brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                              || market.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                              || !coach.isConfigured || !coach.dataConsent)
                            }
                            if !coach.isConfigured || !coach.dataConsent {
                                Text("Connect Coach and enable AI data access.")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                            }
                        }
                        .disabled(working)
                    }
                    if working {
                        HStack(spacing: NoopMetrics.space2) {
                            ProgressView().controlSize(.small)
                            Text(status).font(StrandFont.caption)
                            Spacer()
                            Button("Cancel") { worker?.cancel() }
                        }
                    }
                    if let error { Text(error).font(StrandFont.body).foregroundStyle(StrandPalette.statusCritical) }
                    if !rows.isEmpty {
                        Text("Check source values and servings. Only selected foods are saved; no meal is logged.")
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                        ForEach($rows) { $row in
                            NoopCard {
                                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                    Toggle(isOn: $row.selected) { Text(row.name).font(StrandFont.subhead) }
                                    TextField("Food name", text: $row.name)
                                    TextField("Serving basis", text: $row.serving)
                                    number("Calories", value: $row.macros.kcal)
                                    number("Protein (g)", value: $row.macros.protein)
                                    number("Carbs (g)", value: $row.macros.carbs)
                                    number("Fat (g)", value: $row.macros.fat)
                                    if row.source.fiberListed {
                                        number("Fibre (g)", value: $row.macros.fiber)
                                    } else {
                                        Text("Fibre is not listed in this source.")
                                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    DisclosureGroup("Source and evidence") {
                                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                            Text(row.source.citation).font(StrandFont.caption)
                                            Text(row.source.evidence).font(StrandFont.body).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                        Toggle("I checked values and serving sizes.", isOn: $reviewed)
                        Button("Save selected foods") { save() }
                            .buttonStyle(NoopButtonStyle(.primary))
                            .disabled(working || !reviewed || !rows.contains(where: { $0.selected })
                                      || rows.contains(where: { $0.selected && !$0.valid }))
                    }
                }
                .padding(NoopMetrics.screenHPadding)
            }
            .background(StrandPalette.surfaceBase)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                worker?.cancel()
                working = true
                status = String(localized: "Reading PDF on device…")
                error = nil
                rows = []
                document = nil
                worker = Task {
                    defer { working = false }
                    do {
                        let value = try await NutritionDocument.read(url: url)
                        try Task.checkCancellation()
                        document = value
                    } catch is CancellationError { }
                    catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
            }
            .onDisappear { worker?.cancel() }
            .interactiveDismissDisabled(working)
        }
    }

    private func number(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(StrandFont.caption)
            Spacer()
            TextField(title, value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .font(StrandFont.body)
        }
    }

    private func extract(_ document: NutritionDocument) {
        working = true
        error = nil
        rows = []
        reviewed = false
        let brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let market = market.trimmingCharacters(in: .whitespacesAndNewlines)
        worker = Task {
            defer { working = false }
            do {
                var extracted: [NutritionDocumentRow] = []
                for (index, page) in document.pages.enumerated() {
                    try Task.checkCancellation()
                    status = String(localized: "Extracting page \(index + 1) of \(document.pages.count)…")
                    extracted += try await coach.extractNutritionPage(page, document: document, brand: brand, market: market)
                }
                guard !extracted.isEmpty else { throw NutritionDocument.Failure.noRows }
                rows = extracted
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func save() {
        working = true
        status = String(localized: "Saving foods…")
        worker = Task {
            defer { working = false }
            do {
                _ = try await repo.saveNutritionDocumentRows(rows)
                onSaved()
                dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
