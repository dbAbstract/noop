import Foundation
import GRDB

// MARK: - v48 store: the food log (saved items + logged entries)
//
// Mirrors the LiftLogStore / LabMarkerStore idiom: plain Codable row structs, raw `Row` fetch with
// manual decode, idempotent upserts keyed by id, all GRDB work through the actor's syncWrite/syncRead.
//
// The day TOTALS are NOT here — they ride `metricSeries` under the `food-log` source, which is what
// every chart, Trends and Compare already read. These tables hold what a day total cannot reconstruct:
// the user's food vocabulary, and the individual entries the total was derived from.
//
// Living in the database rather than UserDefaults is what puts them in `.noopbak`, which is a ZIP of
// this SQLite file plus a fixed whitelist of scalar settings. Anything outside the database is not in
// the backup, and deleting the app takes the whole container with it.

// MARK: - Rows

/// A reusable food in the user's library. Macros are PER SERVING; a log scales them by its portion.
///
/// NOOP ships no food database and looks nothing up online — a food is whatever the user typed. That is
/// also why `servingLabel` is free text: a food's natural unit is not always mass.
public struct FoodItemRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var name: String
    /// What one serving IS, in the user's own words: "1 scoop", "100 g", "1 medium banana".
    public var servingLabel: String
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double
    /// Unix seconds.
    public var createdAt: Int
    /// Unix seconds; most-recently-used floats to the top of the picker. Nil until first used.
    public var lastUsedTs: Int?

    public init(id: String, deviceId: String, name: String, servingLabel: String,
                kcal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double,
                createdAt: Int, lastUsedTs: Int? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.servingLabel = servingLabel
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.createdAt = createdAt
        self.lastUsedTs = lastUsedTs
    }

    static func decode(_ row: Row) -> FoodItemRow {
        FoodItemRow(
            id: row["id"],
            deviceId: row["deviceId"],
            name: row["name"],
            servingLabel: row["servingLabel"],
            kcal: row["kcal"],
            protein: row["protein"],
            carbs: row["carbs"],
            fat: row["fat"],
            fiber: row["fiber"],
            createdAt: row["createdAt"],
            lastUsedTs: row["lastUsedTs"]
        )
    }
}

/// One logged eat.
///
/// The name and macros are a SNAPSHOT taken at log time, deliberately duplicating the item. Editing a
/// library item next month must not rewrite what last month's days say you ate, and deleting it must not
/// strand its history — which is why `itemId` is optional and carries no foreign key. It exists only so
/// the picker can offer "log this again"; nothing reads through it for macros.
public struct FoodEntryRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Local day key, `yyyy-MM-dd` — the same key `metricSeries` is written under.
    public var day: String
    public var itemId: String?
    public var nameSnapshot: String
    /// Servings eaten. 1.0 = one serving as the item defines it.
    public var portion: Double
    /// Per-serving macros as they stood at log time. Scale by `portion` for the day contribution.
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double
    /// Unix seconds.
    public var loggedAt: Int
    /// "breakfast" / "lunch" / "dinner" / "snack", or nil. Stored but not yet surfaced.
    public var mealType: String?

    public init(id: String, deviceId: String, day: String, itemId: String?, nameSnapshot: String,
                portion: Double, kcal: Double, protein: Double, carbs: Double, fat: Double,
                fiber: Double, loggedAt: Int, mealType: String? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.day = day
        self.itemId = itemId
        self.nameSnapshot = nameSnapshot
        self.portion = portion
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.loggedAt = loggedAt
        self.mealType = mealType
    }

    static func decode(_ row: Row) -> FoodEntryRow {
        FoodEntryRow(
            id: row["id"],
            deviceId: row["deviceId"],
            day: row["day"],
            itemId: row["itemId"],
            nameSnapshot: row["nameSnapshot"],
            portion: row["portion"],
            kcal: row["kcal"],
            protein: row["protein"],
            carbs: row["carbs"],
            fat: row["fat"],
            fiber: row["fiber"],
            loggedAt: row["loggedAt"],
            mealType: row["mealType"]
        )
    }
}

// MARK: - Store API

extension WhoopStore {

    // MARK: Library

    /// Insert or update library items by id. Idempotent — re-saving an item updates it in place rather
    /// than duplicating, which is what lets an edit and a `lastUsedTs` stamp share one path.
    @discardableResult
    public func upsertFoodItems(_ rows: [FoodItemRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO foodItem
                        (id, deviceId, name, servingLabel, kcal, protein, carbs, fat, fiber,
                         createdAt, lastUsedTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        deviceId = excluded.deviceId,
                        name = excluded.name,
                        servingLabel = excluded.servingLabel,
                        kcal = excluded.kcal,
                        protein = excluded.protein,
                        carbs = excluded.carbs,
                        fat = excluded.fat,
                        fiber = excluded.fiber,
                        lastUsedTs = excluded.lastUsedTs
                    """, arguments: [r.id, r.deviceId, r.name, r.servingLabel, r.kcal, r.protein,
                                     r.carbs, r.fat, r.fiber, r.createdAt, r.lastUsedTs])
            }
            return rows.count
        }
    }

    /// The library, most-recently-used first. An item never logged falls back to its creation time, so a
    /// brand-new food does not sort below everything merely because it has never been used.
    public func foodItems(deviceId: String) async throws -> [FoodItemRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodItem WHERE deviceId = ?
                ORDER BY COALESCE(lastUsedTs, createdAt) DESC, name COLLATE NOCASE ASC
                """, arguments: [deviceId]).map(FoodItemRow.decode)
        }
    }

    /// Delete one library item. Logged entries are untouched and still render in full — that is the
    /// point of their snapshots.
    @discardableResult
    public func deleteFoodItem(deviceId: String, id: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM foodItem WHERE deviceId = ? AND id = ?",
                           arguments: [deviceId, id])
            return db.changesCount
        }
    }

    // MARK: Entries

    @discardableResult
    public func upsertFoodEntries(_ rows: [FoodEntryRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO foodEntry
                        (id, deviceId, day, itemId, nameSnapshot, portion,
                         kcal, protein, carbs, fat, fiber, loggedAt, mealType)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        day = excluded.day,
                        itemId = excluded.itemId,
                        nameSnapshot = excluded.nameSnapshot,
                        portion = excluded.portion,
                        kcal = excluded.kcal,
                        protein = excluded.protein,
                        carbs = excluded.carbs,
                        fat = excluded.fat,
                        fiber = excluded.fiber,
                        loggedAt = excluded.loggedAt,
                        mealType = excluded.mealType
                    """, arguments: [r.id, r.deviceId, r.day, r.itemId, r.nameSnapshot, r.portion,
                                     r.kcal, r.protein, r.carbs, r.fat, r.fiber, r.loggedAt, r.mealType])
            }
            return rows.count
        }
    }

    /// One local day's entries, oldest first — the order they were eaten in, which is how the day reads.
    public func foodEntries(deviceId: String, day: String) async throws -> [FoodEntryRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodEntry WHERE deviceId = ? AND day = ? ORDER BY loggedAt ASC
                """, arguments: [deviceId, day]).map(FoodEntryRow.decode)
        }
    }

    @discardableResult
    public func deleteFoodEntry(deviceId: String, id: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM foodEntry WHERE deviceId = ? AND id = ?",
                           arguments: [deviceId, id])
            return db.changesCount
        }
    }
}
