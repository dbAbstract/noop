import XCTest
@testable import StrandAnalytics

final class FoodWeekDigestTests: XCTestCase {

    private let oikosId = "7C01AAAA-0000-0000-0000-000000000001"
    private let karahiBatch = "B3000000-0000-0000-0000-000000000002"

    private func m(_ kcal: Double, _ p: Double = 0, _ c: Double = 0, _ f: Double = 0) -> MacroTotals {
        MacroTotals(kcal: kcal, protein: p, carbs: c, fat: f, fiber: 0)
    }

    private func oikos(daysAgo: Int, portion: Double = 1) -> WeekEntryDigest {
        WeekEntryDigest(daysAgo: daysAgo, itemId: oikosId, batchId: nil, name: "Oikos vanilla",
                        portion: portion, macros: m(114 * portion, 10 * portion, 9 * portion,
                                                    4 * portion),
                        meal: "breakfast")
    }

    private func karahi(daysAgo: Int, portion: Double) -> WeekEntryDigest {
        WeekEntryDigest(daysAgo: daysAgo, itemId: nil, batchId: karahiBatch, name: "Karahi",
                        portion: portion, macros: m(2_100 * portion, 145 * portion, 120 * portion,
                                                    95 * portion),
                        meal: "dinner")
    }

    // MARK: - Deduplication, which is the whole point

    /// A repeated food must be DESCRIBED once however many times it was eaten. This is the token saving
    /// the keyed form exists for.
    func testARepeatedFoodIsDescribedOnce() {
        let week = (0..<5).map { oikos(daysAgo: $0) }
        let block = FoodWeekDigest.block(entries: week, savedFoodIds: [oikosId])
        let describedLines = block.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(describedLines.count, 1, "five eats, one description")
        // But every occurrence is still present.
        // Occurrences are grouped by day, so five eats on five days are five day-lines each carrying
        // one reference. The count that matters is the references, not the lines.
        let references = block.components(separatedBy: "×1").count - 1
        XCTAssertEqual(references, 5)
    }

    /// A saved food's macros are already in the saved-foods block above, so repeating them here is pure
    /// duplication — the thing dedup is supposed to remove.
    func testSavedFoodsAreReferencedRatherThanRedescribed() {
        let block = FoodWeekDigest.block(entries: [oikos(daysAgo: 0)], savedFoodIds: [oikosId])
        XCTAssertTrue(block.contains("see SAVED FOODS"))
        // Checked on the DESCRIPTION line only. The daily-totals line legitimately contains "114 kcal"
        // — it is a sum, not a restatement of the food — and asserting over the whole block would have
        // been a test that passes only while the totals happen to differ from the single item's macros.
        let describedLine = block.split(separator: "\n").first { $0.hasPrefix("- ") }!
        XCTAssertFalse(describedLine.contains("kcal"),
                       "a saved food's macros belong to the saved-foods block, not here")
    }

    /// A one-off's macros exist nowhere else, so they MUST be stated or the model is guessing.
    func testOneOffFoodsCarryTheirOwnMacros() {
        let block = FoodWeekDigest.block(entries: [karahi(daysAgo: 1, portion: 0.6)], savedFoodIds: [])
        XCTAssertTrue(block.contains("per portion"), block)
        // Stated per WHOLE portion, not pre-scaled: the occurrence line multiplies by ×0.6, and a figure
        // already scaled would be counted twice.
        XCTAssertTrue(block.contains("2100 kcal"), block)
    }

    /// The saving is MARGINAL, not absolute, and this measures the thing actually claimed.
    ///
    /// The keyed block carries fixed overhead a naive list does not — the header explaining the key
    /// scheme, and the daily totals. On a tiny week that overhead dominates and the keyed form is LARGER;
    /// an absolute size comparison would therefore assert something untrue. What dedup buys is that each
    /// additional occurrence of a food already described costs a short reference instead of a full
    /// restatement, so the two curves cross and keep diverging as eating repeats.
    func testEachExtraOccurrenceCostsFarLessThanRestatingTheFood() {
        // The extra five land on the SAME five days as the first five. Spreading them onto new days
        // would also buy a new day label and a new daily-totals entry, and charging those to the
        // per-occurrence cost measures something other than the claim — that was the first version of
        // this test, and it read 25 chars per occurrence when the occurrence itself costs 15.
        let five = FoodWeekDigest.block(entries: (0..<5).map { oikos(daysAgo: $0) },
                                        savedFoodIds: [oikosId])
        let ten = FoodWeekDigest.block(entries: (0..<10).map { oikos(daysAgo: $0 % 5) },
                                       savedFoodIds: [oikosId])
        let marginalPerOccurrence = Double(ten.count - five.count) / 5.0
        let restatementCost = "  Oikos vanilla ×1 — 114 kcal 10P 9C 4F".count
        XCTAssertLessThan(marginalPerOccurrence, Double(restatementCost) / 2,
                          "an extra occurrence must cost well under half a full restatement")
    }

