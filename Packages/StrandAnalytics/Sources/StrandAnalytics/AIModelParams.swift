import Foundation

// MARK: - Which parameter shape a chat model wants
//
// OpenAI's newer families reject the parameters the gpt-4 family requires, and vice versa. `gpt-5` answers
// a `max_tokens` request with a 400 naming `max_completion_tokens`; a gpt-4 model answers
// `max_completion_tokens` with a 400 of its own. Reasoning models additionally reject `temperature`
// outright rather than ignoring it.
//
// SO THE SHAPE IS CHOSEN FROM THE MODEL ID, and the 400-retry stays as a SAFETY NET rather than as the
// mechanism. Relying on the retry alone was the bug: every request for a newer model paid a failed round
// trip first, and on the streaming path — which is the main chat path — there was no retry at all, so the
// user simply saw the provider's error. Relying on the id alone would be equally wrong, because the next
// family is not in this list yet.
//
// MATCHED ON PREFIXES, not an exhaustive list of ids. Snapshot suffixes (`gpt-5-2026-01-01`), `-mini` and
// `-nano` variants all have to work, and a list of exact ids is a list that is already out of date.
//
// Pure string work. Kotlin-twinnable; the Android client sends the same bodies.

public enum AIModelParams {

    /// Model-id prefixes that want `max_completion_tokens` and no `temperature`.
    ///
    /// `gpt-5` and the `o`-series reasoning models. Ordered longest-first is unnecessary — these are
    /// disjoint — but note `o1`/`o3`/`o4` need the dash: a bare "o" prefix would match "openai/…" on a
    /// gateway, and `chatgpt-4o` ends in something that looks like a reasoning id without being one.
    public static let modernPrefixes = ["gpt-5", "o1-", "o3-", "o4-"]

    /// Exact ids that take the modern shape but carry no dash suffix, so the prefix rule would miss them.
    public static let modernExact: Set<String> = ["o1", "o3", "o4", "gpt-5"]

    /// Completion cap for the gpt-4 family: the visible answer only.
    public static let standardMaxTokens = 4096

    /// Completion cap for reasoning models, which is a DIFFERENT QUANTITY despite the similar name.
    ///
    /// `max_completion_tokens` counts REASONING tokens as well as the visible reply, so a cap sized for an
    /// answer starves the thinking that produces it: gpt-5 spends the whole budget reasoning, hits the cap,
    /// and returns an EMPTY message with `finish_reason: "length"`. On screen that is a long "thinking…"
    /// followed by nothing — which is exactly the failure this value was set too low to avoid.
    ///
    /// 16384 is headroom rather than a target. The system prompt still governs reply length, and an unused
    /// allowance costs nothing: completion tokens are billed as generated, not as reserved.
    public static let reasoningMaxTokens = 16_384

    /// How hard a reasoning model should think, where the parameter is supported.
    ///
    /// "low", deliberately. This is a food-logging assistant: the work is reading a sentence about toast and
    /// returning a macro estimate, not solving a proof. Deep reasoning spends minutes and thousands of
    /// tokens to answer a question that does not need them, and the latency is what reads as a hang.
    public static let reasoningEffort = "low"

    /// Whether the model accepts `reasoning_effort`.
    ///
    /// Tied to the same families that need the modern body — the two travel together on OpenAI's side — but
    /// named separately, because a future model could want one and not the other and a shared flag would
    /// hide that.
    public static func acceptsReasoningEffort(model: String) -> Bool {
        needsModernParams(model: model)
    }

    /// Whether this model needs the modern parameter shape.
    ///
    /// Unknown models answer FALSE — the gpt-4 shape — because that is what every OpenAI-compatible
    /// gateway, local Ollama and LM Studio build accepts. Guessing modern for an unknown id would break
    /// the Custom provider for everyone running llama.cpp.
    public static func needsModernParams(model: String) -> Bool {
        let id = normalised(model)
        guard !id.isEmpty else { return false }
        if modernExact.contains(id) { return true }
        return modernPrefixes.contains { id.hasPrefix($0) }
    }

    /// A 400's detail text says the body was the wrong shape.
    ///
    /// The retry trigger, kept here beside the id rule so the two cannot drift — a provider that starts
    /// phrasing this differently is one edit in one place.
    public static func isParameterShapeError(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return d.contains("max_completion_tokens")
            || d.contains("max_tokens")
            || d.contains("temperature")
            || d.contains("unsupported parameter")
            || d.contains("unsupported value")
    }

    /// Strip a gateway's vendor prefix and lowercase.
    ///
    /// A Custom endpoint commonly addresses models as `openai/gpt-5` or `azure/gpt-5`, and the shape the
    /// model wants is a property of the model rather than of the route it was reached by.
    static func normalised(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
