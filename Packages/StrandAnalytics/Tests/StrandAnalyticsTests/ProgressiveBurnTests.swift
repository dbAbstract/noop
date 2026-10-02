import XCTest
@testable import StrandAnalytics

/// What has been spent so far today.
///
/// The load-bearing test is `testTheFigureConvergesOnTheWholeDayFigure`: if a running total does not land
/// exactly on the whole-day figure, the Calories card and the diet budget describe one day with two
/// numbers. Everything else here is about not discounting activity that has already happened.
final class ProgressiveBurnTests: XCTestCase {

    // This user: 173 cm, 73 kg, 27, male.
    private let bmr = 1_681.25
    private let multiplier = 1.2
    private var dayBaseline: Double { bmr * multiplier }   // 2,017.5

    private func burn(elapsed: Double, night: Double = 7.667, sleptSoFar: Double? = nil,
                      activity: Double = 0) -> ProgressiveBurn.Result {
        ProgressiveBurn.burnedSoFar(bmrKcal: bmr,
                                    activityMultiplier: multiplier,
                                    nightSleepHours: night,
                                    sleepHoursToday: sleptSoFar ?? min(night, elapsed),
                                    elapsedHours: elapsed,
                                    activityKcal: activity)
    }

    // MARK: - The identity that keeps the card and the budget honest

    /// THE ONE THAT MATTERS. At the end of the day the running total must equal the whole-day figure
    /// EXACTLY — the waking rate is solved for precisely so that this holds, and a future tweak that broke
    /// it would make the Calories card and the budget disagree about the same day.
    func testTheFigureConvergesOnTheWholeDayFigure() {
        let end = burn(elapsed: 24, activity: 250)
        XCTAssertEqual(end.totalSoFarKcal, dayBaseline + 250, accuracy: 0.001)
        XCTAssertEqual(end.basis, .complete)
    }

    /// And it holds a minute BEFORE midnight too, which is the real test of the solved rate — `elapsed: 24`
    /// takes the short-circuit, so on its own it would prove nothing about the arithmetic.
    func testTheSolvedRateBalancesTheDayJustBeforeMidnight() {
        let late = burn(elapsed: 23.983)
        XCTAssertEqual(late.baselineSoFarKcal, dayBaseline, accuracy: 2.0)
        XCTAssertEqual(late.basis, .sleepAware)
    }

    /// The same identity must hold against the figure the budget is actually built from, not just against
    /// an arithmetic restatement of it.
    func testACompleteDayMatchesDayExpenditure() {
        let modelled = CalorieTarget.dayExpenditure(sex: "male", weightKg: 73, heightCm: 173, age: 27,
                                                    activity: .sedentary, neatSteps: 3_000,
                                                    workoutKcal: 150)
        let progressive = ProgressiveBurn.burnedSoFar(bmrKcal: modelled.bmrKcal,
                                                      activityMultiplier: 1.2,
                                                      nightSleepHours: 7.667,
                                                      sleepHoursToday: 7.667,
                                                      elapsedHours: 24,
                                                      activityKcal: modelled.activityKcal)
        XCTAssertEqual(progressive.totalSoFarKcal, modelled.totalKcal, accuracy: 0.001)
    }

    // MARK: - Activity is never prorated

    /// A workout done at 07:00 has fully happened by 14:00. Scaling it down with the rest of the day is the
    /// error worth hundreds of kcal.
    func testAnEarlyWorkoutIsNotDiscountedLaterInTheDay() {
        let withWorkout = burn(elapsed: 14, activity: 500)
        let withoutWorkout = burn(elapsed: 14, activity: 0)
        XCTAssertEqual(withWorkout.totalSoFarKcal - withoutWorkout.totalSoFarKcal, 500, accuracy: 0.001,
                       "the workout must be added whole, not scaled by elapsed time")

        // And the naive alternative — prorating everything — would be materially lower.
        let naive = (dayBaseline + 500) * (14.0 / 24.0)
        XCTAssertGreaterThan(withWorkout.totalSoFarKcal, naive + 100)
    }

    func testActivityIsAddedEvenAtTheVeryStartOfTheDay() {
        // A 05:00 run, before much baseline has accrued at all.
        let r = burn(elapsed: 5, sleptSoFar: 5, activity: 400)
        XCTAssertEqual(r.totalSoFarKcal - r.baselineSoFarKcal, 400, accuracy: 0.001)
    }

    func testNonsenseActivityIsIgnoredRatherThanPropagated() {
        XCTAssertEqual(burn(elapsed: 12, activity: .nan).totalSoFarKcal,
                       burn(elapsed: 12, activity: 0).totalSoFarKcal, accuracy: 0.001)
        XCTAssertEqual(burn(elapsed: 12, activity: -500).totalSoFarKcal,
                       burn(elapsed: 12, activity: 0).totalSoFarKcal, accuracy: 0.001)
    }

    // MARK: - Sleep-aware beats linear in the morning

