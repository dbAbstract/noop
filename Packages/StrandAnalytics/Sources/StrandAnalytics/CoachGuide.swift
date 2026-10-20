import Foundation

// MARK: - Coach guides: how NOOP computes what it shows
//
// FORK-LOCAL (Apple). Coach is given the user's numbers but not how the app arrived at them, so it used to
// explain a Charge or a budget from general knowledge, which is often not how NOOP does it. The app ships a
// short guide per topic (`Strand/Resources/CoachGuide/*.md`): what the number means, how it is computed,
// with the constants the code uses, and what it cannot say.
//
// LAZY, like the nutrition documents. Coach always sees the topic index; a topic's text goes into the
// context when the user's message asks about it (`matching`), or when Coach asks for it with `read_guide`.
//
// A guide is markdown with a small header:
//
//     ---
//     topic: charge
//     title: Charge — the daily recovery score
//     keywords: charge, recovery, readiness
//     sources: Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift
//     ---
//     body
//
// `sources` names the files the guide describes, so a test can fail when one moves and a reader knows what
// to re-check when one changes. Pure: strings in, values out.
public struct CoachGuide: Equatable, Sendable {
    public let topic: String
    public let title: String
    /// Lowercased words and phrases that mark a message as being about this topic.
    public let keywords: [String]
    /// Repository-relative paths of the code the guide describes.
    public let sources: [String]
    public let body: String

    public init(topic: String, title: String, keywords: [String], sources: [String], body: String) {
        self.topic = topic; self.title = title; self.keywords = keywords; self.sources = sources; self.body = body
    }

    /// Read a guide file, or nil when it has no header or lacks a topic, title or body.
    public static func parse(_ text: String) -> CoachGuide? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        func list(_ key: String) -> [String] {
            (fields[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let topic = fields["topic"], !topic.isEmpty, let title = fields["title"], !title.isEmpty,
              !body.isEmpty else { return nil }
        return CoachGuide(topic: topic, title: title, keywords: list("keywords").map { $0.lowercased() },
                          sources: list("sources"), body: body)
    }

    /// Whether a message asks how or why rather than reporting something: a question mark, or a question
    /// word. Logging "had two eggs" must not pull the macro guide into every turn.
    public static func asksForExplanation(_ message: String) -> Bool {
        let m = NutritionDocumentLookup.normalise(message)
        if m.contains("?") || m.contains("？") { return true }
        let words = Set(NutritionDocumentLookup.words(m))
        if !words.isDisjoint(with: questionWords) { return true }
        return ["calculat", "work out", "worked out", "なぜ", "どう", "どうやって", "仕組み"].contains { m.contains($0) }
    }

    static let questionWords: Set<String> = ["how", "why", "what", "explain", "mean", "means", "meaning", "whats"]

    /// Guides whose keywords appear in `message`, most keywords first, at most `limit`. A one-word keyword
    /// must match a whole word ("rest" is not in "restaurant"); a phrase must appear as written.
    public static func matching(_ message: String, in guides: [CoachGuide], limit: Int = 2) -> [CoachGuide] {
        let m = NutritionDocumentLookup.normalise(message)
        let words = Set(NutritionDocumentLookup.words(m))
        let scored: [(guide: CoachGuide, hits: Int, order: Int)] = guides.enumerated().compactMap { i, g in
            let hits = g.keywords.filter { k in
                k.contains(" ") || k.contains("/") || k.contains("-") ? m.contains(k) : words.contains(k)
            }.count
            return hits > 0 ? (g, hits, i) : nil
        }
        return scored.sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.order < $1.order }.prefix(limit).map(\.guide)
    }

    /// The index line Coach always sees for a guide.
    public var indexLine: String { "- \(topic): \(title)" }

    /// The guide as it is placed in Coach's context.
    public var contextText: String { "## \(topic): \(title)\n\(body)" }
}
