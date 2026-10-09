import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Food log (v0) — opt-in, local-only food & macro logging
//
// The user saves reusable FOOD ITEMS (a packet of crisps, a scoop of whey) and logs them against a day with
// a portion multiplier. The day's macro TOTALS are banked in the generic `metricSeries` tall table under the
// already-registered nutrition keys, so Trends / Compare / Explore light up with no new plumbing. The
// saved library and the individual ENTRIES live in the v48 `foodItem` / `foodEntry` tables.
//
// `metricSeries` stays the canonical day figure every other surface reads, and the entry rows are the
// editable detail behind it, kept in sync so deleting or re-portioning an entry re-derives and re-banks
// the totals.
//
// WHY THE DATABASE and not UserDefaults, where the first cut put them: `.noopbak` — the full backup, and
// the only thing standing between a faulty migration and a lost log — is a ZIP of the SQLite file plus a
// FIXED whitelist of scalar settings (`BackupSettings`). Anything held outside the database is simply not
// in the backup, so a restore would have brought the charts back and silently dropped every saved food.
// Deleting the app takes the entire container with it, which makes that the difference between an
// inconvenience and losing the library outright. Hydration entries and caffeine intakes still have that
// hole; this one no longer does.
//
// PARITY DEBT: no Kotlin twin yet. Android needs the Room twin of the v48 tables (matching column ORDER,
// per AGENTS.md) plus `com.noop.analytics.FoodLogStore`, and both schema_oracle.json copies stay in step.

enum FoodLogStore {
    /// Source/device id the day totals are written under — its own local-only source, never confused with
    /// the `nutrition-csv` import or a strap metric.
    static let sourceId = "food-log"

    /// Settings opt-in key (default OFF, matching every other optional tracker).
    static let enabledKey = "noop.foodLogging"

    /// The `metricSeries` keys a logged day writes. Mirrors `NutritionCsvImporter.Keys` for the four it
    /// shares, plus `fiber_g`, which the CSV importer has no column for.
    enum Keys {
        static let caloriesIn = "calories_in"
        static let proteinG = "protein_g"
        static let carbsG = "carbs_g"
        static let fatG = "fat_g"
        static let fiberG = "fiber_g"

        /// 1 when any of the day's entries was logged as an admitted GUESS, 0 otherwise.
        ///
        /// A per-day flag banked beside the totals rather than derived from the entry rows on demand,
        /// because the adaptive engine needs it for every day in a six-week window and reading entries
        /// for each would be 42 queries where this is one ranged read — the same reasoning that put the
        /// totals here.
        ///
        /// Stored as a number because `metricSeries` carries Doubles. 0 and absent mean the same thing,
        /// which is fine: both say "nothing here was flagged as a guess".
        static let roughDay = "intake_rough"

        /// Every key a day total writes, so a re-bank can clear all of them together and none is left
        /// behind holding a stale figure after the last entry of a day is deleted.
        ///
        /// Includes `roughDay`, which is NOT a chartable quantity — see `charted`.
        static let all = [caloriesIn, proteinG, carbsG, fatG, fiberG, roughDay]

        /// The subset that is a MEASURED QUANTITY and therefore belongs in the metric catalog.
        ///
        /// Split from `all` because the two lists answer different questions and a single list answering
        /// both gets one of them wrong. `all` is "what must be cleared on a re-bank"; this is "what can be
        /// plotted". `roughDay` is a 0/1 flag about how a figure was obtained — charting it would put a
        /// square wave in the metric explorer and invite it to be read as an amount.
        ///
        /// A guard test asserts this stays a subset of `all`, so a new chartable key cannot be registered
        /// in the catalog while being left out of the clear list.
        static let charted = [caloriesIn, proteinG, carbsG, fatG, fiberG]
    }
}

// MARK: - Models

/// A reusable food in the user's library. `macros` are PER SERVING; a log scales them by its portion.
struct FoodItem: Identifiable, Equatable, Codable {
    let id: UUID
    /// nil when the user stated these macros; `FoodMacroSource.aiEstimate` when a model proposed them and
    /// the user accepted. An estimate that reads as a label figure is the failure this prevents.
    var macroSource: String?
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