    /// The magnitude this feature exists for. At 08:00 after a 7h40m night the sleep-aware figure is ~567
    /// against linear's ~676 — a 109 kcal over-read avoided, on a card whose whole point is honesty about
    /// estimation.
    func testTheMorningOverReadIsAvoided() {
        let aware = burn(elapsed: 8, sleptSoFar: 7.667)
        let linear = dayBaseline * (8.0 / 24.0)
        XCTAssertEqual(aware.baselineSoFarKcal, 567, accuracy: 12)
        XCTAssertEqual(linear, 672.5, accuracy: 1)
        XCTAssertLessThan(aware.baselineSoFarKcal, linear - 80)
    }

    /// While still asleep, the figure is sleep alone — no waking hours have happened to charge for.
    func testMidSleepTheFigureIsRestingOnly() {
        let r = burn(elapsed: 6, sleptSoFar: 6)
        XCTAssertEqual(r.baselineSoFarKcal, (bmr / 24) * 6, accuracy: 0.001)
    }

    /// The two methods converge as the day runs out — the sleep-aware path front-loads less and then
    /// catches up, rather than being permanently lower.
    func testTheGapToLinearClosesByEvening() {
        let morningGap = abs(dayBaseline * (8.0 / 24.0) - burn(elapsed: 8).baselineSoFarKcal)
        let eveningGap = abs(dayBaseline * (22.0 / 24.0) - burn(elapsed: 22).baselineSoFarKcal)
        XCTAssertLessThan(eveningGap, morningGap)
    }

    // MARK: - The linear fallback

    /// No sleep recorded means there is nothing to derive the two rates from. Falling back is correct;
    /// inventing a night is not — and the basis is reported so the caller can say the figure is cruder.
    func testNoRecordedSleepFallsBackToLinearAndSaysSo() {
        let r = burn(elapsed: 12, night: 0, sleptSoFar: 0)
        XCTAssertEqual(r.basis, .linear)
        XCTAssertEqual(r.baselineSoFarKcal, dayBaseline * 0.5, accuracy: 0.001)
    }

    /// A 24-hour "night" would leave no waking hours to balance against, i.e. a division by zero.
    func testAnAllDayNightFallsBackRatherThanDividingByZero() {
        let r = burn(elapsed: 12, night: 24, sleptSoFar: 12)
        XCTAssertEqual(r.basis, .linear)
        XCTAssertTrue(r.baselineSoFarKcal.isFinite)
    }

    // MARK: - Degenerate input

    func testStartOfDayIsZero() {
        let r = burn(elapsed: 0, sleptSoFar: 0)
        XCTAssertEqual(r.baselineSoFarKcal, 0, accuracy: 0.001)
        XCTAssertEqual(r.totalSoFarKcal, 0, accuracy: 0.001)
    }

    func testNonsenseProfileYieldsActivityOnlyRatherThanNaN() {
        let r = ProgressiveBurn.burnedSoFar(bmrKcal: .nan, activityMultiplier: 1.2,
                                            nightSleepHours: 8, sleepHoursToday: 8,
                                            elapsedHours: 12, activityKcal: 100)
        XCTAssertEqual(r.totalSoFarKcal, 100, accuracy: 0.001)
        XCTAssertTrue(r.baselineSoFarKcal.isFinite)
    }

    /// A nap after the night was measured makes the real night longer than assumed. The running total is
    /// capped at the day's own baseline so it cannot drift past the figure it must converge on — a "so far"
    /// exceeding the whole day is self-evidently wrong on screen.
    func testTheRunningTotalNeverExceedsTheWholeDayBaseline() {
        for elapsed in stride(from: 0.0, through: 24.0, by: 0.5) {
            let r = burn(elapsed: elapsed, sleptSoFar: 0)   // as if awake the entire time
            XCTAssertLessThanOrEqual(r.baselineSoFarKcal, dayBaseline + 0.001,
                                     "elapsed \(elapsed) exceeded the day's own baseline")
        }
    }

    func testElapsedIsClampedToTheDay() {
        XCTAssertEqual(burn(elapsed: 48).basis, .complete)
        XCTAssertEqual(burn(elapsed: -5, sleptSoFar: 0).baselineSoFarKcal, 0, accuracy: 0.001)
    }

    // MARK: - Elapsed hours helper

    func testElapsedHoursFromMinuteOfDay() {
        XCTAssertEqual(ProgressiveBurn.elapsedHours(minuteOfDay: 0), 0)
        XCTAssertEqual(ProgressiveBurn.elapsedHours(minuteOfDay: 8 * 60), 8, accuracy: 1e-9)
        XCTAssertEqual(ProgressiveBurn.elapsedHours(minuteOfDay: 1_439), 23.983, accuracy: 0.001)
        XCTAssertEqual(ProgressiveBurn.elapsedHours(minuteOfDay: -10), 0)
        XCTAssertEqual(ProgressiveBurn.elapsedHours(minuteOfDay: 99_999), 24, accuracy: 1e-9)
    }
}
