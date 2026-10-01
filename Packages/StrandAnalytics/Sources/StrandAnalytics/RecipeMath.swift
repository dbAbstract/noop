import Foundation

// MARK: - A recipe's macros, computed from its parts
//
// A recipe is an ordinary food whose numbers nobody typed. "Protein shake" is 1 scoop of whey, 300 ml of
// oat milk and a banana, and its macros are whatever those add up to.
//
// THE TOTAL IS NEVER STORED. It is derived here on every read, which is the rule the user's own diet
// backend already follows and the reason to keep following it: a stored total is a second answer to the
// same question, and the moment an ingredient is corrected the stored one is wrong while still being the
// one on screen. Deriving costs a multiply-add per ingredient and cannot go stale.
//
// Storing is still correct one layer up, at LOG time — the computed total is snapshotted into the entry,
// so fixing the whey's protein next month does not silently rewrite what last Tuesday says you ate. Live
// where the thing is being edited, frozen where it is being remembered: the same split the food log
// already applies to names and macros.
//
// AN INGREDIENT NEED NOT BE IN THE LIBRARY. A component either REFERENCES a library food — whose macros
// then resolve live, so correcting the food corrects every recipe containing it — or carries its macros
// INLINE. The inline case is the common one for anything used in exactly one dish: a bulgogi marinade is
// soy sauce, oyster sauce, sesame oil and sugar, four foods that exist only as part of that marinade.
// Requiring each to be saved first would fill the food picker with things nobody logs on their own.
//
// Only a REFERENCE can go missing, which is the only reason the two cases are distinguished here at all.
//
// A MISSING INGREDIENT IS NOT ZERO. If a component names a food that no longer exists, the total it
// belongs to is refused rather than quietly computed without it. Deleting the banana must not make the
// shake look like a 180 kcal food — an absent number and a smaller number are different claims, and only
// one of them is honest. `resolve` reports which ingredients went missing so a caller can say so.
//
// Pure: no store, no UUIDs, no dates. The caller supplies ingredients already looked up.

/// One ingredient's contribution: a food's per-serving macros and how many of those servings.
public struct RecipePart: Equatable, Sendable {
    /// The ingredient's macros for ONE of its own servings.
    public let macrosPerServing: MacroTotals
    /// Servings of the ingredient, in its own unit — "2 scoops", not "2 grams".
    public let quantity: Double

    public init(macrosPerServing: MacroTotals, quantity: Double) {
        self.macrosPerServing = macrosPerServing
        self.quantity = quantity
    }
}

/// The outcome of composing a recipe: what it adds up to, and what could not be found.
public struct RecipeComposition: Equatable, Sendable {
    /// The recipe's macros for one serving of the recipe, or nil when an ingredient is missing.
    ///
    /// nil rather than a partial sum, deliberately. See the file header: a total computed without a
    /// component it is supposed to include is a wrong number wearing a right number's clothes.
    public let macros: MacroTotals?
    /// Ingredient ids that were named but not found. Non-empty means `macros` is nil.
    public let missingIngredientIds: [String]
    /// How many ingredients were resolved and summed.
    public let resolvedCount: Int

    public var isComplete: Bool { missingIngredientIds.isEmpty }

    public init(macros: MacroTotals?, missingIngredientIds: [String], resolvedCount: Int) {
        self.macros = macros
        self.missingIngredientIds = missingIngredientIds
        self.resolvedCount = resolvedCount
    }
}

public enum RecipeMath {

    /// A recipe with more parts than this is almost certainly a mistake, and summing an unbounded list is
    /// how one bad write becomes a slow screen. Generous enough for any real dish.
    public static let maxParts = 100

    // MARK: - Composing

    /// Sum a recipe's parts into one serving's macros.
    ///
    /// Each part is its own per-serving macros scaled by its quantity, through the SAME
    /// `NutritionMath.scaled` the food log uses for a logged portion — so a recipe's arithmetic and an
    /// entry's arithmetic cannot drift apart, including how each treats a nonsense quantity.
    public static func compose(_ parts: [RecipePart]) -> MacroTotals {
        NutritionMath.total(parts.prefix(maxParts).map {
            NutritionMath.scaled($0.macrosPerServing, portion: $0.quantity)
        })
    }

    /// Look each component's ingredient up, then compose — reporting anything that could not be found
    /// instead of leaving it out of the sum.
    ///
    /// `order` is preserved so a recipe reads the way the user arranged it; `lookup` returns nil for an
    /// ingredient that has been deleted from the library.
    ///
    /// An EMPTY recipe composes to zero and counts as complete. That is not the missing-ingredient case —
    /// a recipe with no parts yet is a recipe being built, and zero is the honest total of nothing.
    public static func resolve(componentIds: [String],
                              quantities: [Double],
                              lookup: (String) -> MacroTotals?) -> RecipeComposition {
        resolve(references: componentIds.map(Reference.library),
                quantities: quantities,
                lookup: lookup)
    }

    /// What a component points at: a library food that must be looked up, or macros it carries itself.
    ///
    /// The distinction matters to exactly one thing — whether the component can go MISSING. A library
    /// reference can (the food was deleted), and that refuses the total. An inline ingredient cannot, by
    /// construction, because there is nothing to delete out from under it.
    public enum Reference: Equatable, Sendable {
        /// An id to resolve against the library.
        case library(String)
        /// Per-serving macros held by the component itself — an ad-hoc ingredient used in one dish and
        /// not worth a library entry.
        case inline(MacroTotals)
    }

    /// Compose a mix of library references and inline ingredients.
    ///
    /// Same rule as before for references: any that cannot be resolved refuses the whole total rather
    /// than being summed around. Inline ingredients are already resolved and simply participate.
    public static func resolve(references: [Reference],
                              quantities: [Double],
                              lookup: (String) -> MacroTotals?) -> RecipeComposition {
        var parts: [RecipePart] = []
        var missing: [String] = []
        for (i, ref) in references.prefix(maxParts).enumerated() {
            let quantity = i < quantities.count ? quantities[i] : 0
            switch ref {
            case .inline(let macros):
                parts.append(RecipePart(macrosPerServing: macros, quantity: quantity))
            case .library(let id):
                guard let macros = lookup(id) else {
                    missing.append(id)
                    continue
                }
                parts.append(RecipePart(macrosPerServing: macros, quantity: quantity))
            }
        }
        // Refused, not partially summed — the whole point of tracking `missing` at all.
        guard missing.isEmpty else {
            return RecipeComposition(macros: nil, missingIngredientIds: missing,
                                     resolvedCount: parts.count)
        }
        return RecipeComposition(macros: compose(parts), missingIngredientIds: [],
                                 resolvedCount: parts.count)
    }

    // MARK: - Editing

    /// Whether a quantity is one a recipe may hold.
    ///
    /// Zero is rejected as well as negatives: an ingredient at zero servings contributes nothing, so it
    /// is a deletion wearing an edit's clothes — and leaving it in the list means a row the total does
    /// not reflect, which is the two-readouts-disagreeing failure the repo's hard rules name.
    public static func isValidQuantity(_ q: Double) -> Bool {
        q.isFinite && q > 0 && q <= 1_000
    }

    /// Renumber a reordered ingredient list so the stored `ord` values are dense and ascending.
    ///
    /// Dense rather than sparse: `ORDER BY ord` is the only thing that preserves arrangement, and gaps
    /// left by a deletion accumulate until two ingredients collide on one value and the order becomes
    /// whatever SQLite feels like.
    public static func renumbered(_ count: Int) -> [Int] {
        Array(0..<max(0, count))
    }
}
