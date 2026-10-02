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

    /// The diet path pins the no-measured-movement baseline, and this names why.
    func testTheDietBaselineIsSedentary() {
        XCTAssertEqual(ActivityLevel.measuredMovementBaseline, .sedentary)
    }

    /// THE REASON THERE IS NO ACTIVITY PICKER, pinned so it survives someone "restoring" the familiar
    /// tiers. A conventional activity factor stands in for movement nobody measured; here movement IS
    /// measured, so declaring yourself active charges for it twice.
    ///
    /// The gap between the two multipliers is equivalent to claiming ~13,400 extra steps a day — steps
    /// the pedometer would then count again. The original figure was ~10,000; lowering the per-step rate
    /// to 0.0003 RAISED this, because the same 294 kcal gap now buys more steps. So the double-count
    /// argument got stronger with the revision, not weaker, and the picker stays gone.
    ///
    /// Asserted as a floor rather than a point value: the exact number tracks the step coefficient, and
    /// what matters is that it stays implausibly large. If it ever drops near a real day's step count, the
    /// coefficient has moved far enough that this argument needs re-deriving rather than re-asserting.
    func testChoosingLightlyActiveWouldDoubleCountAnImplausibleNumberOfSteps() {
        let bmr = CalorieTarget.mifflinBMR(sex: sex, weightKg: weight, heightCm: height, age: age)
        let gap = CalorieTarget.baselineKcal(bmrKcal: bmr, activity: .lightlyActive)
               - CalorieTarget.baselineKcal(bmrKcal: bmr, activity: .sedentary)
        XCTAssertEqual(gap, 294, accuracy: 1.0)

        let impliedSteps = gap / StepNeat.kcal(stepsAboveBaseline: 1, weightKg: weight)
        XCTAssertEqual(impliedSteps, 13_425, accuracy: 500)
        XCTAssertGreaterThan(impliedSteps, 9_000,
                             "a multiplier gap worth fewer steps than an active day would weaken the case")
    }

    func testBaselineIsBMRTimesMultiplier() {
        let bmr = CalorieTarget.mifflinBMR(sex: sex, weightKg: weight, heightCm: height, age: age)
        XCTAssertEqual(CalorieTarget.baselineKcal(bmrKcal: bmr, activity: .sedentary),
                       bmr * 1.2, accuracy: 0.01)
    }

    // MARK: - Assembling a day

    func testDayExpenditureSumsItsParts() {
        let d = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                             activity: .sedentary, neatSteps: 6_000, workoutKcal: 150)
        XCTAssertEqual(d.bmrKcal, 1681.25, accuracy: 0.01)
        XCTAssertEqual(d.baselineKcal, 2017.5, accuracy: 0.01)
        // 6,000 × 73 × 0.0003 = 131.4
        XCTAssertEqual(d.stepNeatKcal, 131.4, accuracy: 0.01)
        XCTAssertEqual(d.workoutKcal, 150)
        XCTAssertEqual(d.totalKcal, 2017.5 + 131.4 + 150, accuracy: 0.01)
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

// MARK: - The measured baseline, and the double-count it must not cause

/// Replacing the modelled baseline with a measured one is the point of closing the loop, and the way to
/// get it wrong is arithmetic rather than plumbing: a measured average TDEE already contains its window's
/// average activity, so adding today's activity on top charges the average twice.
///
/// These are the tests that would catch that, and the first one is the whole stage in one assertion.
extension CalorieTargetTests {

    private var bmr: Double {
        CalorieTarget.mifflinBMR(sex: sex, weightKg: weight, heightCm: height, age: age)
    }

