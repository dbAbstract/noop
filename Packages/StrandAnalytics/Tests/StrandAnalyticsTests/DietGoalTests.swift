import XCTest
@testable import StrandAnalytics

/// A goal is stated as a destination and a timeline; the deficit is derived. These pin the derivation and
/// the two guardrails — the pace band, and the BMI floor on the destination itself.
final class DietGoalTests: XCTestCase {

    // The user this was built for: 73 kg, 173 cm, aiming at 69 kg.
    private let start = 73.0
    private let target = 69.0
    private let height = 173.0

    private func plan(_ months: Int, from: Double? = nil, to: Double? = nil) -> DietGoalPlan? {
        guard case .success(let p) = DietGoal.plan(startWeightKg: from ?? start,
                                                   targetWeightKg: to ?? target,
                                                   heightCm: height, months: months) else { return nil }
        return p
    }

    // MARK: - The derivation

    /// 4 kg over six months. The headline case the whole feature was specced around.
    func testSixMonthPlanDerivesTheExpectedDeficit() throws {
        let p = try XCTUnwrap(plan(6))
        XCTAssertEqual(p.kgToLose, 4.0, accuracy: 1e-9)
        // 4 kg / 182.64 days × 7 = 0.153 kg/week
        XCTAssertEqual(p.kgPerWeek, 0.1533, accuracy: 0.001)
        // 4 × 7700 / 182.64 = 168.6 kcal/day
        XCTAssertEqual(p.dailyDeficitKcal, 168.6, accuracy: 0.5)
        XCTAssertEqual(p.rate, .gradual)
        XCTAssertTrue(p.isAllowed)
    }

    /// Halving the timeline doubles the deficit — the relationship the slider is teaching.
    func testDeficitScalesInverselyWithTimeline() throws {
        let six = try XCTUnwrap(plan(6))
        let three = try XCTUnwrap(plan(3))
        XCTAssertEqual(three.dailyDeficitKcal, six.dailyDeficitKcal * 2, accuracy: 1.0)
    }

    func testTwelveMonthsIsVeryGradual() throws {
        let p = try XCTUnwrap(plan(12))
        XCTAssertEqual(p.dailyDeficitKcal, 84.3, accuracy: 0.5)
        XCTAssertEqual(p.rate, .gradual)
    }

    // MARK: - Pace bands

    /// One month for 4 kg is ~0.92 kg/week on a 73 kg frame — 1.26%/week, past the 1% ceiling.
    func testOneMonthForFourKilosIsUnsafe() throws {
        let p = try XCTUnwrap(plan(1))
        XCTAssertEqual(p.rate, .unsafe)
        XCTAssertFalse(p.isAllowed, "an unsafe pace must not be committable")
    }

    /// The middle band exists so a push does not read the same as a crash. Two months for 4 kg is
    /// ~0.63%/week: past gradual, inside the ceiling.
    func testTwoMonthsIsAggressiveButAllowed() throws {
        let p = try XCTUnwrap(plan(2))
        XCTAssertEqual(p.rate, .aggressive)
        XCTAssertTrue(p.isAllowed, "aggressive is the user's call, not a refusal")
    }

    /// The bands are defined on PERCENT of bodyweight, not absolute kilos — the same weekly loss is
    /// gentle on a large frame and severe on a small one.
    func testBandsScaleWithBodyweight() throws {
        // 4 kg in 2 months is aggressive at 73 kg...
        XCTAssertEqual(try XCTUnwrap(plan(2)).rate, .aggressive)
        // ...and merely gradual for someone at 120 kg losing the same 4 kg in the same time.
        let heavy = try XCTUnwrap(plan(2, from: 120, to: 116))
        XCTAssertEqual(heavy.rate, .gradual)
    }

    // MARK: - The destination

    func testTargetAboveOrEqualToCurrentIsRejected() {
        guard case .failure(let a) = DietGoal.plan(startWeightKg: 73, targetWeightKg: 75,
                                                   heightCm: height, months: 6) else {
            return XCTFail("gaining weight is not a loss plan")
        }
        XCTAssertEqual(a, .notALoss)
        guard case .failure(let b) = DietGoal.plan(startWeightKg: 73, targetWeightKg: 73,
                                                   heightCm: height, months: 6) else {
            return XCTFail("no change is not a loss plan")
        }
        XCTAssertEqual(b, .notALoss)
    }

    /// The hard floor. At 173 cm, BMI 18.5 is ~55.4 kg — a target under it is refused outright, however
    /// gentle the timeline.
    func testTargetBelowHealthyBMIIsRejectedRegardlessOfPace() {
        guard case .failure(let r) = DietGoal.plan(startWeightKg: 73, targetWeightKg: 45,
                                                   heightCm: height, months: 12) else {
            return XCTFail("an underweight destination must be refused")
        }
        XCTAssertEqual(r, .belowHealthyBMI)
    }

    func testMinTargetWeightMatchesTheBMIFloor() throws {
        let floor = try XCTUnwrap(DietGoal.minTargetWeightKg(heightCm: height))
        XCTAssertEqual(floor, 55.36, accuracy: 0.05)
        // A target one gram above the floor is acceptable; the floor itself is inclusive.
        XCTAssertEqual(DietGoal.bmi(weightKg: floor, heightCm: height), 18.5, accuracy: 1e-6)
    }

    func testInvalidInputIsRejectedRatherThanComputed() {
        for (w, t, h, m) in [(0.0, 69.0, 173.0, 6), (73.0, 0.0, 173.0, 6),
                             (73.0, 69.0, 0.0, 6), (73.0, 69.0, 173.0, 0),
                             (Double.nan, 69.0, 173.0, 6)] {
            guard case .failure(let r) = DietGoal.plan(startWeightKg: w, targetWeightKg: t,
                                                       heightCm: h, months: m) else {
                return XCTFail("(\(w), \(t), \(h), \(m)) should not produce a plan")
            }
            XCTAssertEqual(r, .invalidInput)
        }
    }

    // MARK: - Slider support

    /// The slider marks where the unsafe region starts rather than only refusing once you are inside it.
    func testFastestSafeMonthsFindsTheBoundary() throws {
        let fastest = try XCTUnwrap(DietGoal.fastestSafeMonths(startWeightKg: start,
                                                               targetWeightKg: target,
                                                               heightCm: height))
        XCTAssertEqual(fastest, 2)
        XCTAssertTrue(try XCTUnwrap(plan(fastest)).isAllowed)
        XCTAssertFalse(try XCTUnwrap(plan(fastest - 1)).isAllowed,
                       "the month before the boundary must be the unsafe one")
    }

    /// A goal that cannot be reached safely inside the slider's range has no boundary to mark.
    func testFastestSafeMonthsIsNilWhenUnreachableInRange() {
        // 30 kg off a 73 kg frame cannot be done at ≤1%/week within twelve months.
        XCTAssertNil(DietGoal.fastestSafeMonths(startWeightKg: 73, targetWeightKg: 43,
                                                heightCm: height, maxMonths: 12))
    }

    // MARK: - Shared constant

    /// The conversion must be the SAME one the expenditure engine reads loss back out with, or the app
    /// would predict against one constant and measure itself against another.
    func testKcalPerKgMatchesTheExpenditureEngine() {
        XCTAssertEqual(DietGoal.kcalPerKg, AdaptiveExpenditureEngine.kcalPerKg)
    }
}
