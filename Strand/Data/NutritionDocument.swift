import Foundation
import CoreFoundation
import CryptoKit
import PDFKit
import Vision
import StrandAnalytics
import WhoopStore

/// Document provenance travels with the existing macro-source string through logs and backups.
/// A reviewed extraction is not a verified publisher identity or an AI macro estimate.
struct NutritionDocumentSource: Codable, Equatable, Sendable {
    var title: String
    var brand: String
    var market: String
    var documentSHA256: String
    var page: Int
    var evidence: String
    var roughGuess: Bool? = nil
    var fiberListed = true
    var userAdjusted: Bool

    var stored: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "nutrition-document:" + ((try? encoder.encode(self).base64EncodedString()) ?? "")
    }

    static func decode(_ value: String?) -> Self? {
        guard let value, value.hasPrefix("nutrition-document:"),
              let data = Data(base64Encoded: String(value.dropFirst("nutrition-document:".count))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var citation: String { "\(brand) · \(market) · \(title) · p. \(page)" }
}

struct NutritionDocumentPage: Sendable {
    let number: Int
    let text: String
}

struct NutritionDocument: Sendable {
    let title: String
    let sha256: String
    let pages: [NutritionDocumentPage]

    /// PDFKit and OCR run on a worker, never on the UI actor. No document upload is needed to read it.
    static func read(url: URL) async throws -> Self {
        let worker = Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= 25_000_000 else { throw Failure.tooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let pdf = PDFDocument(data: data), !pdf.isLocked,
                  pdf.pageCount > 0, pdf.pageCount <= 60 else { throw Failure.unreadable }
            var pages: [NutritionDocumentPage] = []
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { continue }
                let text: String = try autoreleasepool {
                    let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if embedded.count >= 30 {
                        // Rebuild visual rows before asking the model to map table columns. PDF text
                        // storage order may contain an entire column before the next column's values.
                        let selections = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
                        let fragments = selections.compactMap { selection -> (CGRect, String)? in
                            guard let value = selection.string, !value.isEmpty else { return nil }
                            return (selection.bounds(for: page), value)
                        }.sorted { $0.0.midY > $1.0.midY }
                        var lines: [(Double, [(CGRect, String)])] = []
                        for fragment in fragments {
                            if let last = lines.last, abs(last.0 - fragment.0.midY) <= 3 {
                                lines[lines.count - 1].1.append(fragment)
                            } else { lines.append((fragment.0.midY, [fragment])) }
                        }
                        return lines.isEmpty ? embedded : lines.map {
                            $0.1.sorted { $0.0.minX < $1.0.minX }.map { $0.1 }.joined(separator: "\t")
                        }.joined(separator: "\n")
                    }
                    let bounds = page.bounds(for: .mediaBox)
                    guard bounds.width > 0, bounds.height > 0 else { return "" }
                    let scale = min(2, 2400 / max(bounds.width, bounds.height))
                    guard let context = CGContext(data: nil, width: Int(bounds.width * scale),
                        height: Int(bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .mediaBox, to: context)
                    guard let image = context.makeImage() else { return "" }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US", "ja-JP"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }
                guard text.count <= 30_000 else { throw Failure.tooLarge }
                if !text.isEmpty { pages.append(.init(number: index + 1, text: text)) }
            }
            guard !pages.isEmpty else { throw Failure.unreadable }
            return Self(title: url.lastPathComponent,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), pages: pages)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value },
                                                     onCancel: { worker.cancel() })
    }

    enum Failure: LocalizedError {
        case tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: return String(localized: "Use a PDF under 25 MB with up to 60 pages.")
            case .unreadable: return String(localized: "Cannot read this PDF. Choose an unlocked nutrition document.")
            }
        }
    }
}