    // MARK: - Determinism

    /// Identical input, identical block. A prompt that reshuffles defeats prompt caching and makes a bad
    /// reply impossible to reproduce.
    func testBlockIsDeterministicRegardlessOfInputOrder() {
        let entries = [oikos(daysAgo: 0), karahi(daysAgo: 1, portion: 0.6), oikos(daysAgo: 2),
                       karahi(daysAgo: 0, portion: 0.25)]
        let a = FoodWeekDigest.block(entries: entries, savedFoodIds: [oikosId])
        let b = FoodWeekDigest.block(entries: entries.reversed(), savedFoodIds: [oikosId])
        XCTAssertEqual(a, b)
    }

    /// Adding an alphabetically earlier food must not change an existing reference.
    func testOneOffKeysDependOnTheSetNotTheOrder() {
        let apple = WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Apple",
                                    portion: 1, macros: m(80), meal: "snack")
        let zucchini = WeekEntryDigest(daysAgo: 0, itemId: nil, batchId: nil, name: "Zucchini",
                                       portion: 1, macros: m(30), meal: "lunch")
        let forward = FoodWeekDigest.keys(for: [apple, zucchini])
        let backward = FoodWeekDigest.keys(for: [zucchini, apple])
        XCTAssertEqual(forward, backward)
        let original = FoodWeekDigest.keys(for: [zucchini])
        XCTAssertEqual(FoodWeekDigest.key(for: zucchini, in: original),
                       FoodWeekDigest.key(for: zucchini, in: forward))
    }

    /// Case and spacing differences are the same food, or the week sprouts phantom duplicates.
    func testOneOffNamesNormaliseBeforeKeying() {
        let a = WeekEntryDigest(daysAgo: 0, itemId: nil, batchId: nil, name: "Karahi  ",
                                portion: 1, macros: m(100), meal: nil)
        let b = WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "karahi",
                                portion: 1, macros: m(100), meal: nil)
        let keys = FoodWeekDigest.keys(for: [a, b])
        XCTAssertEqual(keys.count, 1)
    }

    // MARK: - Keys the model can act on

    /// A key here must be the SAME key the saved-foods block uses, or the model has two vocabularies for
    /// one food and a quoted key resolves to nothing.
    func testLibraryKeysMatchTheSavedFoodsHandle() {
        let keys = FoodWeekDigest.keys(for: [oikos(daysAgo: 0)])
        XCTAssertEqual(keys[oikosId], FoodLibraryDigest.handle(for: oikosId))
    }

    func testEveryEmittedKeyResolvesBackToAFood() {
        let entries = [oikos(daysAgo: 0), karahi(daysAgo: 1, portion: 0.6)]
        let keys = FoodWeekDigest.keys(for: entries)
        for e in entries {
            XCTAssertNotNil(FoodWeekDigest.key(for: e, in: keys), "\(e.name) produced no key")
        }
    }

    // MARK: - Shape

    func testEmptyWeekSaysSoRatherThanRenderingAnEmptyScaffold() {
        XCTAssertEqual(FoodWeekDigest.block(entries: []),
                       "EATEN (last 7 days): nothing logged.")
    }

    func testDailyTotalsAreEmittedPerDay() {
        let block = FoodWeekDigest.block(entries: [oikos(daysAgo: 0), oikos(daysAgo: 0),
                                                   oikos(daysAgo: 2)],
                                         savedFoodIds: [oikosId])
        XCTAssertTrue(block.contains("DAILY TOTALS"))
        XCTAssertTrue(block.contains("today 228 kcal/20P"), block)
        XCTAssertTrue(block.contains("-2d 114 kcal/10P"), block)
    }

    func testTodayAndYesterdayAreNamedRatherThanNumbered() {
        let block = FoodWeekDigest.block(entries: [oikos(daysAgo: 0), oikos(daysAgo: 1)],
                                         savedFoodIds: [oikosId])
        XCTAssertTrue(block.contains("today:"), block)
        XCTAssertTrue(block.contains("yesterday:"), block)
    }

    /// Truncation must be STATED — a model told "here is your week" that is quietly missing a food will
    /// confidently propose creating a duplicate of it.
    func testTruncationIsAnnounced() {
        let many = (0..<(FoodWeekDigest.maxFoods + 5)).map { i in
            WeekEntryDigest(daysAgo: 0, itemId: nil, batchId: nil, name: "Food \(i)",
                            portion: 1, macros: m(100), meal: nil)
        }
        let block = FoodWeekDigest.block(entries: many)
        XCTAssertTrue(block.contains("more foods this week, not listed"), block)
    }

    func testHistoryReferencesUseWholePortionMacros() throws {
        let historicalMeal = WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Karahi",
            portion: 0.6, macros: m(1260, 87, 72, 57))
        let references = FoodWeekDigest.foodReferences(entries: [historicalMeal])
        let cook = try XCTUnwrap(references.values.first)
        XCTAssertEqual(cook.macros.kcal, 2100, accuracy: 0.000001)
        XCTAssertEqual(cook.macros.protein, 145, accuracy: 0.000001)
    }

    func testCookHistoryCannotBecomeAnUnlinkedRepeat() {
        XCTAssertTrue(FoodWeekDigest.foodReferences(entries: [karahi(daysAgo: 1, portion: 0.6)]).isEmpty)
    }

    func testDifferentMacrosWithTheSameNameHaveDistinctLoggableReferences() {
        let a = WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Curry",
            portion: 1, macros: m(500))
        let b = WeekEntryDigest(daysAgo: 2, itemId: nil, batchId: nil, name: "Curry",
            portion: 1, macros: m(900))
        let references = FoodWeekDigest.foodReferences(entries: [a, b])
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(Set(references.values.map { $0.macros.kcal }), [500, 900])
        XCTAssertEqual(references, FoodWeekDigest.foodReferences(entries: [b, a]))
        XCTAssertEqual(FoodWeekDigest.block(entries: [a, b]), FoodWeekDigest.block(entries: [b, a]))
    }

    func testOldNumberedHistoryKeysAreNeverAliasesForANewFood() {
        let food = WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Butter",
            portion: 1, macros: m(74, 0, 0, 8))
        let references = FoodWeekDigest.foodReferences(entries: [food])
        XCTAssertNil(references["o4"])
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.keys.first?.count, 17)
    }

    func testPortionScalingDoesNotChangeAHistoryReference() {
        let a = WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Karahi",
            portion: 0.6, macros: m(1260, 87, 72, 57))
        let b = WeekEntryDigest(daysAgo: 0, itemId: nil, batchId: nil, name: "karahi  ",
            portion: 0.25, macros: m(525, 36.25, 30, 23.75))
        XCTAssertEqual(FoodWeekDigest.keys(for: [a]).values.first, FoodWeekDigest.keys(for: [b]).values.first)
        XCTAssertEqual(FoodWeekDigest.foodReferences(entries: [a, b]).count, 1)
    }

    // MARK: - Open cooks

    func testOpenCooksBlockCarriesRemainingNotWhole() {
        let cook = OpenCookDigest(batchId: karahiBatch, name: "Karahi", note: "400g chicken",
                                  daysAgo: 1, remainingFraction: 0.4,
                                  remainingMacros: m(840, 58, 48, 38))
        let block = FoodWeekDigest.openCooksBlock([cook])
        XCTAssertTrue(block.contains("40% left"), block)
        XCTAssertTrue(block.contains("840 kcal"), block)
        XCTAssertTrue(block.contains("cooked yesterday"), block)
        // The deviation must travel, or the model reconciles against the recipe and "corrects" it back.
        XCTAssertTrue(block.contains("400g chicken"), block)
    }

    func testNoOpenCooksProducesNoBlockAtAll() {
        XCTAssertEqual(FoodWeekDigest.openCooksBlock([]), "")
    }

    func testOpenCooksAreOrderedNewestFirst() {
        let a = OpenCookDigest(batchId: karahiBatch, name: "Karahi", note: nil, daysAgo: 3,
                               remainingFraction: 0.5, remainingMacros: m(100))
        let b = OpenCookDigest(batchId: oikosId, name: "Dal", note: nil, daysAgo: 0,
                               remainingFraction: 0.5, remainingMacros: m(100))
        let block = FoodWeekDigest.openCooksBlock([a, b])
        let dalLine = block.range(of: "Dal")!
        let karahiLine = block.range(of: "Karahi")!
        XCTAssertTrue(dalLine.lowerBound < karahiLine.lowerBound)
    }
}
