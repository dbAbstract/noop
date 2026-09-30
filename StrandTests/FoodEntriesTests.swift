import XCTest
import StrandAnalytics
@testable import Strand

/// The per-day food entry list and the reusable item library (v0 food log). The day totals banked into
/// `metricSeries` are always re-derived from this list, so the math here is the source of truth for an
/// edited day.
///
/// These pin the behaviours that would silently corrupt a day: a bad portion never enters the list, an edit
/// to 0 is a delete rather than a lingering zero row, and — the important one — an entry keeps the macros it
/// was logged with even after the library item it came from is edited or deleted.
final class FoodEntriesTests: XCTestCase {

    private let shake = FoodItem(name: "Protein shake", servingLabel: "1 scoop",
                                 macros: MacroTotals(kcal: 120, protein: 24, carbs: 3, fat: 1.5, fiber: 0))

    private func entry(_ item: FoodItem, portion: Double, secondsAgo: TimeInterval = 0) -> FoodEntry {
        FoodEntry(itemId: item.id, nameSnapshot: item.name, macrosSnapshot: item.macros,
                  portion: portion, loggedAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }

    // MARK: - adding

    func testAddingAppends() {
        let list = FoodEntries.adding([], entry(shake, portion: 1))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.nameSnapshot, "Protein shake")
    }

    /// A rejected portion must leave the list untouched, so `logFood`'s "did anything change?" guard can
    /// tell a real write from a no-op and skip the re-bank.
    func testAddingRejectsNonPositiveAndNonFinitePortions() {
        for bad in [0.0, -1.0, .nan, .infinity] {
            XCTAssertTrue(FoodEntries.adding([], entry(shake, portion: bad)).isEmpty,
                          "portion \(bad) should not enter the list")
        }
    }

    // MARK: - removing / updating

    func testRemovingById() {
        let e = entry(shake, portion: 1)
        XCTAssertTrue(FoodEntries.removing([e], id: e.id).isEmpty)
    }

    func testRemovingUnknownIdIsNoOp() {
        let e = entry(shake, portion: 1)
        XCTAssertEqual(FoodEntries.removing([e], id: UUID()).count, 1)
    }

    func testUpdatingChangesPortionOnly() {
        let e = entry(shake, portion: 1)
        let next = FoodEntries.updating([e], id: e.id, portion: 2)
        XCTAssertEqual(next.first?.portion, 2)
        XCTAssertEqual(next.first?.id, e.id, "identity must survive a re-portion")
        XCTAssertEqual(next.first?.macrosSnapshot, e.macrosSnapshot, "the snapshot must not be rewritten")
    }

    /// An edit to zero is a delete — the same contract `HydrationEntries.updating` holds, so no zero row is
    /// left behind to render as "you ate nothing" in the day list.
    func testUpdatingToNonPositiveDeletes() {
        let e = entry(shake, portion: 1)
        XCTAssertTrue(FoodEntries.updating([e], id: e.id, portion: 0).isEmpty)
        XCTAssertTrue(FoodEntries.updating([e], id: e.id, portion: -2).isEmpty)
        XCTAssertTrue(FoodEntries.updating([e], id: e.id, portion: .nan).isEmpty)
    }

    // MARK: - totals

    func testTotalScalesEachEntryByItsOwnPortion() {
        let list = [entry(shake, portion: 2), entry(shake, portion: 0.5)]
        let t = FoodEntries.total(list)
        // 2.5 scoops: 120*2.5 = 300 kcal, 24*2.5 = 60 P
        XCTAssertEqual(t.kcal, 300, accuracy: 1e-9)
        XCTAssertEqual(t.protein, 60, accuracy: 1e-9)
        XCTAssertEqual(t.carbs, 7.5, accuracy: 1e-9)
        XCTAssertEqual(t.fat, 3.75, accuracy: 1e-9)
    }

    func testTotalOfEmptyDayIsZero() {
        XCTAssertEqual(FoodEntries.total([]), .zero)
    }

