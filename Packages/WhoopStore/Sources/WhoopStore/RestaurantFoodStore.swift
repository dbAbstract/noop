import Foundation
import GRDB

// MARK: - v53 store: published restaurant nutrition
//
// Reference data, not the user's library. A chain's menu is hundreds of rows nobody has chosen to eat, so
// it lives apart from `foodItem` and only becomes one when something is actually logged.
//
// EVERY MACRO IS OPTIONAL and stays optional all the way through. Partial publication is the norm — one
// chain gives kcal and protein but no fibre, another gives fibre but no fat — and a non-optional field
// would turn "not published" into a claim of zero somewhere between here and the screen.

/// One published menu item.
public struct RestaurantFoodRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Normalised for lookup: lowercased and trimmed, so "Kura Sushi" and "kura sushi" are one chain.
    public var chain: String
    /// What to show, as the user typed or the menu titled it.
    public var chainLabel: String
    public var name: String
    public var servingLabel: String?
    public var kcal: Double?
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var fiber: Double?
    /// "menu-pdf", "menu-text", or "coach" — so a figure the user dictated is distinguishable from one read
    /// off a published menu, which matters when the two disagree.
    public var source: String?
    public var importedAt: Int

    public init(id: String, deviceId: String, chain: String, chainLabel: String, name: String,
                servingLabel: String? = nil, kcal: Double? = nil, protein: Double? = nil,
                carbs: Double? = nil, fat: Double? = nil, fiber: Double? = nil,
                source: String? = nil, importedAt: Int) {
        self.id = id
        self.deviceId = deviceId
        self.chain = chain
        self.chainLabel = chainLabel
        self.name = name
        self.servingLabel = servingLabel
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.source = source
        self.importedAt = importedAt
    }

    /// Normalise a chain name for the lookup column. One spelling rule, used by both the writer and every
    /// reader — two would let "Kura Sushi" and "kura  sushi" become separate chains.
    public static func normalisedChain(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func decode(_ row: Row) -> RestaurantFoodRow {
        RestaurantFoodRow(
            id: row["id"], deviceId: row["deviceId"], chain: row["chain"],
            chainLabel: row["chainLabel"], name: row["name"], servingLabel: row["servingLabel"],
            kcal: row["kcal"], protein: row["protein"], carbs: row["carbs"], fat: row["fat"],
            fiber: row["fiber"], source: row["source"], importedAt: row["importedAt"])
    }
}

extension WhoopStore {

    /// Replace a chain's menu wholesale.
    ///
    /// Delete-then-insert in ONE transaction, deliberately. A re-import is a new edition of the menu, not a
    /// diff against the old one: items get renamed, withdrawn and re-costed, and reconciling that would
    /// leave withdrawn items behind forever. In a transaction so a failure keeps the previous edition
    /// rather than leaving a chain half-replaced.
    @discardableResult
    public func replaceRestaurantMenu(deviceId: String, chain: String,
                                      with rows: [RestaurantFoodRow]) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM restaurantFood WHERE deviceId = ? AND chain = ?",
                           arguments: [deviceId, chain])
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO restaurantFood
                        (id, deviceId, chain, chainLabel, name, servingLabel,
                         kcal, protein, carbs, fat, fiber, source, importedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.id, r.deviceId, r.chain, r.chainLabel, r.name, r.servingLabel,
                                     r.kcal, r.protein, r.carbs, r.fat, r.fiber, r.source, r.importedAt])
            }
            return rows.count
        }
    }

    /// Add or update single items without disturbing the rest of a chain — the path a coach-dictated figure
    /// takes, as opposed to a menu import.
    @discardableResult
    public func upsertRestaurantFoods(_ rows: [RestaurantFoodRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO restaurantFood
                        (id, deviceId, chain, chainLabel, name, servingLabel,
                         kcal, protein, carbs, fat, fiber, source, importedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        chain = excluded.chain, chainLabel = excluded.chainLabel,
                        name = excluded.name, servingLabel = excluded.servingLabel,
                        kcal = excluded.kcal, protein = excluded.protein, carbs = excluded.carbs,
                        fat = excluded.fat, fiber = excluded.fiber,
                        source = excluded.source, importedAt = excluded.importedAt
                    """, arguments: [r.id, r.deviceId, r.chain, r.chainLabel, r.name, r.servingLabel,
                                     r.kcal, r.protein, r.carbs, r.fat, r.fiber, r.source, r.importedAt])
            }
            return rows.count
        }
    }

    /// One chain's items.
    public func restaurantFoods(deviceId: String, chain: String) async throws -> [RestaurantFoodRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM restaurantFood WHERE deviceId = ? AND chain = ? ORDER BY name ASC
                """, arguments: [deviceId, chain]).map(RestaurantFoodRow.decode)
        }
    }

    /// Every chain held, with how many items each has.
    ///
    /// What the coach is told it HAS, as opposed to the items themselves: naming the chains costs a line
    /// and lets the model ask for one, where sending every menu would crowd out the conversation.
    public func restaurantChains(deviceId: String) async throws -> [(chain: String, label: String, count: Int)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT chain, chainLabel, COUNT(*) AS n FROM restaurantFood
                WHERE deviceId = ? GROUP BY chain, chainLabel ORDER BY chainLabel ASC
                """, arguments: [deviceId])
                .map { (chain: $0["chain"], label: $0["chainLabel"], count: $0["n"]) }
        }
    }

    /// Items matching a name across EVERY chain — the cross-chain reference lookup.
    ///
    /// The query the single-table design exists for: eating at a chain with no figures for a dish, but
    /// another chain has a comparable one. Matching is a plain substring here; judging whether two items are
    /// actually comparable is the model's job, and it must ask before borrowing.
    public func restaurantFoodsMatching(deviceId: String, nameLike: String,
                                        limit: Int = 40) async throws -> [RestaurantFoodRow] {
        let needle = "%\(nameLike.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())%"
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM restaurantFood
                WHERE deviceId = ? AND LOWER(name) LIKE ?
                ORDER BY chainLabel ASC, name ASC LIMIT ?
                """, arguments: [deviceId, needle, limit]).map(RestaurantFoodRow.decode)
        }
    }

    @discardableResult
    public func deleteRestaurantMenu(deviceId: String, chain: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM restaurantFood WHERE deviceId = ? AND chain = ?",
                           arguments: [deviceId, chain])
            return db.changesCount
        }
    }
}
