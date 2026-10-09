import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Cooks, as the app handles them
//
// A cook is one making of a dish: macros for the WHOLE thing, drawn down by fractions. See
// `WhoopStore.FoodBatchStore` for why there is no stored remainder, and `BatchRemainder` for the
// arithmetic.
//
// Everything here reads the remainder rather than keeping one, which is why these are all `async` and
// none of them has a setter for it.

/// One cook, with what is left of it already worked out.
struct FoodCook: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The saved recipe this is a making of, or nil for a standalone cook.
    var recipeId: UUID?
    var name: String
    /// What differed about this cook — "400g chicken instead of the usual 500".
    var note: String?
    var cookedOn: String
    /// The WHOLE cook.
    var whole: MacroTotals
    var createdAt: Date
    var closedAt: Date?
    /// Every portion logged against it, in log order. The input to the remainder, kept rather than
    /// collapsed so an over-log can be described as the two entries it actually is.
    var loggedPortions: [Double]

    var remainingFraction: Double {
        BatchRemainder.remainingFraction(loggedPortions: loggedPortions)
    }
    var remainingMacros: MacroTotals {
        BatchRemainder.remainingMacros(whole: whole, fraction: remainingFraction)
    }
    /// How much more than the whole cook has been logged, or 0.
    var overage: Double { BatchRemainder.overage(loggedPortions: loggedPortions) }
}

extension Repository {

    /// Cooks from the leftover window, each with its remainder resolved.
    ///
    /// Resolves portions per cook rather than in one join, because the window is a handful of rows: a
    /// week of cooking is rarely more than five pots, and the clarity of one query per cook is worth
    /// more than a join saving four round trips against an on-device SQLite file.
    func recentCooks(now: Date = Date()) async -> [FoodCook] {
        guard let store = await storeHandle() else { return [] }
        let since = Repository.localDayKey(
            Calendar.current.date(byAdding: .day,
                                  value: -BatchRemainder.maxLeftoverDays, to: now) ?? now)
        let rows = (try? await store.foodBatches(deviceId: FoodLogStore.sourceId,
                                                 since: since)) ?? []
        var out: [FoodCook] = []
        for row in rows {
            let portions = (try? await store.batchPortions(deviceId: FoodLogStore.sourceId,
                                                           batchId: row.id)) ?? []
            out.append(FoodCook(
                id: UUID(uuidString: row.id) ?? UUID(),
                recipeId: row.recipeId.flatMap(UUID.init(uuidString:)),
                name: row.name,
                note: row.note,
                cookedOn: row.cookedOn,
                whole: MacroTotals(kcal: row.kcal, protein: row.protein, carbs: row.carbs,
                                   fat: row.fat, fiber: row.fiber),
                createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAt)),
                closedAt: row.closedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                loggedPortions: portions))
        }
        return out
    }

    /// The cooks with leftovers still worth offering.
    func openCooks(now: Date = Date()) async -> [FoodCook] {
        let today = Repository.epochDay(now)
        return await recentCooks(now: now).filter { cook in
            BatchRemainder.isOpen(remaining: cook.remainingFraction,
                                  isClosed: cook.closedAt != nil,
                                  cookedEpochDay: Repository.epochDay(dayKey: cook.cookedOn) ?? today,
                                  todayEpochDay: today)
        }
    }

    @discardableResult
    func saveCook(_ cook: FoodCook) async -> Bool {
        guard let store = await storeHandle() else { return false }
        let row = FoodBatchRow(
            id: cook.id.uuidString, deviceId: FoodLogStore.sourceId,
            recipeId: cook.recipeId?.uuidString, name: cook.name, note: cook.note,
            cookedOn: cook.cookedOn, kcal: cook.whole.kcal, protein: cook.whole.protein,
            carbs: cook.whole.carbs, fat: cook.whole.fat, fiber: cook.whole.fiber,
            createdAt: Int(cook.createdAt.timeIntervalSince1970),
            closedAt: cook.closedAt.map { Int($0.timeIntervalSince1970) })
        return (try? await store.upsertFoodBatch(row)) != nil
    }

    /// Mark the rest as binned, or undo that.
    func setCookClosed(_ id: UUID, closed: Bool, at now: Date = Date()) async {
        guard let store = await storeHandle() else { return }
        try? await store.closeFoodBatch(deviceId: FoodLogStore.sourceId, id: id.uuidString,
                                        at: closed ? Int(now.timeIntervalSince1970) : nil)
    }

    /// Entries across the coach's window, newest day last.
    func foodEntriesWithDays(from: String, to: String) async -> [(day: String, entry: FoodEntry)] {
        guard let store = await storeHandle() else { return [] }
        let rows = (try? await store.foodEntries(deviceId: FoodLogStore.sourceId,
                                                 from: from, to: to)) ?? []
        guard !rows.isEmpty else { return [] }
        // The same live-rename resolution `foodEntries(day:)` does: a library food that was renamed shows
        // its current name, because the snapshot exists to preserve the NUMBERS, not the spelling.
        let library = await foodLibrary()
        var nameById: [UUID: String] = [:]
        for item in library { nameById[item.id] = item.name }
        return rows.map { row in
            var entry = FoodEntry(row: row)
            if let id = entry.itemId, let current = nameById[id] { entry.nameSnapshot = current }
            return (day: row.day, entry: entry)
        }
    }
}

extension Repository {

    /// Eat a fraction of a cook.
    ///
    /// Mirrors `logFood` but snapshots the WHOLE COOK's macros with the fraction as the portion, so
    /// `effectiveMacros` needs no special case and the day totals come out right by the same arithmetic
    /// every other entry uses.
    ///
    /// `itemId` stays nil and `batchId` carries the link. A cook is not a library food — it is one
    /// making of a dish — and giving it an item would put every pot the user ever cooked into the picker.
    @discardableResult
    func logCookPortion(_ cook: FoodCook, portion: Double, day: String? = nil,
                        at date: Date = Date(), mealType: MealType? = nil) async -> Bool {
        let dayKey = day ?? Repository.localDayKey(date)
        let resolvedMeal = FoodEntries.mealToStore(dayKey: dayKey, loggedAt: date,
                                                   today: Repository.localDayKey(Date()),
                                                   explicit: mealType)
        let entry = FoodEntry(macroSource: FoodMacroSource.aiEstimate,
                              itemId: nil,
                              nameSnapshot: cook.name,
                              macrosSnapshot: cook.whole,
                              portion: portion, loggedAt: date, mealType: resolvedMeal,
                              batchId: cook.id)
        let current = await foodEntries(day: dayKey)
        let next = FoodEntries.adding(current, entry)
        guard next.count != current.count, let store = await storeHandle() else { return false }
        _ = try? await store.upsertFoodEntries([entry.row(day: dayKey)])
        if dayKey == Repository.localDayKey(Date()) {
            Task { @MainActor in FoodLogReminder.clearDeliveredIfAny() }
        }
        _ = await rebankFoodTotals(entries: next, day: dayKey)
        return true
    }

    /// Local days since 1970 for an instant.
    static func epochDay(_ date: Date, calendar: Calendar = .current) -> Int {
        Int((calendar.startOfDay(for: date).timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Local days since 1970 for a `yyyy-MM-dd` key, or nil when it does not parse.
    ///
    /// Returns nil rather than a fallback day: a key that will not parse is a bug upstream, and quietly
    /// resolving it to today would make a cook of unknown vintage look fresh.
    static func epochDay(dayKey: String) -> Int? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        guard let date = Calendar.current.date(from: c) else { return nil }
        return epochDay(date)
    }
}
