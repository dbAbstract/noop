import Foundation
import CoreTransferable
import UniformTypeIdentifiers
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
    /// 2: adds `errorText`, `isSending`, `failedMessageCount` and per-message `failure`.
    static let formatVersion = 2

    /// Build the JSON. Returns nil only if encoding fails, which would mean a non-finite number reached a
    /// macro field and is itself worth knowing about.
    static func json(messages: [ChatMessage],
                     provider: String,
                     model: String,
                     dataConsent: Bool,
                     onDeviceSignals: Bool,
                     hasCustomPrompt: Bool,
                     customPromptMissesFoodProtocol: Bool,
                     errorText: String? = nil,
                     isSending: Bool = false,
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
            // THE OMISSION THAT MADE THE FIRST DUMP HARD TO READ. It showed five identical user turns and
            // an empty assistant turn with no indication that anything had FAILED — the reason was in
            // `errorText`, which was not carried. A transcript of failures that does not say they failed
            // reads as the app silently ignoring the user.
            "errorText": errorText ?? "",
            // True when the dump was taken mid-request, which explains a trailing empty assistant turn
            // rather than leaving it to look like a bug of its own.
            "isSending": isSending,
            "failedMessageCount": messages.filter { $0.failure != nil }.count,
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
        // Which turn failed and why, rather than one global error that cannot say which.
        if let failure = message.failure { out["failure"] = failure }
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
        out["roughGuess"] = proposal.roughGuess
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
        // The WHOLE cook plus the fraction, both, because either alone is unreadable: the macros do not
        // say how much was eaten and the fraction does not say of what.
        case .cook(_, let recipe, let macros, let note, let portion):
            out["portion"] = portion
            out["wholeCookMacros"] = dict(for: macros)
            if let note { out["note"] = note }
            if let recipe {
                out["recipeId"] = recipe.id.uuidString
                // The baseline this cook deviated from, so a disagreement in the figures is readable as
                // the deviation it was rather than as an error.
                out["recipeMacros"] = dict(for: recipe.macros)
            }
        case .logBatch(let cook, let portion):
            out["batchId"] = cook.id.uuidString
            out["portion"] = portion
            out["wholeCookMacros"] = dict(for: cook.whole)
            out["remainingAfter"] = BatchRemainder.remainingFraction(
                loggedPortions: cook.loggedPortions + [portion])
        case .closeBatch(let cook):
            out["batchId"] = cook.id.uuidString
            out["remainingWhenBinned"] = cook.remainingFraction
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
        case .cook: return "cook"
        case .logBatch: return "logBatch"
        case .closeBatch: return "closeBatch"
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

/// A cheap value snapshot. Encoding and disk I/O happen only when the share service requests a file.
struct CoachConversationExport: Transferable {
    let messages: [ChatMessage]
    let provider: String
    let model: String
    let dataConsent: Bool
    let onDeviceSignals: Bool
    let hasCustomPrompt: Bool
    let customPromptMissesFoodProtocol: Bool
    let errorText: String?
    let isSending: Bool
    let generatedAt: Date

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { snapshot in
            SentTransferredFile(try await snapshot.file())
        }
    }

    func file() async throws -> URL {
        try await CoachDumpWriter.shared.write(self)
    }
}

/// A separate actor keeps serialization and filesystem work off the UI actor.
private actor CoachDumpWriter {
    static let shared = CoachDumpWriter()

    func write(_ snapshot: CoachConversationExport) throws -> URL {
        // Separate exports never overwrite a file a share service is still reading.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CoachDump.filename(snapshot.generatedAt))
        let json = CoachDump.json(messages: snapshot.messages, provider: snapshot.provider,
            model: snapshot.model, dataConsent: snapshot.dataConsent,
            onDeviceSignals: snapshot.onDeviceSignals, hasCustomPrompt: snapshot.hasCustomPrompt,
            customPromptMissesFoodProtocol: snapshot.customPromptMissesFoodProtocol,
            errorText: snapshot.errorText, isSending: snapshot.isSending,
            generatedAt: snapshot.generatedAt)
        try (json ?? "{\"error\":\"could not encode the conversation\"}")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

extension AICoachEngine {
    /// Capture the live proposal states without creating a cached file during view updates.
    func conversationExport() -> CoachConversationExport {
        CoachConversationExport(messages: messages, provider: provider.rawValue, model: model,
            dataConsent: dataConsent, onDeviceSignals: includeOnDeviceSignals,
            hasCustomPrompt: hasCustomSystemPrompt,
            customPromptMissesFoodProtocol: customPromptMissesFoodProtocol,
            errorText: errorText, isSending: sending, generatedAt: Date())
    }
}