    init(id: UUID = UUID(), macroSource: String? = nil, name: String, servingLabel: String,
         macros: MacroTotals, createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.macroSource = macroSource
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
    /// Snapshotted alongside the macros, because the snapshot outlives library edits and "this number
    /// was once a guess" is exactly the kind of fact a log should keep.
    var macroSource: String?
    var itemId: UUID?
    var nameSnapshot: String
    var macrosSnapshot: MacroTotals
    /// Servings eaten. 1.0 = one serving as the item defines it.
    var portion: Double
    var loggedAt: Date
    /// Which meal this was, when it is known. nil means unknown rather than "no meal" — see
    /// `MealGrouping` for why an unknown time is not inferred into one.
    var mealType: MealType?
    /// The cook this portion came out of, if any.
    ///
    /// Non-nil reinterprets `portion` as a FRACTION OF THAT COOK — 0.6 is 60% of the pot, not 0.6
    /// servings — and `macrosSnapshot` as the WHOLE cook's macros, so `effectiveMacros` needs no special
    /// case: scaling the whole by the fraction is already the right arithmetic.
    var batchId: UUID?

    init(id: UUID = UUID(), macroSource: String? = nil, itemId: UUID?, nameSnapshot: String,
         macrosSnapshot: MacroTotals, portion: Double, loggedAt: Date = Date(),
         mealType: MealType? = nil, batchId: UUID? = nil) {
        self.id = id
        self.macroSource = macroSource
        self.itemId = itemId
        self.nameSnapshot = nameSnapshot
        self.macrosSnapshot = macrosSnapshot
        self.portion = portion
        self.loggedAt = loggedAt
        self.mealType = mealType
        self.batchId = batchId
    }

    /// What this entry actually contributes to the day — the snapshot scaled by the portion.
    var effectiveMacros: MacroTotals { NutritionMath.scaled(macrosSnapshot, portion: portion) }
}

/// Where a macro figure came from.
///
/// A deliberately small vocabulary: the absence of a value means the user stated the numbers, which is
/// the overwhelming case and should not need a marker. Only a guess needs labelling.
enum FoodMacroSource {
    /// Stored value for a figure a language model proposed and the user accepted.
    static let aiEstimate = "ai-estimate"
    /// The user's own admitted guess — a restaurant meal, a day out, something with no label to read.
    ///
    /// Exists because the alternative behaviour is logging NOTHING, and an omitted day is worse evidence
    /// than a bad guess in two separate ways: it is a hole in the coverage the adaptive engine gates on,
    /// and it is a silent downward bias, because the days people skip are the big ones. Marking a guess
    /// as a guess is what lets the engine widen its interval honestly instead of treating the number as
    /// though it had been read off a packet.
    static let roughGuess = "rough-guess"
}

/// The STORED meal vocabulary: four cases, and nullable.
///
/// Deliberately NOT `StrandAnalytics.Meal`, which carries a fifth `unassigned` case for display. nil here
/// already means unassigned, so making it storable too would give two spellings of one state — and every
/// reader would then have to handle both or be subtly wrong about one.
enum MealType: String, Codable, CaseIterable, Equatable {
    case breakfast, lunch, dinner, snack

    /// How this renders. nil maps to `.unassigned`, which is the whole reason that case exists.
    static func displayMeal(_ stored: MealType?) -> Meal? {
        guard let stored else { return nil }
        return Meal(rawValue: stored.rawValue)
    }

    /// The stored form of an inferred meal. `.unassigned` deliberately does not round-trip: there is
    /// nothing to store for it, and writing the string "unassigned" would be the second spelling this type
    /// exists to prevent.
    static func fromMeal(_ meal: Meal) -> MealType? {
        MealType(rawValue: meal.rawValue)
    }
}

extension FoodEntry {

