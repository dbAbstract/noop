import Foundation
import CoreFoundation
import CryptoKit
import PDFKit
import Vision
import StrandAnalytics

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
        case tooLarge, unreadable, invalidExtraction, noRows, configuration
        var errorDescription: String? {
            switch self {
            case .tooLarge: return String(localized: "Use a PDF under 25 MB with up to 60 pages.")
            case .unreadable: return String(localized: "Cannot read this PDF. Choose an unlocked nutrition document.")
            case .invalidExtraction: return String(localized: "Extraction did not match the source. Nothing saved.")
            case .noRows: return String(localized: "No complete nutrition rows found. Nothing saved.")
            case .configuration: return String(localized: "Connect Coach and enable AI data access.")
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

struct NutritionDocumentRow: Identifiable, Sendable {
    var id = UUID()
    var selected = true
    var name: String
    var serving: String
    var macros: MacroTotals
    var source: NutritionDocumentSource
    let originalMacros: MacroTotals
    let originalName: String
    let originalServing: String

    var food: FoodItem {
        var provenance = source
        provenance.userAdjusted = macros != originalMacros || name != originalName || serving != originalServing
        return FoodItem(macroSource: provenance.stored, name: "\(source.brand) [\(source.market)] · \(name)",
                        servingLabel: serving, macros: macros)
    }

    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !serving.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [macros.kcal, macros.protein, macros.carbs, macros.fat, macros.fiber].allSatisfy { $0.isFinite && $0 >= 0 }
            && macros.kcal <= 10_000 && max(macros.protein, macros.carbs, macros.fat, macros.fiber) <= 1000
    }

    /// Reject invented evidence and missing values instead of quietly filling unknown macros with zero.
    static func parse(_ reply: String, page: NutritionDocumentPage, document: NutritionDocument,
                      brand: String, market: String) throws -> [Self] {
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = clean.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]], items.count <= 200 else { throw NutritionDocument.Failure.invalidExtraction }
        func normal(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func number(_ item: [String: Any], _ key: String) -> Double? {
            guard let value = item[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        var rows: [Self] = []
        for item in items {
            guard let name = item["name"] as? String, let serving = item["serving"] as? String,
                  let evidence = item["evidence"] as? String, normal(evidence).count >= 10,
                  evidence.count <= 2000, name.count <= 300, serving.count <= 200,
                  normal(page.text).contains(normal(evidence)),
                  !name.isEmpty, !serving.isEmpty,
                  normal(evidence).localizedCaseInsensitiveContains(normal(name)),
                  normal(page.text).localizedCaseInsensitiveContains(normal(serving)),
                  let kcal = number(item, "kcal"), let protein = number(item, "protein"),
                  let carbs = number(item, "carbs"), let fat = number(item, "fat") else { continue }
            // All required numbers must occur in the quoted evidence. This is a plausibility gate,
            // not proof of column alignment: the review remains mandatory.
            let regex = try NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
            let ns = evidence as NSString
            let numbers = regex.matches(in: evidence, range: NSRange(location: 0, length: ns.length))
                .compactMap { Double(ns.substring(with: $0.range).replacingOccurrences(of: ",", with: ".")) }
            guard [kcal, protein, carbs, fat].allSatisfy({ value in numbers.contains { abs($0 - value) < 0.001 } }) else { continue }
            let fiber = number(item, "fiber")
            guard fiber == nil || numbers.contains(where: { abs($0 - (fiber ?? 0)) < 0.001 }) else { continue }
            let macros = MacroTotals(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber ?? 0)
            let source = NutritionDocumentSource(title: document.title, brand: brand, market: market,
                documentSHA256: document.sha256, page: page.number, evidence: String(evidence.prefix(2000)), fiberListed: fiber != nil, userAdjusted: false)
            let row = Self(name: name, serving: serving, macros: macros, source: source, originalMacros: macros, originalName: name, originalServing: serving)
            if row.valid { rows.append(row) }
        }
        return rows
    }
}

extension Repository {
    /// One transaction makes the reviewed catalog visible all at once; re-imports upsert stable IDs.
    func saveNutritionDocumentRows(_ rows: [NutritionDocumentRow]) async throws -> Int {
        guard let store = await storeHandle() else { throw CocoaError(.fileWriteUnknown) }
        let existing = await foodLibrary()
        var items: [FoodItem] = []
        for row in rows where row.selected && row.valid {
            var item = row.food
            if let old = existing.first(where: { $0.name == item.name && $0.servingLabel == item.servingLabel
                && NutritionDocumentSource.decode($0.macroSource) != nil }) {
                item = FoodItem(id: old.id, macroSource: item.macroSource, name: item.name,
                    servingLabel: item.servingLabel, macros: item.macros, createdAt: old.createdAt, lastUsedAt: old.lastUsedAt)
            }
            if let index = items.firstIndex(where: { $0.name == item.name && $0.servingLabel == item.servingLabel }) { items[index] = item }
            else { items.append(item) }
        }
        guard !items.isEmpty else { throw NutritionDocument.Failure.noRows }
        _ = try await store.upsertFoodItems(items.map(\.row))
        noteFoodChanged()
        return items.count
    }
}