enum NutritionDocumentCatalog {
    /// Prefer relevant saved foods without shipping every imported table on every chat turn.
    static func ranked(_ library: [FoodItem], query: String) -> [FoodItem] {
        func normal(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "mcds", with: "mcdonalds")
        }
        let tokens = normal(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        func score(_ food: FoodItem) -> Int {
            let name = normal(food.name + " " + food.servingLabel)
            return tokens.reduce(0) { $0 + (name.contains($1) ? min(12, $1.count) : 0) }
        }
        return library.enumerated().sorted {
            let a = score($0.element), b = score($1.element)
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }

    static func citations(_ foods: [FoodItem]) -> String {
        let lines = foods.prefix(FoodLibraryDigest.maxEntries).compactMap { food -> String? in
            guard let source = NutritionDocumentSource.decode(food.macroSource) else { return nil }
            return "- \(FoodLibraryDigest.handle(for: food.id.uuidString)) | reviewed document extraction | \(source.citation)"
                + (source.userAdjusted ? " | user-adjusted values" : "")
        }
        return lines.isEmpty ? "" : "DOCUMENT SOURCES (not AI-estimated macros):\n" + lines.joined(separator: "\n")
    }
}

/// One stored document row, resolved for the coach: the line as printed, the table header above it, and
/// the document it came from. What the context shows and what a `log_document` proposal is checked against
/// are this same value, so the card cannot cite a row the coach was not shown.
struct NutritionDocumentRowRef: Equatable, Sendable {
    let key: String
    let document: NutritionDocumentRecord
    let page: Int
    let line: Int
    /// The indexed name, or nil for a row matched on its raw text.
    let name: String?
    let aliases: [String]
    let text: String
    let header: String?

    /// The provenance a food logged from this row carries.
    func source(fiberListed: Bool) -> NutritionDocumentSource {
        NutritionDocumentSource(title: document.title, brand: document.brand, market: document.market,
                                documentSHA256: document.sha256, page: page,
                                evidence: String(([header, text].compactMap { $0 }).joined(separator: "\n").prefix(2000)),
                                fiberListed: fiberListed, userAdjusted: false)
    }

    /// How a food from this row is named in the library: brand and market first, as the eager import named
    /// them, so a saved document food says whose menu it is wherever it appears.
    func foodName(_ itemName: String) -> String {
        "\(document.brand) [\(document.market)] · \(itemName)"
    }
}

/// Why a page could not be indexed. The document is still stored: raw-line search covers the page.
enum NutritionDocumentIndexError: LocalizedError {
    case notConnected
    var errorDescription: String? {
        String(localized: "Connect Coach and enable AI data access to index item names.")
    }
}

/// One indexed row produced at import, before it is stored.
struct NutritionDocumentIndexItem: Equatable, Sendable {
    let page: Int
    let line: Int
    let name: String
    let aliases: [String]
}

extension Repository {

    /// Store a document read on the device, with the name index built at import (empty when Coach is not
    /// connected: raw-line search still works for a request in the document's own words). Replaces an earlier
    /// import of the same file.
    func storeNutritionDocument(_ document: NutritionDocument, brand: String, market: String,
                                index: [NutritionDocumentIndexItem]) async throws {
        guard let store = await storeHandle() else { throw CocoaError(.fileWriteUnknown) }
        let id = UUID().uuidString
        try await store.replaceNutritionDocument(
            NutritionDocumentRecord(id: id, title: document.title, sha256: document.sha256, brand: brand,
                                    market: market, pageCount: document.pages.count,
                                    importedAt: Int(Date().timeIntervalSince1970)),
            pages: document.pages.map { NutritionDocumentPageRecord(documentId: id, page: $0.number, text: $0.text) },
            index: index.map { NutritionDocumentIndexRecord(documentId: id, page: $0.page, line: $0.line,
                                                            name: $0.name, aliases: $0.aliases) })
        noteFoodChanged()
    }

    func nutritionDocuments() async -> [NutritionDocumentRecord] {
        guard let store = await storeHandle() else { return [] }
        return (try? await store.nutritionDocuments()) ?? []
    }

    /// Index entries per document, for the list's "N items indexed" line.
    func nutritionDocumentIndexCounts() async -> [String: Int] {
        guard let store = await storeHandle() else { return [:] }
        let index = (try? await store.nutritionDocumentIndex()) ?? []
        return Dictionary(grouping: index, by: \.documentId).mapValues(\.count)
    }

    func deleteNutritionDocument(id: String) async {
        guard let store = await storeHandle() else { return }
        try? await store.deleteNutritionDocument(id: id)
        noteFoodChanged()
    }

