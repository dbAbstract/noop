import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Food log (v0) — opt-in, local-only food & macro logging
//
// The user saves reusable FOOD ITEMS (a packet of crisps, a scoop of whey) and logs them against a day with
// a portion multiplier. The day's macro TOTALS are banked in the generic `metricSeries` tall table under the
// already-registered nutrition keys, so Trends / Compare / Explore light up with no new plumbing and no
// schema change. The individual ENTRIES live in per-day UserDefaults JSON.
//
// That split is lifted wholesale from `HydrationStore`: `metricSeries` is the canonical day figure every
// other surface reads, and the entry list is the editable detail behind it, kept in sync so deleting or
// re-portioning an entry re-derives and re-banks the totals.
//
// WHY NOT A GRDB TABLE (v0): a new table obliges updating BOTH copies of `schema_oracle.json` and commits
// the (currently deferred) Room side to matching column order forever — a permanent parity liability taken
// on before the model has settled. Caffeine and hydration entries already live in UserDefaults JSON, and
// period views never read the entry lists (they range-query `metricSeries`, which IS SQLite), so the JSON
// store is only ever read one day at a time. Promote to a `vN-food-log` migration when recipes arrive.
//
// PARITY DEBT: there is no Kotlin twin yet. Android needs `com.noop.analytics.FoodLogStore` over
// SharedPreferences with identical source ids, keys and rounding before this could go upstream.

enum FoodLogStore {
    /// Source/device id the day totals are written under — its own local-only source, never confused with
    /// the `nutrition-csv` import or a strap metric.
    static let sourceId = "food-log"

    /// Settings opt-in key (default OFF, matching every other optional tracker).
    static let enabledKey = "noop.foodLogging"

    /// UserDefaults key for the saved item library — ONE JSON array, not per-day. Small enough to hold in
    /// memory (a personal library is hundreds of items, not millions) and read only when a picker opens.
    static let libraryKey = "noop.foodLibrary"

    /// UserDefaults prefix for the per-day entry list, `noop.foodEntries.<yyyy-MM-dd>`. One array per local
    /// day so a read is small and a day's edit never rewrites unrelated history.
    static let entriesKeyPrefix = "noop.foodEntries."

    static func entriesKey(forDay dayKey: String) -> String { entriesKeyPrefix + dayKey }

    /// The `metricSeries` keys a logged day writes. Mirrors `NutritionCsvImporter.Keys` for the four it
    /// shares, plus `fiber_g`, which the CSV importer has no column for.
    enum Keys {
        static let caloriesIn = "calories_in"
        static let proteinG = "protein_g"
        static let carbsG = "carbs_g"
        static let fatG = "fat_g"
        static let fiberG = "fiber_g"

        /// Every key a day total writes, so a re-bank can clear all five together and none is left behind
        /// holding a stale figure after the last entry of a day is deleted.
        static let all = [caloriesIn, proteinG, carbsG, fatG, fiberG]
    }
}

// MARK: - Models

/// A reusable food in the user's library. `macros` are PER SERVING; a log scales them by its portion.
struct FoodItem: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    /// What one serving IS, in the user's own words — "1 scoop", "100 g", "1 medium banana". Free text on
    /// purpose: a food's natural unit is not always mass, and forcing grams would make the user do the
    /// conversion NOOP is supposed to save them.
    var servingLabel: String
    var macros: MacroTotals
    var createdAt: Date
    /// Bumped on every log so the picker can surface recents first. Optional so items written by an older
    /// build (or an import) decode without a migration.
    var lastUsedAt: Date?

    init(id: UUID = UUID(), name: String, servingLabel: String, macros: MacroTotals,
         createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.servingLabel = servingLabel
        self.macros = macros
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// One logged eat.
///
/// `nameSnapshot` and `macrosSnapshot` are copies taken AT LOG TIME, deliberately duplicating the library
/// item. Editing "Protein shake" to a new recipe next month must not silently rewrite what last month's
/// days say you ate, and deleting the item must not strand its history. `itemId` is kept only so the picker
/// can offer "log this again" — nothing reads through it for macros.
struct FoodEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var itemId: UUID?
    var nameSnapshot: String
    var macrosSnapshot: MacroTotals
    /// Servings eaten. 1.0 = one serving as the item defines it.
    var portion: Double
    var loggedAt: Date
    /// Carried but not surfaced in v0, so grouping by meal can arrive later without touching stored data.
    var mealType: MealType?

    init(id: UUID = UUID(), itemId: UUID?, nameSnapshot: String, macrosSnapshot: MacroTotals,
         portion: Double, loggedAt: Date = Date(), mealType: MealType? = nil) {
        self.id = id
        self.itemId = itemId
        self.nameSnapshot = nameSnapshot
        self.macrosSnapshot = macrosSnapshot
        self.portion = portion
        self.loggedAt = loggedAt
        self.mealType = mealType
    }

    /// What this entry actually contributes to the day — the snapshot scaled by the portion.
    var effectiveMacros: MacroTotals { NutritionMath.scaled(macrosSnapshot, portion: portion) }
}

