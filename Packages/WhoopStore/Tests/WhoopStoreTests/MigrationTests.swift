import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    /// v24 widens the R-R key with a `seq` tiebreaker so two EQUAL successive intervals in the same
    /// second both survive (the old value-only key dropped the 2nd, biasing RMSSD/HRV high). #163.
    func testRrIntervalPrimaryKeyIncludesSeq() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs", "seq"])
    }

    func testV24AddsSeqColumnToRrInterval() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("seq"), "rrInterval missing v24 seq column")
    }

    func testV24KeepsEqualSameSecondBeats() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Two EQUAL R-R intervals in the same second: the old value-only key dropped the 2nd; v24 keeps both.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 812), RRInterval(ts: 100, rrMs: 812)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 2)
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.count, 2)
        XCTAssertTrue(read.allSatisfy { $0.ts == 100 && $0.rrMs == 812 })
    }

    func testV24DistinctBeatsAllKept() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Distinct (ts, rrMs) beats — incl. two values in the same second — each keep seq 0 and their slot.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 602), RRInterval(ts: 100, rrMs: 613),
                         RRInterval(ts: 101, rrMs: 602)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 3)
    }

    // MARK: - v30 R-R emission order (#823)

    /// `ord` must exist and must stay OUT of the primary key. An insertion counter in the key would
    /// collide distinct beats arriving in separate batches — the data-loss regression v24's note warns
    /// about, and the reason the obvious `ORDER BY ts, seq` fix was rejected.
    func testV30AddsOrdColumnAndKeepsItOutOfThePrimaryKey() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("ord"), "rrInterval missing v30 ord column")
        let pk = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(pk, ["deviceId", "ts", "rrMs", "seq"], "ord must not enter the key")
    }

    /// The bug itself: a second's beats came back sorted by VALUE. Sorting makes successive beats
    /// similar by construction, and RMSSD is built entirely from successive differences.
    func testV30ReadsSameSecondBeatsInEmissionOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let emission = [812, 795, 840, 801, 833]
        let n = try await store.insert(
            Streams(rr: emission.map { RRInterval(ts: 100, rrMs: $0) }), deviceId: "dev1")
        XCTAssertEqual(n.rr, emission.count, "every distinct beat must still be stored")

        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), emission,
                       "beats must read back in emission order, not magnitude order")
        let ords = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 100)
        XCTAssertEqual(ords, [0, 1, 2, 3, 4])

        // The measurable consequence, on the issue's own example: magnitude order reads 12.72 ms,
        // emission order 34.85 ms. A one-directional −22 ms bias in a headline metric.
        func rmssd(_ v: [Int]) -> Double {
            let d = zip(v, v.dropFirst()).map { pow(Double($1 - $0), 2) }
            return (d.reduce(0, +) / Double(d.count)).squareRoot()
        }
        XCTAssertEqual(rmssd(read.map(\.rrMs)), rmssd(emission), accuracy: 1e-9)
        XCTAssertEqual(rmssd(read.map(\.rrMs)), 34.85, accuracy: 0.01)
        XCTAssertGreaterThan(rmssd(read.map(\.rrMs)), rmssd(emission.sorted()) + 20.0,
                             "sorted order should be the badly-biased one this fix avoids")
    }

    /// `ord` is BATCH-LOCAL — a beat's position among the beats sharing its second *in this insert* —
    /// which is what let #1072 happen: a transport that inserts one beat at a time restarts the counter
    /// on every row, so every beat is written `ord = 0` and the v30 fix silently does nothing. With
    /// `ord` tied the read falls back to `(rrMs, seq)`, i.e. magnitude order, which is exactly the #823
    /// symptom. This pins both shapes side by side so the store-side contract the Oura call sites now
    /// satisfy (one record's beats = one insert) cannot regress unnoticed.
    func testV30OrdIsBatchLocalSoOneInsertPerBeatRecordsNoOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let emission = [812, 795, 840, 801, 833]
        for v in emission {   // the pre-#1072 Oura shape: one insert per beat
            _ = try await store.insert(Streams(rr: [RRInterval(ts: 400, rrMs: v)]), deviceId: "dev1")
        }
        let ords = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 400)
        XCTAssertEqual(ords, [0, 0, 0, 0, 0], "a one-beat insert can only ever compute ord 0")
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), emission.sorted(),
                       "tied ord falls through to (rrMs, seq) — the magnitude order #823 reports")

        // The same beats delivered as ONE insert keep their emission order, `ord` counting 0,1,2,…
        _ = try await store.insert(
            Streams(rr: emission.map { RRInterval(ts: 500, rrMs: $0) }), deviceId: "dev1")
        let batchedOrds = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 500)
        XCTAssertEqual(batchedOrds, [0, 1, 2, 3, 4])
    }

    /// The second consequence of insert-per-beat, and the reason a post-fix night holds slightly MORE
    /// rows than a pre-fix one: `seq` (v24) exists so two beats with the same interval in the same
    /// second survive as distinct rows, and it is batch-local for the same reason `ord` is. One insert
    /// per beat recomputed `seq = 0` for the second beat, so it collided on the primary key and was
    /// silently dropped by `ON CONFLICT DO NOTHING`. Batched, both are stored — real beats recovered,
    /// not duplicates invented.
    func testEqualIntervalsInOneRecordSurviveOnlyWhenTheRecordIsOneInsert() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        for _ in 0..<2 {   // the pre-#1072 shape
            _ = try await store.insert(Streams(rr: [RRInterval(ts: 600, rrMs: 812)]), deviceId: "dev1")
        }
        let dropped = try await store.rrIntervals(deviceId: "dev1", from: 590, to: 610, limit: 100)
        XCTAssertEqual(dropped.count, 1, "insert-per-beat silently loses the second identical beat")

        _ = try await store.insert(
            Streams(rr: [RRInterval(ts: 700, rrMs: 812), RRInterval(ts: 700, rrMs: 812)]),
            deviceId: "dev1")
        let kept = try await store.rrIntervals(deviceId: "dev1", from: 690, to: 710, limit: 100)
        XCTAssertEqual(kept.count, 2, "batched, seq 0/1 keeps both beats")
    }

    /// Rows written before v30 have `ord` NULL — the order was never recorded, so it cannot be
    /// backfilled. SQLite sorts NULL first in ASC, so an all-legacy second ties on `ord` and falls
    /// through to the old (rrMs, seq) order: existing data reads back exactly as it did before.
    func testV30LegacyNullOrdRowsKeepTheOldDeterministicOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        for v in [812, 795, 840, 801, 833] {
            try await store.insertLegacyRrWithoutOrdForTest(deviceId: "dev1", ts: 200, rrMs: v)
        }
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), [795, 801, 812, 833, 840],
                       "pre-v30 rows must keep the old (rrMs, seq) order, unchanged and deterministic")
        let ords = try await store.rrOrdValuesForTest(deviceId: "dev1", ts: 200)
        XCTAssertEqual(ords, [nil, nil, nil, nil, nil])
    }

    /// A second holding both legacy and post-v30 rows (possible via import/merge) must still be
    /// deterministic. NULL-first is arbitrary but fixed, which is the property that matters:
    /// the same data must never read back two different ways.
    func testV30MixedLegacyAndOrderedRowsAreDeterministic() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 300, rrMs: 700)]), deviceId: "dev1")
        try await store.insertLegacyRrWithoutOrdForTest(deviceId: "dev1", ts: 300, rrMs: 650)
        let first = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        let again = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(first.map(\.rrMs), [650, 700], "NULL ord sorts first")
        XCTAssertEqual(first.map(\.rrMs), again.map(\.rrMs), "repeated reads must not differ")
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    // MARK: - v51: inline recipe ingredients

    /// v51 REBUILDS `recipeComponent` to drop `foodItemId`'s NOT NULL. A rebuild is the migration shape
    /// that can lose data, so this pins the column set, the order Room has to match, and the index that
    /// does not survive a rename on its own.
    func testV51RecipeComponentHasInlineColumnsInTheOracleOrder() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "recipeComponent")
        XCTAssertEqual(cols, ["id", "deviceId", "recipeId", "foodItemId", "quantity", "ord",
                              "inlineName", "inlineServingLabel", "inlineKcal", "inlineProtein",
                              "inlineCarbs", "inlineFat", "inlineFiber"],
                       "column ORDER is the Room contract, not just the column set")
    }

    /// The index is created inside the migration AFTER the rename, because a rebuilt-and-renamed table
    /// does not carry the old table's indices with it. Without this, every recipe read is a full scan —
    /// which is invisible until the library is large.
    func testV51RecreatesTheRecipeComponentIndexAfterTheRebuild() async throws {
        let store = try await WhoopStore.inMemory()
        let indices = try await store.indexNamesForTest(table: "recipeComponent")
        XCTAssertTrue(indices.contains("idx_recipeComponent_device_recipe"),
                      "the rebuild dropped the index and never put it back")
    }

    /// A library reference round-trips with its inline columns null, and an inline ingredient round-trips
    /// with `foodItemId` null. Exactly one of the two shapes is ever populated — that nil IS the
    /// discriminator, so a row that carried both would make the reader guess.
    func testV51StoresBothIngredientShapesDistinguishably() async throws {
        let store = try await WhoopStore.inMemory()
        let reference = RecipeComponentRow(id: "c1", deviceId: "food-log", recipeId: "r1",
                                           foodItemId: "whey", quantity: 2, ord: 0)
        let inline = RecipeComponentRow(id: "c2", deviceId: "food-log", recipeId: "r1",
                                        foodItemId: nil, quantity: 1, ord: 1,
                                        inlineName: "Soy sauce", inlineServingLabel: "1 tbsp",
                                        inlineKcal: 8, inlineProtein: 1.3, inlineCarbs: 0.8,
                                        inlineFat: 0, inlineFiber: 0)
        _ = try await store.upsertRecipeComponents([reference, inline])

        let rows = try await store.recipeComponents(deviceId: "food-log", recipeId: "r1")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].foodItemId, "whey")
        XCTAssertNil(rows[0].inlineName, "a library reference must not also carry inline macros")
        XCTAssertNil(rows[1].foodItemId, "a nil foodItemId is what marks the row inline")
        XCTAssertEqual(rows[1].inlineName, "Soy sauce")
        XCTAssertEqual(rows[1].inlineKcal ?? .nan, 8, accuracy: 0.001)
        XCTAssertEqual(rows[1].inlineProtein ?? .nan, 1.3, accuracy: 0.001)
    }

    /// A wholesale replace must keep both shapes intact — it is the only write path the recipe editor
    /// uses, and an inline ingredient silently dropped there would take its calories with it.
    func testV51ReplacePreservesInlineIngredients() async throws {
        let store = try await WhoopStore.inMemory()
        let inline = RecipeComponentRow(id: "c9", deviceId: "food-log", recipeId: "r2",
                                        foodItemId: nil, quantity: 3, ord: 0,
                                        inlineName: "Oyster sauce", inlineServingLabel: "1 tbsp",
                                        inlineKcal: 9, inlineProtein: 0.2, inlineCarbs: 2,
                                        inlineFat: 0, inlineFiber: 0)
        _ = try await store.replaceRecipeComponents(deviceId: "food-log", recipeId: "r2", with: [inline])
        let rows = try await store.recipeComponents(deviceId: "food-log", recipeId: "r2")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inlineName, "Oyster sauce")
        XCTAssertEqual(rows[0].quantity, 3)
    }

    /// THE ONE THAT MATTERS. v51 rebuilds the table, and a rebuild is the migration shape that loses
    /// data: create-copy-drop-rename with a column list spelled out by hand. This stages a real v50-era
    /// row, runs v51 over it, and checks it survived with its values intact and its new columns null.
    ///
    /// The fresh-database tests above cannot catch a broken copy, because a fresh database has no rows
    /// to lose.
    func testV51RebuildPreservesExistingV50Components() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v50-diet-v3")
        try await dbQueue.write { db in
            // Written against the v50 shape, where foodItemId was NOT NULL and there were no inline
            // columns to write.
            try db.execute(sql: """
                INSERT INTO recipeComponent (id, deviceId, recipeId, foodItemId, quantity, ord)
                VALUES ('old1', 'food-log', 'shake', 'whey', 1.5, 0),
                       ('old2', 'food-log', 'shake', 'banana', 1, 1)
                """)
        }

        // Full migrator: GRDB resumes from the applied v50, so only v51 runs.
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipeComponent"), 2,
                           "the rebuild dropped rows")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT foodItemId FROM recipeComponent WHERE id = 'old1'"),
                           "whey")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT quantity FROM recipeComponent WHERE id = 'old1'"),
                           1.5, "a copy that mismatched its column list would scramble the values")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT ord FROM recipeComponent WHERE id = 'old2'"), 1,
                           "ord is what preserves the user's arrangement")
            // The new columns exist and are null on migrated rows — a pre-v51 component is a library
            // reference by definition, since inline ones could not be expressed yet.
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT inlineName FROM recipeComponent WHERE id = 'old1'"))
        }
    }

    /// After v51 an inline row must be INSERTABLE with a null `foodItemId` — the whole point of the
    /// rebuild. If the NOT NULL survived, this throws rather than failing an assertion.
    func testV51AllowsNullFoodItemIdAfterTheRebuild() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO recipeComponent (id, deviceId, recipeId, foodItemId, quantity, ord, inlineName, inlineKcal)
                VALUES ('inline1', 'food-log', 'marinade', NULL, 2, 0, 'Sesame oil', 40)
                """)
        }
        try await dbQueue.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT foodItemId FROM recipeComponent WHERE id = 'inline1'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT inlineName FROM recipeComponent WHERE id = 'inline1'"),
                           "Sesame oil")
        }
    }

    // MARK: - v52: the measured baseline

    /// An ALTER-appended column lands LAST, and that order is the Room contract.
    func testV52AppendsMeasuredBaselineToDietGoal() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "dietGoal")
        XCTAssertEqual(cols.last, "measuredBaselineKcal")
        // The v49 column it deliberately did NOT reuse is still there, still unread.
        XCTAssertTrue(cols.contains("targetOverrideKcal"))
    }

    /// An existing goal must survive the migration with its own values intact and the new column nil —
    /// nil being what makes every pre-v52 install keep using the Mifflin model until it opts in.
    func testV52LeavesExistingGoalsOnTheModel() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v51-inline-recipe-ingredients")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dietGoal (id, deviceId, startedOn, startWeightKg, targetWeightKg, months,
                                      activityLevel, dailyDeficitKcal, createdAt, proteinGPerKg)
                VALUES ('g1', 'diet', '2026-09-01', 73.0, 69.0, 6, 'sedentary', 168.6, 1756000000, 1.2)
                """)
        }
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT dailyDeficitKcal FROM dietGoal WHERE id = 'g1'"),
                           168.6)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT proteinGPerKg FROM dietGoal WHERE id = 'g1'"),
                           1.2)
            XCTAssertNil(try Double.fetchOne(db, sql: "SELECT measuredBaselineKcal FROM dietGoal WHERE id = 'g1'"),
                         "nil is what keeps an existing install on the model until it opts in")
        }
    }

    /// Round-trips through the row model, including the upsert's new column.
    func testV52MeasuredBaselineRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        let row = DietGoalRow(id: "g2", deviceId: "diet", startedOn: "2026-10-01",
                              startWeightKg: 73, targetWeightKg: 69, months: 6,
                              activityLevel: "sedentary", dailyDeficitKcal: 168.6,
                              createdAt: 1_759_000_000, proteinGPerKg: 1.2,
                              measuredBaselineKcal: 2_150)
        _ = try await store.upsertDietGoals([row])
        let back = try await store.dietGoals(deviceId: "diet")
        XCTAssertEqual(back.first?.measuredBaselineKcal ?? .nan, 2_150, accuracy: 0.01)

        // And clearing it must stick — the Revert control depends on this.
        var cleared = row
        cleared.measuredBaselineKcal = nil
        _ = try await store.upsertDietGoals([cleared])
        let afterClear = try await store.dietGoals(deviceId: "diet").first?.measuredBaselineKcal
        XCTAssertNil(afterClear, "the Revert control depends on a nil surviving the upsert")
    }

    // MARK: - v53: published restaurant nutrition

    /// EVERY MACRO MUST BE NULLABLE. That is the design, not laxity: partial publication is the norm, and a
    /// NOT NULL column would turn "fibre not published" into a claim of zero somewhere between the table
    /// and the screen.
    func testV53MacroColumnsAreAllNullable() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "restaurantFood")
        for macro in ["kcal", "protein", "carbs", "fat", "fiber"] {
            XCTAssertTrue(cols.contains(macro), "missing \(macro)")
        }
        // Writing a row with every macro absent must succeed; under NOT NULL it would throw.
        let row = RestaurantFoodRow(id: "r1", deviceId: "diet", chain: "kura sushi",
                                    chainLabel: "Kura Sushi", name: "Salmon nigiri",
                                    importedAt: 1_760_000_000)
        _ = try await store.upsertRestaurantFoods([row])
        let back = try await store.restaurantFoods(deviceId: "diet", chain: "kura sushi")
        XCTAssertEqual(back.count, 1)
        XCTAssertNil(back.first?.kcal)
        XCTAssertNil(back.first?.fat)
    }

    func testV53PartialRowsRoundTripWithTheirGapsIntact() async throws {
        let store = try await WhoopStore.inMemory()
        // The real shape: kcal and protein published, fat and fibre not.
        _ = try await store.upsertRestaurantFoods([
            RestaurantFoodRow(id: "r2", deviceId: "diet", chain: "kura sushi", chainLabel: "Kura Sushi",
                              name: "Tamago", servingLabel: "1 piece", kcal: 60, protein: 3,
                              importedAt: 1_760_000_000),
        ])
        let back = try await store.restaurantFoods(deviceId: "diet", chain: "kura sushi").first
        XCTAssertEqual(back?.kcal ?? .nan, 60, accuracy: 0.001)
        XCTAssertEqual(back?.protein ?? .nan, 3, accuracy: 0.001)
        XCTAssertNil(back?.fat, "an unpublished value must not come back as zero")
        XCTAssertNil(back?.fiber)
    }

    /// THE QUERY THE SINGLE-TABLE DESIGN EXISTS FOR: eating at a chain with no figures for a dish, while
    /// another chain has a comparable one. Across tables-per-chain this would be a join over an unknown
    /// number of tables.
    func testV53FindsAComparableItemInAnotherChain() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertRestaurantFoods([
            RestaurantFoodRow(id: "k1", deviceId: "diet", chain: "kura sushi", chainLabel: "Kura Sushi",
                              name: "Salmon nigiri", kcal: 90, protein: 6, importedAt: 1),
            RestaurantFoodRow(id: "h1", deviceId: "diet", chain: "hama sushi", chainLabel: "Hama Sushi",
                              name: "Tamago nigiri", kcal: 70, importedAt: 1),
        ])
        let matches = try await store.restaurantFoodsMatching(deviceId: "diet", nameLike: "salmon")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.chainLabel, "Kura Sushi")
    }

    /// A re-import is a new EDITION, not a diff: items get renamed, withdrawn and re-costed, and diffing
    /// would leave withdrawn ones behind forever.
    func testV53ReimportReplacesTheChainWholesale() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.replaceRestaurantMenu(deviceId: "diet", chain: "kura sushi", with: [
            RestaurantFoodRow(id: "a", deviceId: "diet", chain: "kura sushi", chainLabel: "Kura Sushi",
                              name: "Withdrawn item", kcal: 100, importedAt: 1),
        ])
        _ = try await store.replaceRestaurantMenu(deviceId: "diet", chain: "kura sushi", with: [
            RestaurantFoodRow(id: "b", deviceId: "diet", chain: "kura sushi", chainLabel: "Kura Sushi",
                              name: "Current item", kcal: 120, importedAt: 2),
        ])
        let rows = try await store.restaurantFoods(deviceId: "diet", chain: "kura sushi")
        XCTAssertEqual(rows.map(\.name), ["Current item"])
    }

    /// Chain names are normalised ONCE, by a rule both the writer and every reader share — two rules would
    /// let "Kura Sushi" and "kura  sushi" become separate chains.
    func testV53ChainNormalisationIsSingleSpelled() {
        XCTAssertEqual(RestaurantFoodRow.normalisedChain("  Kura   Sushi "), "kura sushi")
        XCTAssertEqual(RestaurantFoodRow.normalisedChain("KURA SUSHI"), "kura sushi")
    }

    func testV53ListsChainsWithTheirCounts() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertRestaurantFoods([
            RestaurantFoodRow(id: "a", deviceId: "diet", chain: "kura sushi", chainLabel: "Kura Sushi",
                              name: "One", importedAt: 1),
            RestaurantFoodRow(id: "b", deviceId: "diet", chain: "kura sushi", chainLabel: "Kura Sushi",
                              name: "Two", importedAt: 1),
            RestaurantFoodRow(id: "c", deviceId: "diet", chain: "hama sushi", chainLabel: "Hama Sushi",
                              name: "Three", importedAt: 1),
        ])
        let chains = try await store.restaurantChains(deviceId: "diet")
        XCTAssertEqual(chains.count, 2)
        XCTAssertEqual(chains.first(where: { $0.chain == "kura sushi" })?.count, 2)
    }

    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 18)
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    /// v26 heals `efficiency` values stored on the 0-100 percent scale (written by the pre-fix Oura API
    /// importer AND the pre-fix WHOOP CSV importer, under any deviceId) back to NOOP's 0-1 fraction
    /// convention. UPDATE-only: seed rows at the v25 schema (i.e. BEFORE v26 has run), then apply the
    /// rest of the migrator and confirm the heal.
    func testV26HealsEfficiencyPercentToFraction() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v25-oura-raw")
        try await dbQueue.write { db in
            // oura-api, bad (percent) → must be healed to a fraction.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 100, 200, 90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-01', 90)
                """)
            // oura-api, already a fraction → must be left unchanged (idempotent predicate: efficiency > 1.5).
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 300, 400, 0.9)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-02', 0.9)
                """)
            // A WHOOP-CSV-imported percent row (arbitrary strap deviceId) must ALSO be healed — the
            // pre-fix WhoopImporter wrote "Sleep efficiency %" straight through, same bug class.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('my-whoop', 500, 600, 90)
                """)
            // A native fraction row under a strap deviceId must be left unchanged.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('my-whoop', 700, 800, 0.66)
                """)
        }

        // Apply the FULL migrator: GRDB resumes from the already-applied v25, so only v26 runs here.
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 100"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 300"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 500"), 0.9,
                           "a CSV-imported percent row must be healed regardless of deviceId")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 700"), 0.66,
                           "a native fraction row must never be touched")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-01'"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-02'"), 0.9)
        }
    }
}
