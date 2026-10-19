import Foundation

// MARK: - Looking a food up in a stored nutrition document
//
// FORK-LOCAL (diet). A nutrition PDF is stored as page text plus a NAME INDEX (per menu row: the printed
// name and a few aliases). When the user asks the coach to log something, the app finds the rows whose
// names match what was said, hands those rows — verbatim, with the table's header line — to the coach,
// and checks every figure the coach then proposes against the row it cites.
//
// THE INDEX NEVER CARRIES A NUMBER. It exists so "Big Mac" finds ビッグマック; the kcal, protein, carbs
// and fat always come from the page line itself, and a proposal whose figures are not printed on that
// line is refused. That keeps the one guarantee the eager import had — no figure the document does not
// print — without extracting and reviewing a whole menu nobody will eat most of.
//
// Pure: strings in, values out. No store, no network.
public enum NutritionDocumentLookup {

    /// One indexed menu row.
    public struct Entry: Equatable, Sendable {
        public let documentId: String
        public let page: Int
        /// 0-based line within the page text.
        public let line: Int
        public let name: String
        public let aliases: [String]

        public init(documentId: String, page: Int, line: Int, name: String, aliases: [String]) {
            self.documentId = documentId; self.page = page; self.line = line; self.name = name; self.aliases = aliases
        }
    }

    /// A row matched to a query.
    public struct Match: Equatable, Sendable {
        public let documentId: String
        public let page: Int
        public let line: Int
        /// The indexed name, or nil for a match on raw page text (a document stored without an index).
        public let name: String?
        public let score: Int

        public init(documentId: String, page: Int, line: Int, name: String?, score: Int) {
            self.documentId = documentId; self.page = page; self.line = line; self.name = name; self.score = score
        }
    }

    // MARK: Normalising text

    /// Case-, diacritic- and width-folded, apostrophes dropped, whitespace collapsed. Width folding is what
    /// makes a full-width "ＢＩＧ ＭＡＣ" or "５２５" in a Japanese PDF compare equal to what the user typed.
    public static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Words of two or more characters. A run of CJK text has no spaces, so it stays one word; matching it
    /// relies on containment (`score`), not on token overlap.
    static func words(_ normalised: String) -> [String] {
        normalised.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    /// Words too common in a food request to mean anything on their own.
    static let stopWords: Set<String> = [
        "log", "logged", "had", "have", "ate", "eat", "eaten", "the", "and", "for", "with", "from", "just",
        "lunch", "dinner", "breakfast", "snack", "today", "yesterday", "please", "can", "you", "add", "one",
        "two", "large", "small", "medium", "set", "meal", "some", "this", "that", "was", "got", "get",
    ]

    // MARK: Matching

    /// How well one name (or alias) matches a normalised query. 0 = no match.
    ///
    /// Containment of the whole name in the query is the strong signal: "big mac" inside "log a big mac
    /// for lunch", or ビッグマック inside a request typed in Japanese. Otherwise every meaningful word of
    /// the name must appear in the query — "mac big" still matches, "big" alone does not match "Big Mac".
    static func score(candidate: String, query: String, queryWords: Set<String>) -> Int {
        let c = normalise(candidate)
        guard c.count >= 2 else { return 0 }
        if query.contains(c) { return 100 + c.count }
        let meaningful = words(c).filter { !stopWords.contains($0) }
        guard !meaningful.isEmpty, meaningful.allSatisfy({ queryWords.contains($0) }) else { return 0 }
        return 50 + meaningful.reduce(0) { $0 + $1.count }
    }

    /// Rows matching `query`, best first. Indexed entries are matched on their name and aliases; pages of a
    /// document with no index entries at all (`unindexedPages`) are matched on their raw lines, so a document
    /// stored without an AI index still answers a request in its own language.
    public static func match(query: String, entries: [Entry],
                             unindexedPages: [(documentId: String, page: Int, text: String)] = [],
                             limit: Int = 8) -> [Match] {
        let q = normalise(query)
        let qWords = Set(words(q))
        var out: [Match] = []
        for e in entries {
            let best = ([e.name] + e.aliases).map { score(candidate: $0, query: q, queryWords: qWords) }.max() ?? 0
            if best > 0 {
                out.append(Match(documentId: e.documentId, page: e.page, line: e.line, name: e.name, score: best))
            }
        }
        for p in unindexedPages {
            let meaningful = qWords.filter { !stopWords.contains($0) && $0.count >= 3 }
            guard !meaningful.isEmpty else { continue }
            for (i, line) in p.text.components(separatedBy: "\n").enumerated() where hasNumber(line) {
                let l = normalise(line)
                // Raw lines are noisier than names, so they need every meaningful query word.
                guard meaningful.allSatisfy({ l.contains($0) }) else { continue }
                out.append(Match(documentId: p.documentId, page: p.page, line: i, name: nil,
                                 score: 10 + meaningful.reduce(0) { $0 + $1.count }))
            }
        }
        return Array(out.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.documentId != $1.documentId { return $0.documentId < $1.documentId }
            return ($0.page, $0.line) < ($1.page, $1.line)
        }.prefix(limit))
    }

    // MARK: The table header

    /// Words that mark a nutrition table's header row, in the languages the import reads.
    static let headerTerms = [
        "kcal", "calorie", "energy", "protein", "fat", "carb", "fibre", "fiber", "sugar", "salt", "sodium",
        "エネルギー", "熱量", "たんぱく質", "蛋白質", "タンパク質", "脂質", "炭水化物", "糖質", "食物繊維", "食塩",
    ]

