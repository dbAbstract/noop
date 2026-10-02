import XCTest
@testable import StrandAnalytics

/// The food library as the coach sees it. The load-bearing part is the handle scheme: a handle the model
/// quotes back must resolve to exactly one food, or refuse. Resolving an ambiguous handle to "the first"
/// is how a near-miss becomes the wrong meal logged.
final class FoodLibraryDigestTests: XCTestCase {

    private func entry(_ id: String, _ name: String, kcal: Double = 100,
                       protein: Double = 0, serving: String = "1 serving",
                       isRecipe: Bool = false) -> FoodDigestEntry {
        FoodDigestEntry(id: id, name: name, servingLabel: serving,
                        macros: MacroTotals(kcal: kcal, protein: protein, carbs: 0, fat: 0, fiber: 0),
                        isRecipe: isRecipe)
    }

    private let oikosId = "A1B2C3D4-0000-0000-0000-000000000001"
    private let proId   = "99887766-0000-0000-0000-000000000002"

    // MARK: - Handles

    func testHandleIsAShortLowercasePrefixWithoutDashes() {
        XCTAssertEqual(FoodLibraryDigest.handle(for: oikosId), "a1b2c3d4")
        XCTAssertEqual(FoodLibraryDigest.handle(for: oikosId).count, FoodLibraryDigest.handleLength)
    }

    func testResolveFindsTheFoodByItsHandle() {
        let entries = [entry(oikosId, "Oikos yogurt"), entry(proId, "Oikos Pro Rich Vanilla")]
        XCTAssertEqual(FoodLibraryDigest.resolve(handle: "a1b2c3d4", among: entries)?.name,
                       "Oikos yogurt")
        XCTAssertEqual(FoodLibraryDigest.resolve(handle: "99887766", among: entries)?.name,
                       "Oikos Pro Rich Vanilla")
    }

    /// A model that quotes the FULL id must not be penalised for it.
    func testResolveAcceptsTheFullId() {
        let entries = [entry(oikosId, "Oikos yogurt")]
        XCTAssertEqual(FoodLibraryDigest.resolve(handle: oikosId, among: entries)?.name, "Oikos yogurt")
    }

    func testResolveIsCaseAndDashInsensitive() {
        let entries = [entry(oikosId, "Oikos yogurt")]
        XCTAssertNotNil(FoodLibraryDigest.resolve(handle: "A1B2C3D4", among: entries))
        XCTAssertNotNil(FoodLibraryDigest.resolve(handle: "a1b2-c3d4", among: entries))
        XCTAssertNotNil(FoodLibraryDigest.resolve(handle: " a1b2c3d4 ", among: entries))
    }

    /// THE ONE THAT MATTERS. Two foods sharing a prefix must refuse rather than pick one. A refusal is
    /// recoverable (no card appears, the user says it again); a wrong pick is a wrong meal in the trend.
    func testAnAmbiguousHandleRefusesRatherThanPickingTheFirst() {
        let entries = [entry("AAAA0000-0000-0000-0000-000000000001", "Yogurt A"),
                       entry("AAAA0000-0000-0000-0000-000000000002", "Yogurt B")]
        XCTAssertNil(FoodLibraryDigest.resolve(handle: "aaaa0000", among: entries),
                     "two foods share this handle — picking either would be a guess")
    }

    func testAnUnknownHandleResolvesToNothing() {
        let entries = [entry(oikosId, "Oikos yogurt")]
        XCTAssertNil(FoodLibraryDigest.resolve(handle: "deadbeef", among: entries))
        XCTAssertNil(FoodLibraryDigest.resolve(handle: "", among: entries))
        XCTAssertNil(FoodLibraryDigest.resolve(handle: "   ", among: entries))
    }

    /// A model that truncates the handle must still resolve while it stays unambiguous — and must stop
    /// resolving the moment it does not.
    func testAShorterPrefixResolvesOnlyWhileItIsUnique() {
        let one = [entry(oikosId, "Oikos yogurt")]
        XCTAssertNotNil(FoodLibraryDigest.resolve(handle: "a1b2", among: one))

        let two = one + [entry("A1B2FFFF-0000-0000-0000-000000000003", "Other")]
        XCTAssertNil(FoodLibraryDigest.resolve(handle: "a1b2", among: two))
    }

    // MARK: - The block

    func testBlockListsHandleNameServingAndCalories() {
        let block = FoodLibraryDigest.block(entries: [
            entry(oikosId, "Oikos yogurt", kcal: 95, protein: 10, serving: "100 g")
        ])
        XCTAssertTrue(block.contains("a1b2c3d4"))
        XCTAssertTrue(block.contains("Oikos yogurt"))
        XCTAssertTrue(block.contains("per 100 g"))
        XCTAssertTrue(block.contains("95 kcal"))
        XCTAssertTrue(block.contains("10P"))
    }

    func testAnEmptyLibraryProducesNoBlockAtAll() {
        XCTAssertEqual(FoodLibraryDigest.block(entries: []), "")
    }

