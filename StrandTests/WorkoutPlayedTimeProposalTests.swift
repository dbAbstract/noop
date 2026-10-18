import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The coach's `workout_played_time` proposal: it resolves only against workouts the context listed, only
/// for sports the cap applies to, and the card's figures are the app's pricing, not the model's.
@MainActor
final class WorkoutPlayedTimeProposalTests: XCTestCase {

    private let body = DietBody(sex: "male", weightKg: 72.8, heightCm: 174, age: 27)

    private func row(sport: String, start: Int = 1_792_058_357, minutes: Int = 120,
                     kcal: Double = 1_720) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: "manual",
                   durationS: Double(minutes * 60), energyKcal: kcal, avgHr: 149, maxHr: 192, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func credit(_ r: WorkoutRow) -> DietWorkoutCredit {
        DietWorkoutCredit(row: r,
                          credit: DietWorkoutCredit.price(r, playedS: nil, weightKg: body.weightKg,
                                                          bmrKcalPerDay: body.bmrKcalPerDay),
                          isPlayedTimeConfirmed: false, weightKg: body.weightKg,
                          bmrKcalPerDay: body.bmrKcalPerDay)
    }

    private func resolve(_ key: String, minutes: Double, workouts: [DietWorkoutCredit]) -> FoodProposal? {
        FoodProposal.resolve(FoodActionRequest(action: .workoutPlayedTime(workoutKey: key, playedMinutes: minutes)),
                             library: [], recipeIds: [], defaultServingLabel: "1 serving",
                             lastKnownWeightKg: nil, workouts: workouts)
    }

    /// The 2026-10-15 session: unconfirmed counts 9 × 72.8 × 2 = 1310.4; at 79 played,
    /// 9 × 72.8 × 79/60 + 1 × 72.8 × 41/60 = 862.68 + 49.75 = 912.43.
    func testResolvesAListedSoccerSessionWithTheAppsPricing() throws {
        let w = credit(row(sport: "Soccer"))
        let p = try XCTUnwrap(resolve("w1792058357", minutes: 79, workouts: [w]))
        guard case .playedTime(let source, let start, _, let duration, let played, let recorded,
                               let before, let after) = p.kind else {
            return XCTFail("expected a played-time card, got \(p.kind)")
        }
        XCTAssertEqual(source, "manual")
        XCTAssertEqual(start, 1_792_058_357)
        XCTAssertEqual(duration, 7_200)
        XCTAssertEqual(played, 79 * 60)
        XCTAssertEqual(recorded, 1_720)
        XCTAssertEqual(before, 1_310.4, accuracy: 0.01)
        XCTAssertEqual(after, 912.43, accuracy: 0.01)
        XCTAssertEqual(p.dedupeKey, "playedTime:manual:1792058357")
        XCTAssertNil(p.loggedMacros, "a played-time card logs no food")
    }

    func testAKeyNotInTheContextIsUnresolved() throws {
        let p = try XCTUnwrap(resolve("w999", minutes: 80, workouts: [credit(row(sport: "Soccer"))]))
        guard case .unresolved = p.kind else { return XCTFail("expected unresolved") }
    }

    /// The cap does not apply to a run, so confirming played time on one would change nothing the card claims.
    func testANonIntermittentSportIsUnresolved() throws {
        let p = try XCTUnwrap(resolve("w1792058357", minutes: 30, workouts: [credit(row(sport: "Running", minutes: 45, kcal: 600))]))
        guard case .unresolved = p.kind else { return XCTFail("expected unresolved") }
    }

    /// More minutes than the session lasted clamp to the session.
    func testPlayedTimeClampsToTheSession() throws {
        let p = try XCTUnwrap(resolve("w1792058357", minutes: 500, workouts: [credit(row(sport: "Soccer"))]))
        guard case .playedTime(_, _, _, _, let played, _, _, _) = p.kind else { return XCTFail() }
        XCTAssertEqual(played, 7_200)
    }
}
