import Foundation

// MARK: - Which meal an entry belongs to
//
// A day's food as a flat list answers "what did I eat" only after you have read it all and added it up.
// Grouped by meal with subtotals, it answers at a glance — and "dinner was 680" is a far more actionable
// fact than six rows that happen to sum to it.
//
// EXPLICIT ALWAYS BEATS INFERRED. When the user has said which meal something was — to Coach, or by
// logging it at the time — that is a fact and the clock does not get to overrule it. Someone eating lunch
// at 23:00 after a long shift has had lunch.
//
// AN UNKNOWN TIME IS NOT A MEAL. A backfilled entry carries no real timestamp (the app stamps midday as an
// admission that the time is unknown — see `FoodLogView.logTimestamp`), so inferring "lunch" from it would
// be precisely the guess-dressed-as-a-fact that stamp exists to avoid. Those land in `.unassigned`, which
// renders as a plain heading rather than claiming a meal nobody stated.
//
// Pure: minute-of-day integers and an optional explicit meal. No Calendar, no timezone, no store.

/// A meal, in the order a day is eaten.
public enum Meal: String, Equatable, Sendable, CaseIterable {
    case breakfast, lunch, dinner, snack
    /// Logged without a meal and without a usable time — a backfilled day, almost always. Last in display
    /// order because it is the group with the least to say, not because it matters least.
    case unassigned

    /// Display order. `CaseIterable`'s order already matches, but relying on declaration order for
    /// something a screen depends on is the kind of coupling that breaks when a case is inserted.
    public var sortIndex: Int {
        switch self {
        case .breakfast: return 0
        case .lunch: return 1
        case .dinner: return 2
        case .snack: return 3
        case .unassigned: return 4
        }
    }
}

public enum MealGrouping {

    // MARK: - Boundaries

    /// Minute-of-day a day's eating stops counting as breakfast. 11:00.
    ///
    /// Later than the conventional 10:00 or 10:30, deliberately. Plenty of people — the author of this
    /// fork among them — wake at 09:30–10:30 and take their first meal at 11:30 as LUNCH, having skipped
    /// breakfast entirely. A 10:00 boundary would label that a late breakfast and then show a day with a
    /// breakfast they did not eat and no lunch they did.
    ///
    /// The cost of being generous here is small: an early riser's 10:30 breakfast reads as breakfast
    /// either way, and anyone whose pattern this misreads can tell Coach the meal outright.
    public static let breakfastEndsMinute = 11 * 60

    /// Minute-of-day lunch gives way to dinner. 16:00 — late enough to hold a 15:00 lunch, early enough
    /// that an early dinner is not called lunch.
    public static let lunchEndsMinute = 16 * 60

    /// Minute-of-day dinner gives way to a late snack. 21:00.
    public static let dinnerEndsMinute = 21 * 60

    /// Minute-of-day before which eating is a late-night snack rather than breakfast. 05:00 — 02:00 is the
    /// end of a long night, not the start of a day.
    public static let nightEndsMinute = 5 * 60

    // MARK: - Classifying

    /// Which meal an entry belongs to.
    ///
    /// - Parameters:
    ///   - explicit: the meal the user or Coach stated. Wins outright when present.
    ///   - minuteOfDay: minute since local midnight the entry was logged at.
    ///   - isUnknownTime: true when the timestamp is the backfill sentinel rather than a real time, in
    ///     which case no inference is made at all.
    public static func meal(explicit: Meal?, minuteOfDay: Int, isUnknownTime: Bool) -> Meal {
        if let explicit { return explicit }
        guard !isUnknownTime else { return .unassigned }
        guard minuteOfDay >= 0, minuteOfDay < 24 * 60 else { return .unassigned }

        if minuteOfDay < nightEndsMinute { return .snack }
        if minuteOfDay < breakfastEndsMinute { return .breakfast }
        if minuteOfDay < lunchEndsMinute { return .lunch }
        if minuteOfDay < dinnerEndsMinute { return .dinner }
        return .snack
    }

    // MARK: - Grouping

    /// One meal's worth of a day, ready to render.
    public struct Group<Item>: Sendable where Item: Sendable {
        public let meal: Meal
        public let items: [Item]
        /// The group's own total, summed by the SAME helper the day total uses — so a subtotal and the day
        /// figure can never be derived two different ways and disagree.
        public let total: MacroTotals

        public init(meal: Meal, items: [Item], total: MacroTotals) {
            self.meal = meal
            self.items = items
            self.total = total
        }
    }

    /// Group items into meals, dropping empty ones.
    ///
    /// EMPTY GROUPS ARE DROPPED, which is the behaviour the skipped-breakfast case needs: a day of lunch
    /// and dinner must render two headings, not four with two of them blank. A placeholder for a meal
    /// somebody deliberately does not eat is noise that implies they got something wrong.
    ///
    /// Generic over the item so this stays free of the app's `FoodEntry` and remains testable with
    /// anything. The caller supplies how to read a meal and macros off an item.
    public static func grouped<Item: Sendable>(_ items: [Item],
                                              meal: (Item) -> Meal,
                                              macros: (Item) -> MacroTotals) -> [Group<Item>] {
        var byMeal: [Meal: [Item]] = [:]
        for item in items {
            byMeal[meal(item), default: []].append(item)
        }
        return byMeal
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .map { Group(meal: $0.key, items: $0.value, total: NutritionMath.total($0.value.map(macros))) }
    }
}
