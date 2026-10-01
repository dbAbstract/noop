import Foundation

// MARK: - Reading a food-log ACTION out of a coach reply
//
// The conversational logging path. The user says "just had an Oikos", the model asks which one, and once
// it knows it emits a machine-readable proposal alongside its prose. This parses that proposal.
//
// THE MODEL PROPOSES, IT NEVER COMMITS. Nothing here writes anything. A parsed action is rendered as a
// card the user taps, and the tap is what logs. That is not politeness about autonomy — it is the only
// defence against the failure mode that would make this feature worse than the button it replaces: a
// model that logs three phantom meals from a sentence about yesterday, silently moving the one number the
// whole diet is judged on. An unwanted card costs a glance; an unwanted entry corrupts the trend that
// `AdaptiveExpenditureEngine` reads.
//
// A SENTINEL KEY, NOT "THE FIRST JSON OBJECT". The proposal must sit under `noop_food_action`. Coaches
// write prose containing braces — a macro table, an example, a JSON snippet the user asked about — and
// treating any object as an action would propose logging food from a conversation that was not about
// logging food. A false positive here is worse than a miss, because the miss is visible.
//
// STRICT ABOUT CONTENT, same posture as `MacroEstimateParse` and for the same reason: the arithmetic
// check is the only thing standing between a hallucinated macro set and the food log. A `create` whose
// stated kcal disagrees with its own macros is refused, not repaired.
//
// Pure. No store, no network, no UUID generation. Kotlin-twinnable.

/// What the model is proposing to do.
public enum FoodAction: Equatable, Sendable {
    /// Log a food already in the library. The id is the model's claim and the CALLER must resolve it —
    /// an id that matches nothing is a hallucinated reference, not a new food.
    case log(itemId: String, portion: Double)
    /// Create a food that is not in the library, and log it. Whether it is SAVED is the user's choice at
    /// the card, not the model's: the one-off case is the common one.
    case create(name: String, servingLabel: String, macros: MacroTotals, portion: Double)
    /// Correct an existing library food's macros. Deliberately separate from `create` — "the yogurt is
    /// actually 150 kcal" and "here is a new yogurt" are different intents with different consequences,
    /// and a model that conflated them would quietly fork the library into near-duplicates.
    case edit(itemId: String, name: String?, macros: MacroTotals)
}

public enum FoodActionParse {

    /// The key a proposal must sit under. Namespaced so it cannot collide with anything a model would
    /// write by accident.
    public static let sentinel = "noop_food_action"

    /// Why a reply carried no usable action. `noAction` is the overwhelming case and is NOT an error:
    /// most coach turns are conversation, including the clarifying question that makes this feature work.
    public enum Failure: String, Equatable, Sendable, Error {
        /// No proposal present. The reply is ordinary conversation — including the clarifying question
        /// that makes this feature work — so this is the common case and NOT an error.
        ///
        /// Named `noAction` rather than `none` deliberately: in a `Failure?` context Swift resolves a bare
        /// `.none` to `Optional.none`, so `XCTAssertEqual(failed(x), .none)` silently compares against nil
        /// and passes for the wrong reason. It cost a test-debug cycle to notice; the name removes the trap.
        case noAction
        /// The sentinel appeared but its object never closed, or would not decode.
        case malformed
        /// `action` was absent or not one of the three verbs.
        case unknownAction
        /// A `log` or `edit` arrived without the item id it is meaningless without.
        case missingItemId
        /// A `create` arrived with no name to call the food.
        case missingName
        /// No usable energy figure on a `create`/`edit`.
        case noCalories
        /// Stated kcal and stated macros disagree beyond the Atwater tolerance. The model contradicted
        /// itself, so neither figure can be trusted and nothing is offered to the user.
        case inconsistent
        /// A portion outside anything a meal could be.
        case badPortion
    }

    /// Portion ceiling. Twelve servings of one food is already implausible; past that it is a model
    /// mis-parsing "120 g" as a portion count, which would log a day's calories twelve times over.
    public static let maxPortion = 12.0

