import Foundation
import StrandAnalytics

// MARK: - The conversation, as a file you can hand to someone
//
// Exists because "earlier today it did something weird" is not a reportable bug. A screenshot shows the
// prose and loses everything that decides behaviour: which proposals the model actually emitted, what they
// resolved to against the library, which day they targeted, and whether the user tapped them.
//
// THE PROPOSALS ARE THE POINT. `persistMessages` stores text only — a proposal lives in `ChatMessage` in
// memory and is deliberately not persisted, so a card does not come back hours later inviting the user to
// log a meal they have long since logged or forgotten. That makes a dump read from LIVE engine state the
// only place the full picture exists, and it means a dump is worth taking while the oddity is on screen
// rather than after a relaunch.
//
// WHAT IT MUST NOT CARRY. No API key, no provider credentials, and no raw strap data. The transcript, the
// proposals, and the few settings that change how the model behaves — the provider name and model id,
// whether data consent is on — because a reply is unexplainable without knowing which model produced it.
// A key would make the file unshareable, which is the opposite of its purpose.
//
// Available in RELEASE builds, deliberately. The user is on a sideloaded release install; a diagnostic
// only the dev build can take is a diagnostic that is never there when something goes wrong.

enum CoachDump {

    /// Schema version, so a file can be read correctly after the shape changes. Bumped on any field change
    /// — a reader that guesses from the keys present will get a later version subtly wrong.
    static let formatVersion = 1

    /// Build the JSON. Returns nil only if encoding fails, which would mean a non-finite number reached a
    /// macro field and is itself worth knowing about.
    static func json(messages: [ChatMessage],
                     provider: String,
                     model: String,
                     dataConsent: Bool,
                     onDeviceSignals: Bool,
                     hasCustomPrompt: Bool,
                     customPromptMissesFoodProtocol: Bool,
                     generatedAt: Date = Date()) -> String? {
        let payload: [String: Any] = [
            "formatVersion": formatVersion,
            "generatedAt": ISO8601DateFormatter().string(from: generatedAt),
            // No key, no base URL — see the header. The provider and model are what make a reply
            // explainable; the credential is what would make the file unshareable.
            "provider": provider,
            "model": model,
            "dataConsent": dataConsent,
            "onDeviceSignals": onDeviceSignals,
            "hasCustomPrompt": hasCustomPrompt,
            // Carried because it silently disables the food-logging protocol, and "Coach never offers to log
            // anything" is exactly the kind of report this file is meant to explain.
            "customPromptMissesFoodProtocol": customPromptMissesFoodProtocol,
            "messageCount": messages.count,
            "messages": messages.map(dict(for:)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// A suggested filename. Second-resolution stamp so two dumps in one minute do not collide.
    static func filename(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "noop-coach-\(f.string(from: date)).json"
    }

    // MARK: - Shapes

    private static func dict(for message: ChatMessage) -> [String: Any] {
        var out: [String: Any] = [
            "id": message.id.uuidString,
            "role": message.role.rawValue,
            "text": message.text,
        ]
        if !message.proposals.isEmpty {
            out["proposals"] = message.proposals.map(dict(for:))
        }
        return out
    }

    private static func dict(for proposal: FoodProposal) -> [String: Any] {
        var out: [String: Any] = [
            "id": proposal.id.uuidString,
            // Whether the user ACTED on it, which is the difference between "the model proposed something
            // odd" and "something odd got logged".
            "state": String(describing: proposal.state),
            "day": proposal.dayKey,
            "dayLabel": proposal.dayLabel,
            "kind": kindName(proposal.kind),
            "displayName": proposal.displayName,
        ]
        if let meal = proposal.meal { out["meal"] = meal.rawValue }
        // What it would actually have banked, which is the figure a reader needs to judge whether the
        // proposal was wrong — the per-serving macros alone do not say.
        if let logged = proposal.loggedMacros { out["logsMacros"] = dict(for: logged) }

        switch proposal.kind {
        case .log(let item, let portion):
            out["itemId"] = item.id.uuidString
            out["portion"] = portion
            out["itemMacros"] = dict(for: item.macros)
        case .create(_, let serving, let macros, let portion):
            out["servingLabel"] = serving
            out["portion"] = portion
            out["macros"] = dict(for: macros)
        case .save(_, let serving, let macros):
            out["servingLabel"] = serving
            out["macros"] = dict(for: macros)
        case .edit(let item, let name, let macros):
            out["itemId"] = item.id.uuidString
            // Before AND after. An edit with only the proposed figures cannot be judged at all.
            out["macrosBefore"] = dict(for: item.macros)
            out["macrosProposed"] = dict(for: macros)
            if let name { out["proposedName"] = name }
        case .weight(let kg):
            out["kg"] = kg
        case .unresolved(let handle):
            // The handle the model quoted, which is the whole diagnostic for this case — it says whether
            // the model invented an id or merely hit an ambiguous prefix.
            out["unresolvedHandle"] = handle
        case .implausibleWeight(let kg, let last):
            out["kg"] = kg
            out["lastKnownKg"] = last
        case .duplicate(let name):
            // Worth carrying: a run of these says the model is repeating its own earlier output, which is a
            // different report from "it proposed something wrong".
            out["duplicateOf"] = name
        }
        return out
    }

    private static func kindName(_ kind: FoodProposal.Kind) -> String {
        switch kind {
        case .log: return "log"
        case .create: return "create"
        case .save: return "save"
        case .edit: return "edit"
        case .weight: return "weight"
        case .unresolved: return "unresolved"
        case .implausibleWeight: return "implausibleWeight"
        case .duplicate: return "duplicate"
        }
    }

    /// Macros as a dict, with non-finite values dropped rather than encoded.
    ///
    /// `JSONSerialization` THROWS on a NaN or an infinity, so one bad figure would fail the whole dump —
    /// losing the file at exactly the moment it is most wanted, since a non-finite macro is itself a bug
    /// worth reporting. Dropped keys say "absent", which is true and readable.
    private static func dict(for m: MacroTotals) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in [("kcal", m.kcal), ("protein", m.protein), ("carbs", m.carbs),
                             ("fat", m.fat), ("fiber", m.fiber)] where value.isFinite {
            out[key] = value
        }
        return out
    }
}