enum MealType: String, Codable, CaseIterable, Equatable {
    case breakfast, lunch, dinner, snack
}

// MARK: - Pure list operations (unit-testable without a store)

/// Add / remove / re-portion / total over a day's entries. Kept free of persistence and UI so the list math
/// is testable in isolation — the same split `HydrationEntries` uses.
enum FoodEntries {
    /// Append an entry. A non-positive or non-finite portion is rejected outright rather than stored and
    /// silently scaled to zero later, so the list never holds a row that contributes nothing.
    static func adding(_ entries: [FoodEntry], _ entry: FoodEntry) -> [FoodEntry] {
        guard entry.portion.isFinite, entry.portion > 0 else { return entries }
        return entries + [entry]
    }

    static func removing(_ entries: [FoodEntry], id: UUID) -> [FoodEntry] {
        entries.filter { $0.id != id }
    }

    /// Re-portion an existing entry. A non-positive portion deletes it (an edit to 0 is a delete), matching
    /// `HydrationEntries.updating`. Unknown ids are ignored.
    static func updating(_ entries: [FoodEntry], id: UUID, portion: Double) -> [FoodEntry] {
        guard portion.isFinite, portion > 0 else { return removing(entries, id: id) }
        return entries.map { e in
            guard e.id == id else { return e }
            var next = e
            next.portion = portion
            return next
        }
    }

    /// The day's totals — every entry scaled by its own portion, then summed.
    static func total(_ entries: [FoodEntry]) -> MacroTotals {
        NutritionMath.total(entries.map(\.effectiveMacros))
    }
}

/// Library operations. Separate from the day lists because the library is one global array, not per-day.
enum FoodLibrary {
    /// Insert or replace by id, then sort most-recently-used first so the picker's top rows are the foods
    /// the user actually repeats. Ties fall back to name so the order is stable rather than arbitrary.
    static func upserting(_ items: [FoodItem], _ item: FoodItem) -> [FoodItem] {
        var out = items.filter { $0.id != item.id }
        out.append(item)
        return sorted(out)
    }

    static func removing(_ items: [FoodItem], id: UUID) -> [FoodItem] {
        items.filter { $0.id != id }
    }

    /// Stamp `lastUsedAt` after a log so recents ordering reflects use, not creation.
    static func markingUsed(_ items: [FoodItem], id: UUID, at date: Date) -> [FoodItem] {
        sorted(items.map { item in
            guard item.id == id else { return item }
            var next = item
            next.lastUsedAt = date
            return next
        })
    }

