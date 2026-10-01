import Foundation

// MARK: - The food library, as the coach sees it
//
// For "just had an Oikos" to end in a clarifying question rather than a guess, the model has to know
// which Oikos foods exist. This formats that list, and defines the id scheme the model quotes back.
//
// WHY A SHORT HANDLE AND NOT THE UUID. A library of 60 foods is 60 × 36 characters of UUID before a
// single macro is stated — pure token cost for strings no human will read. Eight hex characters is
// plenty to distinguish 60 items, and the resolver demands a UNIQUE prefix match, so the one thing that
// could go wrong is detected rather than guessed at.
//
// WHY NOT A LIST INDEX, which would be shorter still: the ordering is recency, and recency changes the
// moment anything is logged. A model quoting "item 3" from earlier in the conversation would then log a
// different food than the one it meant — silently, and into the series the diet is judged on. A handle
// derived from the id cannot drift.
//
// THE CAP IS STATED, NOT SILENT. A library longer than the cap is truncated, and the block SAYS it was
// truncated — a model told "here are your foods" that is quietly missing the one the user ate will
// confidently propose creating a duplicate.
//
// Pure: the caller supplies the foods, already sorted.

/// One food as the digest needs it. A reduction of the app's own model, so this module stays free of it.
public struct FoodDigestEntry: Equatable, Sendable {
    /// The food's full id. Only its prefix is sent; the full value stays on device.
    public let id: String
    public let name: String
    public let servingLabel: String
    public let macros: MacroTotals
    /// True when this food is a recipe (its macros come from its parts). Worth telling the model: a
    /// recipe is the one kind of food it should not offer to edit macros on directly.
    public let isRecipe: Bool

    public init(id: String, name: String, servingLabel: String, macros: MacroTotals,
                isRecipe: Bool = false) {
        self.id = id
        self.name = name
        self.servingLabel = servingLabel
        self.macros = macros
        self.isRecipe = isRecipe
    }
}

public enum FoodLibraryDigest {

    /// How many foods the block may carry.
    ///
    /// 60 is enough for a real library's useful head — a year of logging settles into a few dozen
    /// repeated foods — while keeping the block to roughly a page. Beyond this the marginal food is one
    /// eaten once, which the model can propose creating instead.
    public static let maxEntries = 60

    /// Characters of the id used as the conversational handle. Eight hex characters distinguishes far
    /// more than `maxEntries` items; the resolver still verifies uniqueness rather than trusting that.
    public static let handleLength = 8

    /// The handle for a food — what the model quotes in a `log` or `edit` action.
    public static func handle(for id: String) -> String {
        String(id.replacingOccurrences(of: "-", with: "").prefix(handleLength)).lowercased()
    }

    /// Resolve a handle the model quoted back to exactly one food.
    ///
    /// Returns nil for no match AND for an ambiguous one. Ambiguity resolving to "the first" is how a
    /// model's near-miss becomes the wrong meal logged, and a refusal is recoverable — the user sees no
    /// card and says it again.
    public static func resolve(handle: String, among entries: [FoodDigestEntry]) -> FoodDigestEntry? {
        let needle = handle.replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        // An exact id match first: a model that quotes the full id (or the app passes one through) must
        // not be held to the prefix rule.
        if let exact = entries.first(where: {
            $0.id.replacingOccurrences(of: "-", with: "").lowercased() == needle
        }) { return exact }
        let matches = entries.filter {
            self.handle(for: $0.id).hasPrefix(needle) || needle.hasPrefix(self.handle(for: $0.id))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The block to put in the coach context, or "" when there is nothing to describe.
    ///
    /// `entries` must arrive in the order the user should see them — recency-first, as the food picker
    /// sorts — because that is what makes the head of a truncated list the useful part.
    public static func block(entries: [FoodDigestEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let shown = entries.prefix(maxEntries)
        var lines = ["SAVED FOODS (the user's own library, most recently used first).",
                     "Quote the id EXACTLY as given when logging or editing one of these."]
        for e in shown {
            let kcal = Int(e.macros.kcal.rounded())
            var line = "- \(handle(for: e.id)) | \(e.name)"
            if !e.servingLabel.isEmpty { line += " | per \(e.servingLabel)" }
            line += " | \(kcal) kcal"
            // Macros only where they are non-zero: a quick-added kcal-only food has none, and printing
            // "0P 0C 0F" would invite the model to state those zeros back as if they were measured.
            var parts: [String] = []
            for (label, value) in [("P", e.macros.protein), ("C", e.macros.carbs), ("F", e.macros.fat)]
            where value > 0 {
                parts.append(grams(value) + label)
            }
            if !parts.isEmpty { line += " | " + parts.joined(separator: " ") }
            if e.isRecipe { line += " | recipe (macros come from its ingredients)" }
            lines.append(line)
        }
        if entries.count > shown.count {
            // Said out loud, because a model that believes it has the whole library will propose creating
            // a duplicate of a food that is merely out of frame.
            lines.append("(\(entries.count - shown.count) older foods not listed — if the user names "
                       + "something not above, ask before assuming it is new.)")
        }
        return lines.joined(separator: "\n")
    }

    /// A gram figure without a pointless ".0" — "15P", not "15.0P". Extracted because inlining the
    /// conditional in the list comprehension above made the type-checker give up.
    static func grams(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// One line on where the day stands, so the coach can answer "can I have this?" rather than only
    /// recording what already happened.
    ///
    /// Takes figures rather than computing any: the budget belongs to `CalorieTarget` and a second
    /// derivation here is exactly the two-readouts-disagreeing failure the repo's rules name.
    public static func todayLine(consumedKcal: Double, budgetKcal: Double?, proteinG: Double,
                                 proteinTargetG: Double?) -> String {
        var s = "TODAY SO FAR: \(Int(consumedKcal.rounded())) kcal eaten"
        if let budget = budgetKcal, budget > 0 {
            let left = budget - consumedKcal
            s += " of a \(Int(budget.rounded())) kcal budget"
            s += left >= 0 ? " (\(Int(left.rounded())) left)" : " (\(Int((-left).rounded())) over)"
        }
        s += "; protein \(Int(proteinG.rounded())) g"
        if let target = proteinTargetG, target > 0 {
            s += " of \(Int(target.rounded())) g"
        }
        s += ". The budget rises with the day's steps and workouts, so it is not fixed."
        return s
    }
}
