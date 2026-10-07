import Foundation

// MARK: - Macros where a value can genuinely be ABSENT
//
// `MacroTotals` carries five non-optional Doubles, which is right for a LOGGED entry — a day's total cannot
// contain a maybe. It is wrong for published restaurant data, where partial is the norm rather than the
// exception: one chain publishes kcal and protein but no fibre, another publishes fibre but no fat.
//
// With non-optional fields those two cases are indistinguishable from zero, and a model handed
// "Salmon nigiri | 90 kcal | 6P" will read the silence as 0 g fat and log a fat-free piece of fish. This is
// the same absent-is-not-zero rule the rest of the app already keeps — the steps column that means "no
// answer" rather than "did not move", the sleep read that distinguishes unworn from awake, the recipe that
// refuses a total rather than summing around a deleted ingredient.
//
// SOME GAPS ARE NOT GAPS. Atwater is an identity, so a missing field is often COMPUTABLE from the published
// ones: fat = (kcal − 4·protein − 4·carbs) / 9. That is arithmetic, not inference — exact, free, and it
// needs neither a model nor a question. `derived` does it, and only what cannot be derived is ever worth
// asking a human or a model about.
//
// Pure. Kotlin-twinnable.

public struct PartialMacros: Equatable, Sendable {
    public var kcal: Double?
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var fiber: Double?

    public init(kcal: Double? = nil, protein: Double? = nil, carbs: Double? = nil,
                fat: Double? = nil, fiber: Double? = nil) {
        self.kcal = PartialMacros.sane(kcal)
        self.protein = PartialMacros.sane(protein)
        self.carbs = PartialMacros.sane(carbs)
        self.fat = PartialMacros.sane(fat)
        self.fiber = PartialMacros.sane(fiber)
    }

    /// A non-finite or negative figure is not a measurement, so it becomes ABSENT rather than zero —
    /// clamping it to 0 would manufacture the exact false certainty this type exists to avoid.
    static func sane(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// Which of the four energy-bearing fields are published. Fibre is excluded: it carries no energy in
    /// the Atwater sum this app uses, so its absence never blocks anything.
    public var publishedEnergyFieldCount: Int {
        [kcal, protein, carbs, fat].compactMap { $0 }.count
    }

    /// Everything needed to log is present.
    public var isComplete: Bool {
        kcal != nil && protein != nil && carbs != nil && fat != nil
    }
}

public enum PartialMacroMath {

    // MARK: - Filling gaps by arithmetic

    /// Fill what Atwater can determine exactly, and leave the rest absent.
    ///
    /// Four quantities related by one equation (`kcal = 4P + 4C + 9F`), so exactly ONE unknown is solvable.
    /// With two or more missing there is nothing to compute and guessing would be inference wearing
    /// arithmetic's clothes — those rows come back still incomplete, which is what sends them to the
    /// borrow-or-estimate path with a question attached.
    ///
    /// Fibre is never derived: it does not appear in the identity.
    public static func derived(_ m: PartialMacros) -> PartialMacros {
        var out = m
        let p = m.protein, c = m.carbs, f = m.fat, k = m.kcal
        switch (k, p, c, f) {
        case (nil, .some(let p), .some(let c), .some(let f)):
            out.kcal = p * NutritionMath.kcalPerGramProtein
                     + c * NutritionMath.kcalPerGramCarbs
                     + f * NutritionMath.kcalPerGramFat
        case (.some(let k), nil, .some(let c), .some(let f)):
            out.protein = nonNegative((k - c * NutritionMath.kcalPerGramCarbs
                                         - f * NutritionMath.kcalPerGramFat)
                                      / NutritionMath.kcalPerGramProtein)
        case (.some(let k), .some(let p), nil, .some(let f)):
            out.carbs = nonNegative((k - p * NutritionMath.kcalPerGramProtein
                                       - f * NutritionMath.kcalPerGramFat)
                                    / NutritionMath.kcalPerGramCarbs)
        case (.some(let k), .some(let p), .some(let c), nil):
            out.fat = nonNegative((k - p * NutritionMath.kcalPerGramProtein
                                     - c * NutritionMath.kcalPerGramCarbs)
                                  / NutritionMath.kcalPerGramFat)
        default:
            break   // complete already, or two-plus unknowns: nothing is determined.
        }
        return out
    }

    /// A derived figure below zero means the published fields contradict each other — the row is wrong, not
    /// the arithmetic. Left ABSENT so the contradiction surfaces in validation rather than being stored as
    /// a confident 0.
    static func nonNegative(_ v: Double) -> Double? {
        guard v.isFinite, v >= 0 else { return nil }
        return v
    }

    // MARK: - Validating a parsed row