    /// Case- and diacritic-insensitive substring match on the name. A blank query returns everything, so a
    /// picker can use one code path for "browsing" and "searching".
    static func matching(_ items: [FoodItem], query: String) -> [FoodItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func sorted(_ items: [FoodItem]) -> [FoodItem] {
        items.sorted { a, b in
            let ka = a.lastUsedAt ?? a.createdAt
            let kb = b.lastUsedAt ?? b.createdAt
            if ka != kb { return ka > kb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Logging + read seam (Repository extension)

extension Repository {

    // MARK: Entries

    /// A day's logged foods, oldest first. Empty when nothing was logged.
    func foodEntries(day: String? = nil) -> [FoodEntry] {
        Self.readFoodEntries(day: day ?? Repository.localDayKey(Date()))
    }

    /// The day's macro totals as stored. Derived from the entry list rather than read back out of
    /// `metricSeries` so the figure a screen shows cannot drift from the rows behind it.
    func foodTotals(day: String? = nil) -> MacroTotals {
        FoodEntries.total(foodEntries(day: day))
    }

    /// Log `item` at `portion` servings. Stamps the library item's `lastUsedAt`, appends the entry, then
    /// re-derives and re-banks the day totals. Returns the new day totals.
    @discardableResult
    func logFood(item: FoodItem, portion: Double, day: String? = nil,
                 at date: Date = Date(), mealType: MealType? = nil) async -> MacroTotals {
        let dayKey = day ?? Repository.localDayKey(date)
        let entry = FoodEntry(itemId: item.id, nameSnapshot: item.name, macrosSnapshot: item.macros,
                              portion: portion, loggedAt: date, mealType: mealType)
        let current = Self.readFoodEntries(day: dayKey)
        let next = FoodEntries.adding(current, entry)
        // `adding` rejects a bad portion, so an unchanged list means nothing was logged — don't re-bank or
        // bump the UI for a write that did not happen.
        guard next.count != current.count else { return FoodEntries.total(current) }
        Self.writeFoodEntries(next, day: dayKey)
        Self.writeFoodLibrary(FoodLibrary.markingUsed(Self.readFoodLibrary(), id: item.id, at: date))
        return await rebankFoodTotals(entries: next, day: dayKey)
    }

    @discardableResult
    func deleteFoodEntry(id: UUID, day: String? = nil) async -> MacroTotals {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = FoodEntries.removing(Self.readFoodEntries(day: dayKey), id: id)
        Self.writeFoodEntries(next, day: dayKey)
        return await rebankFoodTotals(entries: next, day: dayKey)
    }

    /// Re-portion a logged entry (a non-positive portion deletes it), then re-derive and re-bank.
    @discardableResult
    func updateFoodEntry(id: UUID, portion: Double, day: String? = nil) async -> MacroTotals {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = FoodEntries.updating(Self.readFoodEntries(day: dayKey), id: id, portion: portion)
        Self.writeFoodEntries(next, day: dayKey)
        return await rebankFoodTotals(entries: next, day: dayKey)
    }

    /// Re-derive the day totals from `entries` and upsert all five nutrition keys.
    ///
    /// Writes every key on every re-bank, including zeros, rather than only the non-zero ones. Deleting the
    /// last fatty food of a day must drive `fat_g` to 0; skipping the write would strand yesterday's figure
    /// in the table and the chart would keep showing food that is no longer logged.
    @discardableResult
    private func rebankFoodTotals(entries: [FoodEntry], day dayKey: String) async -> MacroTotals {
        let totals = FoodEntries.total(entries)
        if let store = await storeHandle() {
            let points = [
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.caloriesIn, value: totals.kcal),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.proteinG, value: totals.protein),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.carbsG, value: totals.carbs),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.fatG, value: totals.fat),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.fiberG, value: totals.fiber),
            ]
            _ = try? await store.upsertMetricSeries(points, deviceId: FoodLogStore.sourceId)
        }
        noteFoodChanged()
        return totals
    }

