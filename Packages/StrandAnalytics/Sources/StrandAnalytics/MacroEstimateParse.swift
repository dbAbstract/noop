import Foundation

// MARK: - Reading macros out of a language model's reply
//
// The model is asked for a bare JSON object. It will not always send one: it may wrap it in a ```json
// fence, prefix it with "Sure! Here's the breakdown:", or — on a small local model with a short context
// window — stop halfway through.
//
// So this is deliberately tolerant about the WRAPPING and deliberately strict about the CONTENT. Finding
// the object is a formatting problem and worth being generous with; believing the numbers inside it is a
// correctness problem and is not.
//
// THE REJECTIONS ARE THE POINT. A model that returns plausible-looking macros which do not add up to its
// own calorie figure has hallucinated, and that is detectable in code — `NutritionMath.kcalConsistency`
// already does it, and already has tests. An estimate that survives this function has been checked
// against arithmetic, not merely parsed.
//
// What this does NOT do is correct anything. If the numbers disagree, the estimate is refused rather than
// repaired: silently rewriting a model's kcal from its own macros would hand the user a figure neither
// they nor the model ever stated, which is the failure mode the whole food log is built to avoid.
//
// Pure, no network, no store. Kotlin-twinnable; `SseDeltas` is the structural model.

public enum MacroEstimateParse {

    /// Rejection reasons, so a caller can say something useful rather than "that didn't work".
    public enum Failure: String, Equatable, Sendable, Error {
        /// No JSON object could be found at all — the model answered in prose.
        case noJSON
        /// An object started but never closed. Specifically NOT salvaged: a truncated reply's last
        /// number is as likely to be half-written as complete, and a plausible-looking fragment is
        /// worse than an honest failure.
        case truncated
        /// Parsed, but carried no usable energy figure.
        case noCalories
        /// The stated calories and the stated macros disagree by more than the Atwater tolerance. The
        /// model contradicted itself, so neither number is trustworthy.
        case inconsistent
    }

    /// An upper bound per field, to stop a misplaced decimal becoming a day's budget.
    ///
    /// Generous on purpose — a very large restaurant meal is a real thing and this must not refuse it.
    /// It exists to catch 25,000 kcal, not 1,500.
    public static let maxKcal = 10_000.0
    public static let maxGrams = 2_000.0

    /// Pull macros out of a model's reply, or say why not.
    public static func macros(fromReply reply: String) -> Result<MacroTotals, Failure> {
        guard let objectText = firstJSONObject(in: reply) else {
            // An opening brace with no close is a truncation, not an absence — worth telling apart,
            // because the user's remedy differs (retry vs. the model simply cannot do this).
            return .failure(reply.contains("{") ? .truncated : .noJSON)
        }
        guard let data = objectText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.truncated)
        }

        let macros = MacroTotals(
            kcal: clamped(number(obj, "kcal", "calories", "energy"), max: maxKcal),
            protein: clamped(number(obj, "protein", "protein_g", "proteinG"), max: maxGrams),
            carbs: clamped(number(obj, "carbs", "carbohydrates", "carbs_g", "carbsG"), max: maxGrams),
            fat: clamped(number(obj, "fat", "fat_g", "fatG"), max: maxGrams),
            fiber: clamped(number(obj, "fiber", "fibre", "fiber_g", "fiberG"), max: maxGrams))

        guard macros.kcal > 0 else { return .failure(.noCalories) }
        // The arithmetic check. A reply whose macros do not add up to its own calorie figure is a
        // hallucination with a plausible shape, and this is the only part of the pipeline that can
        // notice. Fibre is excluded from the sum — see NutritionMath.
        guard !NutritionMath.kcalLooksInconsistent(macros) else { return .failure(.inconsistent) }
        return .success(macros)
    }

    // MARK: - Finding the object

    /// The first balanced `{…}` in the text, ignoring braces inside strings.
    ///
    /// Brace COUNTING rather than a regex or a first-to-last slice, because a nested object (a model
    /// helpfully adding `"per_serving": {...}`) would defeat both: a naive scan to the last `}` would
    /// swallow trailing prose, and to the first `}` would cut the outer object short.
    ///
    /// Returns nil for an unterminated object, which the caller reports as truncation.
    static func firstJSONObject(in text: String) -> String? {
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
                guard depth > 0 else { break }   // a stray close before any open — ignore it
                depth -= 1
                if depth == 0, let s = start {
                    return String(text[s...i])
                }
            default: break
            }
        }
        return nil
    }

    // MARK: - Reading fields

    /// First present key wins, so the model can say `protein` or `protein_g` without the prompt having
    /// to win that argument. Accepts a JSON number or a numeric string ("24" and "24 g" both read as 24),
    /// because models return both and refusing a string would fail on a formatting detail.
    static func number(_ obj: [String: Any], _ keys: String...) -> Double {
        for k in keys {
            guard let raw = obj[k] else { continue }
            if let d = raw as? Double { return d }
            if let i = raw as? Int { return Double(i) }
            if let s = raw as? String {
                let digits = s.trimmingCharacters(in: .whitespaces)
                    .prefix { $0.isNumber || $0 == "." || $0 == "-" }
                if let d = Double(digits) { return d }
            }
        }
        return 0
    }

    /// Non-finite and negative collapse to zero (the shared `NutritionMath` rule); anything past the
    /// ceiling is treated as a decimal slip and also collapses, rather than being capped AT the ceiling —
    /// a 10,000 kcal sandwich is not a better answer than no answer.
    static func clamped(_ v: Double, max limit: Double) -> Double {
        guard v.isFinite, v > 0, v <= limit else { return 0 }
        return v
    }
}
