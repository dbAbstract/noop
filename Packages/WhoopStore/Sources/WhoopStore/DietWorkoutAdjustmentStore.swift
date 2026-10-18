import Foundation
import GRDB

// MARK: - v55 store: confirmed played time for an intermittent workout
//
// FORK-LOCAL (diet). See the v55 migration comment: a diet-only fact about one workout row, held beside
// it rather than in it, so the shared row and its measured energy stay exactly as recorded.

public struct DietWorkoutAdjustmentRow: Equatable, Codable, Sendable {
    /// The workout row's `source`, verbatim.
    public var workoutSource: String
    /// The workout row's `startTs` (unix seconds).
    public var startTs: Int
    /// Seconds actually playing, as the user confirmed or edited it.
    public var playedS: Double
    public var updatedAt: Int

    public init(workoutSource: String, startTs: Int, playedS: Double, updatedAt: Int) {
        self.workoutSource = workoutSource
        self.startTs = startTs
        self.playedS = playedS
        self.updatedAt = updatedAt
    }

    static func decode(_ row: Row) -> DietWorkoutAdjustmentRow {
        DietWorkoutAdjustmentRow(workoutSource: row["workoutSource"], startTs: row["startTs"],
                                 playedS: row["playedS"], updatedAt: row["updatedAt"])
    }
}

extension WhoopStore {

    /// Insert or replace one workout's confirmed played time.
    public func upsertDietWorkoutAdjustment(_ r: DietWorkoutAdjustmentRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO dietWorkoutAdjustment (workoutSource, startTs, playedS, updatedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(workoutSource, startTs) DO UPDATE SET
                    playedS = excluded.playedS,
                    updatedAt = excluded.updatedAt
                """, arguments: [r.workoutSource, r.startTs, r.playedS, r.updatedAt])
        }
    }

    /// Adjustments for workouts starting in [fromTs, toTs].
    public func dietWorkoutAdjustments(fromTs: Int, toTs: Int) async throws -> [DietWorkoutAdjustmentRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM dietWorkoutAdjustment WHERE startTs BETWEEN ? AND ? ORDER BY startTs
                """, arguments: [fromTs, toTs]).map(DietWorkoutAdjustmentRow.decode)
        }
    }

    /// Forget a confirmation, returning the workout to the unconfirmed (whole-session) credit.
    public func deleteDietWorkoutAdjustment(workoutSource: String, startTs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM dietWorkoutAdjustment WHERE workoutSource = ? AND startTs = ?",
                           arguments: [workoutSource, startTs])
        }
    }
}
