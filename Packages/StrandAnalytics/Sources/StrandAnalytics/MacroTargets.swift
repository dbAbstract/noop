import Foundation

// MARK: - Macro targets: what the calorie budget should be made of
//
// A kcal target alone is indifferent to whether the weight coming off is fat or muscle. At a deficit,
// protein is what decides that, and dietary fat has a floor below which hormonal function suffers. So
// the budget gets a shape:
//
//     protein   = g/kg × weight          (user-set rate; the one genuine choice here)
//     fat floor = 0.7 g/kg × weight      (a MINIMUM, not a target)
//     carbs     = whatever the budget has left
//
// ON THE PROTEIN RANGE. The figure usually quoted for preserving lean mass in a deficit is 1.6–2.2 g/kg,
// and the default here is deliberately lower, at 1.2. Those numbers come from studies on people training
// several times a week; the lifting stimulus is what creates the demand. Someone lifting once a
// fortnight and holding their numbers at 1.2 g/kg is not contradicting the research, they are outside
// its population. The slider spans 0.8–2.0 so either regime is reachable, and the default does not
// quietly prescribe a high-volume athlete's intake to someone who is not one.
//
// Everything is pure. The caller supplies weight and budget.

/// The day's targets, derived together so they cannot disagree about the budget they divide.
public struct MacroTargetSet: Equatable, Sendable {
    /// Grams of protein to aim for.
    public let proteinG: Double
    /// Grams of fat NOT to go under. A floor, not a goal — eating more is fine, it just comes out of
    /// the carb remainder.
    public let fatFloorG: Double
    /// Grams of carbohydrate the budget leaves once protein and the fat floor are paid for.
    public let carbsG: Double
    /// The kcal budget these divide up.
    public let budgetKcal: Double
    /// True when protein and the fat floor alone exceed the budget, so there is nothing left for carbs.
    /// Surfaced rather than hidden: it means the deficit and the protein target are asking for
    /// incompatible things, and silently showing 0 g of carbs would look like a rounding artefact.
    public let isOverCommitted: Bool

    public init(proteinG: Double, fatFloorG: Double, carbsG: Double, budgetKcal: Double,
                isOverCommitted: Bool) {
        self.proteinG = proteinG
        self.fatFloorG = fatFloorG
        self.carbsG = carbsG
        self.budgetKcal = budgetKcal
        self.isOverCommitted = isOverCommitted
    }
}

public enum MacroTargets {

    // MARK: - Tuning surface

    /// The slider's range. 0.8 is below any lean-mass recommendation and is there because it is the
    /// user's body and their data; 2.0 is past the point where more protein buys anything measurable.
    public static let minProteinGPerKg = 0.8
    public static let maxProteinGPerKg = 2.0

    /// Default protein rate. See the file header for why this is not 1.6.
    public static let defaultProteinGPerKg = 1.2

    /// Dietary fat floor, g/kg. Below roughly this, sex-hormone production and fat-soluble vitamin
    /// absorption start to suffer — which is a different kind of problem from missing a protein target,
    /// so it is modelled as a MINIMUM rather than something to hit.
    public static let fatFloorGPerKg = 0.7

    // MARK: - Derivation

    /// Clamp a protein rate into the slider's range. Non-finite input falls back to the default rather
    /// than propagating a NaN into a gram figure.
    public static func clampedProteinRate(_ gPerKg: Double) -> Double {
        guard gPerKg.isFinite else { return defaultProteinGPerKg }
        return min(max(gPerKg, minProteinGPerKg), maxProteinGPerKg)
    }

    /// Divide a day's budget into protein, a fat floor, and the carb remainder.
    ///
    /// Carbs are the remainder on purpose. Protein has a target, fat has a floor, and carbohydrate is
    /// the one macro with no requirement at all — so it is the honest place to absorb whatever the
    /// budget has left, including on a day when training has raised it.
    public static func targets(budgetKcal: Double,
                               weightKg: Double,
                               proteinGPerKg: Double = defaultProteinGPerKg) -> MacroTargetSet {
        guard budgetKcal.isFinite, budgetKcal > 0, weightKg.isFinite, weightKg > 0 else {
            return MacroTargetSet(proteinG: 0, fatFloorG: 0, carbsG: 0,
                                  budgetKcal: max(0, budgetKcal), isOverCommitted: false)
        }
        let protein = weightKg * clampedProteinRate(proteinGPerKg)
        let fat = weightKg * fatFloorGPerKg
        let spent = protein * NutritionMath.kcalPerGramProtein + fat * NutritionMath.kcalPerGramFat
        let remaining = budgetKcal - spent
        return MacroTargetSet(proteinG: protein,
                              fatFloorG: fat,
                              carbsG: max(0, remaining) / NutritionMath.kcalPerGramCarbs,
                              budgetKcal: budgetKcal,
                              isOverCommitted: remaining < 0)
    }

    /// How much of a target has been eaten, 0...1 and clamped — for a progress readout.
    ///
    /// nil when there is no target to measure against, which a caller must render differently from 0:
    /// "no target" and "none eaten" look identical on a bar and mean opposite things.
    public static func fraction(consumed: Double, target: Double) -> Double? {
        guard target > 0, target.isFinite, consumed.isFinite else { return nil }
        return min(1, max(0, consumed / target))
    }
}
