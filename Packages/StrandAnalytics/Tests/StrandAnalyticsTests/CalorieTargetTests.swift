import XCTest
@testable import StrandAnalytics

/// BMR, the activity multiplier, and how a day's expenditure is assembled from its measured parts.
final class CalorieTargetTests: XCTestCase {

    // The user this was built for: male, 73 kg, 173 cm, 27.
    private let sex = "male", weight = 73.0, height = 173.0, age = 27.0

    // MARK: - Mifflin-St Jeor

    /// 10(73) + 6.25(173) − 5(27) + 5 = 730 + 1081.25 − 135 + 5 = 1681.25
    func testMifflinForTheReferenceProfile() {
        XCTAssertEqual(CalorieTarget.mifflinBMR(sex: sex, weightKg: weight, heightCm: height, age: age),
                       1681.25, accuracy: 0.01)
    }

    /// The female constant differs by 166 kcal (+5 vs −161), the whole sex difference in this formula.
    func testFemaleOffset() {
        let m = CalorieTarget.mifflinBMR(sex: "male", weightKg: weight, heightCm: height, age: age)
        let f = CalorieTarget.mifflinBMR(sex: "female", weightKg: weight, heightCm: height, age: age)
        XCTAssertEqual(m - f, 166, accuracy: 0.01)
    }

    /// Nonbinary takes the midpoint rather than silently defaulting to one — matching how `Calories.Coeffs`
    /// resolves the same problem in the measured path.
    func testNonbinaryIsTheMidpoint() {
        let m = CalorieTarget.mifflinBMR(sex: "male", weightKg: weight, heightCm: height, age: age)
        let f = CalorieTarget.mifflinBMR(sex: "female", weightKg: weight, heightCm: height, age: age)
        let n = CalorieTarget.mifflinBMR(sex: "nonbinary", weightKg: weight, heightCm: height, age: age)
        XCTAssertEqual(n, (m + f) / 2, accuracy: 0.01)
    }

    /// An unrecognised value must not produce a wildly different number; male is the documented default.
    func testUnknownSexFallsBackToMale() {
        XCTAssertEqual(CalorieTarget.mifflinBMR(sex: "???", weightKg: weight, heightCm: height, age: age),
                       CalorieTarget.mifflinBMR(sex: "male", weightKg: weight, heightCm: height, age: age))
    }

    /// Nonsense inputs must floor at zero rather than emit a negative resting metabolism.
    func testBMRNeverGoesNegative() {
        XCTAssertEqual(CalorieTarget.mifflinBMR(sex: sex, weightKg: 1, heightCm: 1, age: 200), 0)
    }

    /// This is deliberately NOT the formula the measured-calorie path uses. Pinned so the divergence stays
    /// a decision rather than becoming a surprise: Harris–Benedict gives ~1743 for the same profile.
    func testMifflinDivergesFromTheHarrisBenedictUsedByMeasuredCalories() {
        let mifflin = CalorieTarget.mifflinBMR(sex: sex, weightKg: weight, heightCm: height, age: age)
        let harrisBenedict = 88.362 + 13.397 * weight + 479.9 * (height / 100) - 5.677 * age
        XCTAssertEqual(harrisBenedict, 1743, accuracy: 1.0)
        XCTAssertLessThan(mifflin, harrisBenedict)
        XCTAssertEqual(harrisBenedict - mifflin, 62, accuracy: 1.5)
    }

    // MARK: - Activity

    func testMultipliers() {
        XCTAssertEqual(ActivityLevel.sedentary.multiplier, 1.2)
        XCTAssertEqual(ActivityLevel.lightlyActive.multiplier, 1.375)
    }

    /// Only two levels, because exercise is added separately from measured workouts. Tiers like
    /// "very active" would double-count the thing they describe.
    func testOnlyTwoActivityLevelsExist() {
        XCTAssertEqual(ActivityLevel.allCases.count, 2)
    }

    func testBaselineIsBMRTimesMultiplier() {
        let bmr = CalorieTarget.mifflinBMR(sex: sex, weightKg: weight, heightCm: height, age: age)
        XCTAssertEqual(CalorieTarget.baselineKcal(bmrKcal: bmr, activity: .sedentary),
                       bmr * 1.2, accuracy: 0.01)
    }

    // MARK: - Assembling a day

