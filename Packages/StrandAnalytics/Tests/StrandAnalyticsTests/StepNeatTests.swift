import XCTest
@testable import StrandAnalytics

/// Energy from ordinary walking — the band NOOP's 50% heart-rate-reserve gate discards. These pin the two
/// subtractions that stop it being counted twice.
final class StepNeatTests: XCTestCase {

    private let weight = 73.0

    // MARK: - Which steps count

    func testBaselineIsSubtracted() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: 0), 7_000)
    }

    /// Workout steps are removed before the baseline, because heart rate has already counted them AT
    /// THEIR TRUE INTENSITY. Two thousand incline-treadmill steps and two thousand shop-walk steps are
    /// not the same energy, and a flat per-step rate cannot tell them apart.
    func testWorkoutStepsAreExcluded() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 12_000, workoutSteps: 2_000), 7_000)
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
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: -2_000), 7_000,
                       "a negative workout count must not inflate NEAT")
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: 0, baseline: -500),
                       10_000)
    }

    func testBaselineIsTunable() {
        XCTAssertEqual(StepNeat.stepsAboveBaseline(dailySteps: 10_000, workoutSteps: 0, baseline: 5_000),
                       5_000)
    }

    // MARK: - Energy

    /// 7,000 × 73 × 0.0004 = 204.4 kcal — the reference figure from the design.
    func testReferenceDay() {
        XCTAssertEqual(StepNeat.kcal(stepsAboveBaseline: 7_000, weightKg: weight), 204.4, accuracy: 0.01)
    }

    /// Scales with bodyweight — heavier costs more per step, which is why no calibration is needed.
    func testScalesWithBodyweight() {
        let light = StepNeat.kcal(stepsAboveBaseline: 7_000, weightKg: 50)
        let heavy = StepNeat.kcal(stepsAboveBaseline: 7_000, weightKg: 100)
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
        let kcal = StepNeat.kcal(dailySteps: 15_000, workoutSteps: 0, weightKg: weight)
        XCTAssertGreaterThan(kcal, 250)
        XCTAssertLessThan(kcal, 450)
    }

    /// 10k steps is the canonical "active day" and should read as a few hundred kcal, not a thousand.
    func testTenThousandStepsIsNotWildlyOverCredited() {
        XCTAssertLessThan(StepNeat.kcal(dailySteps: 10_000, workoutSteps: 0, weightKg: weight), 300)
    }
}