    /// Deleting the last entry must drive the day to a real zero, which is what forces `rebankFoodTotals`
    /// to write zeros rather than leave yesterday's figures stranded in `metricSeries`.
    func testTotalAfterDeletingLastEntryIsZero() {
        let e = entry(shake, portion: 1)
        XCTAssertEqual(FoodEntries.total(FoodEntries.removing([e], id: e.id)), .zero)
    }

    func testEffectiveMacrosMatchesScaledSnapshot() {
        XCTAssertEqual(entry(shake, portion: 1.5).effectiveMacros,
                       NutritionMath.scaled(shake.macros, portion: 1.5))
    }

    // MARK: - snapshot independence (the reason snapshots exist)

    /// Editing the library item must NOT retroactively change what an already-logged day says you ate.
    func testEditingLibraryItemDoesNotRewriteLoggedEntry() {
        let logged = entry(shake, portion: 1)
        var edited = shake
        edited.macros = MacroTotals(kcal: 999, protein: 1, carbs: 1, fat: 1)
        _ = FoodLibrary.upserting([shake], edited)

        XCTAssertEqual(logged.macrosSnapshot.kcal, 120, accuracy: 1e-9)
        XCTAssertEqual(FoodEntries.total([logged]).kcal, 120, accuracy: 1e-9)
    }

    /// Deleting the library item must not strand the history either — the entry still renders in full.
    func testDeletingLibraryItemLeavesLoggedEntryIntact() {
        let logged = entry(shake, portion: 2)
        XCTAssertTrue(FoodLibrary.removing([shake], id: shake.id).isEmpty)
        XCTAssertEqual(logged.nameSnapshot, "Protein shake")
        XCTAssertEqual(FoodEntries.total([logged]).kcal, 240, accuracy: 1e-9)
    }
}

/// The reusable item library: upsert-by-id, recents ordering and search.
final class FoodLibraryTests: XCTestCase {

    private func item(_ name: String, used: TimeInterval?) -> FoodItem {
        FoodItem(name: name, servingLabel: "1 serving", macros: MacroTotals(kcal: 100),
                 createdAt: Date(timeIntervalSince1970: 0),
                 lastUsedAt: used.map { Date(timeIntervalSince1970: $0) })
    }

    func testUpsertReplacesByIdRatherThanDuplicating() {
        let a = item("Oats", used: 10)
        var renamed = a
        renamed.name = "Porridge"
        let out = FoodLibrary.upserting([a], renamed)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "Porridge")
    }

    func testSortedPutsMostRecentlyUsedFirst() {
        let old = item("Old", used: 10)
        let recent = item("Recent", used: 500)
        XCTAssertEqual(FoodLibrary.sorted([old, recent]).map(\.name), ["Recent", "Old"])
    }

    /// An item never logged falls back to its creation date, so a brand-new item does not sort below
    /// everything just because `lastUsedAt` is nil.
    func testNeverUsedItemFallsBackToCreatedAt() {
        let neverUsed = FoodItem(name: "New", servingLabel: "1", macros: MacroTotals(kcal: 50),
                                 createdAt: Date(timeIntervalSince1970: 900), lastUsedAt: nil)
        let used = item("Used", used: 100)
        XCTAssertEqual(FoodLibrary.sorted([used, neverUsed]).map(\.name), ["New", "Used"])
    }

    func testMarkingUsedMovesItemToFront() {
        let a = item("A", used: 10)
        let b = item("B", used: 500)
        let out = FoodLibrary.markingUsed([a, b], id: a.id, at: Date(timeIntervalSince1970: 9_000))
        XCTAssertEqual(out.first?.name, "A")
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        let items = [item("Crème brûlée", used: 1), item("Chips", used: 2)]
        XCTAssertEqual(FoodLibrary.matching(items, query: "creme").map(\.name), ["Crème brûlée"])
        XCTAssertEqual(FoodLibrary.matching(items, query: "CHIPS").map(\.name), ["Chips"])
    }

    /// A blank query means "browsing", so one code path serves both the empty search field and a real one.
    func testBlankQueryReturnsEverything() {
        let items = [item("A", used: 1), item("B", used: 2)]
        XCTAssertEqual(FoodLibrary.matching(items, query: "   ").count, 2)
        XCTAssertEqual(FoodLibrary.matching(items, query: "").count, 2)
    }
}
