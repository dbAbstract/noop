import XCTest
import GRDB
@testable import WhoopStore

/// The v48 food-log tables. These exist because the library and the per-day entries moved OUT of
/// UserDefaults and into the database, which is what puts them inside `.noopbak` — anything outside the
/// SQLite file is not in the backup, and deleting the app takes the whole container with it.
final class FoodLogStoreTests: XCTestCase {

    private let dev = "food-log"

    private func item(_ name: String, kcal: Double = 120, created: Int = 1_000, used: Int? = nil) -> FoodItemRow {
        FoodItemRow(id: UUID().uuidString, deviceId: dev, name: name, servingLabel: "1 scoop",
                    kcal: kcal, protein: 24, carbs: 3, fat: 1.5, fiber: 0,
                    createdAt: created, lastUsedTs: used)
    }

    private func entry(_ name: String, day: String, portion: Double = 1, at: Int = 1_000) -> FoodEntryRow {
        FoodEntryRow(id: UUID().uuidString, deviceId: dev, day: day, itemId: nil, nameSnapshot: name,
                     portion: portion, kcal: 120, protein: 24, carbs: 3, fat: 1.5, fiber: 0,
                     loggedAt: at, mealType: nil)
    }

    // MARK: - Schema

    func testMigrationCreatesBothTables() async throws {
        let store = try await WhoopStore.inMemory()
        let itemCols = try await store.columnNamesForTest(table: "foodItem")
        let entryCols = try await store.columnNamesForTest(table: "foodEntry")
        let itemPk = try await store.primaryKeyColumns("foodItem")
        let entryPk = try await store.primaryKeyColumns("foodEntry")
        let itemIdx = try await store.indexNamesForTest(table: "foodItem")
        let entryIdx = try await store.indexNamesForTest(table: "foodEntry")
        XCTAssertEqual(itemCols, ["id", "deviceId", "name", "servingLabel", "kcal", "protein", "carbs",
                                  "fat", "fiber", "createdAt", "lastUsedTs", "macroSource"])
        XCTAssertEqual(entryCols, ["id", "deviceId", "day", "itemId", "nameSnapshot", "portion", "kcal",
                                   "protein", "carbs", "fat", "fiber", "loggedAt", "mealType",
                                   "macroSource"])
        XCTAssertEqual(itemPk, ["id"])
        XCTAssertEqual(entryPk, ["id"])
        XCTAssertTrue(itemIdx.contains("idx_foodItem_device_used"))
        XCTAssertTrue(entryIdx.contains("idx_foodEntry_device_day"))
    }

    // MARK: - Library

    func testUpsertItemIsIdempotentById() async throws {
        let store = try await WhoopStore.inMemory()
        var row = item("Protein shake")
        _ = try await store.upsertFoodItems([row])
        row.name = "Whey shake"
        _ = try await store.upsertFoodItems([row])
        let all = try await store.foodItems(deviceId: dev)
        XCTAssertEqual(all.count, 1, "re-saving an item must update, not duplicate")
        XCTAssertEqual(all.first?.name, "Whey shake")
    }

