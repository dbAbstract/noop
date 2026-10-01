import XCTest
@testable import StrandAnalytics

/// Composing a recipe from its ingredients. The one these are really about is
/// `testMissingIngredientRefusesTheTotal` — everything else is arithmetic, that one is a claim about
/// honesty.
final class RecipeMathTests: XCTestCase {

    // One scoop of whey: 120 kcal, 24P, 3C, 1.5F.
    private let whey = MacroTotals(kcal: 120, protein: 24, carbs: 3, fat: 1.5, fiber: 0)
    // 100 ml of oat milk: 45 kcal, 1P, 7C, 1.5F.
    private let oatMilk = MacroTotals(kcal: 45, protein: 1, carbs: 7, fat: 1.5, fiber: 0.8)
    // A banana: 105 kcal, 1.3P, 27C, 0.4F, 3.1 fibre.
    private let banana = MacroTotals(kcal: 105, protein: 1.3, carbs: 27, fat: 0.4, fiber: 3.1)

    private func part(_ m: MacroTotals, _ q: Double) -> RecipePart {
        RecipePart(macrosPerServing: m, quantity: q)
    }

    // MARK: - Composing

    /// The worked example: 1 scoop whey + 3×100 ml oat milk + 1 banana.
    func testComponentMacrosSum() {
        let m = RecipeMath.compose([part(whey, 1), part(oatMilk, 3), part(banana, 1)])
        XCTAssertEqual(m.kcal, 120 + 135 + 105, accuracy: 0.01)        // 360
        XCTAssertEqual(m.protein, 24 + 3 + 1.3, accuracy: 0.01)        // 28.3
        XCTAssertEqual(m.carbs, 3 + 21 + 27, accuracy: 0.01)           // 51
        XCTAssertEqual(m.fat, 1.5 + 4.5 + 0.4, accuracy: 0.01)         // 6.4
        XCTAssertEqual(m.fiber, 0 + 2.4 + 3.1, accuracy: 0.01)         // 5.5
    }

    /// A fractional quantity is the common case for a recipe (half an avocado), not an edge case.
    func testFractionalQuantitiesScale() {
        let m = RecipeMath.compose([part(banana, 0.5)])
        XCTAssertEqual(m.kcal, 52.5, accuracy: 0.01)
        XCTAssertEqual(m.carbs, 13.5, accuracy: 0.01)
    }

    func testEmptyRecipeComposesToZero() {
        let m = RecipeMath.compose([])
        XCTAssertEqual(m.kcal, 0)
        XCTAssertEqual(m.protein, 0)
    }

    /// The recipe must divide its parts with the SAME helper a logged portion uses, or a recipe's total
    /// and the entry it becomes could disagree about what "×2" means.
    func testUsesTheSharedScalingHelper() {
        let viaRecipe = RecipeMath.compose([part(whey, 2)])
        let viaPortion = NutritionMath.scaled(whey, portion: 2)
        XCTAssertEqual(viaRecipe, viaPortion)
    }

    /// A nonsense quantity must be handled identically to a nonsense logged portion — same helper, so
    /// this pins the consequence rather than a second rule.
    func testNonsenseQuantityMatchesTheLoggedPortionRule() {
        for q in [Double.nan, -1, .infinity] {
            XCTAssertEqual(RecipeMath.compose([part(whey, q)]),
                           NutritionMath.total([NutritionMath.scaled(whey, portion: q)]),
                           "quantity \(q) must behave as a logged portion of \(q) does")
        }
    }

    func testPartsBeyondTheCeilingAreIgnoredRatherThanSummed() {
        let many = Array(repeating: part(whey, 1), count: RecipeMath.maxParts + 50)
        let m = RecipeMath.compose(many)
        XCTAssertEqual(m.kcal, 120 * Double(RecipeMath.maxParts), accuracy: 0.01)
    }

    // MARK: - Resolving against a library

