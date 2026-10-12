import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

final class WeeklyDietReportsTests: XCTestCase {
    @MainActor
    func testRepositoryPreservesSourceCoverageAndCorrectedHistory() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "weekly-test")
        repo.setStoreForTesting(store)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-10-05", key: FoodLogStore.Keys.caloriesIn, value: 2000),
            MetricPoint(day: "2026-10-06", key: FoodLogStore.Keys.caloriesIn, value: 1800),
            MetricPoint(day: "2026-10-05", key: FoodLogStore.Keys.roughDay, value: 1),
        ], deviceId: FoodLogStore.sourceId)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-10-05", key: DietStore.Keys.expenditure, value: 2400),
            MetricPoint(day: "2026-10-06", key: DietStore.Keys.expenditure, value: 2300),
            MetricPoint(day: "2026-10-06", key: DietStore.Keys.burnSource, value: 1),
        ], deviceId: DietStore.sourceId)
        let now = Date(timeIntervalSince1970: Double(WeeklyDietReview.dayIndex("2026-10-12")!) * 86400 + 43200)
        let reports = try await repo.weeklyDietReports(now: now)
        XCTAssertEqual(reports[0].startKey, "2026-10-05")
        XCTAssertEqual(reports[0].formulaDays, 0, "Do not retrofit provenance onto old estimates")
        XCTAssertEqual(reports[0].calibratedDays, 1)
        XCTAssertEqual(reports[0].roughDays, 1)
        XCTAssertEqual(reports[0].pairedBalanceKcal, -900)
        XCTAssertNil(reports[0].fullWeekBalanceKcal)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-10-05", key: FoodLogStore.Keys.caloriesIn, value: 2200),
        ], deviceId: FoodLogStore.sourceId)
        let corrected = try await repo.weeklyDietReports(now: now)
        XCTAssertEqual(corrected[0].pairedBalanceKcal, -700)
        XCTAssertTrue(corrected[0].coachContext.contains("matched days ONLY"))
    }

    func testReviewAcknowledgementIsPerWeekAndStrictlyParsed() throws {
        let defaults = UserDefaults(suiteName: "WeeklyDietReportsTests.\(UUID())")!
        defer { defaults.removeObject(forKey: CoachDietReviewHistory.weeksKey) }
        let key = "2026-10-05"
        let prompt = CoachDietReviewHistory.weeklyPrompt(startKey: key)
        XCTAssertEqual(CoachDietReviewHistory.requestedWeek(prompt), key)
        XCTAssertNil(CoachDietReviewHistory.requestedWeek(prompt + " extra"))
        XCTAssertNil(CoachDietReviewHistory.requestedWeek(CoachDietReviewHistory.weeklyPrompt(startKey: "2026-10-06")))
        XCTAssertFalse(CoachDietReviewHistory.hasReviewed(week: key, defaults: defaults))
        CoachDietReviewHistory.record(week: key, defaults: defaults)
        XCTAssertTrue(CoachDietReviewHistory.hasReviewed(week: key, defaults: defaults))
        XCTAssertFalse(CoachDietReviewHistory.hasReviewed(week: "2026-10-12", defaults: defaults))
    }
}
