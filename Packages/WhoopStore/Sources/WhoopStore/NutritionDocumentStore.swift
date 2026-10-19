import Foundation
import GRDB

// MARK: - v56 store: nutrition PDFs kept as documents
//
// FORK-LOCAL (diet). See the v56 migration comment. A document is written and removed as one unit — its
// row, its pages and its name index in one transaction — so the coach can never see an index pointing at
// pages that are not there.

public struct NutritionDocumentRecord: Equatable, Codable, Sendable {
    public var id: String
    /// The file name as chosen.
    public var title: String
    /// SHA-256 of the file's bytes, hex. Unique: the same file imported twice is one document.
    public var sha256: String
    /// The restaurant or brand, as the user typed it.
    public var brand: String
    /// The market or country, as the user typed it. Menus differ by country, so it travels with every figure.
    public var market: String
    public var pageCount: Int
    public var importedAt: Int

    public init(id: String, title: String, sha256: String, brand: String, market: String,
                pageCount: Int, importedAt: Int) {
        self.id = id; self.title = title; self.sha256 = sha256; self.brand = brand
        self.market = market; self.pageCount = pageCount; self.importedAt = importedAt
    }

    static func decode(_ row: Row) -> Self {
        Self(id: row["id"], title: row["title"], sha256: row["sha256"], brand: row["brand"],
             market: row["market"], pageCount: row["pageCount"], importedAt: row["importedAt"])
    }
}

public struct NutritionDocumentPageRecord: Equatable, Codable, Sendable {
    public var documentId: String
    /// 1-based page number in the source PDF.
    public var page: Int
    public var text: String

    public init(documentId: String, page: Int, text: String) {
        self.documentId = documentId; self.page = page; self.text = text
    }

    static func decode(_ row: Row) -> Self {
        Self(documentId: row["documentId"], page: row["page"], text: row["text"])
    }
}

public struct NutritionDocumentIndexRecord: Equatable, Codable, Sendable {
    public var documentId: String
    public var page: Int
    /// 0-based line within that page's text (split on "\n").
    public var line: Int
    /// The item's name as printed.
    public var name: String
    /// Other names the item goes by — an English name, a romanisation, a common short form.
    public var aliases: [String]

    public init(documentId: String, page: Int, line: Int, name: String, aliases: [String]) {
        self.documentId = documentId; self.page = page; self.line = line; self.name = name; self.aliases = aliases
    }

    static func decode(_ row: Row) -> Self {
        let raw: String = row["aliases"]
        return Self(documentId: row["documentId"], page: row["page"], line: row["line"], name: row["name"],
                    aliases: raw.split(separator: "\n").map(String.init))
    }
}

extension WhoopStore {

    /// Store a document with its pages and index, replacing any earlier import of the same file (same
    /// SHA-256) or the same id. One transaction: a failure keeps the previous edition whole.
    public func replaceNutritionDocument(_ document: NutritionDocumentRecord,
                                         pages: [NutritionDocumentPageRecord],
                                         index: [NutritionDocumentIndexRecord]) async throws {
        try syncWrite { db in
            let stale = try String.fetchAll(db, sql: "SELECT id FROM nutritionDocument WHERE sha256 = ? OR id = ?",
                                            arguments: [document.sha256, document.id])
            for id in stale { try Self.deleteNutritionDocument(id, in: db) }
            try db.execute(sql: """
                INSERT INTO nutritionDocument (id, title, sha256, brand, market, pageCount, importedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [document.id, document.title, document.sha256, document.brand, document.market,
                                 document.pageCount, document.importedAt])
            for p in pages {
                try db.execute(sql: "INSERT INTO nutritionDocumentPage (documentId, page, text) VALUES (?, ?, ?)",
                               arguments: [document.id, p.page, p.text])
            }
            for e in index {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO nutritionDocumentIndex (documentId, page, line, name, aliases)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [document.id, e.page, e.line, e.name,
                                     e.aliases.map { $0.replacingOccurrences(of: "\n", with: " ") }
                                         .joined(separator: "\n")])
            }
        }
    }

    /// Every stored document, newest import first.
    public func nutritionDocuments() async throws -> [NutritionDocumentRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM nutritionDocument ORDER BY importedAt DESC, id")
                .map(NutritionDocumentRecord.decode)
        }
    }

    /// Every stored page, ordered by document then page.
    public func nutritionDocumentPages() async throws -> [NutritionDocumentPageRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM nutritionDocumentPage ORDER BY documentId, page")
                .map(NutritionDocumentPageRecord.decode)
        }
    }

    /// Every index entry, ordered by document, page and line.
    public func nutritionDocumentIndex() async throws -> [NutritionDocumentIndexRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM nutritionDocumentIndex ORDER BY documentId, page, line")
                .map(NutritionDocumentIndexRecord.decode)
        }
    }

    /// Remove a document with its pages and index. Foods already logged or saved from it keep their own
    /// snapshot and citation.
    public func deleteNutritionDocument(id: String) async throws {
        try syncWrite { db in try Self.deleteNutritionDocument(id, in: db) }
    }

    private static func deleteNutritionDocument(_ id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM nutritionDocumentIndex WHERE documentId = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM nutritionDocumentPage WHERE documentId = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM nutritionDocument WHERE id = ?", arguments: [id])
    }
}