    // MARK: - Parsing

    /// Pull an action out of a reply, or say why there is none.
    public static func action(fromReply reply: String) -> Result<FoodAction, Failure> {
        guard reply.contains(sentinel) else { return .failure(.noAction) }
        guard let objectText = objectContainingSentinel(in: reply),
              let data = objectText.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = outer[sentinel] as? [String: Any] else { return .failure(.malformed) }

        let verb = (body["action"] as? String)?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let portion = body["portion"] == nil ? 1 : MacroEstimateParse.number(body, "portion")
        guard portion.isFinite, portion > 0, portion <= maxPortion else { return .failure(.badPortion) }

        switch verb {
        case "log":
            guard let id = nonEmpty(body["itemId"]) ?? nonEmpty(body["item_id"]) else {
                return .failure(.missingItemId)
            }
            return .success(.log(itemId: id, portion: portion))

        case "create":
            guard let name = nonEmpty(body["name"]) else { return .failure(.missingName) }
            switch macros(body) {
            case .failure(let f): return .failure(f)
            case .success(let m):
                // A blank serving label would make the logged row read "1 x" with no unit. The caller
                // supplies its own default rather than this inventing a localized string in a pure module.
                return .success(.create(name: name,
                                        servingLabel: nonEmpty(body["servingLabel"])
                                            ?? nonEmpty(body["serving_label"]) ?? "",
                                        macros: m,
                                        portion: portion))
            }

        case "edit":
            guard let id = nonEmpty(body["itemId"]) ?? nonEmpty(body["item_id"]) else {
                return .failure(.missingItemId)
            }
            switch macros(body) {
            case .failure(let f): return .failure(f)
            case .success(let m):
                return .success(.edit(itemId: id, name: nonEmpty(body["name"]), macros: m))
            }

        default:
            return .failure(.unknownAction)
        }
    }

