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
        /// Add a food to the library and log NOTHING — "save it so I can log it against yesterday myself".
        case save(name: String, servingLabel: String, macros: MacroTotals)
        /// Record a weigh-in.
        case weight(kg: Double)
        /// The model re-emitted an action this conversation has ALREADY applied.
        ///
        /// Models repeat their own previous structured output: mention an apple after logging a banana and
        /// the reply carries both. Rendered as a stated note with no confirm button — not silently dropped,
        /// because then the model's mistake is invisible and a genuine second helping looks like a bug, and
        /// not silently offered, because one tap would log breakfast twice.
        case duplicate(of: String)
        /// The model referred to a food that could not be resolved. Rendered as a plain note, with no
        /// confirm button, because there is nothing safe to confirm.
        case unresolved(handle: String)
        /// A weigh-in so far from the user's own recent weight that it is almost certainly pounds misread
        /// as kilos. Rendered as a question rather than a confirm, because storing it would corrupt the one
        /// series the entire weight trend is fitted through — and the pure parser cannot catch it, since
        /// 160 kg is a real weight for somebody.
        case implausibleWeight(kg: Double, lastKnownKg: Double)
    }

    /// Where the card is in its life. Guards against the obvious double-tap: a card that has already
    /// written must not be able to write again, and the transcript is scrollable so it stays on screen.
    enum State: Equatable { case pending, applied, dismissed }

    let id: UUID
    let kind: Kind
    var state: State
    /// The local day key this lands on. Resolved at proposal time from the model's symbolic day, so a card
    /// left on screen across midnight still writes to the day it said it would.
    let dayKey: String
    /// How that day reads on the card. Carried rather than re-derived so the label and the write cannot
    /// disagree about which day they mean.
    let dayLabel: String
    /// The meal the user named, passed through to the write so a backfilled entry — which has no usable
    /// timestamp — still groups under the meal they said it was.
    let meal: MealType?

    init(id: UUID = UUID(), kind: Kind, state: State = .pending,
         dayKey: String, dayLabel: String, meal: MealType? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.dayKey = dayKey
        self.dayLabel = dayLabel
        self.meal = meal
    }

    /// A content identity for spotting a re-proposal.
    ///
    /// Deliberately coarse: the kind, the name and the day. Not the portion or the macros — a model
    /// repeating itself often jitters a figure slightly, and a duplicate that differs by 2 kcal is still a
    /// duplicate. The cost of being coarse is that a genuine second identical helping on the same day is
    /// flagged, which the card's wording handles by telling the user how to log it anyway.
    var dedupeKey: String? {
        switch kind {
        case .log(let item, _): return "log:\(item.id.uuidString):\(dayKey)"
        case .create(let name, _, _, _): return "create:\(name.lowercased()):\(dayKey)"
        case .save(let name, _, _): return "save:\(name.lowercased())"
        case .edit(let item, _, _): return "edit:\(item.id.uuidString)"
        case .weight: return "weight:\(dayKey)"
        // Nothing was written, so there is nothing to duplicate.
        case .unresolved, .implausibleWeight, .duplicate: return nil
        }
    }

    /// Whether this writes to a day other than today, which the card must say out loud.
    func targetsAnotherDay(today: String) -> Bool { dayKey != today }

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
        // None of these add to a day. An edit changes a definition, a save only fills the library, a
        // weigh-in is not food — showing "this adds N kcal" on any of them would answer a question the
        // card is not asking.
        case .edit, .save, .weight, .unresolved, .implausibleWeight, .duplicate:
            return nil
        }
    }

    var displayName: String {
        switch kind {
        case .log(let item, _): return item.name
        case .create(let name, _, _, _): return name
        case .save(let name, _, _): return name
        case .edit(let item, let name, _): return name ?? item.name
        case .weight(let kg), .implausibleWeight(let kg, _):
            return String(format: "%.1f kg", locale: AppLanguage.activeLocale, kg)
        case .duplicate(let name): return name
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
    /// How far back a proposal may reach, matching the food log's own stepper limit. Beyond two weeks
    /// someone is reconstructing rather than remembering, and the two surfaces must agree about that.
    static let maxDaysAgo = 13

    /// Resolve the model's symbolic day into a local day key plus a label, or nil if it is out of range.
    ///
    /// Range-checked HERE rather than in the parser, because "how far back may this go" is a product rule
    /// about the food log, not a fact about JSON. A future date is refused outright: nothing has been eaten
    /// tomorrow, so it is a model error rather than a backdated entry.
    /// `todayKey` is injected rather than computed, so a caller can hand in the DIET day — which in the
    /// small hours is yesterday's calendar day. Defaulted to the calendar day, so a caller that does not
    /// care (and every test) behaves exactly as before.
    static func resolveDay(_ day: FoodActionDay, now: Date = Date(),
                           todayKey: String? = nil) -> (key: String, label: String)? {
        switch day {
        case .today:
            // "Today" means the day the user is LIVING, which before bed at 00:15 is still yesterday by the
            // calendar. The label stays "Today" because that is what they mean by it.
            return (todayKey ?? Repository.localDayKey(now), String(localized: "Today"))
        case .daysAgo(let n):
            guard n >= 0, n <= maxDaysAgo else { return nil }
            let date = now.addingTimeInterval(-Double(n) * 86_400)
            return (Repository.localDayKey(date), label(for: n, date: date))
        case .explicit(let iso):
            // Compared as day KEYS rather than as dates, so this inherits whatever local-day definition the
            // rest of the app uses instead of introducing a second one.
            for n in 0...maxDaysAgo {
                let date = now.addingTimeInterval(-Double(n) * 86_400)
                if Repository.localDayKey(date) == iso { return (iso, label(for: n, date: date)) }
            }
            return nil
        }
    }

    private static func label(for daysAgo: Int, date: Date) -> String {
        switch daysAgo {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .locale(AppLanguage.activeLocale))
        }
    }

    /// How far a proposed weigh-in may sit from the user's last known weight before it is treated as a unit
    /// mix-up rather than a measurement. 25 kg — nobody's morning weight moves that much, and 73 kg read as
    /// 73 lb (33 kg) or 160 lb stated as 160 kg both land well outside it.
    static let maxWeightJumpKg = 25.0

    /// Resolve one parsed request into something renderable.
    ///
    /// `lastKnownWeightKg` is what catches the pounds confusion the pure parser cannot: 160 kg is a real
    /// weight for somebody, so only a comparison against THIS user's own history can tell a measurement
    /// from a unit error. nil (no history yet) means the check cannot run and the figure is accepted — a
    /// first weigh-in has nothing to be inconsistent with.
    static func resolve(_ request: FoodActionRequest,
                        library: [FoodItem],
                        recipeIds: Set<UUID>,
                        defaultServingLabel: String,
                        lastKnownWeightKg: Double?,
                        now: Date = Date(),
                        todayKey: String? = nil) -> FoodProposal? {
        // An unresolvable day drops the whole proposal rather than silently landing on today. "Log this
        // against last Tuesday" answered by writing to today is the wrong day recorded as fact.
        guard let day = resolveDay(request.day, now: now, todayKey: todayKey) else { return nil }

        let entries = library.map {
            FoodDigestEntry(id: $0.id.uuidString, name: $0.name, servingLabel: $0.servingLabel,
                            macros: $0.macros)
        }

        func item(for handle: String) -> FoodItem? {
            guard let entry = FoodLibraryDigest.resolve(handle: handle, among: entries),
                  let uuid = UUID(uuidString: entry.id) else { return nil }
            return library.first { $0.id == uuid }
        }

        func proposal(_ kind: Kind) -> FoodProposal {
            FoodProposal(kind: kind, dayKey: day.key, dayLabel: day.label,
                         meal: request.meal.flatMap(MealType.fromMeal))
        }

        switch request.action {
        case .log(let handle, let portion):
            guard let found = item(for: handle) else { return proposal(.unresolved(handle: handle)) }
            return proposal(.log(item: found, portion: portion))

        case .create(let name, let serving, let macros, let portion):
            return proposal(.create(name: name,
                                    servingLabel: serving.isEmpty ? defaultServingLabel : serving,
                                    macros: macros,
                                    portion: portion))

        case .save(let name, let serving, let macros):
            return proposal(.save(name: name,
                                  servingLabel: serving.isEmpty ? defaultServingLabel : serving,
                                  macros: macros))

        case .edit(let handle, let name, let macros):
            guard let found = item(for: handle), !recipeIds.contains(found.id) else {
                return proposal(.unresolved(handle: handle))
            }
            return proposal(.edit(item: found, name: name, macros: macros))

        case .weight(let kg):
            if let last = lastKnownWeightKg, last > 0, abs(kg - last) > maxWeightJumpKg {
                return proposal(.implausibleWeight(kg: kg, lastKnownKg: last))
            }
            return proposal(.weight(kg: kg))
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
                           at date: Date = Date(),
                           profile: ProfileStore? = nil) async -> Bool {
        // The day comes from the PROPOSAL, not from the caller. A card that said "Yesterday" and then wrote
        // to whatever day the screen happened to be showing would be the two-readouts-disagreeing failure
        // with real consequences — the entry lands somewhere the user did not agree to.
        let day = proposal.dayKey
        switch proposal.kind {
        case .log(let item, let portion):
            // saveToLibrary: true because the food is ALREADY in the library — this is what stamps
            // `lastUsedAt` so the picker's recents stay meaningful, matching a pick in the Add food sheet.
            await logFood(item: item, portion: portion, day: day, at: date,
                          mealType: proposal.meal, saveToLibrary: true)
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
                          mealType: proposal.meal, saveToLibrary: saveToLibrary)
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

        case .save(let name, let serving, let macros):
            // Library only. Nothing is logged, which is the whole distinction from `create` — the user
            // asked to save a food so they could log a portion of it against a past day themselves.
            await saveFoodItem(FoodItem(macroSource: FoodMacroSource.aiEstimate,
                                        name: name, servingLabel: serving, macros: macros))
            return true

        case .weight(let kg):
            // `logWeight` also writes the profile's weight scalar, which every calorie estimate reads — so
            // the profile has to be handed in rather than left stale. Without it a weigh-in would move the
            // trend while the budget went on pricing an old mass.
            return await logWeight(kg: kg, day: day, profile: profile)

        case .unresolved, .implausibleWeight, .duplicate:
            // Nothing safe to do. Deliberately not "create it anyway", "store it anyway", or "log it
            // again" — a duplicate reaching the write path is the double-log this case exists to prevent.
            return false
        }
    }
}