    /// The meal this renders under.
    ///
    /// A stored `mealType` wins. Failing that the time is used — EXCEPT when it is the backfill sentinel,
    /// which is not a time at all.
    ///
    /// THE SENTINEL CHECK IS A LEGACY PATH. `FoodLogView.logTimestamp` stamps a backfilled entry at exactly
    /// 12:00:00 local as "the real time is unknown", and it was the only writer of that instant — a live
    /// `Date()` landing on 12:00:00.000 is not a real case. Every entry written from now on stores its meal
    /// (or nil for a backfill), so this only has to resolve entries logged before that change. It is
    /// deliberately narrow rather than "anything near midday", which would misread a real noon lunch.
    var displayMeal: Meal {
        MealGrouping.meal(explicit: MealType.displayMeal(mealType),
                          minuteOfDay: FoodEntries.minuteOfDay(loggedAt),
                          isUnknownTime: FoodEntries.isBackfillSentinel(loggedAt))
    }
}

// MARK: - Pure list operations (unit-testable without a store)

/// Add / remove / re-portion / total over a day's entries. Kept free of persistence and UI so the list math
/// is testable in isolation — the same split `HydrationEntries` uses.
enum FoodEntries {

    /// Minutes since local midnight for a logged-at instant.
    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Whether an instant is the backfill sentinel — exactly 12:00:00 local, to the second.
    ///
    /// Checked to the SECOND on purpose. A looser "around midday" test would swallow a genuine 12:05 lunch,
    /// and the whole point is to tell "time unknown" apart from "ate at noon". See `FoodEntry.displayMeal`
    /// for why this only concerns entries written before meals were stored.
    static func isBackfillSentinel(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return c.hour == 12 && c.minute == 0 && c.second == 0 && (c.nanosecond ?? 0) < 1_000_000
    }

    /// The meal to STORE for a log, or nil when it genuinely is not known.
    ///
    /// Inferred from the clock only for a log landing on the day it is being made — that is the one case
    /// where the timestamp is a real time. A backfill gets nil: the user is reconstructing, and guessing
    /// which meal they are reconstructing is worse than admitting the gap, because a stored guess then
    /// looks exactly like a stated fact to every later reader.
    static func mealToStore(dayKey: String, loggedAt: Date, today: String,
                            explicit: MealType?) -> MealType? {
        if let explicit { return explicit }
        guard dayKey == today else { return nil }
        let meal = MealGrouping.meal(explicit: nil,
                                     minuteOfDay: minuteOfDay(loggedAt),
                                     isUnknownTime: false)
        return MealType.fromMeal(meal)
    }

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

// MARK: - Row mapping
//
// The app models carry UUIDs and Dates because that is what SwiftUI and the pure list helpers want; the
// store speaks TEXT ids and unix seconds. Mapping happens only here, at the boundary.
//
// Everything is written under `FoodLogStore.sourceId` as its deviceId — the SAME id the day totals go to
// in `metricSeries`. Deliberately NOT `Repository.deviceId`, which follows the ACTIVE STRAP: a food log
// belongs to the person, not to the band they happened to be wearing, and keying it to the strap would
// strand the library behind a remove-and-re-add.

private extension FoodItem {
    init(row: FoodItemRow) {
        self.init(id: UUID(uuidString: row.id) ?? UUID(),
                  macroSource: row.macroSource,
                  name: row.name,
                  servingLabel: row.servingLabel,
                  macros: MacroTotals(kcal: row.kcal, protein: row.protein, carbs: row.carbs,
                                      fat: row.fat, fiber: row.fiber),
                  createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAt)),
                  lastUsedAt: row.lastUsedTs.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    var row: FoodItemRow {
        FoodItemRow(id: id.uuidString, deviceId: FoodLogStore.sourceId, name: name,
                    servingLabel: servingLabel, kcal: macros.kcal, protein: macros.protein,
                    carbs: macros.carbs, fat: macros.fat, fiber: macros.fiber,
                    createdAt: Int(createdAt.timeIntervalSince1970),
                    lastUsedTs: lastUsedAt.map { Int($0.timeIntervalSince1970) },
                    macroSource: macroSource)
    }
}

// Internal rather than private: `Repository.foodEntriesWithDays(from:to:)` and the cook reads in
// `Strand/Data/FoodBatchStore.swift` need the same bridge, and a second copy of it is how the row and the
// model drift apart. Left-private, the call resolved to `Decodable.init(from:)` instead and failed with a
// label error that says nothing about the real cause.
extension FoodEntry {
    init(row: FoodEntryRow) {
        self.init(id: UUID(uuidString: row.id) ?? UUID(),
                  macroSource: row.macroSource,
                  itemId: row.itemId.flatMap(UUID.init(uuidString:)),
                  nameSnapshot: row.nameSnapshot,
                  macrosSnapshot: MacroTotals(kcal: row.kcal, protein: row.protein, carbs: row.carbs,
                                              fat: row.fat, fiber: row.fiber),
                  portion: row.portion,
                  loggedAt: Date(timeIntervalSince1970: TimeInterval(row.loggedAt)),
                  mealType: row.mealType.flatMap(MealType.init(rawValue:)),
                  batchId: row.batchId.flatMap(UUID.init(uuidString:)))
    }

