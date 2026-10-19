import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore

/// Store a nutrition PDF for Coach to look foods up in, and manage the ones already stored.
///
/// LAZY BY DESIGN. Nothing is extracted into the food library here and there is no review of a whole menu:
/// the page text is read on the device and kept, and when the user later asks Coach to log a food, the app
/// finds the matching row and Coach proposes it on a card that shows the printed line — that card is the
/// review, for the one item actually eaten. The only AI use at import is an optional NAME INDEX (item names
/// and aliases, no figures), so an English request finds a row printed in Japanese.
struct NutritionDocumentImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @State private var chooseFile = false
    @State private var brand = ""
    @State private var market = ""
    @State private var document: NutritionDocument?
    @State private var working = false
    @State private var status = ""
    @State private var error: String?
    @State private var note: String?
    @State private var worker: Task<Void, Never>?
    @State private var stored: [NutritionDocumentRecord] = []
    @State private var indexCounts: [String: Int] = [:]
    let onSaved: () -> Void

    private var canIndex: Bool { coach.isConfigured && coach.dataConsent }
    private var ready: Bool {
        document != nil && !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !market.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    importCard
                    if working {
                        HStack(spacing: NoopMetrics.space2) {
                            ProgressView().controlSize(.small)
                            Text(status).font(StrandFont.caption)
                            Spacer()
                            Button("Cancel") { worker?.cancel() }
                        }
                    }
                    if let error { Text(error).font(StrandFont.body).foregroundStyle(StrandPalette.statusCritical) }
                    if let note { Text(note).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary) }
                    storedSection
                }
                .padding(NoopMetrics.screenHPadding)
            }
            .background(StrandPalette.surfaceBase)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                read(url)
            }
            .task { await reload() }
            .onDisappear { worker?.cancel() }
            .interactiveDismissDisabled(working)
        }
    }

    private var importCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Add a nutrition PDF").font(StrandFont.headline)
                Text("Read and kept on this device. When you ask Coach to log something from this restaurant, it looks the item up here and shows you the printed row to confirm.")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Restaurant or brand", text: $brand)
                TextField("Market or country", text: $market)
                Text("Values vary by country and serving size.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Button("Choose PDF") { chooseFile = true }
                if let document {
                    Text(document.title).font(StrandFont.subhead)
                    Text("\(document.pages.count) readable pages").font(StrandFont.caption)
                }
                Text(canIndex
                     ? "Saving sends each page's text to your AI provider once, to index item names (no nutrition figures), so an English request finds a row printed in another language."
                     : "Coach is not connected, so item names will not be indexed. Coach can still find a row when you use the name as printed on the menu.")
                    .font(StrandFont.caption)
                    .foregroundStyle(canIndex ? StrandPalette.textTertiary : StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Save document") { save() }
                    .buttonStyle(NoopButtonStyle(.primary))
                    .disabled(working || !ready)
            }
            .disabled(working)
        }
    }

    @ViewBuilder private var storedSection: some View {
        if !stored.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Stored documents", overline: "Coach looks foods up in these")
                ForEach(stored, id: \.id) { doc in
                    NoopCard {
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                Text(verbatim: Self.sourceLabel(doc)).font(StrandFont.subhead)
                                Text(verbatim: doc.title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                Text(indexCounts[doc.id].map { String(localized: "\(doc.pageCount) pages · \($0) items indexed") }
                                     ?? String(localized: "\(doc.pageCount) pages · names not indexed"))
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await repo.deleteNutritionDocument(id: doc.id); await reload(); onSaved() }
                            } label: { Image(systemName: "trash") }
                                .accessibilityLabel(Text("Delete \(doc.brand) document"))
                        }
                    }
                }
                Text("Deleting a document keeps every food already logged or saved from it.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// "McDonald's [Japan]": the user's own words for whose menu it is, never localized.
    private static func sourceLabel(_ doc: NutritionDocumentRecord) -> String { "\(doc.brand) [\(doc.market)]" }

    private func reload() async {
        stored = await repo.nutritionDocuments()
        indexCounts = await repo.nutritionDocumentIndexCounts()
    }

    private func read(_ url: URL) {
        worker?.cancel()
        working = true
        status = String(localized: "Reading PDF on device…")
        error = nil
        note = nil
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

    /// Index (when Coach is connected), then store. A page whose indexing fails is stored without entries
    /// and covered by raw-line search; cancelling stores nothing.
    private func save() {
        guard let document else { return }
        let brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let market = market.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true
        error = nil
        note = nil
        worker = Task {
            defer { working = false }
            var index: [NutritionDocumentIndexItem] = []
            var failedPages = 0
            if canIndex {
                for (i, page) in document.pages.enumerated() {
                    if Task.isCancelled { return }
                    status = String(localized: "Indexing item names, page \(i + 1) of \(document.pages.count)…")
                    do { index += try await coach.indexNutritionPage(page, brand: brand, market: market) }
                    catch is CancellationError { return }
                    catch { failedPages += 1 }
                }
            }
            if Task.isCancelled { return }
            status = String(localized: "Saving document…")
            do {
                try await repo.storeNutritionDocument(document, brand: brand, market: market, index: index)
                self.document = nil
                await reload()
                onSaved()
                note = failedPages > 0
                    ? String(localized: "Saved. \(failedPages) pages could not be indexed; Coach can still find their items by the name as printed.")
                    : String(localized: "Saved. Ask Coach to log something from \(brand).")
            } catch { self.error = error.localizedDescription }
        }
    }
}