    /// Whether a line reads as a column header: two or more nutrient terms.
    public static func isHeader(_ line: String) -> Bool {
        let l = normalise(line)
        return headerTerms.filter { l.contains(normalise($0)) }.count >= 2
    }

    /// The header for a row: the nearest header line above it on the page, else the page's first header.
    /// nil when the page has none — the row is then shown without one, and the coach told so.
    public static func header(forLine line: Int, inPage text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return nil }
        if let above = (0..<line).reversed().first(where: { isHeader(lines[$0]) }) { return lines[above] }
        return lines.indices.first(where: { isHeader(lines[$0]) }).map { lines[$0] }
    }

    /// The line itself, or nil when it is out of range.
    public static func line(_ line: Int, inPage text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        return line >= 0 && line < lines.count ? lines[line] : nil
    }

    // MARK: Checking figures against a row

    /// Every number printed in a line. A comma followed by exactly three digits is read BOTH ways, as a
    /// thousands separator and as a decimal comma: "1,050 kcal" is 1050 in one menu and "2,5 g" is 2.5 in
    /// another, and the check only needs the proposed figure to be among the readings.
    public static func numbers(in line: String) -> [Double] {
        let s = Array(normalise(line))
        var out: [Double] = []
        var i = 0
        while i < s.count {
            guard s[i].isASCII, s[i].isNumber else { i += 1; continue }
            var j = i
            while j < s.count, s[j].isASCII, s[j].isNumber { j += 1 }
            var text = String(s[i..<j])
            var alternative: String?
            if j + 1 < s.count, s[j] == "." || s[j] == ",", s[j + 1].isASCII, s[j + 1].isNumber {
                var k = j + 1
                while k < s.count, s[k].isASCII, s[k].isNumber { k += 1 }
                let fraction = String(s[(j + 1)..<k])
                if s[j] == ",", fraction.count == 3 { alternative = text + fraction }
                text += "." + fraction
                j = k
            }
            if let v = Double(text) { out.append(v) }
            if let alternative, let v = Double(alternative) { out.append(v) }
            i = j
        }
        return out
    }

    public static func hasNumber(_ line: String) -> Bool { !numbers(in: line).isEmpty }

    /// Whether every proposed figure is printed on the row. nil fibre means "not stated" and is not checked.
    public static func figuresArePrinted(kcal: Double, protein: Double, carbs: Double, fat: Double,
                                         fiber: Double?, in line: String) -> Bool {
        let printed = numbers(in: line)
        let wanted = [kcal, protein, carbs, fat] + (fiber.map { [$0] } ?? [])
        return wanted.allSatisfy { w in w.isFinite && printed.contains { abs($0 - w) < 0.001 } }
    }

    // MARK: Row keys

    /// How the coach context names a row, and how a `log_document` action refers back to it:
    /// "d" + the first eight hex digits of the document id, then page and line. Short enough to copy
    /// reliably, specific enough that two stored documents cannot share one by accident.
    public static func rowKey(documentId: String, page: Int, line: Int) -> String {
        "d\(documentPrefix(documentId))p\(page)l\(line)"
    }

    static func documentPrefix(_ documentId: String) -> String {
        String(documentId.lowercased().filter { $0.isHexDigit }.prefix(8))
    }

    /// Split a row key back into its parts. nil for anything not of that shape.
    public static func parseRowKey(_ key: String) -> (documentPrefix: String, page: Int, line: Int)? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard k.hasPrefix("d"), let p = k.firstIndex(of: "p"), let l = k.lastIndex(of: "l"), p < l else { return nil }
        let prefix = String(k[k.index(after: k.startIndex)..<p])
        guard prefix.count == 8, prefix.allSatisfy(\.isHexDigit),
              let page = Int(k[k.index(after: p)..<l]), let line = Int(k[k.index(after: l)...]),
              page >= 1, line >= 0 else { return nil }
        return (prefix, page, line)
    }

    /// Whether a row key names this document.
    public static func key(_ parsed: (documentPrefix: String, page: Int, line: Int), names documentId: String) -> Bool {
        parsed.documentPrefix == documentPrefix(documentId)
    }

    // MARK: Building the index

    /// The page text with each line numbered, for the indexing request: "L0\t…".
    public static func numberedLines(_ text: String) -> String {
        text.components(separatedBy: "\n").enumerated().map { "L\($0.offset)\t\($0.element)" }.joined(separator: "\n")
    }

    /// Read an indexing reply: `{"items":[{"line":12,"name":"ビッグマック","aliases":["Big Mac"]}]}`.
    ///
    /// An entry survives only when its line exists, carries at least one number (a menu row prints figures),
    /// is not the header, and contains the name as printed. Aliases are capped and trimmed; they are search
    /// terms, never shown as the food's name. Anything else in the reply is ignored.
    public static func parseIndexReply(_ reply: String, pageText: String) -> [(line: Int, name: String, aliases: [String])] {
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = clean.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return [] }
        let lines = pageText.components(separatedBy: "\n")
        var out: [(line: Int, name: String, aliases: [String])] = []
        var seen = Set<Int>()
        for item in items.prefix(400) {
            guard let n = (item["line"] as? NSNumber)?.intValue, n >= 0, n < lines.count, !seen.contains(n),
                  let rawName = item["name"] as? String else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let row = lines[n]
            guard name.count >= 2, name.count <= 200, hasNumber(row), !isHeader(row),
                  normalise(row).contains(normalise(name)) else { continue }
            let aliases = ((item["aliases"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 && $0.count <= 80 && normalise($0) != normalise(name) }
            seen.insert(n)
            out.append((n, name, Array(aliases.prefix(5))))
        }
        return out
    }
}