    func row(day: String) -> FoodEntryRow {
        FoodEntryRow(id: id.uuidString, deviceId: FoodLogStore.sourceId, day: day,
                     itemId: itemId?.uuidString, nameSnapshot: nameSnapshot, portion: portion,
                     kcal: macrosSnapshot.kcal, protein: macrosSnapshot.protein,
                     carbs: macrosSnapshot.carbs, fat: macrosSnapshot.fat, fiber: macrosSnapshot.fiber,
                     loggedAt: Int(loggedAt.timeIntervalSince1970), mealType: mealType?.rawValue,
                     macroSource: macroSource, batchId: batchId?.uuidString)
    }
}

// MARK: - Logging + read seam (Repository extension)

extension Repository {

    // MARK: Entries

    /// A day's logged foods, oldest first. Empty when nothing was logged.
    ///
    /// The displayed NAME is resolved live from the library item when that item still exists, falling
    /// back to the stored snapshot once it has been deleted. A rename therefore updates every past entry
    /// at once, with no migration and no write that could half-succeed.
    ///
    /// Names and macros are treated differently ON PURPOSE. A name is a LABEL for a thing — correcting
    /// "protein yogurt" to "Danone protein yogurt" describes the same yogurt better, and leaving history
    /// on the old label would just be stale. Macros are a MEASUREMENT of what was eaten; rewriting those
    /// retroactively would change the record rather than its description, so they stay snapshotted.
    ///
    /// It is also analytically free: nothing reads the name. Every total comes from `macrosSnapshot` on
    /// the entry, never from the library item.
    ///
    /// The one case this gets wrong is REPURPOSING rather than correcting — renaming an item to a
    /// genuinely different food relabels its history too. That cannot be told apart automatically, so the
    /// edit sheet says the rename applies everywhere and offers saving a new food instead.
    func foodEntries(day: String? = nil) async -> [FoodEntry] {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle() else { return [] }
        let rows = (try? await store.foodEntries(deviceId: FoodLogStore.sourceId, day: dayKey)) ?? []
        guard !rows.isEmpty else { return [] }
        let library = await foodLibrary()
        var nameById: [UUID: String] = [:]
        for item in library { nameById[item.id] = item.name }
        return rows.map { row in
            var entry = FoodEntry(row: row)
            if let id = entry.itemId, let current = nameById[id] { entry.nameSnapshot = current }
            return entry
        }
    }

    /// The day's macro totals, derived from the entry rows rather than read back out of `metricSeries`,
    /// so the figure a screen shows cannot drift from the rows behind it.
    func foodTotals(day: String? = nil) async -> MacroTotals {
        FoodEntries.total(await foodEntries(day: day))
    }

