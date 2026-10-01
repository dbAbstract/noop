import XCTest
@testable import StrandAnalytics

/// Dividing a calorie budget into macros. The thing these guard is that the three figures always add up
/// to the budget they came from — a set that silently over- or under-spends would have the user chasing
/// targets that cannot all be met.
final class MacroTargetsTests: XCTestCase {

    private let weight = 73.0

    // MARK: - Protein

    /// The reference case: 1.2 g/kg at 73 kg.
    func testProteinScalesWithWeightAndRate() {
        let t = MacroTargets.targets(budgetKcal: 2150, weightKg: weight, proteinGPerKg: 1.2)
        XCTAssertEqual(t.proteinG, 87.6, accuracy: 0.01)

        let heavier = MacroTargets.targets(budgetKcal: 2150, weightKg: 100, proteinGPerKg: 1.2)
        XCTAssertEqual(heavier.proteinG, 120, accuracy: 0.01)
    }

    /// The default is deliberately below the usually-quoted 1.6–2.2: that range comes from studies on
    /// people training several times a week, and prescribing it to someone lifting once a fortnight
    /// would be applying a result outside its population.
    func testDefaultRateIsTheLowerTrainingVolumeFigure() {
        XCTAssertEqual(MacroTargets.defaultProteinGPerKg, 1.2)
        XCTAssertLessThan(MacroTargets.defaultProteinGPerKg, 1.6)
    }

    func testRateIsClampedToTheSliderRange() {
        XCTAssertEqual(MacroTargets.clampedProteinRate(0.1), MacroTargets.minProteinGPerKg)
        XCTAssertEqual(MacroTargets.clampedProteinRate(5.0), MacroTargets.maxProteinGPerKg)
        XCTAssertEqual(MacroTargets.clampedProteinRate(1.4), 1.4)
    }

    /// A NaN rate must not become a NaN gram target — it falls back to the default instead.
    func testNonFiniteRateFallsBackToTheDefault() {
        XCTAssertEqual(MacroTargets.clampedProteinRate(.nan), MacroTargets.defaultProteinGPerKg)
    }

    // MARK: - Fat floor

    func testFatFloorScalesWithWeight() {
        let t = MacroTargets.targets(budgetKcal: 2150, weightKg: weight)
        XCTAssertEqual(t.fatFloorG, 51.1, accuracy: 0.01)   // 0.7 × 73
    }

    /// The floor does not move with the budget — it is a physiological minimum, not a share of intake.
    func testFatFloorIsIndependentOfTheBudget() {
        let lean = MacroTargets.targets(budgetKcal: 1500, weightKg: weight)
        let generous = MacroTargets.targets(budgetKcal: 3000, weightKg: weight)
        XCTAssertEqual(lean.fatFloorG, generous.fatFloorG, accuracy: 1e-9)
    }

    // MARK: - Carbs as the remainder

    /// The invariant that matters: the three targets spend exactly the budget, no more and no less.
    func testTargetsSpendExactlyTheBudget() {
        let t = MacroTargets.targets(budgetKcal: 2150, weightKg: weight, proteinGPerKg: 1.2)
        let spent = t.proteinG * 4 + t.fatFloorG * 9 + t.carbsG * 4
        XCTAssertEqual(spent, 2150, accuracy: 0.01)
        XCTAssertFalse(t.isOverCommitted)
    }

    /// Training raises the budget, and the extra lands in carbs — protein and fat are set by bodyweight,
    /// so there is nowhere else for it to go.
    func testExtraBudgetGoesEntirelyToCarbs() {
        let base = MacroTargets.targets(budgetKcal: 2150, weightKg: weight)
        let trained = MacroTargets.targets(budgetKcal: 2150 + 400, weightKg: weight)
        XCTAssertEqual(trained.proteinG, base.proteinG, accuracy: 1e-9)
        XCTAssertEqual(trained.fatFloorG, base.fatFloorG, accuracy: 1e-9)
        XCTAssertEqual(trained.carbsG - base.carbsG, 100, accuracy: 0.01)   // 400 kcal ÷ 4
    }

    /// A budget too small for protein plus the fat floor is a real conflict between the deficit and the
    /// protein rate. Carbs floor at zero AND the conflict is flagged, because 0 g of carbs on its own
    /// looks like a rounding artefact rather than a plan that does not fit.
    func testOverCommittedBudgetIsFlaggedNotHidden() {
        let t = MacroTargets.targets(budgetKcal: 600, weightKg: weight, proteinGPerKg: 2.0)
        XCTAssertEqual(t.carbsG, 0)
        XCTAssertTrue(t.isOverCommitted)
    }

    func testAnExactlyConsumedBudgetIsNotOverCommitted() {
        // protein 2.0 g/kg (146 g = 584) + fat floor (51.1 g = 459.9) = 1043.9 kcal
        let t = MacroTargets.targets(budgetKcal: 1043.9, weightKg: weight, proteinGPerKg: 2.0)
        XCTAssertEqual(t.carbsG, 0, accuracy: 0.01)
        XCTAssertFalse(t.isOverCommitted, "spending the budget exactly is not over-committing it")
    }

    // MARK: - Degenerate input

    func testNonsenseInputYieldsZerosRatherThanNaN() {
        for (b, w) in [(0.0, 73.0), (-500.0, 73.0), (2150.0, 0.0), (Double.nan, 73.0)] {
            let t = MacroTargets.targets(budgetKcal: b, weightKg: w)
            XCTAssertEqual(t.proteinG, 0)
            XCTAssertEqual(t.fatFloorG, 0)
            XCTAssertEqual(t.carbsG, 0)
            XCTAssertFalse(t.isOverCommitted)
        }
    }

    // MARK: - Progress

    func testFractionIsClampedToZeroAndOne() {
        XCTAssertEqual(MacroTargets.fraction(consumed: 44, target: 88), 0.5)
        XCTAssertEqual(MacroTargets.fraction(consumed: 200, target: 88), 1)
        XCTAssertEqual(MacroTargets.fraction(consumed: -5, target: 88), 0)
    }

    /// "No target" must be distinguishable from "none eaten": on a bar they look identical and mean
    /// opposite things.
    func testFractionIsNilWithoutATarget() {
        XCTAssertNil(MacroTargets.fraction(consumed: 50, target: 0))
        XCTAssertNil(MacroTargets.fraction(consumed: 50, target: .nan))
    }

    // MARK: - Shared constants

    /// The split must use the SAME Atwater factors the rest of the app converts with, or a target and
    /// the intake measured against it would be denominated differently.
    func testUsesTheSharedAtwaterFactors() {
        let t = MacroTargets.targets(budgetKcal: 2000, weightKg: weight)
        let spent = t.proteinG * NutritionMath.kcalPerGramProtein
                  + t.fatFloorG * NutritionMath.kcalPerGramFat
                  + t.carbsG * NutritionMath.kcalPerGramCarbs
        XCTAssertEqual(spent, 2000, accuracy: 0.01)
    }
}
