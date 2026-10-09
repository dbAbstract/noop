import Foundation

// MARK: - A week of eating, deduplicated
//
// The coach used to be shown TODAY and nothing else. A user who ate 60% of a karahi last night and asked
// about the leftover the next day got a model that had never heard of it — the entry was in the database
// the whole time, simply never sent. That is the bug this block fixes.
//
// WHY DEDUPLICATED RATHER THAN SEVEN DAYS LISTED OUT. Not because the model can skim keys and fetch
// details on demand: there is no fetch inside a request, and every token of the prompt is read and billed
// on every turn. What dedup buys is strictly fewer tokens for the same information. People eat
// repetitively, so a plain list prints "Oikos vanilla | 114 kcal 10P 9C 4F" once per occurrence — five
// times in a week is five copies of a fact that did not change. Keyed, the food is described once and an
// occurrence costs `7c01 ×1`.
//
// AND FOR SAVED FOODS IT IS DESCRIBED ZERO TIMES HERE, because `FoodLibraryDigest.block` already printed
// its macros further up the prompt. Re-stating them is pure duplication, so this block points at them.
//
// DETERMINISM IS A REQUIREMENT, NOT A NICETY. Identical input must produce an identical block: a prompt
// that reshuffles between turns defeats prompt caching on every provider that offers it, and makes a bad
// reply impossible to reproduce. Entries with no id use stable references derived from normalized names
// and per-portion nutrition, so distinct snapshots remain loggable without renumbering other foods.
//
// Pure. Kotlin-twinnable.

/// One logged eat, reduced to what the digest needs.
public struct WeekEntryDigest: Equatable, Sendable {
    /// Days back from today. 0 = today, 1 = yesterday.
    public let daysAgo: Int
    /// The library food's id, or nil for a one-off.
    public let itemId: String?
    /// The cook this was drawn from, or nil.
    public let batchId: String?
    public let name: String
    public let portion: Double
    /// The contribution actually made, already scaled by portion.
    public let macros: MacroTotals
    /// "breakfast" / "lunch" / "dinner" / "snack", or nil.
    public let meal: String?

    public init(daysAgo: Int, itemId: String?, batchId: String?, name: String, portion: Double,
                macros: MacroTotals, meal: String? = nil) {
        self.daysAgo = daysAgo
        self.itemId = itemId
        self.batchId = batchId
        self.name = name
        self.portion = portion
        self.macros = macros
        self.meal = meal
    }
}

/// A cook with leftovers still worth offering.
public struct OpenCookDigest: Equatable, Sendable {
    public let batchId: String
    public let name: String
    public let note: String?
    public let daysAgo: Int
    /// 0…1.
    public let remainingFraction: Double
    public let remainingMacros: MacroTotals

    public init(batchId: String, name: String, note: String?, daysAgo: Int,
                remainingFraction: Double, remainingMacros: MacroTotals) {
        self.batchId = batchId
        self.name = name
        self.note = note
        self.daysAgo = daysAgo
        self.remainingFraction = remainingFraction
        self.remainingMacros = remainingMacros
    }
}

public enum FoodWeekDigest {

    /// How many days back the block covers, today included.
    public static let days = 7

    /// Cap on distinct foods named. A week of real eating lands far below this; the cap exists so a
    /// pathological week cannot crowd out the conversation, and it is STATED when it bites.
    public static let maxFoods = 80

    // MARK: - Keys

