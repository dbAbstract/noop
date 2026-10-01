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
