import XCTest
@testable import WhoopStore

final class ReviewedDietGoalTests: XCTestCase {
    private func goal(_ id: String, day: String = "2026-10-01") -> DietGoalRow {
        DietGoalRow(id: id, deviceId: "diet", startedOn: day, startWeightKg: 73,
                    targetWeightKg: 69, months: 6, activityLevel: "sedentary",
                    dailyDeficitKcal: 170, createdAt: 100, proteinGPerKg: 1.2,
                    measuredBaselineKcal: 1900)
    }

    func testOnlyTheReviewedGoalCanBeReplacedAndHistorySurvives() async throws {
        let store = try await WhoopStore.inMemory()
        let original = goal("original")
        let created = try await store.replaceDietGoal(original, expecting: nil)
        XCTAssertTrue(created)
        let revised = goal("revised", day: "2026-10-12")
        let result1 = try await store.replaceDietGoal(revised, expecting: original)
        XCTAssertTrue(result1)
        let result2 = try await store.replaceDietGoal(goal("stale"), expecting: original)
        XCTAssertFalse(result2)
        let result3 = try await store.replaceDietGoal(goal("new"), expecting: nil)
        XCTAssertFalse(result3)
        let current = try await store.currentDietGoal(deviceId: "diet")
        XCTAssertEqual(current, revised)
        let history = try await store.dietGoal(deviceId: "diet", onDay: "2026-10-05")
        XCTAssertEqual(history?.id, original.id)
        XCTAssertEqual(history?.dailyDeficitKcal, original.dailyDeficitKcal)
    }

    func testInPlaceCalibrationInvalidatesOldProposal() async throws {
        let store = try await WhoopStore.inMemory()
        var original = goal("original")
        _ = try await store.upsertDietGoals([original])
        let snapshot = original
        original.measuredBaselineKcal = 2000
        _ = try await store.upsertDietGoals([original])
        let result4 = try await store.replaceDietGoal(goal("replacement"), expecting: snapshot)
        XCTAssertFalse(result4)
        let current = try await store.currentDietGoal(deviceId: "diet")
        XCTAssertEqual(current, original)
    }

    func testFailedInsertDoesNotCloseOriginalGoal() async throws {
        let store = try await WhoopStore.inMemory()
        let original = goal("original")
        var collision = goal("collision")
        collision.endedOn = "2026-10-02"
        _ = try await store.upsertDietGoals([original, collision])
        do {
            _ = try await store.replaceDietGoal(goal("collision"), expecting: original)
            XCTFail("Expected duplicate primary key to fail")
        } catch { }
        let current = try await store.currentDietGoal(deviceId: "diet")
        XCTAssertEqual(current, original)
    }
}