    func testItemsSortMostRecentlyUsedFirst() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertFoodItems([
            item("Old", created: 10, used: 10),
            item("Recent", created: 10, used: 500),
        ])
        let names = try await store.foodItems(deviceId: dev).map(\.name)
        XCTAssertEqual(names, ["Recent", "Old"])
    }

    /// An item never logged must fall back to its creation time, or a brand-new food sorts below
    /// everything purely because it has never been used.
    func testNeverUsedItemFallsBackToCreatedAt() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertFoodItems([
            item("Used", created: 10, used: 100),
            item("NewNeverUsed", created: 900, used: nil),
        ])
        let names = try await store.foodItems(deviceId: dev).map(\.name)
        XCTAssertEqual(names, ["NewNeverUsed", "Used"])
    }

    /// Two foods can honestly share a name ("porridge" made two ways). The library is keyed by id
    /// precisely so that is allowed and an edit never silently merges them.
    func testDuplicateNamesAreAllowed() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertFoodItems([item("Porridge"), item("Porridge")])
        let count = try await store.foodItems(deviceId: dev).count
        XCTAssertEqual(count, 2)
    }

    func testDeleteItemLeavesLoggedEntriesIntact() async throws {
        let store = try await WhoopStore.inMemory()
        let row = item("Protein shake")
        _ = try await store.upsertFoodItems([row])
        var logged = entry("Protein shake", day: "2026-09-30")
        logged.itemId = row.id
        _ = try await store.upsertFoodEntries([logged])

        _ = try await store.deleteFoodItem(deviceId: dev, id: row.id)

        let remaining = try await store.foodItems(deviceId: dev)
        XCTAssertTrue(remaining.isEmpty)
        let kept = try await store.foodEntries(deviceId: dev, day: "2026-09-30")
        XCTAssertEqual(kept.count, 1, "history must survive its library item being deleted")
        XCTAssertEqual(kept.first?.nameSnapshot, "Protein shake")
        XCTAssertEqual(kept.first?.kcal, 120, "the snapshot carries the macros, not the deleted item")
    }

    // MARK: - Entries

    func testEntriesAreScopedToTheirDayAndOrderedOldestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertFoodEntries([
            entry("Late", day: "2026-09-30", at: 900),
            entry("Early", day: "2026-09-30", at: 100),
            entry("OtherDay", day: "2026-09-29", at: 500),
        ])
        let d30 = try await store.foodEntries(deviceId: dev, day: "2026-09-30").map(\.nameSnapshot)
        let d29 = try await store.foodEntries(deviceId: dev, day: "2026-09-29").map(\.nameSnapshot)
        XCTAssertEqual(d30, ["Early", "Late"])
        XCTAssertEqual(d29, ["OtherDay"])
    }

    func testUpsertEntryIsIdempotentAndCanRePortion() async throws {
        let store = try await WhoopStore.inMemory()
        var row = entry("Oats", day: "2026-09-30", portion: 1)
        _ = try await store.upsertFoodEntries([row])
        row.portion = 2.5
        _ = try await store.upsertFoodEntries([row])
        let all = try await store.foodEntries(deviceId: dev, day: "2026-09-30")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.portion, 2.5)
    }

    func testDeleteEntry() async throws {
        let store = try await WhoopStore.inMemory()
        let row = entry("Oats", day: "2026-09-30")
        _ = try await store.upsertFoodEntries([row])
        _ = try await store.deleteFoodEntry(deviceId: dev, id: row.id)
        let left = try await store.foodEntries(deviceId: dev, day: "2026-09-30")
        XCTAssertTrue(left.isEmpty)
    }

    /// A second device's rows must never leak into this one's reads — the food log is written under its
    /// own "food-log" source, not the active strap's id.
    func testReadsAreScopedByDeviceId() async throws {
        let store = try await WhoopStore.inMemory()
        var other = entry("SomeoneElse", day: "2026-09-30")
        other.deviceId = "other-source"
        _ = try await store.upsertFoodEntries([entry("Mine", day: "2026-09-30"), other])
        let mine = try await store.foodEntries(deviceId: dev, day: "2026-09-30").map(\.nameSnapshot)
        XCTAssertEqual(mine, ["Mine"])
    }

    // MARK: - The reason these tables exist

    /// Forgetting the source must clear the library AND the entries. The day totals live in
    /// `metricSeries`, which `deviceScopedTables` already covers, so leaving these off would delete every
    /// chart while the food itself stayed on disk — a delete that looks complete and is not.
    func testDeleteAllDataClearsFoodRows() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertFoodItems([item("Protein shake")])
        _ = try await store.upsertFoodEntries([entry("Protein shake", day: "2026-09-30")])
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-09-30", key: "calories_in", value: 300)],
                                               deviceId: dev)

        try await store.deleteAllData(deviceId: dev)

        let items = try await store.foodItems(deviceId: dev)
        let entries = try await store.foodEntries(deviceId: dev, day: "2026-09-30")
        let series = try await store.metricSeries(deviceId: dev, key: "calories_in",
                                                  from: "2026-09-30", to: "2026-09-30")
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(series.isEmpty)
    }
}
