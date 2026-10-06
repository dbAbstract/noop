import Foundation
import StrandAnalytics

struct OpenAIClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // The shape is chosen from the MODEL ID first (`AIModelParams`), so a gpt-5 request does not have
        // to fail once before working. The 400-retry below is a safety net for a family that is not in that
        // list yet — and it flips to the OTHER shape rather than always to the modern one, so it recovers
        // in both directions.
        let modern = AIModelParams.needsModernParams(model: model)
        do {
            return try await chat(key: key, model: model, wire: wire, modernParams: modern, session: session)
        } catch let AICoachError.server(code, detail) where code == 400 {
            guard AIModelParams.isParameterShapeError(detail) else {
                throw AICoachError.server(code, detail)
            }
            return try await chat(key: key, model: model, wire: wire, modernParams: !modern,
                                  session: session)
        }
    }

    /// K1: Stream via `stream: true`. Same body as `send`, with `stream: true` added. SSE parsing
    /// via `SseDeltas.openAiDelta`. Byte-parity pin in `SseDeltasTests.openAiReassembleMatchesFullReply`.
    ///
    /// THE PARAMETER-SHAPE RETRY LIVES HERE TOO, which it did not before. The old comment claimed this path
    /// "falls back to `send`'s retry" — it does not: streaming is the MAIN chat path, so a gpt-5 user got
    /// the provider's raw 400 about `max_tokens` and no reply at all. The retry is re-issued as a
    /// non-streamed `send`, because the first attempt may already have emitted deltas and re-streaming
    /// would duplicate them on screen.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        let modern = AIModelParams.needsModernParams(model: model)
        do {
            try await streamOnce(key: key, model: model, wire: wire, modernParams: modern,
                                 session: session, onDelta: onDelta)
        } catch let AICoachError.server(code, detail) where code == 400 {
            guard AIModelParams.isParameterShapeError(detail) else {
                throw AICoachError.server(code, detail)
            }
            // Re-issued NON-STREAMED and delivered as one delta. A 400 arrives before any body, so nothing
            // has been shown yet — but re-streaming would risk duplicating deltas if that ever changed,
            // and the whole reply in one chunk renders identically.
            let whole = try await chat(key: key, model: model, wire: wire, modernParams: !modern,
                                       session: session)
            onDelta(whole)
        }
    }

    private func streamOnce(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var body: [String: Any] = ["model": model, "messages": wire, "stream": true]
        if modernParams {
            body["max_completion_tokens"] = 4096
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 4096
        }

        var req = URLRequest(url: AIProvider.openAI.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.openAiDelta(payload) {
                onDelta(delta)
            }
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.openAI.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into chat-capable ids (gpt*/o*). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return (id.hasPrefix("gpt") || id.hasPrefix("o")) ? id : nil
        }
    }

    // MARK: Private

    /// `modernParams`: use `max_completion_tokens`, drop `temperature` — required by reasoning models.
    private func chat(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": wire]
        // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
        // reply complete (a cap, not a target — the system prompt keeps it short). Matches Gemini + Android.
        if modernParams {
            body["max_completion_tokens"] = 4096
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 4096
        }

        var req = URLRequest(url: AIProvider.openAI.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        return content
    }
}