    /// Log `item` at `portion` servings: stamp the library item's recency, insert the entry, then
    /// re-derive and re-bank the day totals. Returns the new day totals.
    /// `saveToLibrary: false` logs a ONE-OFF — the meal is recorded in full, but nothing is added to the
    /// library and the entry carries no `itemId`.
    ///
    /// That is the common case and therefore the default in the UI. Most meals are eaten once; forcing
    /// each into the library would fill it with "Pret sandwich 14 March" and make the picker useless for
    /// the handful of foods actually eaten repeatedly. The entry still carries a full macro snapshot, so
    /// nothing analytical is lost — only the offer to log it again in one tap.
    @discardableResult
    func logFood(item: FoodItem, portion: Double, day: String? = nil,
                 at date: Date = Date(), mealType: MealType? = nil,
                 saveToLibrary: Bool = true) async -> MacroTotals {
        let dayKey = day ?? Repository.localDayKey(date)
        // Resolved rather than taken verbatim, so the meal is STORED from now on instead of being inferred
        // again by every reader. A caller that states one is honoured; otherwise it comes from the clock for
        // a same-day log and stays nil for a backfill.
        let resolvedMeal = FoodEntries.mealToStore(dayKey: dayKey, loggedAt: date,
                                                  today: Repository.localDayKey(Date()),
                                                  explicit: mealType)
        let entry = FoodEntry(macroSource: item.macroSource,
                              itemId: saveToLibrary ? item.id : nil,
                              nameSnapshot: item.name, macrosSnapshot: item.macros,
                              portion: portion, loggedAt: date, mealType: resolvedMeal)
        // Validated by the SAME pure helper the tests pin, so a bad portion is rejected identically
        // whether it came from the UI or from a future import — not re-checked inline here.
        let current = await foodEntries(day: dayKey)
        let next = FoodEntries.adding(current, entry)
        guard next.count != current.count, let store = await storeHandle() else {
            return FoodEntries.total(current)
        }
        _ = try? await store.upsertFoodEntries([entry.row(day: dayKey)])
        // Clear a reminder already sitting in Notification Centre, now that there is something logged.
        // Gated on the entry landing on TODAY: backfilling last Tuesday says nothing about whether today
        // has been logged, and clearing on it would dismiss a nudge that is still owed. It cannot cancel
        // a reminder yet to fire — see `FoodLogReminder.clearDeliveredIfAny` for why that is deliberate.
        if dayKey == Repository.localDayKey(Date()) {
            Task { @MainActor in FoodLogReminder.clearDeliveredIfAny() }
        }
        if saveToLibrary {
            var used = item
            used.lastUsedAt = date
            _ = try? await store.upsertFoodItems([used.row])
        }
        return await rebankFoodTotals(entries: next, day: dayKey)
    }

    @discardableResult
    func deleteFoodEntry(id: UUID, day: String? = nil) async -> MacroTotals {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle() else { return await foodTotals(day: dayKey) }
        _ = try? await store.deleteFoodEntry(deviceId: FoodLogStore.sourceId, id: id.uuidString)
        return await rebankFoodTotals(entries: await foodEntries(day: dayKey), day: dayKey)
    }

    /// Re-portion a logged entry (a non-positive portion deletes it), then re-derive and re-bank.
    @discardableResult
    func updateFoodEntry(id: UUID, portion: Double, day: String? = nil) async -> MacroTotals {
        let dayKey = day ?? Repository.localDayKey(Date())
        let current = await foodEntries(day: dayKey)
        let next = FoodEntries.updating(current, id: id, portion: portion)
        guard let store = await storeHandle() else { return FoodEntries.total(current) }
        if next.count < current.count {
            // `updating` treats a non-positive portion as a delete; mirror that in the store rather than
            // leaving a row the day total no longer counts.
            _ = try? await store.deleteFoodEntry(deviceId: FoodLogStore.sourceId, id: id.uuidString)
        } else if let edited = next.first(where: { $0.id == id }) {
            _ = try? await store.upsertFoodEntries([edited.row(day: dayKey)])
        }
        return await rebankFoodTotals(entries: next, day: dayKey)
    }