    /// The last `days` local-day calorie-in totals up to and including today, OLDEST first, one row per
    /// calendar day with 0 for days with no log. Backs the mini history bars.
    ///
    /// Reads `metricSeries` rather than the per-day JSON: one ranged SQL read beats N UserDefaults reads,
    /// and the table is exactly what the re-bank above keeps current.
    func foodHistory(days: Int = 7, now: Date = Date()) async -> [(day: String, kcal: Double)] {
        let n = max(1, days)
        let fromKey = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1) * 86_400))
        let toKey = Repository.localDayKey(now)
        var byDay: [String: Double] = [:]
        if let store = await storeHandle() {
            let pts = (try? await store.metricSeries(deviceId: FoodLogStore.sourceId,
                                                     key: FoodLogStore.Keys.caloriesIn,
                                                     from: fromKey, to: toKey)) ?? []
            for p in pts { byDay[p.day] = p.value }
        }
        return (0..<n).map { i in
            let key = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1 - i) * 86_400))
            return (key, byDay[key] ?? 0)
        }
    }

    // MARK: Library

    func foodLibrary() -> [FoodItem] { Self.readFoodLibrary() }

    /// Insert or update a library item. Does NOT touch any logged entry — existing entries keep their
    /// snapshots, which is the point of taking them.
    func saveFoodItem(_ item: FoodItem) {
        Self.writeFoodLibrary(FoodLibrary.upserting(Self.readFoodLibrary(), item))
        noteFoodChanged()
    }

    /// Remove a library item. Logged history is untouched and still renders, because each entry carries its
    /// own name and macros.
    func deleteFoodItem(id: UUID) {
        Self.writeFoodLibrary(FoodLibrary.removing(Self.readFoodLibrary(), id: id))
        noteFoodChanged()
    }

    // MARK: Persistence (UserDefaults JSON)

    fileprivate static func readFoodEntries(day dayKey: String) -> [FoodEntry] {
        guard let data = UserDefaults.standard.data(forKey: FoodLogStore.entriesKey(forDay: dayKey)),
              let decoded = try? JSONDecoder().decode([FoodEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.loggedAt < $1.loggedAt }
    }

    fileprivate static func writeFoodEntries(_ entries: [FoodEntry], day dayKey: String) {
        let key = FoodLogStore.entriesKey(forDay: dayKey)
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    fileprivate static func readFoodLibrary() -> [FoodItem] {
        guard let data = UserDefaults.standard.data(forKey: FoodLogStore.libraryKey),
              let decoded = try? JSONDecoder().decode([FoodItem].self, from: data) else { return [] }
        return FoodLibrary.sorted(decoded)
    }

    fileprivate static func writeFoodLibrary(_ items: [FoodItem]) {
        if items.isEmpty {
            UserDefaults.standard.removeObject(forKey: FoodLogStore.libraryKey)
        } else if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: FoodLogStore.libraryKey)
        }
    }
}

// MARK: - Weight log — hand-entered weigh-ins

enum WeightLogStore {
    /// Its own source so a hand-entered weigh-in never collides with Apple Health's `weight` series, which
    /// is owned by whichever app wrote it and gets replaced wholesale on import.
    static let sourceId = "weight-log"
    static let key = "weight"
}

extension Repository {

    /// Record a weigh-in (kg) for a local day, replacing any earlier value for that day — a second reading
    /// on one morning is a correction, not a second data point, and `AdaptiveExpenditureEngine` counts
    /// DISTINCT days rather than readings precisely so a chatty scale cannot buy extra confidence.
    ///
    /// Also writes the profile's weight scalar, which feeds the Harris–Benedict resting term in every
    /// calorie estimate — a weigh-in that left the profile stale would keep scoring against an old mass.
    /// The caller passes `profile` explicitly so this stays a plain Repository function with no ambient
    /// dependency on a store it does not own.
    @discardableResult
    func logWeight(kg: Double, day: String? = nil, profile: ProfileStore? = nil) async -> Bool {
        guard kg.isFinite, kg > 0 else { return false }
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle() else { return false }
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: dayKey, key: WeightLogStore.key, value: kg)],
            deviceId: WeightLogStore.sourceId)
        profile?.weightKg = kg
        noteFoodChanged()
        return true
    }

    /// Hand-logged weigh-ins over the last `days`, oldest first — only days that actually have a reading.
    /// Unlike the calorie history this does NOT pad missing days with zeros: a day without a weigh-in has
    /// no weight, and a zero would be a fabricated measurement rather than an absent one.
    func weightHistory(days: Int = 30, now: Date = Date()) async -> [(day: String, kg: Double)] {
        let n = max(1, days)
        let fromKey = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1) * 86_400))
        let toKey = Repository.localDayKey(now)
        guard let store = await storeHandle(),
              let pts = try? await store.metricSeries(deviceId: WeightLogStore.sourceId,
                                                      key: WeightLogStore.key,
                                                      from: fromKey, to: toKey) else { return [] }
        return pts.map { (day: $0.day, kg: $0.value) }
    }

    /// Today's weigh-in, if one was recorded.
    func weightToday(day: String? = nil) async -> Double? {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle() else { return nil }
        let pts = try? await store.metricSeries(deviceId: WeightLogStore.sourceId,
                                                key: WeightLogStore.key, from: dayKey, to: dayKey)
        return pts?.first?.value
    }
}
