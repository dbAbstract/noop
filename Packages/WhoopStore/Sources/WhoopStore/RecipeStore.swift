import Foundation
import GRDB

// MARK: - v50 store: recipe components
//
// A recipe is an ordinary `foodItem` whose macros come from its parts rather than from typed numbers.
// The parts live here, one row per ingredient.
//
// THE MACROS ARE NEVER STORED ON THE RECIPE. They are computed from these rows on read, which is the
// same rule the user's own diet backend follows. Storing them would create a second answer that goes
// stale the moment an ingredient is corrected — and the stale one would be the one on screen.
//
// Logging a recipe still snapshots, exactly like any other food: the computed total is copied into the
// entry at log time, so editing the recipe next month cannot rewrite what a past day says you ate.

/// One ingredient in a recipe: either a reference to a library food, or an ad-hoc one held inline.
///
/// EXACTLY ONE of `foodItemId` and the `inline*` fields is populated. A reference resolves its macros
/// live, so correcting the ingredient corrects every recipe using it; an inline ingredient carries its
/// own numbers because there is no library row to correct. Both are scaled by `quantity` identically.
public struct RecipeComponentRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// The `foodItem` acting as the recipe.
    public var recipeId: String
    /// The `foodItem` used as an ingredient, or nil for an inline one. No foreign key — deleting an
    /// ingredient must not cascade away the recipe that mentioned it, the same reason `foodEntry.itemId`
    /// carries none.
    public var foodItemId: String?
    /// Servings of the ingredient in ITS OWN unit — "2 scoops", not "2 grams".
    public var quantity: Double
    /// Display order as the user arranged it.
    public var ord: Int

    /// An ad-hoc ingredient, used only when `foodItemId` is nil: something used once in one dish and not
    /// worth a library entry (the soy sauce in a marinade). Macros are PER SERVING, matching `foodItem`.
    public var inlineName: String?
    public var inlineServingLabel: String?
    public var inlineKcal: Double?
    public var inlineProtein: Double?
    public var inlineCarbs: Double?
    public var inlineFat: Double?
    public var inlineFiber: Double?

    public init(id: String, deviceId: String, recipeId: String, foodItemId: String?,
                quantity: Double, ord: Int,
                inlineName: String? = nil, inlineServingLabel: String? = nil,
                inlineKcal: Double? = nil, inlineProtein: Double? = nil,
                inlineCarbs: Double? = nil, inlineFat: Double? = nil, inlineFiber: Double? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.recipeId = recipeId
        self.foodItemId = foodItemId
        self.quantity = quantity
        self.ord = ord
        self.inlineName = inlineName
        self.inlineServingLabel = inlineServingLabel
        self.inlineKcal = inlineKcal
        self.inlineProtein = inlineProtein
        self.inlineCarbs = inlineCarbs
        self.inlineFat = inlineFat
        self.inlineFiber = inlineFiber
    }

    static func decode(_ row: Row) -> RecipeComponentRow {
        RecipeComponentRow(
            id: row["id"],
            deviceId: row["deviceId"],
            recipeId: row["recipeId"],
            foodItemId: row["foodItemId"],
            quantity: row["quantity"],
            ord: row["ord"],
            inlineName: row["inlineName"],
            inlineServingLabel: row["inlineServingLabel"],
            inlineKcal: row["inlineKcal"],
            inlineProtein: row["inlineProtein"],
            inlineCarbs: row["inlineCarbs"],
            inlineFat: row["inlineFat"],
            inlineFiber: row["inlineFiber"]
        )
    }
}

extension WhoopStore {

    @discardableResult
    public func upsertRecipeComponents(_ rows: [RecipeComponentRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO recipeComponent (id, deviceId, recipeId, foodItemId, quantity, ord, inlineName, inlineServingLabel, inlineKcal, inlineProtein, inlineCarbs, inlineFat, inlineFiber)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        recipeId = excluded.recipeId,
                        foodItemId = excluded.foodItemId,
                        quantity = excluded.quantity,
                        ord = excluded.ord,
                        inlineName = excluded.inlineName,
                        inlineServingLabel = excluded.inlineServingLabel,
                        inlineKcal = excluded.inlineKcal,
                        inlineProtein = excluded.inlineProtein,
                        inlineCarbs = excluded.inlineCarbs,
                        inlineFat = excluded.inlineFat,
                        inlineFiber = excluded.inlineFiber
                    """, arguments: [r.id, r.deviceId, r.recipeId, r.foodItemId, r.quantity, r.ord, r.inlineName, r.inlineServingLabel, r.inlineKcal, r.inlineProtein, r.inlineCarbs, r.inlineFat, r.inlineFiber])
            }
            return rows.count
        }
    }

    /// One recipe's ingredients, in the order the user arranged them.
    public func recipeComponents(deviceId: String, recipeId: String) async throws -> [RecipeComponentRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM recipeComponent WHERE deviceId = ? AND recipeId = ? ORDER BY ord ASC
                """, arguments: [deviceId, recipeId]).map(RecipeComponentRow.decode)
        }
    }

    /// Every component for this device, grouped by recipe.
    ///
    /// One query rather than N, because the food picker needs each recipe's computed macros to show a
    /// kcal figure per row — and asking per recipe would be a query per visible row while scrolling.
    public func allRecipeComponents(deviceId: String) async throws -> [String: [RecipeComponentRow]] {
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM recipeComponent WHERE deviceId = ? ORDER BY recipeId, ord ASC
                """, arguments: [deviceId]).map(RecipeComponentRow.decode)
        }
        return Dictionary(grouping: rows, by: \.recipeId)
    }

    /// Replace a recipe's ingredients wholesale.
    ///
    /// Delete-then-insert rather than a diff: a recipe is a handful of rows, the user edits it as a
    /// list, and reconciling adds/moves/removes individually would be more code and more ways to leave
    /// it half-applied. In one transaction, so a failure leaves the previous ingredients intact rather
    /// than an empty recipe.
    @discardableResult
    public func replaceRecipeComponents(deviceId: String, recipeId: String,
                                        with rows: [RecipeComponentRow]) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM recipeComponent WHERE deviceId = ? AND recipeId = ?",
                           arguments: [deviceId, recipeId])
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO recipeComponent (id, deviceId, recipeId, foodItemId, quantity, ord, inlineName, inlineServingLabel, inlineKcal, inlineProtein, inlineCarbs, inlineFat, inlineFiber)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.id, r.deviceId, r.recipeId, r.foodItemId, r.quantity, r.ord, r.inlineName, r.inlineServingLabel, r.inlineKcal, r.inlineProtein, r.inlineCarbs, r.inlineFat, r.inlineFiber])
            }
            return rows.count
        }
    }

    /// Remove a recipe's ingredients. The recipe's own `foodItem` row is deleted separately.
    @discardableResult
    public func deleteRecipeComponents(deviceId: String, recipeId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM recipeComponent WHERE deviceId = ? AND recipeId = ?",
                           arguments: [deviceId, recipeId])
            return db.changesCount
        }
    }
}