    func testResolveLooksUpAndSums() {
        let library = ["whey": whey, "oat": oatMilk, "banana": banana]
        let c = RecipeMath.resolve(componentIds: ["whey", "oat", "banana"],
                                  quantities: [1, 3, 1]) { library[$0] }
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.resolvedCount, 3)
        XCTAssertEqual(c.macros?.kcal ?? .nan, 360, accuracy: 0.01)
    }

    /// THE IMPORTANT ONE. Deleting the banana must not make the shake look like a 255 kcal food. An
    /// absent total and a smaller total are different claims, and a partial sum is the dishonest one —
    /// it is indistinguishable from a correct answer.
    func testMissingIngredientRefusesTheTotal() {
        let library = ["whey": whey, "oat": oatMilk]   // banana deleted
        let c = RecipeMath.resolve(componentIds: ["whey", "oat", "banana"],
                                  quantities: [1, 3, 1]) { library[$0] }
        XCTAssertNil(c.macros, "a total missing an ingredient must be refused, not computed without it")
        XCTAssertFalse(c.isComplete)
        XCTAssertEqual(c.missingIngredientIds, ["banana"])
        // The parts that DID resolve are still counted, so a caller can say "2 of 3 ingredients found"
        // rather than only that something is wrong.
        XCTAssertEqual(c.resolvedCount, 2)
    }

    func testEveryMissingIngredientIsReportedNotJustTheFirst() {
        let c = RecipeMath.resolve(componentIds: ["a", "b", "c"], quantities: [1, 1, 1]) { _ in nil }
        XCTAssertEqual(c.missingIngredientIds, ["a", "b", "c"])
        XCTAssertEqual(c.resolvedCount, 0)
    }

    /// An empty recipe is complete at zero — it is being built, not broken. Distinct from the missing
    /// case on purpose: one is a blank slate, the other is a wrong number.
    func testEmptyRecipeIsCompleteNotMissing() {
        let c = RecipeMath.resolve(componentIds: [], quantities: []) { _ in nil }
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.macros?.kcal ?? .nan, 0, accuracy: 1e-9)
    }

    /// Order is what the user arranged, so it must survive the lookup.
    func testOrderIsPreserved() {
        let c = RecipeMath.resolve(componentIds: ["z", "y"], quantities: [2, 1]) { _ in nil }
        XCTAssertEqual(c.missingIngredientIds, ["z", "y"])
    }

    /// A quantities array shorter than the ids must not crash or silently pair the wrong numbers.
    func testShortQuantitiesArrayDegradesToZeroForTheExtras() {
        let c = RecipeMath.resolve(componentIds: ["whey", "whey"], quantities: [1]) { _ in self.whey }
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.macros?.kcal ?? .nan, 120, accuracy: 0.01)   // second part contributes nothing
    }

    // MARK: - Editing rules

    /// Zero is rejected alongside the negatives: an ingredient at zero servings is a deletion wearing an
    /// edit's clothes, and leaving the row in place means a list the total does not reflect.
    func testZeroQuantityIsNotValid() {
        XCTAssertFalse(RecipeMath.isValidQuantity(0))
        XCTAssertFalse(RecipeMath.isValidQuantity(-1))
        XCTAssertFalse(RecipeMath.isValidQuantity(.nan))
        XCTAssertFalse(RecipeMath.isValidQuantity(.infinity))
        XCTAssertTrue(RecipeMath.isValidQuantity(0.25))
        XCTAssertTrue(RecipeMath.isValidQuantity(1))
    }

    func testQuantityCeilingIsInclusive() {
        XCTAssertTrue(RecipeMath.isValidQuantity(1_000))
        XCTAssertFalse(RecipeMath.isValidQuantity(1_001))
    }

    /// Dense ordinals, because gaps left by deletions accumulate until two ingredients collide on one
    /// value and `ORDER BY ord` stops preserving the arrangement.
    func testRenumberingIsDenseAndAscending() {
        XCTAssertEqual(RecipeMath.renumbered(3), [0, 1, 2])
        XCTAssertEqual(RecipeMath.renumbered(0), [])
        XCTAssertEqual(RecipeMath.renumbered(-5), [])
    }
}