    func testDayExpenditureSumsItsParts() {
        let d = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                             activity: .sedentary, neatSteps: 7_000, workoutKcal: 150)
        XCTAssertEqual(d.bmrKcal, 1681.25, accuracy: 0.01)
        XCTAssertEqual(d.baselineKcal, 2017.5, accuracy: 0.01)
        // 7,000 × 73 × 0.0004 = 204.4
        XCTAssertEqual(d.stepNeatKcal, 204.4, accuracy: 0.01)
        XCTAssertEqual(d.workoutKcal, 150)
        XCTAssertEqual(d.totalKcal, 2017.5 + 204.4 + 150, accuracy: 0.01)
    }

    /// A sedentary day with no workout collapses to baseline alone — no invented movement.
    func testQuietDayIsBaselineOnly() {
        let d = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                             activity: .sedentary, neatSteps: 0, workoutKcal: 0)
        XCTAssertEqual(d.totalKcal, d.baselineKcal, accuracy: 0.01)
        XCTAssertEqual(d.stepNeatKcal, 0)
    }

    func testNegativeWorkoutKcalIsClampedNotSubtracted() {
        let d = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                             activity: .sedentary, neatSteps: 0, workoutKcal: -500)
        XCTAssertEqual(d.workoutKcal, 0, "a bad workout figure must not eat into the budget")
    }

    // MARK: - Budget

    func testBudgetIsExpenditureMinusDeficit() {
        let d = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                             activity: .sedentary, neatSteps: 7_000, workoutKcal: 150)
        XCTAssertEqual(d.budgetKcal(deficitKcal: 169), d.totalKcal - 169, accuracy: 0.01)
    }

    /// A deficit larger than the day's expenditure is a broken plan, not a negative instruction.
    func testBudgetNeverGoesNegative() {
        let d = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                             activity: .sedentary, neatSteps: 0, workoutKcal: 0)
        XCTAssertEqual(d.budgetKcal(deficitKcal: 99_999), 0)
    }

    /// Exercise raises the allowance — the behaviour the user asked for explicitly.
    func testWorkoutRaisesTheBudgetByItsOwnCalories() {
        let base = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                                activity: .sedentary, neatSteps: 0, workoutKcal: 0)
        let gym = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                               activity: .sedentary, neatSteps: 0, workoutKcal: 150)
        XCTAssertEqual(gym.budgetKcal(deficitKcal: 169) - base.budgetKcal(deficitKcal: 169), 150,
                       accuracy: 0.01)
    }

    // MARK: - Recalibration

    /// Losing slower than predicted means expenditure is lower than assumed, so the deficit must grow.
    func testLosingSlowerThanExpectedIncreasesTheDeficit() {
        let next = CalorieTarget.adjustedDeficit(currentDeficitKcal: 169,
                                                 expectedKgPerWeek: 0.15, actualKgPerWeek: 0.05)
        // shortfall 0.10 kg/wk × 7700 / 7 × 0.5 damping = +55 kcal
        XCTAssertEqual(next, 169 + 55, accuracy: 0.5)
    }

    func testLosingFasterThanExpectedReducesTheDeficit() {
        let next = CalorieTarget.adjustedDeficit(currentDeficitKcal: 400,
                                                 expectedKgPerWeek: 0.15, actualKgPerWeek: 0.35)
        XCTAssertEqual(next, 400 - 110, accuracy: 0.5)
    }

    /// Damping is what stops the loop oscillating on noisy weight data — a full correction would
    /// routinely overshoot and correct back.
    func testDampingHalvesTheCorrection() {
        let damped = CalorieTarget.adjustedDeficit(currentDeficitKcal: 200,
                                                   expectedKgPerWeek: 0.2, actualKgPerWeek: 0.0,
                                                   damping: 0.5)
        let full = CalorieTarget.adjustedDeficit(currentDeficitKcal: 200,
                                                 expectedKgPerWeek: 0.2, actualKgPerWeek: 0.0,
                                                 damping: 1.0)
        XCTAssertEqual(damped - 200, (full - 200) / 2, accuracy: 0.5)
    }

    /// No single noisy week may walk the target somewhere absurd, in either direction.
    func testAdjustmentIsClampedBothWays() {
        let hugeShortfall = CalorieTarget.adjustedDeficit(currentDeficitKcal: 700,
                                                          expectedKgPerWeek: 2.0, actualKgPerWeek: 0.0)
        XCTAssertEqual(hugeShortfall, CalorieTarget.maxAdjustedDeficitKcal)
        let hugeOvershoot = CalorieTarget.adjustedDeficit(currentDeficitKcal: 200,
                                                          expectedKgPerWeek: 0.0, actualKgPerWeek: 2.0)
        XCTAssertEqual(hugeOvershoot, CalorieTarget.minAdjustedDeficitKcal)
    }

    /// The floor is deliberately BELOW the user's backend value of 200: a late-stage plateau is exactly
    /// when a sub-200 deficit is the right answer, and a 200 floor would refuse to go there.
    func testDeficitFloorAllowsASmallDeficit() {
        XCTAssertLessThan(CalorieTarget.minAdjustedDeficitKcal, 200)
    }
}
