import XCTest
@testable import StrandAnalytics

final class WeeklyDietReviewTests: XCTestCase {
    private let monday = WeeklyDietReview.dayIndex("2026-10-05")!
    private func data(slope: Double = -0.05, scatter: Double = 0,
                      source: WeeklyDietDay.BurnSource = .formula) -> [WeeklyDietDay] {
        (0..<42).map { offset in
            WeeklyDietDay(day: monday - 35 + offset, intake: 2000, expenditure: 2385,
                          weight: 80 + Double(offset) * slope + (offset % 2 == 0 ? scatter : -scatter), source: source)
        }
    }

    func testCivilDatesAndMondayBoundaryExcludeUnfinishedWeek() {
        XCTAssertEqual(WeeklyDietReview.dayIndex("1970-01-01"), 0)
        XCTAssertNil(WeeklyDietReview.dayIndex("2026-02-30"))
        XCTAssertNil(WeeklyDietReview.dayIndex("2026-1-1"))
        for key in ["2026-03-08", "2026-11-01", "2026-10-05"] {
            let day = WeeklyDietReview.dayIndex(key)!
            XCTAssertEqual(WeeklyDietReview.dayKey(day), key)
            XCTAssertEqual(WeeklyDietReview.dayKey(day + 1), key == "2026-03-08" ? "2026-03-09" : key == "2026-11-01" ? "2026-11-02" : "2026-10-06")
        }
        XCTAssertEqual(WeeklyDietReview.monday(containing: monday + 6), monday)
        XCTAssertEqual(WeeklyDietReview.reports(days: data(), today: monday + 6).first?.startDay, monday - 7)
        XCTAssertEqual(WeeklyDietReview.reports(days: data(), today: monday + 7).first?.startDay, monday)
    }

    func testPartialTotalsUseOnlyMatchedDaysAndMissingIsNotZero() {
        let days = [WeeklyDietDay(day: monday, intake: 2100, expenditure: 2500, weight: 80, rough: true),
                    WeeklyDietDay(day: monday + 1, intake: 1900),
                    WeeklyDietDay(day: monday + 2, expenditure: 2400)]
        let report = WeeklyDietReview.reports(days: days, today: monday + 7)[0]
        XCTAssertEqual(report.intakeKcal, 4000)
        XCTAssertEqual(report.expenditureKcal, 4900)
        XCTAssertEqual(report.pairedBalanceKcal, -400, "Cannot subtract totals from different days")
        XCTAssertEqual(report.intakeDays, 2)
        XCTAssertEqual(report.expenditureDays, 2)
        XCTAssertEqual(report.pairedDays, 1)
        XCTAssertEqual(report.roughDays, 1)
        XCTAssertNil(report.fullWeekBalanceKcal)
        XCTAssertEqual(report.alignment, .uncertain)
    }

    func testAlignmentNeedsIndependentCompleteEvidenceAndRejectsNoise() {
        let consistent = WeeklyDietReview.reports(days: data(), today: monday + 7)[0]
        XCTAssertEqual(consistent.fullWeekBalanceKcal, -2695)
        XCTAssertEqual(consistent.alignment, .consistent)
        XCTAssertEqual(consistent.expectedKgPerWeek!, -0.35, accuracy: 0.00001)
        XCTAssertEqual(consistent.evidencePairedDays, 41)
        XCTAssertEqual(WeeklyDietReview.reports(days: data(slope: 0), today: monday + 7)[0].alignment, .mismatch)
        XCTAssertEqual(WeeklyDietReview.reports(days: data(scatter: 10), today: monday + 7)[0].alignment, .uncertain)
        for source in [WeeklyDietDay.BurnSource.calibrated, .unknown] {
            XCTAssertEqual(WeeklyDietReview.reports(days: data(source: source), today: monday + 7)[0].alignment, .uncertain)
        }
        let burnOnly = data().map { WeeklyDietDay(day: $0.day, expenditure: $0.expenditure, weight: $0.weight, source: .formula) }
        XCTAssertEqual(WeeklyDietReview.reports(days: burnOnly, today: monday + 7)[0].uncertainty, .missingCalories)
        let missing = data().filter { $0.day != monday - 10 }
        XCTAssertEqual(WeeklyDietReview.reports(days: missing, today: monday + 7)[0].alignment, .uncertain)
        var rough = data()
        rough[12] = WeeklyDietDay(day: rough[12].day, intake: 2000, expenditure: 2385, weight: 79.4, rough: true, source: .formula)
        XCTAssertEqual(WeeklyDietReview.reports(days: rough, today: monday + 7)[0].alignment, .uncertain)
    }

    func testPastReportNeverUsesFutureWeightAndDoesNotStartAtOldWeightOnlyData() {
        let original = WeeklyDietReview.reports(days: data(), today: monday + 7)[0]
        let future = data() + [WeeklyDietDay(day: monday + 7, intake: 9999, expenditure: 1, weight: 40)]
        XCTAssertEqual(WeeklyDietReview.reports(days: future, today: monday + 7)[0], original)
        let oldWeight = [WeeklyDietDay(day: monday - 400, weight: 85)]
        XCTAssertEqual(WeeklyDietReview.reports(days: data() + oldWeight, today: monday + 7).count, 6)
    }
}