    /// Why a published row cannot be trusted.
    public enum RowProblem: Equatable, Sendable {
        /// Stated kcal disagrees with stated macros beyond the Atwater tolerance.
        case contradictory(statedKcal: Double, impliedKcal: Double)
        /// A figure outside anything a single menu item could be.
        case implausible(field: String, value: Double)
        /// Nothing usable at all.
        case empty
    }

    /// The largest a single menu item can plausibly be. 3,000 kcal is a sharing platter; past that a
    /// decimal has moved or a per-100g column was read as a per-item one.
    public static let maxItemKcal = 3_000.0
    /// Grams of any one macro in a single item.
    public static let maxItemGrams = 500.0

    /// Check a parsed row. nil means usable — INCLUDING when fields are missing, which is expected.
    ///
    /// MISSING IS NOT A PROBLEM; CONTRADICTORY IS. That distinction is the whole import policy: a chain
    /// simply not publishing fibre is normal and the nullable columns exist for it, while a row whose kcal
    /// disagrees with its own macros means the parser put a column in the wrong place — and a parser that
    /// misaligned three rows has no claim to the other two hundred.
    public static func problem(in m: PartialMacros) -> RowProblem? {
        let filled = derived(m)
        if filled.kcal == nil && filled.protein == nil && filled.carbs == nil && filled.fat == nil {
            return .empty
        }
        for (name, value) in [("protein", filled.protein), ("carbs", filled.carbs),
                              ("fat", filled.fat), ("fiber", filled.fiber)] {
            if let value, value > maxItemGrams { return .implausible(field: name, value: value) }
        }
        if let kcal = filled.kcal, kcal > maxItemKcal {
            return .implausible(field: "kcal", value: kcal)
        }
        // Only when all four are present, DERIVATION INCLUDED — a derived field is exact by construction,
        // so checking it against the identity it came from would always pass and prove nothing. The check
        // bites on rows where all four were published independently and disagree.
        guard m.isComplete, let stated = m.kcal else { return nil }
        let implied = NutritionMath.kcalFromMacros(
            MacroTotals(kcal: 0, protein: m.protein ?? 0, carbs: m.carbs ?? 0,
                        fat: m.fat ?? 0, fiber: m.fiber ?? 0))
        let totals = MacroTotals(kcal: stated, protein: m.protein ?? 0, carbs: m.carbs ?? 0,
                                 fat: m.fat ?? 0, fiber: m.fiber ?? 0)
        guard NutritionMath.kcalLooksInconsistent(totals) else { return nil }
        return .contradictory(statedKcal: stated, impliedKcal: implied)
    }

    // MARK: - Completing for a log

    /// Concrete macros for logging, or nil when something is still unknown.
    ///
    /// Deliberately refuses rather than zero-filling. A caller that needs a total must either borrow the
    /// missing figures from a comparable item or have them estimated — and both of those are decisions the
    /// user agrees to, not defaults the app picks silently.
    ///
    /// Fibre is the one exception: it carries no energy here and an unpublished value is reported as 0,
    /// because no total changes and refusing a whole row over it would block logging for a fact nobody uses.
    public static func complete(_ m: PartialMacros) -> MacroTotals? {
        let filled = derived(m)
        guard let kcal = filled.kcal, let protein = filled.protein,
              let carbs = filled.carbs, let fat = filled.fat else { return nil }
        return MacroTotals(kcal: kcal, protein: protein, carbs: carbs, fat: fat,
                           fiber: filled.fiber ?? 0)
    }

    // MARK: - Describing a row to the model

    /// One line for the coach's context.
    ///
    /// NAMES WHAT IS MISSING rather than omitting it. A model handed "Salmon nigiri | 90 kcal | 6P" reads
    /// the silence as zero and logs a fat-free piece of fish; told "fat: not published", it knows to borrow
    /// or ask. Derived figures are marked too, so the model does not treat a computed fat as a published one
    /// when deciding whether another chain's value is worth borrowing.
    public static func describe(_ m: PartialMacros) -> String {
        let filled = derived(m)
        var parts: [String] = []
        for (label, published, computed) in [("kcal", m.kcal, filled.kcal),
                                             ("P", m.protein, filled.protein),
                                             ("C", m.carbs, filled.carbs),
                                             ("F", m.fat, filled.fat),
                                             ("fibre", m.fiber, filled.fiber)] {
            if let published {
                parts.append("\(label) \(trimmed(published))")
            } else if let computed {
                parts.append("\(label) \(trimmed(computed)) (derived)")
            } else {
                parts.append("\(label) not published")
            }
        }
        return parts.joined(separator: ", ")
    }

    static func trimmed(_ v: Double) -> String {
        v.rounded() == v && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.1f", v)
    }
}