    /// Rows of the stored documents that match `query`, best first, resolved with their header line.
    /// `search` marks a term Coach chose to look up rather than what the user said
    /// (`NutritionDocumentLookup.match`).
    func nutritionDocumentMatches(query: String, search: Bool = false, limit: Int = 8) async -> [NutritionDocumentRowRef] {
        guard let store = await storeHandle(),
              let documents = try? await store.nutritionDocuments(), !documents.isEmpty,
              let pages = try? await store.nutritionDocumentPages(),
              let index = try? await store.nutritionDocumentIndex() else { return [] }
        // Raw-line search covers every PAGE with no index entries — a document stored without Coach, or a
        // page whose indexing failed — so a gap in the index never hides a row typed in the menu's own words.
        let indexed = Set(index.map { "\($0.documentId)|\($0.page)" })
        let matches = NutritionDocumentLookup.match(
            query: query,
            entries: index.map { .init(documentId: $0.documentId, page: $0.page, line: $0.line, name: $0.name,
                                       aliases: $0.aliases) },
            unindexedPages: pages.filter { !indexed.contains("\($0.documentId)|\($0.page)") }
                .map { ($0.documentId, $0.page, $0.text) },
            search: search, limit: limit)
        return matches.compactMap { m in
            ref(documentId: m.documentId, page: m.page, line: m.line, documents: documents, pages: pages, index: index)
        }
    }

    /// The rows named by these keys, for checking a proposal. A key matching no stored row, or matching two
    /// documents' prefixes, is left out — the proposal then resolves to nothing rather than to a guess.
    func nutritionDocumentRows(keys: [String]) async -> [String: NutritionDocumentRowRef] {
        let parsed = keys.compactMap { key in NutritionDocumentLookup.parseRowKey(key).map { (key, $0) } }
        guard !parsed.isEmpty, let store = await storeHandle(),
              let documents = try? await store.nutritionDocuments(),
              let pages = try? await store.nutritionDocumentPages(),
              let index = try? await store.nutritionDocumentIndex() else { return [:] }
        var out: [String: NutritionDocumentRowRef] = [:]
        for (key, p) in parsed {
            let owners = documents.filter { NutritionDocumentLookup.key(p, names: $0.id) }
            guard owners.count == 1, let doc = owners.first,
                  let r = ref(documentId: doc.id, page: p.page, line: p.line, documents: documents, pages: pages,
                              index: index) else { continue }
            out[Self.normalisedRowKey(key)] = r
        }
        return out
    }

    /// The lookup form of a row key, so "DA1B2C3D4P3L2 " and "da1b2c3d4p3l2" are one key.
    nonisolated static func normalisedRowKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func ref(documentId: String, page: Int, line: Int, documents: [NutritionDocumentRecord],
                     pages: [NutritionDocumentPageRecord], index: [NutritionDocumentIndexRecord]) -> NutritionDocumentRowRef? {
        guard let doc = documents.first(where: { $0.id == documentId }),
              let text = pages.first(where: { $0.documentId == documentId && $0.page == page })?.text,
              let row = NutritionDocumentLookup.line(line, inPage: text) else { return nil }
        let entry = index.first { $0.documentId == documentId && $0.page == page && $0.line == line }
        return NutritionDocumentRowRef(key: NutritionDocumentLookup.rowKey(documentId: documentId, page: page, line: line),
                                       document: doc, page: page, line: line, name: entry?.name,
                                       aliases: entry?.aliases ?? [], text: row,
                                       header: NutritionDocumentLookup.header(forLine: line, inPage: text))
    }

    /// The library food a document row is logged as: an existing one with the same name, serving and a
    /// document source keeps its id (so repeat logs build one food's history), with its figures and
    /// citation refreshed from the row.
    func documentFood(name: String, servingLabel: String, macros: MacroTotals,
                      source: NutritionDocumentSource) async -> FoodItem {
        let existing = await foodLibrary().first {
            $0.name == name && $0.servingLabel == servingLabel && NutritionDocumentSource.decode($0.macroSource) != nil
        }
        guard let old = existing else {
            return FoodItem(macroSource: source.stored, name: name, servingLabel: servingLabel, macros: macros)
        }
        return FoodItem(id: old.id, macroSource: source.stored, name: name, servingLabel: servingLabel,
                        macros: macros, createdAt: old.createdAt, lastUsedAt: old.lastUsedAt)
    }
}
