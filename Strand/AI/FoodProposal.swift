import Foundation
import StrandAnalytics

// MARK: - A food action the coach has proposed, resolved against the library
//
// `FoodActionParse` gives a parsed intent with a model-supplied handle. This resolves that handle into
// something renderable and commits it when the user taps — the step where the model's claim becomes a
// fact about the day.
//
// A HANDLE THAT RESOLVES TO NOTHING IS A REFUSAL, NOT A NEW FOOD. The model may invent an id, or quote a
// stale one, or hand back a prefix two foods share. Turning any of those into "fine, I'll create it"
// would quietly fork the library into near-duplicates and log a food the user never approved the macros
// of. `FoodLibraryDigest.resolve` already refuses ambiguity; this carries that refusal to the UI as a
// stated problem.
//
// NOTHING IS WRITTEN UNTIL `apply` IS CALLED, and `apply` is only reachable from a button. See the
// header of `FoodActionParse` for why that boundary is the whole design.

/// A proposal, resolved and ready to render.
struct FoodProposal: Identifiable, Equatable {

    /// What the card will do.
    enum Kind: Equatable {
        /// Log a food already in the library.
        case log(item: FoodItem, portion: Double)
        /// Create a food and log it. Saving to the library is the USER's choice at the card — the
        /// one-off case is the common one, so the model does not get to decide it.
        case create(name: String, servingLabel: String, macros: MacroTotals, portion: Double)
        /// Correct an existing food's macros. `item` carries the current values so the card can show
        /// what is changing — a macro edit with no before-figure is impossible to sanity-check.
        case edit(item: FoodItem, name: String?, macros: MacroTotals)
        /// The model referred to a food that could not be resolved. Rendered as a plain note, with no
        /// confirm button, because there is nothing safe to confirm.
        case unresolved(handle: String)
    }

    /// Where the card is in its life. Guards against the obvious double-tap: a card that has already
    /// written must not be able to write again, and the transcript is scrollable so it stays on screen.
    enum State: Equatable { case pending, applied, dismissed }

    let id: UUID
    let kind: Kind
    var state: State

    init(id: UUID = UUID(), kind: Kind, state: State = .pending) {
        self.id = id
        self.kind = kind
        self.state = state
    }

    /// Whether the card offers to save the proposed food to the library. Only a `create` can.
    var canSaveToLibrary: Bool {
        if case .create = kind { return true }
        return false
    }

    /// What this would add to the day, for the card's headline. nil for cases that log nothing.
    var loggedMacros: MacroTotals? {
        switch kind {
        case .log(let item, let portion):
            return NutritionMath.scaled(item.macros, portion: portion)
        case .create(_, _, let macros, let portion):
            return NutritionMath.scaled(macros, portion: portion)
        // An edit changes a definition, not the day. Showing a "this adds N kcal" headline on one would
        // be a second, wrong answer to what the card does.
        case .edit, .unresolved:
            return nil
        }
    }

    var displayName: String {
        switch kind {
        case .log(let item, _): return item.name
        case .create(let name, _, _, _): return name
        case .edit(let item, let name, _): return name ?? item.name
        case .unresolved: return String(localized: "Unrecognised food")
        }
    }
}

extension FoodProposal {

    /// Resolve a parsed action against the library, or return an `unresolved` proposal.
    ///
    /// Recipes are deliberately NOT editable through this path: a recipe's macros come from its
    /// ingredients, so accepting a macro edit on one would write a figure that the next read recomputes
    /// away — a change that appears to work and then silently reverts. The edit degrades to `unresolved`
    /// so the coach says so rather than the app pretending.
    static func resolve(_ action: FoodAction,
                        library: [FoodItem],
                        recipeIds: Set<UUID>,
                        defaultServingLabel: String) -> FoodProposal {
        let entries = library.map {
            FoodDigestEntry(id: $0.id.uuidString, name: $0.name, servingLabel: $0.servingLabel,
                            macros: $0.macros)
        }

        func item(for handle: String) -> FoodItem? {
            guard let entry = FoodLibraryDigest.resolve(handle: handle, among: entries),
                  let uuid = UUID(uuidString: entry.id) else { return nil }
            return library.first { $0.id == uuid }
        }

        switch action {
        case .log(let handle, let portion):
            guard let found = item(for: handle) else {
                return FoodProposal(kind: .unresolved(handle: handle))
            }
            return FoodProposal(kind: .log(item: found, portion: portion))

        case .create(let name, let serving, let macros, let portion):
            return FoodProposal(kind: .create(name: name,
                                              servingLabel: serving.isEmpty ? defaultServingLabel : serving,
                                              macros: macros,
                                              portion: portion))

        case .edit(let handle, let name, let macros):
            guard let found = item(for: handle), !recipeIds.contains(found.id) else {
                return FoodProposal(kind: .unresolved(handle: handle))
            }
            return FoodProposal(kind: .edit(item: found, name: name, macros: macros))
        }
    }
}

extension Repository {

    /// Commit a proposal. THE ONLY WRITE PATH for a coach-proposed action, and it runs from a tap.
    ///
    /// `saveToLibrary` applies to a `create` only, and defaults to false because the one-off meal is the
    /// common case — the same default the Add food sheet uses, and for the same reason: most meals are
    /// eaten once and saving each would fill the picker with "Pret sandwich 14 March".
    ///
    /// `day` is threaded so a proposal about yesterday lands on yesterday. Returns false when nothing was
    /// written, so the card can stay pending rather than claiming success it cannot show.
    @discardableResult
    func applyFoodProposal(_ proposal: FoodProposal,
                           saveToLibrary: Bool = false,
                           day: String? = nil,
                           at date: Date = Date()) async -> Bool {
        switch proposal.kind {
        case .log(let item, let portion):
            // saveToLibrary: true because the food is ALREADY in the library — this is what stamps
            // `lastUsedAt` so the picker's recents stay meaningful, matching a pick in the Add food sheet.
            await logFood(item: item, portion: portion, day: day, at: date, saveToLibrary: true)
            return true

        case .create(let name, let serving, let macros, let portion):
            // Stamped as an AI estimate, because that is what it is: the model produced these macros and
            // the user approved them at a glance, which is not the same as reading them off a label. The
            // marker rides the entry's snapshot too, so "this number was once a guess" survives in the
            // log long after the conversation has scrolled away.
            let item = FoodItem(macroSource: FoodMacroSource.aiEstimate,
                                name: name, servingLabel: serving, macros: macros)
            if saveToLibrary { await saveFoodItem(item) }
            await logFood(item: item, portion: portion, day: day, at: date,
                          saveToLibrary: saveToLibrary)
            return true

        case .edit(let item, let name, let macros):
            // Only the library definition changes. Entries already logged keep their snapshots, which is
            // the whole point of taking them — correcting a food must not rewrite what past days say.
            var updated = item
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { updated.name = name }
            updated.macros = macros
            // The new figures are the model's, so the provenance becomes an estimate even if the food's
            // original numbers were typed by hand. Downgrading provenance on a correction is the honest
            // direction — the stored value is now a guess regardless of what it used to be.
            updated.macroSource = FoodMacroSource.aiEstimate
            await saveFoodItem(updated)
            return true

        case .unresolved:
            // Nothing safe to do. Deliberately not "create it anyway".
            return false
        }
    }
}