    /// Re-derive the day totals from `entries` and upsert all five nutrition keys.
    ///
    /// Writes every key on every re-bank, INCLUDING zeros. Deleting the last fatty food of a day must
    /// drive `fat_g` to 0; skipping the write would strand yesterday's figure in the table and the chart
    /// would keep showing food that is no longer logged.
    @discardableResult
    /// Internal rather than private: `logCookPortion` writes an entry by the same route and must rebank
    /// the day identically. A cook's portion contributes to the day exactly as any other entry does, and
    /// a second banking path is how two readouts of one day start to disagree.
    func rebankFoodTotals(entries: [FoodEntry], day dayKey: String) async -> MacroTotals {
        let totals = FoodEntries.total(entries)
        if let store = await storeHandle() {
            let points = [
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.caloriesIn, value: totals.kcal),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.proteinG, value: totals.protein),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.carbsG, value: totals.carbs),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.fatG, value: totals.fat),
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.fiberG, value: totals.fiber),
                // Re-derived from the day's entries on every write, so deleting the one rough entry
                // clears the flag rather than leaving the day marked as a guess forever.
                MetricPoint(day: dayKey, key: FoodLogStore.Keys.roughDay,
                            value: entries.contains { $0.macroSource == FoodMacroSource.roughGuess } ? 1 : 0),
            ]
            _ = try? await store.upsertMetricSeries(points, deviceId: FoodLogStore.sourceId)
        }
        noteFoodChanged()
        // A reminder that already fired is now stale — see FoodLogReminder.clearDeliveredIfAny.
        FoodLogReminder.clearDeliveredIfAny()
        return totals
    }

    /// The last `days` local-day calorie-in totals up to and including today, OLDEST first, one row per
    /// calendar day with 0 for days with no log.
    ///
    /// Reads `metricSeries` rather than the entry rows: one ranged read beats N per-day queries, and that
    /// table is exactly what the re-bank above keeps current.
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

    /// Local days in the window whose intake was logged as an admitted guess.
    ///
    /// A Set rather than a padded array: absence means "not a guess", so there is nothing to pad with and
    /// a membership test is what the caller actually asks.
    func roughIntakeDays(days: Int, now: Date = Date()) async -> Set<String> {
        let n = max(1, days)
        let fromKey = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1) * 86_400))
        let toKey = Repository.localDayKey(now)
        guard let store = await storeHandle(),
              let points = try? await store.metricSeries(deviceId: FoodLogStore.sourceId,
                                                        key: FoodLogStore.Keys.roughDay,
                                                        from: fromKey, to: toKey) else { return [] }
        return Set(points.filter { $0.value > 0 }.map(\.day))
    }

    // MARK: Library

    func foodLibrary() async -> [FoodItem] {
        guard let store = await storeHandle() else { return [] }
        let rows = (try? await store.foodItems(deviceId: FoodLogStore.sourceId)) ?? []
        return rows.map(FoodItem.init(row:))
    }

    /// Insert or update a library item. Does NOT touch any logged entry — existing entries keep their
    /// snapshots, which is the point of taking them.
    func saveFoodItem(_ item: FoodItem) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.upsertFoodItems([item.row])
        noteFoodChanged()
    }

    /// Remove a library item. Logged history is untouched and still renders, because each entry carries
    /// its own name and macros.
    func deleteFoodItem(id: UUID) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.deleteFoodItem(deviceId: FoodLogStore.sourceId, id: id.uuidString)
        noteFoodChanged()
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
        // The nudge has done its job; leaving it in Notification Centre asks for something already done.
        // Same treatment the food reminder gets once a meal lands.
        WeighInReminder.clearDeliveredIfAny()
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

    /// Remove a weigh-in. The trend is a regression through these points, so one mistyped reading — 7.3
    /// instead of 73 — drags the slope badly and cannot be out-voted by logging more. Being able to take
    /// it back out is what makes the trend trustworthy.
    @discardableResult
    func deleteWeight(day: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        _ = try? await store.deleteMetricSeriesPoint(deviceId: WeightLogStore.sourceId,
                                                    day: day, key: WeightLogStore.key)
        noteFoodChanged()
        return true
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