    /// Normalize names so spelling case and incidental whitespace do not create duplicate references.
    static func normalisedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A history reference describes one macro snapshot, not every meal that happens to share its name.
    /// Includes cook identity so a fresh cook cannot inherit another cook's leftover reference.
    static func identity(for entry: WeekEntryDigest) -> String {
        let unit = entry.portion.isFinite && entry.portion > 0 ? entry.portion : 1
        let m = entry.macros
        let numbers = [m.kcal, m.protein, m.carbs, m.fat, m.fiber].map {
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0 / unit)
        }
        return ([normalisedName(entry.name), entry.batchId ?? ""] + numbers).joined(separator: "\u{1f}")
    }

    /// Canonical FNV-1a over UTF-16 code units. It is deterministic across launches and platforms.
    static func historyHandle(_ identity: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for unit in identity.utf16 { hash = (hash ^ UInt64(unit)) &* 1099511628211 }
        return "o" + String(format: "%016llx", hash)
    }

    /// Library keys retain their established ID scheme; history-only keys never depend on list position.
    public static func keys(for entries: [WeekEntryDigest]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries {
            if let id = entry.itemId { out[id] = FoodLibraryDigest.handle(for: id) }
            else {
                let identity = identity(for: entry)
                out["history:" + identity] = historyHandle(identity)
            }
        }
        return out
    }

    static func key(for entry: WeekEntryDigest, in keys: [String: String]) -> String? {
        if let id = entry.itemId { return keys[id] }
        return keys["history:" + identity(for: entry)]
    }

    /// Per-portion snapshots for confirmation. Hash collisions and conflicting library snapshots fail closed.
    public static func foodReferences(entries: [WeekEntryDigest]) -> [String: FoodDigestEntry] {
        let keyMap = keys(for: entries)
        let groups = Dictionary(grouping: entries) { key(for: $0, in: keyMap) ?? "" }
        var result: [String: FoodDigestEntry] = [:]
        for (handle, group) in groups where !handle.isEmpty {
            guard group.allSatisfy({ $0.batchId == nil }) else { continue }
            let snapshots = group.sorted(by: occurrenceOrder).compactMap { entry -> FoodDigestEntry? in
                guard entry.portion.isFinite, entry.portion > 0 else { return nil }
                let unit = entry.portion
                return FoodDigestEntry(id: handle, name: entry.name, servingLabel: "1 portion",
                    macros: MacroTotals(kcal: entry.macros.kcal / unit,
                        protein: entry.macros.protein / unit, carbs: entry.macros.carbs / unit,
                        fat: entry.macros.fat / unit, fiber: entry.macros.fiber / unit))
            }
            guard let first = snapshots.first, snapshots.count == group.count,
                  snapshots.allSatisfy({ equivalentMacros($0.macros, first.macros) }) else { continue }
            result[handle] = first
        }
        return result
    }

    private static func equivalentMacros(_ a: MacroTotals, _ b: MacroTotals) -> Bool {
        zip([a.kcal, a.protein, a.carbs, a.fat, a.fiber],
            [b.kcal, b.protein, b.carbs, b.fat, b.fiber]).allSatisfy {
                $0.isFinite && $1.isFinite && abs($0 - $1) < 0.000001
            }
    }

    // MARK: - The block

    /// A week of eating, keyed.
    ///
    /// - Parameters:
    ///   - entries: every logged eat in the window, any order.
    ///   - savedFoodIds: ids already described in the saved-foods block. Those are referenced rather than
    ///     re-described, which is where most of the saving comes from.
    public static func block(entries: [WeekEntryDigest],
                             savedFoodIds: Set<String> = []) -> String {
        guard !entries.isEmpty else {
            return "EATEN (last \(days) days): nothing logged."
        }
        let keyMap = keys(for: entries)

        // One descriptor per distinct food, in key order so the list is stable.
        var described: [String: (name: String, macros: MacroTotals, portion: Double,
                                 isSaved: Bool, batchId: String?)] = [:]
        for e in entries.sorted(by: occurrenceOrder) {
            guard let k = key(for: e, in: keyMap) else { continue }
            if described[k] == nil {
                let saved = e.itemId.map { savedFoodIds.contains($0) } ?? false
                described[k] = (e.name, e.macros, e.portion, saved, e.batchId)
            }
        }

        var lines: [String] = []
        lines.append("EATEN (last \(days) days). Each food is listed ONCE below; the occurrences then "
                     + "reference it by key. Quote a CURRENT key exactly with log to repeat a food; edit only SAVED FOODS.")

        let shownKeys = described.keys.sorted().prefix(maxFoods)
        let dropped = described.count - shownKeys.count
        for k in shownKeys {
            guard let d = described[k] else { continue }
            var line = "- \(k) | \(d.name)"
            if let batchId = d.batchId {
                line += " | from cook \(FoodLibraryDigest.handle(for: batchId))"
            }
            if d.isSaved {
                // Its macros are already above. Saying so is cheaper than repeating them and tells the
                // model where to look rather than leaving it to notice the duplicate.
                line += " | see SAVED FOODS"
            } else {
                // A one-off's macros exist nowhere else in the prompt, so they are stated here — scaled
                // back to ONE portion, because an occurrence line multiplies by its own portion and a
                // figure that had already been scaled would be counted twice.
                let unit = d.portion > 0 ? d.portion : 1
                let per = MacroTotals(kcal: d.macros.kcal / unit, protein: d.macros.protein / unit,
                                      carbs: d.macros.carbs / unit, fat: d.macros.fat / unit,
                                      fiber: d.macros.fiber / unit)
                line += " | per portion \(macroText(per))"
            }
            lines.append(line)
        }
        if dropped > 0 {
            lines.append("- (+\(dropped) more foods this week, not listed)")
        }

        // GROUPED BY DAY, one line per day, because the per-occurrence overhead is what decides whether
        // dedup saves anything at all. A line of its own per eat — "today | breakfast | 7c01aaaa ×1" —
        // costs about as much as simply restating the food's name and macros would have, which makes the
        // whole keyed scheme pointless. Collapsed to "today: 7c01aaaa×1(b), o2×0.25(l)" an occurrence is
        // a key, a number and a letter.
        lines.append("OCCURRENCES (day: key×portion(meal); meal b/l/d/s)")
        let byDay = Dictionary(grouping: entries, by: \.daysAgo)
        for day in byDay.keys.sorted() {
            let items = (byDay[day] ?? []).sorted(by: occurrenceOrder).compactMap { e -> String? in
                guard let k = key(for: e, in: keyMap) else { return nil }
                let meal = e.meal.map { "(\($0.lowercased().prefix(1)))" } ?? ""
                return "\(k)×\(trimmed(e.portion))\(meal)"
            }
            guard !items.isEmpty else { continue }
            let label = day == 0 ? "today" : (day == 1 ? "yesterday" : "-\(day)d")
            lines.append("  \(label): " + items.joined(separator: ", "))
        }

        // Day totals, so "how has my week gone" is answerable without the model re-adding the list.
        var totals: [Int: MacroTotals] = [:]
        for e in entries {
            let running = totals[e.daysAgo] ?? MacroTotals(kcal: 0, protein: 0, carbs: 0, fat: 0, fiber: 0)
            totals[e.daysAgo] = MacroTotals(kcal: running.kcal + e.macros.kcal,
                                            protein: running.protein + e.macros.protein,
                                            carbs: running.carbs + e.macros.carbs,
                                            fat: running.fat + e.macros.fat,
                                            fiber: running.fiber + e.macros.fiber)
        }
        let totalText = totals.keys.sorted().map { d -> String in
            let t = totals[d]!
            let label = d == 0 ? "today" : "-\(d)d"
            return "\(label) \(Int(t.kcal.rounded())) kcal/\(Int(t.protein.rounded()))P"
        }.joined(separator: " | ")
        lines.append("DAILY TOTALS  " + totalText)

        return lines.joined(separator: "\n")
    }

    /// Stable ordering for the occurrence list: newest day first, then meal, then key.
    ///
    /// Fully determined by the entries' own content — no tie broken by array position — so the block is
    /// byte-identical for the same set however the store happened to return it.
    static func occurrenceOrder(_ a: WeekEntryDigest, _ b: WeekEntryDigest) -> Bool {
        if a.daysAgo != b.daysAgo { return a.daysAgo < b.daysAgo }
        let am = a.meal ?? "", bm = b.meal ?? ""
        if am != bm { return am < bm }
        if a.name != b.name { return a.name < b.name }
        return a.portion < b.portion
    }

    // MARK: - Open cooks

    /// The leftovers block — what is still in the fridge and loggable.
    ///
    /// Carries the REMAINING macros rather than the whole cook's, because that is the figure a decision
    /// gets made against: "finish the karahi" costs what is left, not what was made.
    public static func openCooksBlock(_ cooks: [OpenCookDigest]) -> String {
        guard !cooks.isEmpty else { return "" }
        var lines = ["OPEN COOKS (leftovers still in the fridge; log a fraction of one with its key, "
                     + "or the user may say \"the rest\")."]
        for c in cooks.sorted(by: { ($0.daysAgo, $0.name) < ($1.daysAgo, $1.name) }) {
            let when = c.daysAgo == 0 ? "cooked today"
                     : (c.daysAgo == 1 ? "cooked yesterday" : "cooked \(c.daysAgo)d ago")
            var line = "- \(FoodLibraryDigest.handle(for: c.batchId)) | \(c.name) | \(when)"
            line += " | \(Int((c.remainingFraction * 100).rounded()))% left"
            line += " | remaining \(macroText(c.remainingMacros))"
            if let note = c.note, !note.isEmpty {
                // What was different about this cook. Without it the model would reconcile the figures
                // against the recipe and "correct" them back.
                line += " | this cook: \(note)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    static func macroText(_ m: MacroTotals) -> String {
        var parts = ["\(Int(m.kcal.rounded())) kcal"]
        if m.protein > 0 { parts.append("\(trimmed(m.protein))P") }
        if m.carbs > 0 { parts.append("\(trimmed(m.carbs))C") }
        if m.fat > 0 { parts.append("\(trimmed(m.fat))F") }
        return parts.joined(separator: " ")
    }

    static func trimmed(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        return v.rounded() == v && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.2g", v)
    }
}
