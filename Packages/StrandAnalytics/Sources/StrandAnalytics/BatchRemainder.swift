import Foundation

// MARK: - What is left of a cook
//
// A pot of karahi is not a serving and not a day's food. It is a QUANTITY that gets eaten down over
// several sittings, possibly across several days, and until now the app had nowhere to put that: a recipe
// composes to ONE serving, and a one-off log carries no identity for a second portion to draw against. So
// "I ate 60% last night and the rest today" had to be two unrelated guesses.
//
// A cook is the missing noun. Its macros describe the WHOLE thing, portions are fractions of it, and what
// remains is the arithmetic below.
//
// THE REMAINDER IS DERIVED, NEVER STORED, and that is the load-bearing decision here. A stored
// `remainingFraction` is a second answer to a question the entries already answer, and the two disagree
// the first time an entry is edited or deleted — the pot would still claim 40% left after the 60% log was
// removed. This is the same rule that makes a recipe "an item that has components" rather than an item
// carrying an `isRecipe` flag: the derived form cannot drift.
//
// OVERAGE IS REPORTED, NOT CLAMPED AWAY. Portions summing past 1.0 means a double-log or a bad estimate,
// and a bare `max(0, …)` would swallow exactly the mistake worth catching. The remainder clamps because a
// negative amount of food in the fridge is not a thing; the overage travels beside it so something can
// say "that is 110% of the pot".
//
// Pure. Kotlin-twinnable.

public enum BatchRemainder {

    /// Below this, a cook counts as finished. 1% of the whole.
    ///
    /// Not zero, because portions are estimates people say out loud — 0.6 and 0.3 and "the rest" will not
    /// land on 1.0 exactly, and a cook stuck at "2% left" forever would sit in the coach's context
    /// claiming leftovers that do not exist.
    public static let finishedEpsilon = 0.01

    /// How long leftovers stay offerable. 7 days.
    ///
    /// A bound rather than forever. The remainder is derived, so an abandoned cook never stops having one,
    /// and a context block naming month-old pots buries the live one it exists to surface. Food goes off;
    /// the model should not keep offering it.
    public static let maxLeftoverDays = 7

    /// What fraction of the cook is still uneaten, clamped to 0…1.
    ///
    /// Clamped at the top too: portions cannot sum to less than zero, but a negative portion slipping
    /// through would otherwise report more than a whole pot remaining.
    public static func remainingFraction(loggedPortions: [Double]) -> Double {
        let eaten = loggedPortions.filter { $0.isFinite }.reduce(0, +)
        return min(1, max(0, 1 - eaten))
    }

    /// How much MORE than the whole cook has been logged, or 0.
    ///
    /// Separate from `remainingFraction` on purpose: folding this into the clamp would make a double-log
    /// indistinguishable from a cook finished exactly, which is the one case worth telling the user about.
    public static func overage(loggedPortions: [Double]) -> Double {
        let eaten = loggedPortions.filter { $0.isFinite }.reduce(0, +)
        return max(0, eaten - 1)
    }

    /// The macros still in the fridge.
    ///
    /// Fibre scales with the rest: it is part of the food, and the "absent is not zero" rule that keeps it
    /// optional on PUBLISHED data does not apply to a figure the user already accepted for this cook.
    public static func remainingMacros(whole: MacroTotals, fraction: Double) -> MacroTotals {
        let f = min(1, max(0, fraction.isFinite ? fraction : 0))
        return MacroTotals(kcal: whole.kcal * f, protein: whole.protein * f, carbs: whole.carbs * f,
                           fat: whole.fat * f, fiber: whole.fiber * f)
    }

    /// Whether a cook should still be offered as leftovers.
    ///
    /// Three independent reasons to say no, and the explicit close outranks the other two: binning the
    /// rest is a statement about the food, where the remainder and the age are only inferences about it.
    ///
    /// - Parameters:
    ///   - remaining: from `remainingFraction`.
    ///   - isClosed: the user said the rest is gone.
    ///   - cookedEpochDay: local days since 1970, the app's day-key convention.
    ///   - todayEpochDay: likewise, now.
    public static func isOpen(remaining: Double,
                              isClosed: Bool,
                              cookedEpochDay: Int,
                              todayEpochDay: Int) -> Bool {
        guard !isClosed else { return false }
        guard remaining > finishedEpsilon else { return false }
        let age = todayEpochDay - cookedEpochDay
        // A future cook date means a clock that moved, not a pot from tomorrow. Treated as current rather
        // than hidden, for the same reason the chat's day bucketing does: the food is real either way.
        guard age <= maxLeftoverDays else { return false }
        return true
    }

    /// The portion that finishes a cook, for "I had the rest".
    ///
    /// Resolved from the CURRENT remainder at confirm time rather than from whatever it was when the model
    /// spoke: a portion logged in between would otherwise overdraw the pot by the amount of the overlap.
    public static func restPortion(loggedPortions: [Double]) -> Double {
        remainingFraction(loggedPortions: loggedPortions)
    }
}