    /// The reply with its proposal block removed, for display.
    ///
    /// The user must never see the JSON. Strips a surrounding ``` fence too, since a model told to emit
    /// bare JSON will fence it anyway and leaving an empty fence behind looks like a rendering bug.
    ///
    /// Returns the text unchanged when there is no sentinel, so the ordinary conversational path pays
    /// nothing and cannot be corrupted by this.
    public static func strippingAction(from reply: String) -> String {
        guard reply.contains(sentinel), let range = sentinelObjectRange(in: reply) else { return reply }
        var text = reply
        var lower = range.lowerBound
        var upper = range.upperBound

        // Widen over an enclosing fence. Checked as a PAIR: widening over an opening fence without a
        // matching close would eat the rest of the reply.
        if let fenceOpen = fenceStart(in: text, before: lower),
           let fenceClose = fenceEnd(in: text, after: upper) {
            lower = fenceOpen
            upper = fenceClose
        }
        text.removeSubrange(lower..<upper)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to SHOW for a reply that may be mid-stream.
    ///
    /// `strippingAction` only helps once the block has closed. While a reply is still arriving the user
    /// would otherwise watch `{"noop_food_action": {"action": "cr` type itself out across the screen,
    /// which looks like the app is broken at the exact moment it is working.
    ///
    /// So: a COMPLETE block is removed, and an INCOMPLETE one truncates the display at its opening brace.
    /// Truncating is safe because the protocol puts the block last — anything after it has not arrived
    /// yet, and the final pass re-renders the whole reply properly.
    public static func displayText(_ reply: String) -> String {
        guard reply.contains(sentinel) else { return reply }
        if sentinelObjectRange(in: reply) != nil { return strippingAction(from: reply) }
        // Incomplete. Cut at the brace that opens the object carrying the sentinel, or at the sentinel
        // itself if even that brace has not arrived.
        guard let s = reply.range(of: sentinel) else { return reply }
        var cut = s.lowerBound
        // Walk back to the enclosing `{`, then over an optional fence, so no stray punctuation is left.
        var i = cut
        while i > reply.startIndex {
            i = reply.index(before: i)
            if reply[i] == "{" { cut = i; break }
            if reply[i].isNewline { break }
        }
        if let fence = fenceStart(in: reply, before: cut) { cut = fence }
        return String(reply[reply.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Locating the block

    /// The balanced `{…}` that CONTAINS the sentinel key — not merely the first object in the text, so a
    /// macro table or an unrelated snippet earlier in the reply cannot shadow the real proposal.
    static func objectContainingSentinel(in text: String) -> String? {
        sentinelObjectRange(in: text).map { String(text[$0]) }
    }

    /// Range of that object. Brace counting, string-aware, matching `MacroEstimateParse.firstJSONObject`
    /// — a nested object (the body under the sentinel is itself one) defeats any first-to-last slice.
    static func sentinelObjectRange(in text: String) -> Range<String.Index>? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for i in text.indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let s = start {
                    let end = text.index(after: i)
                    // Only the object that actually carries the sentinel. Any other balanced object in
                    // the reply is prose and is skipped rather than returned.
                    if text[s..<end].contains(sentinel) { return s..<end }
                    start = nil
                }
            default: break
            }
        }
        return nil
    }

    /// Start of a ``` fence immediately preceding `index` (only whitespace between), else nil.
    static func fenceStart(in text: String, before index: String.Index) -> String.Index? {
        var i = index
        while i > text.startIndex {
            let prev = text.index(before: i)
            if text[prev].isWhitespace { i = prev; continue }
            break
        }
        // Walk back over an optional language tag ("json") to the fence itself.
        var scan = i
        var seen = ""
        while scan > text.startIndex, seen.count < 16 {
            scan = text.index(before: scan)
            seen.insert(text[scan], at: seen.startIndex)
            if seen.hasPrefix("```") { return scan }
            if text[scan].isNewline { break }
        }
        return nil
    }

    /// End of a ``` fence immediately following `index` (only whitespace between), else nil.
    static func fenceEnd(in text: String, after index: String.Index) -> String.Index? {
        var i = index
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
        guard text[i...].hasPrefix("```") else { return nil }
        return text.index(i, offsetBy: 3)
    }

    // MARK: - Fields

    /// Macros, clamped and then checked against their own calorie figure.
    static func macros(_ body: [String: Any]) -> Result<MacroTotals, Failure> {
        let m = MacroTotals(
            kcal: MacroEstimateParse.clamped(
                MacroEstimateParse.number(body, "kcal", "calories", "energy"),
                max: MacroEstimateParse.maxKcal),
            protein: MacroEstimateParse.clamped(
                MacroEstimateParse.number(body, "protein", "protein_g", "proteinG"),
                max: MacroEstimateParse.maxGrams),
            carbs: MacroEstimateParse.clamped(
                MacroEstimateParse.number(body, "carbs", "carbohydrates", "carbs_g", "carbsG"),
                max: MacroEstimateParse.maxGrams),
            fat: MacroEstimateParse.clamped(
                MacroEstimateParse.number(body, "fat", "fat_g", "fatG"),
                max: MacroEstimateParse.maxGrams),
            fiber: MacroEstimateParse.clamped(
                MacroEstimateParse.number(body, "fiber", "fibre", "fiber_g", "fiberG"),
                max: MacroEstimateParse.maxGrams))
        guard m.kcal > 0 else { return .failure(.noCalories) }
        // The SAME check the typed-estimate path uses, so a figure arriving through conversation is held
        // to the arithmetic a figure arriving through the estimate button is held to.
        guard !NutritionMath.kcalLooksInconsistent(m) else { return .failure(.inconsistent) }
        return .success(m)
    }

    /// A trimmed non-empty string, or nil. Whitespace-only is nil: a model emitting `"name": " "` has not
    /// named anything, and a food called " " is worse than a refused proposal.
    static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