    /// A quick-added kcal-only food has no macros, and printing "0P 0C 0F" would invite the model to
    /// state those zeros back as though they had been measured.
    func testZeroMacrosAreOmittedRatherThanPrintedAsZero() {
        let block = FoodLibraryDigest.block(entries: [entry(oikosId, "Mystery pastry", kcal: 300)])
        XCTAssertTrue(block.contains("300 kcal"))
        XCTAssertFalse(block.contains("0P"))
        XCTAssertFalse(block.contains("0C"))
    }

    func testARecipeIsLabelledAsOne() {
        let block = FoodLibraryDigest.block(entries: [
            entry(oikosId, "Protein shake", kcal: 360, isRecipe: true)
        ])
        XCTAssertTrue(block.contains("recipe"))
    }

    /// THE CAP MUST BE AUDIBLE. A model that believes it has the whole library will confidently propose
    /// creating a duplicate of a food that is merely out of frame.
    func testTruncationIsStatedNotSilent() {
        let many = (0..<(FoodLibraryDigest.maxEntries + 7)).map {
            entry(String(format: "%08X-0000-0000-0000-000000000000", $0), "Food \($0)")
        }
        let block = FoodLibraryDigest.block(entries: many)
        XCTAssertTrue(block.contains("7 older foods not listed"),
                      "a silent truncation reads as 'this is everything'")
        XCTAssertTrue(block.contains("ask before assuming it is new"))
    }

    func testTheBlockHonoursTheOrderItWasGiven() {
        let block = FoodLibraryDigest.block(entries: [entry(oikosId, "First"), entry(proId, "Second")])
        let firstPos = block.range(of: "First")!.lowerBound
        let secondPos = block.range(of: "Second")!.lowerBound
        XCTAssertLessThan(firstPos, secondPos, "recency order is what makes a truncated head useful")
    }

    func testTheBlockCapsTheNumberOfListedFoods() {
        let many = (0..<200).map {
            entry(String(format: "%08X-0000-0000-0000-000000000000", $0), "Food \($0)")
        }
        let listed = FoodLibraryDigest.block(entries: many)
            .split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(listed.count, FoodLibraryDigest.maxEntries)
    }

    // MARK: - Today's line

    func testTodayLineStatesWhatIsLeft() {
        let line = FoodLibraryDigest.todayLine(consumedKcal: 1200, budgetKcal: 1950,
                                               proteinG: 60, proteinTargetG: 88)
        XCTAssertTrue(line.contains("1200 kcal eaten"))
        XCTAssertTrue(line.contains("1950 kcal budget"))
        XCTAssertTrue(line.contains("750 left"))
        XCTAssertTrue(line.contains("60 g of 88 g"))
    }

    func testTodayLineSaysOverRatherThanNegativeRemaining() {
        let line = FoodLibraryDigest.todayLine(consumedKcal: 2100, budgetKcal: 1950,
                                               proteinG: 90, proteinTargetG: 88)
        XCTAssertTrue(line.contains("150 over"))
        XCTAssertFalse(line.contains("-150"))
    }

    /// With no goal there is no budget, and the line must not invent one.
    func testTodayLineOmitsTheBudgetWhenThereIsNone() {
        let line = FoodLibraryDigest.todayLine(consumedKcal: 800, budgetKcal: nil,
                                               proteinG: 40, proteinTargetG: nil)
        XCTAssertTrue(line.contains("800 kcal eaten"))
        XCTAssertFalse(line.contains("budget of"))
        XCTAssertFalse(line.contains("left"))
    }

    /// The budget moves with the day. Saying so stops the coach presenting it as a fixed allowance the
    /// user has already blown.
    func testTodayLineSaysTheBudgetIsNotFixed() {
        let line = FoodLibraryDigest.todayLine(consumedKcal: 100, budgetKcal: 2000,
                                               proteinG: 10, proteinTargetG: 88)
        XCTAssertTrue(line.contains("not fixed"))
    }
}


// MARK: - The blocks that were missing

/// The coach knew the library and the day's totals but not what the day CONSISTED of, nor the weight
/// trend, nor a recipe's parts. These pin the blocks that closed those gaps.
extension FoodLibraryDigestTests {

    private func macros(_ kcal: Double, _ p: Double = 0, _ c: Double = 0, _ f: Double = 0) -> MacroTotals {
        MacroTotals(kcal: kcal, protein: p, carbs: c, fat: f, fiber: 0)
    }

    func testEatenBlockNamesEachMealAndItsSubtotal() {
        let block = FoodLibraryDigest.eatenBlock(day: "today", groups: [
            (meal: "LUNCH",
             items: [(name: "Chicken katsu", portion: 1, macros: macros(610, 34, 72, 22))],
             total: macros(610)),
            (meal: "DINNER",
             items: [(name: "Salmon", portion: 1.5, macros: macros(680, 48, 64, 24))],
             total: macros(680)),
        ])
        XCTAssertTrue(block.contains("LUNCH"))
        XCTAssertTrue(block.contains("610 kcal"))
        XCTAssertTrue(block.contains("Chicken katsu"))
        XCTAssertTrue(block.contains("34P"))
        // A non-unit portion must be stated, or the coach reads the scaled macros against one serving.
        XCTAssertTrue(block.contains("1.5"))
    }

