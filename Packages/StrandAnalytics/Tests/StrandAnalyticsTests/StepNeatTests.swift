import XCTest
@testable import StrandAnalytics

/// Energy from ordinary walking — the band NOOP's 50% heart-rate-reserve gate discards. These pin the two
/// subtractions that stop it being counted twice.
final class StepNeatTests: XCTestCase {

    private let weight = 73.0

    // MARK: - Which steps count

    func testBaselineIsSubtracted() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: 0), 6_000)
    }

    /// The baseline is 4,000, not a lower "obviously sedentary" number. Pinned as a VALUE because the
    /// evidence is specific: Tudor-Locke & Bassett class under 5,000/day as sedentary and 5,000–7,499 as
    /// low-active (no sport or exercise at all), and adult accelerometer means sit near 4,800–5,100. A
    /// lower baseline is not cautious — it credits ordinary pottering as earned movement.
    func testBaselineMatchesTheSedentaryLiterature() {
        XCTAssertEqual(StepNeat.sedentaryBaselineSteps, 4_000)
        XCTAssertGreaterThanOrEqual(StepNeat.sedentaryBaselineSteps, 3_500,
                                    "below this the baseline no longer describes a sedentary day")
    }

    /// Workout steps are removed before the baseline, because heart rate has already counted them AT
    /// THEIR TRUE INTENSITY. Two thousand incline-treadmill steps and two thousand shop-walk steps are
    /// not the same energy, and a flat per-step rate cannot tell them apart.
    func testWorkoutStepsAreExcluded() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 12_000, workoutSteps: 2_000), 6_000)
    }

    /// A day quieter than baseline earns nothing. It must not go into debt against a multiplier that
    /// already assumed some movement.
    func testQuietDayFloorsAtZero() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 1_200, workoutSteps: 0), 0)
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 0, workoutSteps: 0), 0)
    }

    /// A workout claiming more steps than the day recorded is a provenance mismatch, not a negative day.
    func testWorkoutStepsExceedingTheDailyTotalFloorAtZero() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 5_000, workoutSteps: 9_000), 0)
    }

    func testNegativeInputsAreTreatedAsZeroRatherThanAdding() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: -2_000), 6_000,
                       "a negative workout count must not inflate NEAT")
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: 0, baseline: -500),
                       10_000)
    }

    func testBaselineIsTunable() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: 0, baseline: 5_000),
                       5_000)
    }

    // MARK: - Energy

    /// 6,000 × 73 × 0.0003 = 131.4 kcal — the reference figure, and the one to check a future tweak
    /// against. A 10,000-step day for this user earns 131 kcal of NEAT, not the 204 the first pass gave.
    func testReferenceDay() {
        XCTAssertEqual(StepNeat.kcal(stepsAboveBaseline: 6_000, weightKg: weight), 131.4, accuracy: 0.01)
    }

    /// The per-step rate is 0.0003, revised down from 0.0004 — pinned because the reason is easy to lose.
    /// 0.0004 derives from 2.5 net METs, i.e. DELIBERATE walking at ~4.8 km/h. The steps reaching this
    /// function have already had workouts and the sedentary baseline removed, so what is left is slow,
    /// fragmented pottering at 1.0–1.5 net METs. Pricing it as purposeful walking over-credits by ~2×.
    func testPerStepRateIsPricedAsPotteringNotPurposefulWalking() {
        XCTAssertEqual(StepNeat.netKcalPerStepPerKg, 0.0003)
        XCTAssertLessThan(StepNeat.netKcalPerStepPerKg, 0.000398,
                          "0.000398 is the purposeful-walking figure and is wrong for residual steps")
    }

    /// Scales with bodyweight — heavier costs more per step, which is why no calibration is needed.
    func testScalesWithBodyweight() {
        let light = StepNeat.kcal(stepsAboveBaseline: 6_000, weightKg: 50)
        let heavy = StepNeat.kcal(stepsAboveBaseline: 6_000, weightKg: 100)
        XCTAssertEqual(heavy, light * 2, accuracy: 0.01)
    }

    func testZeroAndNonsenseInputsYieldNothing() {
        XCTAssertEqual(StepNeat.kcal(stepsAboveBaseline: 0, weightKg: weight), 0)
        XCTAssertEqual(StepNeat.kcal(stepsAboveBaseline: -5_000, weightKg: weight), 0)
        XCTAssertEqual(StepNeat.kcal(stepsAboveBaseline: 7_000, weightKg: 0), 0)
        XCTAssertEqual(StepNeat.kcal(stepsAboveBaseline: 7_000, weightKg: .nan), 0)
    }

    // MARK: - The convenience path must agree with the explicit one

    /// The two-step and one-step forms exist so a caller cannot apply the baseline twice — the one error
    /// here that would silently under-count rather than crash. They must agree exactly.
    func testOneCallFormMatchesTheTwoCallForm() {
        let viaSteps = StepNeat.stepsAboveBaseline(dailySteps: 12_000, workoutSteps: 2_000)
        XCTAssertEqual(StepNeat.kcal(dailySteps: 12_000, workoutSteps: 2_000, weightKg: weight),
                       StepNeat.kcal(stepsAboveBaseline: viaSteps, weightKg: weight),
                       accuracy: 1e-9)
    }

    // MARK: - Sanity of the coefficient

    /// A realistic active day should land in the low hundreds of kcal. Deliberately conservative:
    /// over-crediting NEAT inflates the eating budget, which is the error that silently stalls a diet.
    func testAnActiveDayIsPlausible() {
        // 15,000 steps → 11,000 above baseline → 11,000 × 73 × 0.0003 = 240.9 kcal.
        let kcal = StepNeat.kcal(dailySteps: 15_000, workoutSteps: 0, weightKg: weight)
        XCTAssertGreaterThan(kcal, 180)
        XCTAssertLessThan(kcal, 320)
    }

    /// The whole revision in one assertion: a 10,000-step day must now credit meaningfully LESS than the
    /// original constants did. 131 kcal rather than 204 — a 73 kcal/day difference, which at this user's
    /// 169 kcal/day deficit was most of it, and is the difference between a diet that moves and one that
    /// plateaus while the app insists it is working.
    func testTheRevisedConstantsCreditLessThanTheOriginalOnes() {
        let now = StepNeat.kcal(dailySteps: 10_000, workoutSteps: 0, weightKg: weight)
        let original = Double(10_000 - 3_000) * weight * 0.0004
        XCTAssertEqual(now, 131.4, accuracy: 0.01)
        XCTAssertLessThan(now, original * 0.7, "the revision must be a real reduction, not a rounding")
    }

    /// 10k steps is the canonical "active day" and should read as a few hundred kcal, not a thousand.
    func testTenThousandStepsIsNotWildlyOverCredited() {
        XCTAssertLessThan(StepNeat.kcal(dailySteps: 10_000, workoutSteps: 0, weightKg: weight), 200)
    }
}
