import XCTest
import GRDB
@testable import WhoopStore

final class FoodBatchStoreTests: XCTestCase {

    private let device = "dev-1"

    private func makeStore() async throws -> WhoopStore {
        try await WhoopStore.inMemory()
    }

    private func batch(id: String = "b1", cookedOn: String = "2026-10-07",
                       closedAt: Int? = nil) -> FoodBatchRow {
        FoodBatchRow(id: id, deviceId: device, recipeId: nil, name: "Karahi", note: "400g chicken",
                     cookedOn: cookedOn, kcal: 2_100, protein: 145, carbs: 120, fat: 95, fiber: 18,
                     createdAt: 1_700_000_000, closedAt: closedAt)
    }

    private func entry(id: String, day: String, portion: Double, batchId: String?,
                       loggedAt: Int) -> FoodEntryRow {
        FoodEntryRow(id: id, deviceId: device, day: day, itemId: nil, nameSnapshot: "Karahi",
                     portion: portion, kcal: 2_100, protein: 145, carbs: 120, fat: 95, fiber: 18,
                     loggedAt: loggedAt, batchId: batchId)
    }

    // MARK: - Schema

    func testMigrationCreatesTheBatchTableWithPinnedColumnOrder() async throws {
        let store = try await makeStore()
        let cols = try await store.columnNamesForTest(table: "foodBatch")
        XCTAssertEqual(cols, ["id", "deviceId", "recipeId", "name", "note", "cookedOn", "kcal",
                              "protein", "carbs", "fat", "fiber", "createdAt", "closedAt"])
        let pk = try await store.primaryKeyColumns("foodBatch")
        XCTAssertEqual(pk, ["id"])
        let idx = try await store.indexNamesForTest(table: "foodBatch")
        XCTAssertTrue(idx.contains("idx_foodBatch_device_day"), "got \(idx)")
    }

    /// There must be no stored remainder. If one is ever added, the derivation silently acquires a rival
    /// and this test is where that gets caught.
    func testBatchTableStoresNoRemainder() async throws {
        let store = try await makeStore()
        let cols = try await store.columnNamesForTest(table: "foodBatch")
        for banned in ["remaining", "remainingFraction", "eaten", "portionsLogged"] {
            XCTAssertFalse(cols.contains(banned),
                           "\(banned) must stay DERIVED from foodEntry.portion, never stored")
        }
    }

    // MARK: - Round trip

    func testUpsertAndFetch() async throws {
        let store = try await makeStore()
        try await store.upsertFoodBatch(batch())
        let got = try await store.foodBatch(deviceId: device, id: "b1")
        XCTAssertEqual(got, batch())
    }

    func testUpsertReplacesRatherThanDuplicating() async throws {
        let store = try await makeStore()
        try await store.upsertFoodBatch(batch())
        var adjusted = batch()
        adjusted.kcal = 2_340
        adjusted.note = "extra chicken"
        try await store.upsertFoodBatch(adjusted)
        let all = try await store.foodBatches(deviceId: device, since: "2026-01-01")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.kcal, 2_340)
    }

    func testFetchIsBoundedByDate() async throws {
        let store = try await makeStore()
        try await store.upsertFoodBatch(batch(id: "old", cookedOn: "2026-09-01"))
        try await store.upsertFoodBatch(batch(id: "new", cookedOn: "2026-10-07"))
        let recent = try await store.foodBatches(deviceId: device, since: "2026-10-01")
        XCTAssertEqual(recent.map(\.id), ["new"])
    }

    // MARK: - The portions a cook has had drawn from it

    func testBatchPortionsReturnsEachPortionSeparately() async throws {
        let store = try await makeStore()
        try await store.upsertFoodBatch(batch())
        try await store.upsertFoodEntries([
            entry(id: "e1", day: "2026-10-07", portion: 0.6, batchId: "b1", loggedAt: 100),
            entry(id: "e2", day: "2026-10-08", portion: 0.25, batchId: "b1", loggedAt: 200),
            // An unrelated log must not be counted against the cook.
            entry(id: "e3", day: "2026-10-08", portion: 1.0, batchId: nil, loggedAt: 300),
        ])
        let portions = try await store.batchPortions(deviceId: device, batchId: "b1")
        // Separate, not summed: the overage check needs to see 0.6 and 0.6 as two logs.
        XCTAssertEqual(portions, [0.6, 0.25])
    }

    /// Deleting an entry must give the food back, which is the whole reason the remainder is derived.
    func testDeletingAnEntryReturnsItsPortionToTheCook() async throws {
        let store = try await makeStore()
        try await store.upsertFoodBatch(batch())
        try await store.upsertFoodEntries([
            entry(id: "e1", day: "2026-10-07", portion: 0.6, batchId: "b1", loggedAt: 100),
            entry(id: "e2", day: "2026-10-08", portion: 0.25, batchId: "b1", loggedAt: 200),
        ])
        try await store.deleteFoodEntry(deviceId: device, id: "e1")
        let portions = try await store.batchPortions(deviceId: device, batchId: "b1")
        XCTAssertEqual(portions, [0.25])
    }

    // MARK: - Closing and deleting

    func testCloseSetsAndClearsTheMarker() async throws {
        let store = try await makeStore()
        try await store.upsertFoodBatch(batch())
        try await store.closeFoodBatch(deviceId: device, id: "b1", at: 1_700_009_999)
        var got = try await store.foodBatch(deviceId: device, id: "b1")
        XCTAssertEqual(got?.closedAt, 1_700_009_999)
        try await store.closeFoodBatch(deviceId: device, id: "b1", at: nil)
        got = try await store.foodBatch(deviceId: device, id: "b1")
        XCTAssertNil(got?.closedAt)
    }

    /// Deleting the cook must NOT delete the food. Those portions were eaten whether or not the pot is
    /// still described, so the entries survive and simply stop belonging to anything.
    func testDeletingACookDetachesItsEntriesRatherThanRemovingThem() async throws {
        let store = try await makeStore()
        try await store.upsertFoodBatch(batch())
        try await store.upsertFoodEntries([
            entry(id: "e1", day: "2026-10-07", portion: 0.6, batchId: "b1", loggedAt: 100),
        ])
        try await store.deleteFoodBatch(deviceId: device, id: "b1")

        let gone = try await store.foodBatch(deviceId: device, id: "b1")
        XCTAssertNil(gone)
        let entries = try await store.foodEntries(deviceId: device, day: "2026-10-07")
        XCTAssertEqual(entries.count, 1, "the food was eaten; deleting the pot must not unfeed it")
        XCTAssertNil(entries.first?.batchId)
        XCTAssertEqual(entries.first?.portion, 0.6)
    }

    // MARK: - The week read

    func testRangeReadSpansDaysInOrder() async throws {
        let store = try await makeStore()
        try await store.upsertFoodEntries([
            entry(id: "e3", day: "2026-10-09", portion: 1, batchId: nil, loggedAt: 300),
            entry(id: "e1", day: "2026-10-07", portion: 1, batchId: nil, loggedAt: 100),
            entry(id: "e2", day: "2026-10-08", portion: 1, batchId: nil, loggedAt: 200),
            entry(id: "e0", day: "2026-10-01", portion: 1, batchId: nil, loggedAt: 50),
        ])
        let week = try await store.foodEntries(deviceId: device, from: "2026-10-07", to: "2026-10-09")
        XCTAssertEqual(week.map(\.id), ["e1", "e2", "e3"], "inclusive both ends, oldest first")
    }
}