    private func expenditure(neatSteps: Int, workoutKcal: Double,
                             override: Double? = nil) -> DayExpenditure {
        CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                     activity: .sedentary, neatSteps: neatSteps,
                                     workoutKcal: workoutKcal, baselineOverrideKcal: override)
    }

    /// THE DOUBLE-COUNT GUARD. Measured TDEE of 2,400 over a window whose mean activity was 250 kcal/day
    /// gives a baseline of 2,150. Applied to a day whose activity is ALSO 250, the total must come back to
    /// exactly 2,400 — the measured figure, reproduced. If activity were being counted twice this reads
    /// 2,650.
    func testAMeasuredBaselineReproducesTheMeasuredFigureOnAnAverageDay() throws {
        let measuredTdee = 2_400.0
        // 2,000 steps above baseline at 73 kg = 2,000 × 73 × 0.0003 = 43.8; plus a 206.2 kcal workout
        // makes the day's activity exactly 250.
        let neatSteps = 2_000
        let stepKcal = StepNeat.kcal(stepsAboveBaseline: neatSteps, weightKg: weight)
        let workoutKcal = 250 - stepKcal
        let meanActivity = 250.0

        let baseline = try XCTUnwrap(CalorieTarget.measuredBaseline(measuredTdeeKcal: measuredTdee,
                                                                   meanActivityKcal: meanActivity))
        XCTAssertEqual(baseline, 2_150, accuracy: 0.01)

        let day = expenditure(neatSteps: neatSteps, workoutKcal: workoutKcal, override: baseline)
        XCTAssertEqual(day.totalKcal, measuredTdee, accuracy: 0.01,
                       "an average day must reproduce the measured figure, not exceed it")
        XCTAssertEqual(day.activityKcal, meanActivity, accuracy: 0.01)
    }

    /// The other half: a day with MORE activity than the window average must exceed the measured figure by
    /// exactly the extra, not by the extra plus a re-charged average.
    func testABusierDayExceedsTheMeasuredFigureByExactlyTheExtra() throws {
        let baseline = try XCTUnwrap(CalorieTarget.measuredBaseline(measuredTdeeKcal: 2_400,
                                                                   meanActivityKcal: 250))
        let average = expenditure(neatSteps: 2_000, workoutKcal: 250 - StepNeat.kcal(stepsAboveBaseline: 2_000, weightKg: weight), override: baseline)
        let busier = expenditure(neatSteps: 6_000, workoutKcal: 250 - StepNeat.kcal(stepsAboveBaseline: 2_000, weightKg: weight), override: baseline)

        let extraSteps = StepNeat.kcal(stepsAboveBaseline: 6_000, weightKg: weight)
                       - StepNeat.kcal(stepsAboveBaseline: 2_000, weightKg: weight)
        XCTAssertEqual(busier.totalKcal - average.totalKcal, extraSteps, accuracy: 0.01)
    }

    /// The budget must still MOVE with the day once an override is live. This is the regression that would
    /// undo the fix that made the budget track the day's steps, and it would look like the feature working.
    func testTheBudgetStillRisesWithStepsUnderAnOverride() throws {
        let baseline = try XCTUnwrap(CalorieTarget.measuredBaseline(measuredTdeeKcal: 2_400,
                                                                   meanActivityKcal: 250))
        let quiet = expenditure(neatSteps: 0, workoutKcal: 0, override: baseline)
        let active = expenditure(neatSteps: 5_000, workoutKcal: 0, override: baseline)
        XCTAssertGreaterThan(active.budgetKcal(deficitKcal: 169), quiet.budgetKcal(deficitKcal: 169))
    }

    // MARK: - The override replaces only the baseline

    func testAnOverrideReplacesTheBaselineAndLeavesBMRReported() {
        let day = expenditure(neatSteps: 0, workoutKcal: 0, override: 2_150)
        XCTAssertEqual(day.baselineKcal, 2_150, accuracy: 0.01)
        // BMR is still the measured-model figure: it is reported for the screen's working, and an override
        // is a statement about the baseline, not about resting metabolism.
        XCTAssertEqual(day.bmrKcal, bmr, accuracy: 0.01)
    }

    func testNoOverrideLeavesTheModelExactlyAsItWas() {
        let withNil = expenditure(neatSteps: 3_000, workoutKcal: 100, override: nil)
        let legacy = CalorieTarget.dayExpenditure(sex: sex, weightKg: weight, heightCm: height, age: age,
                                                  activity: .sedentary, neatSteps: 3_000,
                                                  workoutKcal: 100)
        XCTAssertEqual(withNil, legacy, "the new parameter must be inert when absent")
    }

    // MARK: - The sanity floor

    /// A measured baseline below resting metabolism is a food log missing meals, not a slow metabolism.
    /// Acting on it would hand out a starvation budget built from the user's own bad data.
    func testAnOverrideBelowBMRIsRefusedNotClamped() {
        let day = expenditure(neatSteps: 0, workoutKcal: 0, override: bmr - 300)
        XCTAssertEqual(day.baselineKcal, CalorieTarget.baselineKcal(bmrKcal: bmr, activity: .sedentary),
                       accuracy: 0.01, "a sub-BMR override must fall back to the model, not clamp to BMR")
        XCTAssertNil(CalorieTarget.sanitisedBaselineOverride(bmr - 1, bmrKcal: bmr))
        XCTAssertNotNil(CalorieTarget.sanitisedBaselineOverride(bmr, bmrKcal: bmr))
    }

    func testNonFiniteOverridesAreRefused() {
        XCTAssertNil(CalorieTarget.sanitisedBaselineOverride(.nan, bmrKcal: bmr))
        XCTAssertNil(CalorieTarget.sanitisedBaselineOverride(.infinity, bmrKcal: bmr))
        XCTAssertNil(CalorieTarget.sanitisedBaselineOverride(nil, bmrKcal: bmr))
    }

    // MARK: - Deriving it

    func testDerivationRefusesNonsenseInput() {
        XCTAssertNil(CalorieTarget.measuredBaseline(measuredTdeeKcal: .nan, meanActivityKcal: 250))
        XCTAssertNil(CalorieTarget.measuredBaseline(measuredTdeeKcal: 2_400, meanActivityKcal: .nan))
        XCTAssertNil(CalorieTarget.measuredBaseline(measuredTdeeKcal: 2_400, meanActivityKcal: -10))
        // Activity exceeding the whole measured spend cannot be right, and a negative baseline is not a
        // number to carry forward.
        XCTAssertNil(CalorieTarget.measuredBaseline(measuredTdeeKcal: 200, meanActivityKcal: 500))
    }

    /// A window with no activity at all leaves the measured figure untouched — the subtraction is of a real
    /// quantity, not a fudge factor.
    func testZeroActivityWindowLeavesTheFigureAlone() {
        XCTAssertEqual(CalorieTarget.measuredBaseline(measuredTdeeKcal: 2_400, meanActivityKcal: 0) ?? .nan,
                       2_400, accuracy: 0.01)
    }
}