    /// An empty day says so explicitly. Omitting the block would let the coach assume it simply was not
    /// given the data and ask what the user has eaten — the exact question this block exists to answer.
    func testAnEmptyDaySaysNothingLoggedRatherThanGoingAbsent() {
        let block = FoodLibraryDigest.eatenBlock(day: "today", groups: [])
        XCTAssertTrue(block.contains("nothing logged"))
    }

    func testEatenBlockCapsALongDayAndSaysSo() {
        let items = (0..<40).map { (name: "Snack \($0)", portion: 1.0, macros: macros(50)) }
        let block = FoodLibraryDigest.eatenBlock(day: "today", groups: [
            (meal: "SNACKS", items: items, total: macros(2_000)),
        ], maxItems: 5)
        XCTAssertTrue(block.contains("35 more not listed"))
    }

    // MARK: - Targets

    func testTargetsLineCarriesAllThreeAndNamesWhichIsAFloor() {
        let t = MacroTargets.targets(budgetKcal: 2_150, weightKg: 73, proteinGPerKg: 1.2)
        let line = FoodLibraryDigest.targetsLine(t)
        XCTAssertTrue(line.contains("protein 88 g") || line.contains("protein 87.6 g"))
        XCTAssertTrue(line.contains("fat at least"))
        XCTAssertTrue(line.contains("carbs"))
        XCTAssertTrue(line.contains("FLOOR"))
    }

    func testAnOverCommittedBudgetIsFlaggedToTheCoach() {
        let t = MacroTargets.targets(budgetKcal: 600, weightKg: 73, proteinGPerKg: 2.0)
        XCTAssertTrue(FoodLibraryDigest.targetsLine(t).contains("cannot all be met"))
    }

    // MARK: - Weight

    /// THE IMPORTANT ONE. A coach handed a bare rate will talk about it as fact, and a diet judged from
    /// noise is the failure the whole trend apparatus exists to prevent.
    func testAnIndistinguishableRateIsCalledOutAsSuch() {
        let line = FoodLibraryDigest.weightLine(latestKg: 73, trendKg: 73.1,
                                                slopeKgPerWeek: -0.08, marginKgPerWeek: 0.22,
                                                isDistinguishable: false, weighInDays: 5)
        XCTAssertTrue(line.contains("INCLUDES ZERO"))
        XCTAssertTrue(line.contains("do not describe this as losing"))
    }

    func testADistinguishableRateIsStatedPlainly() {
        let line = FoodLibraryDigest.weightLine(latestKg: 72.4, trendKg: 72.6,
                                                slopeKgPerWeek: -0.31, marginKgPerWeek: 0.09,
                                                isDistinguishable: true, weighInDays: 14)
        XCTAssertTrue(line.contains("-0.31"))
        XCTAssertTrue(line.contains("distinguishable"))
        XCTAssertFalse(line.contains("INCLUDES ZERO"))
    }

    func testNoWeighInsSaysWhatThatCosts() {
        let line = FoodLibraryDigest.weightLine(latestKg: nil, trendKg: nil, slopeKgPerWeek: nil,
                                                marginKgPerWeek: nil, isDistinguishable: false,
                                                weighInDays: 0)
        XCTAssertTrue(line.contains("no weigh-ins"))
        XCTAssertTrue(line.contains("real expenditure"))
    }

    func testTooFewReadingsReportsNoRateRatherThanAFabricatedOne() {
        let line = FoodLibraryDigest.weightLine(latestKg: 73, trendKg: nil, slopeKgPerWeek: nil,
                                                marginKgPerWeek: nil, isDistinguishable: false,
                                                weighInDays: 2)
        XCTAssertTrue(line.contains("Too few readings"))
    }

    // MARK: - Recipes

    func testRecipeLinesListTheParts() {
        let lines = FoodLibraryDigest.recipeLines([
            (name: "Protein shake", handle: "a1b2c3d4",
             parts: [(name: "Whey", quantity: 1), (name: "Oat milk", quantity: 3)]),
        ])
        XCTAssertTrue(lines.contains("Protein shake"))
        XCTAssertTrue(lines.contains("Whey"))
        XCTAssertTrue(lines.contains("3"))
        // The coach must be told not to edit a recipe's macros — they are recomputed from the parts, so an
        // edit would appear to work and silently revert.
        XCTAssertTrue(lines.contains("never edit"))
    }

    func testNoRecipesProducesNoBlock() {
        XCTAssertEqual(FoodLibraryDigest.recipeLines([]), "")
    }
}
