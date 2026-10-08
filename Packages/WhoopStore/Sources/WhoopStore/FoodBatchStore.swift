import Foundation
import GRDB

// MARK: - v54 store: a cook, and what is left of it
//
// One making of a dish, with the macros of the WHOLE thing. Portions logged against it are fractions:
// 0.6 is 60% of the pot.
//
// THERE IS NO `remaining` COLUMN HERE and there deliberately never will be. What is left is derived from
// the portions of the entries pointing at this row — see `BatchRemainder`. A stored fraction would be a
// second answer to a question the entries already answer, and the two disagree the first time an entry is
// edited or deleted: the pot would still claim 40% after the 60% log was removed. The same reasoning that
// makes a recipe "an item that has components" rather than an item carrying an `isRecipe` flag.

/// One cook.
public struct FoodBatchRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// The saved recipe this is a making of, or nil for a standalone cook.
    ///
    /// NULLABLE is the point. A cook does not require a recipe, which is what lets "I made a karahi
    /// tonight" be recorded at the moment it happens rather than after a detour through the library.
    public var recipeId: String?
    public var name: String
    /// What differed about this cook — "400g chicken instead of the usual 500".
    ///
    /// The deviation lives on the INSTANCE so the recipe never has to be wrong. That is the whole answer
    /// to "recipes are finnicky": the template stops claiming to describe every making of the dish.
    public var note: String?
    /// Local day key, `yyyy-MM-dd`.
    public var cookedOn: String
    /// The WHOLE cook, not a serving.
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double
    public var createdAt: Int
    /// Set when the rest was binned.
    ///
    /// Distinct from a zero remainder, and it outranks one: this is a statement about the food, where the
    /// remainder is an inference from the logs. Without it, "I threw the rest out" would have to be
    /// recorded as eating it.
    public var closedAt: Int?

    public init(id: String, deviceId: String, recipeId: String? = nil, name: String,
                note: String? = nil, cookedOn: String, kcal: Double, protein: Double, carbs: Double,
                fat: Double, fiber: Double, createdAt: Int, closedAt: Int? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.recipeId = recipeId
        self.name = name
        self.note = note
        self.cookedOn = cookedOn
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.createdAt = createdAt
        self.closedAt = closedAt
    }

    static func decode(_ row: Row) -> FoodBatchRow {
        FoodBatchRow(id: row["id"], deviceId: row["deviceId"], recipeId: row["recipeId"],
                     name: row["name"], note: row["note"], cookedOn: row["cookedOn"],
                     kcal: row["kcal"], protein: row["protein"], carbs: row["carbs"],
                     fat: row["fat"], fiber: row["fiber"], createdAt: row["createdAt"],
                     closedAt: row["closedAt"])
    }
}

extension WhoopStore {

    @discardableResult
    public func upsertFoodBatch(_ row: FoodBatchRow) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO foodBatch
                    (id, deviceId, recipeId, name, note, cookedOn,
                     kcal, protein, carbs, fat, fiber, createdAt, closedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    recipeId = excluded.recipeId, name = excluded.name, note = excluded.note,
                    cookedOn = excluded.cookedOn, kcal = excluded.kcal, protein = excluded.protein,
                    carbs = excluded.carbs, fat = excluded.fat, fiber = excluded.fiber,
                    closedAt = excluded.closedAt
                """, arguments: [row.id, row.deviceId, row.recipeId, row.name, row.note, row.cookedOn,
                                 row.kcal, row.protein, row.carbs, row.fat, row.fiber,
                                 row.createdAt, row.closedAt])
            return 1
        }
    }

    /// Cooks made on or after `from`, newest first.
    ///
    /// Bounded by date rather than returning everything: whether a cook is still OFFERABLE is a question
    /// about its remainder and its age, which `BatchRemainder.isOpen` answers, and handing it a year of
    /// history to filter would read a year of rows to discard all but two.
    public func foodBatches(deviceId: String, since from: String) async throws -> [FoodBatchRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodBatch WHERE deviceId = ? AND cookedOn >= ?
                ORDER BY cookedOn DESC, createdAt DESC
                """, arguments: [deviceId, from]).map(FoodBatchRow.decode)
        }
    }

    public func foodBatch(deviceId: String, id: String) async throws -> FoodBatchRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM foodBatch WHERE deviceId = ? AND id = ?",
                             arguments: [deviceId, id]).map(FoodBatchRow.decode)
        }
    }

    /// Mark the rest as gone, or un-mark it.
    @discardableResult
    public func closeFoodBatch(deviceId: String, id: String, at closedAt: Int?) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "UPDATE foodBatch SET closedAt = ? WHERE deviceId = ? AND id = ?",
                           arguments: [closedAt, deviceId, id])
            return db.changesCount
        }
    }

    /// Delete a cook and detach — NOT delete — the entries drawn from it.
    ///
    /// The portions were eaten whether or not the pot is still described, so removing the cook must not
    /// remove the food from the day's totals. The entries keep their snapshotted macros and simply stop
    /// belonging to anything, which is what an ordinary one-off log already is.
    @discardableResult
    public func deleteFoodBatch(deviceId: String, id: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "UPDATE foodEntry SET batchId = NULL WHERE deviceId = ? AND batchId = ?",
                           arguments: [deviceId, id])
            try db.execute(sql: "DELETE FROM foodBatch WHERE deviceId = ? AND id = ?",
                           arguments: [deviceId, id])
            return db.changesCount
        }
    }
}
