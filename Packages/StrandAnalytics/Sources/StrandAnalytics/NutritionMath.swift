import Foundation

// MARK: - Nutrition math — macros, portion scaling and day totals
//
// Pure arithmetic for the food log: no store, no UI, no date handling beyond what a caller hands in.
// Lives here rather than in the app target because `swift-packages.yml` actually runs over `Packages/**`,
// while the app-target suite only runs under the default-disabled `app-build.yml` — logic placed there is
// effectively untested in CI.
//
// The honesty rule that shapes this file: a logged macro is something the USER stated, and this code never
// silently improves it. `kcalFromMacros` exists so a screen can SHOW that the stated energy and the stated
// macros disagree; nothing here rewrites one from the other.

/// One food's energy and macronutrients. Grams throughout, kcal for energy.
///
/// `fiber` is carried even though NOOP's imported nutrition CSV has no fibre column (`NutritionCsvImport`
/// emits calories/protein/carbs/fat/weight only) — a hand-logged food routinely has it, and retrofitting the
/// field later would mean backfilling every stored entry.
public struct MacroTotals: Equatable, Codable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var fiber: Double

    public init(kcal: Double = 0, protein: Double = 0, carbs: Double = 0, fat: Double = 0, fiber: Double = 0) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
    }

    public static let zero = MacroTotals()

    /// True when every field is zero — an entry worth neither storing nor charting.
    public var isEmpty: Bool {
        kcal == 0 && protein == 0 && carbs == 0 && fat == 0 && fiber == 0
    }
}

public enum NutritionMath {

    /// Atwater factors. Protein and carbohydrate yield ~4 kcal/g, fat ~9 kcal/g. Fibre is deliberately
    /// EXCLUDED: its contribution is small, highly variable, and counted differently between regions
    /// (the EU counts 2 kcal/g, the US commonly folds it into carbohydrate), so including it would make
    /// the consistency check below disagree with most labels the user is copying from.
    public static let kcalPerGramProtein = 4.0
    public static let kcalPerGramCarbs = 4.0
    public static let kcalPerGramFat = 9.0

    /// Scale one food's macros by a portion multiplier — 0.5 for half a serving, 2 for a double.
    ///
    /// A non-finite or negative portion collapses to zero rather than propagating a NaN into a stored day
    /// total, where it would poison every downstream mean and chart and be very hard to trace back.
    public static func scaled(_ m: MacroTotals, portion: Double) -> MacroTotals {
        guard portion.isFinite, portion > 0 else { return .zero }
        return MacroTotals(kcal: m.kcal * portion,
                           protein: m.protein * portion,
                           carbs: m.carbs * portion,
                           fat: m.fat * portion,
                           fiber: m.fiber * portion)
    }

    /// Sum a day's worth of already-scaled entries. Each field is clamped at ≥ 0 on the way in, so a
    /// malformed stored entry can only ever contribute nothing — never pull a day total downwards.
    public static func total(_ items: [MacroTotals]) -> MacroTotals {
        items.reduce(into: MacroTotals.zero) { acc, m in
            acc.kcal += sane(m.kcal)
            acc.protein += sane(m.protein)
            acc.carbs += sane(m.carbs)
            acc.fat += sane(m.fat)
            acc.fiber += sane(m.fiber)
        }
    }

    /// The energy the stated macros imply, by Atwater. This is NOT a correction to `m.kcal` — it is the
    /// second opinion that lets a screen say "these macros come to about 430 kcal" beside a typed 500.
    public static func kcalFromMacros(_ m: MacroTotals) -> Double {
        sane(m.protein) * kcalPerGramProtein
            + sane(m.carbs) * kcalPerGramCarbs
            + sane(m.fat) * kcalPerGramFat
    }

    /// How far the stated energy sits from what the macros imply, as a signed fraction of the stated value
    /// (+0.20 = the typed kcal is 20% above the macro-derived figure).
    ///
    /// nil when there is nothing to compare — no stated energy, or no macros at all — because "0% off" and
    /// "nothing to check" are different answers and a caller must be able to tell them apart.
    public static func kcalConsistency(_ m: MacroTotals) -> Double? {
        let stated = sane(m.kcal)
        guard stated > 0 else { return nil }
        let derived = kcalFromMacros(m)
        guard derived > 0 else { return nil }
        return (stated - derived) / stated
    }

    /// Whether a stated entry is far enough from its macros to be worth mentioning. The band is wide on
    /// purpose: rounding on a nutrition label, sugar alcohols and fibre accounting all move the figure by
    /// a little, and a hint that fires on every honest entry is one the user learns to ignore.
    public static let kcalConsistencyTolerance = 0.15

    /// True when the stated energy and the stated macros disagree by more than `kcalConsistencyTolerance`.
    /// False when they agree OR when there is nothing to compare — the caller wants "should I warn?", and
    /// an unanswerable check is not a warning.
    public static func kcalLooksInconsistent(_ m: MacroTotals) -> Bool {
        guard let c = kcalConsistency(m) else { return false }
        return abs(c) > kcalConsistencyTolerance
    }

    /// Clamp a stored Double to something summable: NaN/infinite/negative all read as 0.
    private static func sane(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 0 }
        return v
    }
}
