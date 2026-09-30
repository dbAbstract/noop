import Foundation
import GRDB

// MARK: - v49 store: the diet goal
//
// One row per goal the user has held. Superseding sets `endedOn` rather than deleting, so a day logged
// months ago still resolves against the target that was actually in force then — adherence for a past
// week must not silently change because today's goal is different.

/// A goal as stored: the destination, the timeline, and the deficit derived from them at the time.
public struct DietGoalRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Local day the goal took effect, `yyyy-MM-dd`.
    public var startedOn: String
    /// nil while current; set when superseded.
    public var endedOn: String?
    public var startWeightKg: Double
    public var targetWeightKg: Double
    public var months: Int
    /// "sedentary" | "lightlyActive".
    public var activityLevel: String
    /// The deficit derived when the goal was set. Stored rather than recomputed so a past day keeps the
    /// number it was judged against even after the weight it was derived from has moved.
    public var dailyDeficitKcal: Double
    /// A hand-set daily target that overrides the derivation entirely. nil means "use the derivation".
    public var targetOverrideKcal: Double?
    public var createdAt: Int

    public init(id: String, deviceId: String, startedOn: String, endedOn: String? = nil,
                startWeightKg: Double, targetWeightKg: Double, months: Int, activityLevel: String,
                dailyDeficitKcal: Double, targetOverrideKcal: Double? = nil, createdAt: Int) {
        self.id = id
        self.deviceId = deviceId
        self.startedOn = startedOn
        self.endedOn = endedOn
        self.startWeightKg = startWeightKg
        self.targetWeightKg = targetWeightKg
        self.months = months
        self.activityLevel = activityLevel
        self.dailyDeficitKcal = dailyDeficitKcal
        self.targetOverrideKcal = targetOverrideKcal
        self.createdAt = createdAt
    }

    static func decode(_ row: Row) -> DietGoalRow {
        DietGoalRow(
            id: row["id"],
            deviceId: row["deviceId"],
            startedOn: row["startedOn"],
            endedOn: row["endedOn"],
            startWeightKg: row["startWeightKg"],
            targetWeightKg: row["targetWeightKg"],
            months: row["months"],
            activityLevel: row["activityLevel"],
            dailyDeficitKcal: row["dailyDeficitKcal"],
            targetOverrideKcal: row["targetOverrideKcal"],
            createdAt: row["createdAt"]
        )
    }
}

extension WhoopStore {

    @discardableResult
    public func upsertDietGoals(_ rows: [DietGoalRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO dietGoal
                        (id, deviceId, startedOn, endedOn, startWeightKg, targetWeightKg, months,
                         activityLevel, dailyDeficitKcal, targetOverrideKcal, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        startedOn = excluded.startedOn,
                        endedOn = excluded.endedOn,
                        startWeightKg = excluded.startWeightKg,
                        targetWeightKg = excluded.targetWeightKg,
                        months = excluded.months,
                        activityLevel = excluded.activityLevel,
                        dailyDeficitKcal = excluded.dailyDeficitKcal,
                        targetOverrideKcal = excluded.targetOverrideKcal
                    """, arguments: [r.id, r.deviceId, r.startedOn, r.endedOn, r.startWeightKg,
                                     r.targetWeightKg, r.months, r.activityLevel, r.dailyDeficitKcal,
                                     r.targetOverrideKcal, r.createdAt])
            }
            return rows.count
        }
    }

    /// The goal in force on `day`: started on or before it, and not ended before it.
    ///
    /// Ties (two goals starting the same day, which a same-day revision produces) resolve to the most
    /// recently created, so editing a goal twice in one afternoon behaves the way the user expects.
    public func dietGoal(deviceId: String, onDay day: String) async throws -> DietGoalRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM dietGoal
                WHERE deviceId = ? AND startedOn <= ? AND (endedOn IS NULL OR endedOn >= ?)
                ORDER BY startedOn DESC, createdAt DESC
                LIMIT 1
                """, arguments: [deviceId, day, day]).map(DietGoalRow.decode)
        }
    }

    /// The current goal — the one with no end date. nil when none has been set.
    public func currentDietGoal(deviceId: String) async throws -> DietGoalRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM dietGoal WHERE deviceId = ? AND endedOn IS NULL
                ORDER BY startedOn DESC, createdAt DESC LIMIT 1
                """, arguments: [deviceId]).map(DietGoalRow.decode)
        }
    }

    /// Every goal, newest first — the history behind "what was I aiming at in March".
    public func dietGoals(deviceId: String) async throws -> [DietGoalRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM dietGoal WHERE deviceId = ? ORDER BY startedOn DESC, createdAt DESC
                """, arguments: [deviceId]).map(DietGoalRow.decode)
        }
    }

    /// Close any open goal as of `day`, so a new one can take over without overlapping.
    ///
    /// Separate from the insert rather than folded into it: superseding and creating are distinct events,
    /// and a caller that only wants to STOP dieting needs the first without the second.
    @discardableResult
    public func endOpenDietGoals(deviceId: String, on day: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE dietGoal SET endedOn = ? WHERE deviceId = ? AND endedOn IS NULL
                """, arguments: [day, deviceId])
            return db.changesCount
        }
    }
}
