import XCTest
@testable import StrandAnalytics

final class NutritionMathTests: XCTestCase {

    private let chickenBreast = MacroTotals(kcal: 284, protein: 53, carbs: 0, fat: 6.2, fiber: 0)

    // MARK: - scaled

    func testScaledMultipliesEveryField() {
        let half = NutritionMath.scaled(chickenBreast, portion: 0.5)
        XCTAssertEqual(half.kcal, 142, accuracy: 1e-9)
        XCTAssertEqual(half.protein, 26.5, accuracy: 1e-9)
        XCTAssertEqual(half.carbs, 0, accuracy: 1e-9)
        XCTAssertEqual(half.fat, 3.1, accuracy: 1e-9)
    }

    func testScaledByOneIsIdentity() {
        XCTAssertEqual(NutritionMath.scaled(chickenBreast, portion: 1), chickenBreast)
    }

    /// A zero/negative/NaN portion must collapse to zero rather than store a negative or NaN day total —
    /// a NaN banked into `metricSeries` would poison every downstream mean and chart.
    func testScaledRejectsNonPositiveAndNonFinitePortions() {
        for bad in [0.0, -1.0, .nan, .infinity] {
            XCTAssertEqual(NutritionMath.scaled(chickenBreast, portion: bad), .zero,
                           "portion \(bad) should collapse to zero")
        }
    }

    func testScaledFiberCarried() {
        let oats = MacroTotals(kcal: 380, protein: 13, carbs: 67, fat: 7, fiber: 10)
        XCTAssertEqual(NutritionMath.scaled(oats, portion: 2).fiber, 20, accuracy: 1e-9)
    }

    // MARK: - total

    func testTotalSumsEveryField() {
        let t = NutritionMath.total([
            MacroTotals(kcal: 100, protein: 10, carbs: 5, fat: 2, fiber: 1),
            MacroTotals(kcal: 250, protein: 20, carbs: 30, fat: 8, fiber: 4),
        ])
        XCTAssertEqual(t.kcal, 350, accuracy: 1e-9)
        XCTAssertEqual(t.protein, 30, accuracy: 1e-9)
        XCTAssertEqual(t.carbs, 35, accuracy: 1e-9)
        XCTAssertEqual(t.fat, 10, accuracy: 1e-9)
        XCTAssertEqual(t.fiber, 5, accuracy: 1e-9)
    }

    func testTotalOfEmptyListIsZero() {
        XCTAssertEqual(NutritionMath.total([]), .zero)
    }

    /// A malformed stored entry may contribute nothing, but must never drag a day total DOWN — otherwise
    /// one bad row silently understates the day and reads as under-eating.
    func testTotalClampsNegativeAndNonFiniteContributions() {
        let t = NutritionMath.total([
            MacroTotals(kcal: 500, protein: 40, carbs: 40, fat: 15, fiber: 5),
            MacroTotals(kcal: -200, protein: -10, carbs: .nan, fat: .infinity, fiber: -3),
        ])
        XCTAssertEqual(t.kcal, 500, accuracy: 1e-9)
        XCTAssertEqual(t.protein, 40, accuracy: 1e-9)
        XCTAssertEqual(t.carbs, 40, accuracy: 1e-9)
        XCTAssertEqual(t.fat, 15, accuracy: 1e-9)
        XCTAssertEqual(t.fiber, 5, accuracy: 1e-9)
    }

    // MARK: - kcalFromMacros / consistency

    func testKcalFromMacrosUsesAtwaterAndIgnoresFiber() {
        // 20 P + 30 C + 10 F = 80 + 120 + 90 = 290. Fibre must not move it.
        let m = MacroTotals(kcal: 0, protein: 20, carbs: 30, fat: 10, fiber: 12)
        XCTAssertEqual(NutritionMath.kcalFromMacros(m), 290, accuracy: 1e-9)
    }

    func testKcalConsistencyIsSignedFractionOfStated() {
        // Macros imply 290; stated 400 → (400-290)/400 = +0.275
        let m = MacroTotals(kcal: 400, protein: 20, carbs: 30, fat: 10)
        let c = try? XCTUnwrap(NutritionMath.kcalConsistency(m))
        XCTAssertEqual(c ?? .nan, 0.275, accuracy: 1e-9)
    }

    func testKcalConsistencyNegativeWhenStatedBelowMacros() {
        // Macros imply 290; stated 200 → (200-290)/200 = -0.45
        let m = MacroTotals(kcal: 200, protein: 20, carbs: 30, fat: 10)
        XCTAssertEqual(NutritionMath.kcalConsistency(m) ?? .nan, -0.45, accuracy: 1e-9)
    }

    /// "Nothing to compare" must be distinguishable from "agrees perfectly" — a caller showing a warning
    /// needs to stay silent in the first case, not report 0% drift.
    func testKcalConsistencyNilWhenNothingToCompare() {
        XCTAssertNil(NutritionMath.kcalConsistency(MacroTotals(kcal: 0, protein: 20, carbs: 30, fat: 10)),
                     "no stated energy → nothing to check")
        XCTAssertNil(NutritionMath.kcalConsistency(MacroTotals(kcal: 300)),
                     "no macros → nothing to check")
        XCTAssertNil(NutritionMath.kcalConsistency(.zero))
    }

    func testLooksInconsistentOnlyBeyondTolerance() {
        // Macros imply 290. Within ±15% of stated → no warning.
        XCTAssertFalse(NutritionMath.kcalLooksInconsistent(
            MacroTotals(kcal: 300, protein: 20, carbs: 30, fat: 10)))
        // 400 stated vs 290 implied = +27.5% → warn.
        XCTAssertTrue(NutritionMath.kcalLooksInconsistent(
            MacroTotals(kcal: 400, protein: 20, carbs: 30, fat: 10)))
    }

    /// An unanswerable check is not a warning.
    func testLooksInconsistentFalseWhenUncheckable() {
        XCTAssertFalse(NutritionMath.kcalLooksInconsistent(MacroTotals(kcal: 300)))
        XCTAssertFalse(NutritionMath.kcalLooksInconsistent(.zero))
    }

    // MARK: - MacroTotals

    func testIsEmpty() {
        XCTAssertTrue(MacroTotals.zero.isEmpty)
        XCTAssertFalse(MacroTotals(fiber: 1).isEmpty)
        XCTAssertFalse(chickenBreast.isEmpty)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(chickenBreast)
        XCTAssertEqual(try JSONDecoder().decode(MacroTotals.self, from: data), chickenBreast)
    }
}
