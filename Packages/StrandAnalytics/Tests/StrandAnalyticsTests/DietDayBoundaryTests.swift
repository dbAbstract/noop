import XCTest
@testable import StrandAnalytics

/// Which diet day an instant belongs to. The case this exists for is the 00:15 snack before bed — under a
/// midnight boundary it lands on a fresh budget with nothing spent against it, reading as a free 2,000 kcal.
final class DietDayBoundaryTests: XCTestCase {

    private func daysBack(_ hour: Int, _ minute: Int = 0,
                          slept: Double = 0, known: Bool = true) -> Int {
        DietDayBoundary.daysBack(minuteOfDay: hour * 60 + minute,
                                 hoursSleptSinceMidnight: slept,
                                 sleepIsKnown: known)
    }

    // MARK: - The case it exists for

    /// 00:15, still up, nothing slept yet: this belongs to the day being lived.
    func testASnackBeforeBedBelongsToYesterday() {
        XCTAssertEqual(daysBack(0, 15, slept: 0), 1)
        XCTAssertEqual(daysBack(2, 30, slept: 0), 1)
    }

    /// Already slept the night, now eating early: a new day, even though the clock still says small hours.
    /// Someone in bed at 21:00 eating at 03:00 has had their night.
    func testEatingAfterTheNightIsTheNewDay() {
        XCTAssertEqual(daysBack(3, slept: 5), 0)
    }

    /// Past the window the answer is always today. An unworn strap must not read as a day that never ended
    /// and file every meal a day early for as long as the gap lasts.
    func testPastTheWindowItIsAlwaysToday() {
        XCTAssertEqual(daysBack(4, slept: 0), 0)
        XCTAssertEqual(daysBack(9, slept: 0), 0)
        XCTAssertEqual(daysBack(23, slept: 0), 0)
    }

    func testTheWindowBoundaryIsExclusive() {
        XCTAssertEqual(daysBack(3, 59, slept: 0), 1)
        XCTAssertEqual(daysBack(4, 0, slept: 0), 0)
    }

    // MARK: - A nap is not a night

    /// Dozing before midnight must not roll the day over, or the real night rolls it a second time and one
    /// calendar day yields two diet days.
    func testAShortSleepDoesNotEndTheDay() {
        XCTAssertEqual(daysBack(1, slept: 0.5), 1)
        XCTAssertEqual(daysBack(1, slept: 2.9), 1)
    }

    /// A genuinely short night is still a night.
    func testThreeHoursCountsAsTheNight() {
        XCTAssertEqual(daysBack(3, 30, slept: 3.0), 0)
    }

    // MARK: - Absent data is not evidence

    /// THE IMPORTANT GUARD. No sleep data is not the same as "awake all night" — without it the honest
    /// fallback is the calendar, because assuming the user is still up silently backdates every entry on
    /// any night the strap missed.
    func testNoSleepDataFallsBackToTheCalendar() {
        XCTAssertEqual(daysBack(0, 15, slept: 0, known: false), 0,
                       "an unworn strap must not backdate the day")
        XCTAssertEqual(daysBack(2, slept: 0, known: false), 0)
    }

    /// Measured zero IS evidence — it means the strap was worn and recorded no sleep.
    func testAMeasuredZeroIsTreatedAsStillAwake() {
        XCTAssertEqual(daysBack(0, 15, slept: 0, known: true), 1)
    }

    // MARK: - Degenerate input

    func testNonsenseMinutesAreToday() {
        XCTAssertEqual(DietDayBoundary.daysBack(minuteOfDay: -1, hoursSleptSinceMidnight: 0,
                                                sleepIsKnown: true), 0)
        XCTAssertEqual(DietDayBoundary.daysBack(minuteOfDay: 99_999, hoursSleptSinceMidnight: 0,
                                                sleepIsKnown: true), 0)
    }

    func testTheRolloverWindowIsReportedForTheUI() {
        XCTAssertTrue(DietDayBoundary.isInRolloverWindow(minuteOfDay: 15))
        XCTAssertFalse(DietDayBoundary.isInRolloverWindow(minuteOfDay: 12 * 60))
    }

    /// The constants are pinned because both are judgement calls a later reader might "tidy".
    func testTheBoundsAreWhatTheDocSays() {
        XCTAssertEqual(DietDayBoundary.latestRolloverMinute, 4 * 60)
        XCTAssertEqual(DietDayBoundary.minimumNightHours, 3.0)
    }
}
