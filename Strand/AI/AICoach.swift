import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - AI Coach (the one networked feature, strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat, no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question - only a short text summary of your metrics goes to the provider you pick."

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    /// Food actions the coach proposed on this turn, resolved and awaiting the user's taps.
    ///
    /// A LIST, because "eggs, toast and a coffee" is one sentence and should be one turn. Each is confirmed
    /// independently, so a wrong item can be dropped without losing the two that were right.
    ///
    /// On the MESSAGE rather than on the engine, so it survives scrolling, re-render and the transcript's
    /// own persistence boundary — and so a conversation that logs three things in a row keeps three
    /// distinct cards in the order they were proposed, instead of one slot they fight over.
    ///
    /// Not persisted: `persistMessages` stores text only, so a proposal does not survive an app restart.
    /// That is deliberate rather than unfinished — a card restored hours later would invite the user to
    /// log a meal they have long since logged or forgotten, with no way to tell which.
    var proposals: [FoodProposal] = []
    /// Why this turn did not get through, when it did not.
    ///
    /// On the USER's message rather than on the engine, because `errorText` is a single global slot: it
    /// describes the latest failure and says nothing about WHICH message is unsent. Without this the user
    /// has no option but to copy their text and paste it again — which is exactly what happened, five
    /// times, and each retry re-sent the whole accumulated history.
    var failure: String?
    /// When this turn was composed, epoch seconds.
    ///
    /// STAMPED ONCE, AT CREATION, and that is the whole point of storing it rather than reading the clock
    /// where it is used. `persistMessages` replaces every row on each completed turn, and it used to write
    /// `Date()` into all of them — so an hour-old brief was re-dated to now every time anything was sent,
    /// and the transcript's history flattened to a single instant with each save.
    ///
    /// The `coachMessage.createdAt` column already existed and already held this; nothing migrates. What
    /// changes is that the value now survives the next write.
    var sentAt: Int

    init(id: UUID = UUID(), role: Role, text: String, proposals: [FoodProposal] = [],
         failure: String? = nil, sentAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id
        self.role = role
        self.text = text
        self.proposals = proposals
        self.failure = failure
        self.sentAt = sentAt
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API key. Uses a generic-password item under a fixed
/// service so the key never lands in UserDefaults, a plist, or on disk in the clear.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// UserDefaults key recording which provider the stored API key belongs to, so one provider's key
    /// is never sent to another provider's endpoint (above all the arbitrary user-typed Custom URL).
    private static let ownerKey = "ai.keyProvider"

    /// The provider the stored key was saved for, or nil for a legacy key saved before this tracking.
    static var ownerProvider: String? { UserDefaults.standard.string(forKey: ownerKey) }

    /// Store (or replace) the API key for `owner`. Empty/whitespace input is treated as a clear.
    /// Returns true once the key is in the Keychain (or was cleared); false if the Keychain write
    /// failed, in which case the owner marker is left untouched so it never points at a key that
    /// isn't actually stored (#872). The live `read()`/`hasKey` gating already reads the real
    /// Keychain, so this is defensive tidying of the discarded write result, not a behaviour change.
    @discardableResult
    static func save(_ key: String, owner: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(owner, forKey: ownerKey)
        return true
    }

    /// Read the stored API key, or nil if none is set.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Remove any stored API key.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
enum AICoachError: LocalizedError {

    /// Whether an HTTP status means the stored key itself was turned away, as opposed to the provider
    /// being busy, broken, or asked for something it does not have.
    ///
    /// Named rather than left as two literals in two switches because it is the hinge the key-repair
    /// affordance hangs on, and it decides what the wearer is told to go and do. Widen it and a rate
    /// limit starts demanding a new key; narrow it and the trap this exists to remove comes straight
    /// back. Byte-identical twin of the Kotlin `AiCoach.isKeyRejection`.
    static func isKeyRejection(_ status: Int) -> Bool { status == 401 || status == 403 }

    case noKey
    case emptyQuestion
    case badKey
    case rateLimited(String)
    case server(Int, String)
    case network(String)
    case decode
    case emptyReply(String)   // #1074: verbatim provider-error / empty-reply text (byte-parity with Android emptyReplyMessage)
    case keySaveFailed
    case badCustomURL(String)

    var errorDescription: String? {
        switch self {
        case .badCustomURL(let message):
            return message
        case .noKey:
            return "Add your own API key first to use the coach."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited(let detail):
            let extra = detail.isEmpty ? "" : " (\(detail))"
            return "The provider is rate-limiting requests right now. Wait a moment and try again.\(extra)"
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        case .emptyReply(let message):
            return message
        }
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    @Published var messages: [ChatMessage] = []

    @Published var sending = false
    @Published var errorText: String?

    /// Whether the last failure was the provider turning the stored key away, as opposed to a rate
    /// limit, a server fault or the network.
    ///
    /// It exists because the rejection message tells the wearer to check their key while the screen
    /// offers no way to reach it: the coach shows the chat as soon as ANY key is stored, and a wrong
    /// key is still a stored key, so the only route back was a Disconnect that also throws the
    /// conversation away. This lets the error carry the field with it.
    ///
    /// It QUALIFIES `errorText` rather than standing on its own, and the view reads it only inside the
    /// branch that renders one, so it cannot leave a key editor open under no error. Assigned on every
    /// failure, so a rejection followed by a rate limit stops claiming to be a rejection. Twin of the
    /// Kotlin `CoachViewModel.keyRejected`.
    @Published var keyRejected = false

    /// #1862: a question handed over by the Today Coach launcher sheet, for `CoachView` to send on appear.
    ///
    /// The launcher owns no send, stream, error or consent surface of its own — duplicating those is how a
    /// second chat UI drifts from the first. It collects a question and hands it here; the Coach screen,
    /// which already has all of that, consumes it exactly once and clears it. Nil is the normal state, and
    /// setting it performs NO network work by itself.
    @Published var pendingPrompt: String?
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
            // The message names a provider ("That API key was rejected", after a request only THIS
            // provider saw), so it cannot survive switching to a different one. Harmless while only the
            // chat rendered it; wrong now that the setup card does too, which is where switching
            // happens. Twin of the Kotlin `selectProvider`.
            errorText = nil
            keyRejected = false
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default, until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    @Published var customAuthHeader: CustomAIAuthHeader {
        didSet { UserDefaults.standard.set(customAuthHeader.rawValue, forKey: AIProvider.customAuthHeaderKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }

    /// K11: THIRD opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. OFF by default and gated behind `dataConsent` too. Only active when the provider is
    /// Gemini (the only provider with multimodal support in the app). When on, the Coach composer
    /// shows an "Attach chart" toggle; the rendered chart is sent as inline_data to Gemini.
    @Published var multimodalChartEnabled: Bool {
        didSet { UserDefaults.standard.set(multimodalChartEnabled, forKey: Self.multimodalChartKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    private static let multimodalChartKey = "ai.multimodalChartEnabled"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    sleep duration and its deep/REM/light breakdown, sleep efficiency, HRV, resting heart rate) and \
    recent workouts. Charge is the daily recovery/readiness score, effort is the daily cardiovascular \
    load score, and rest is the nightly sleep-quality score. A dash in the data means that value was \
    NOT MEASURED that day — say so rather than treating it as a zero. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67-100 = green light to build/push, higher effort is fine; \
    34-66 = maintain, quality over volume, keep it controlled; 0-33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating - like a coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor - never diagnose; suggest a professional for genuine health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans, ### headings only when structure genuinely helps, and a \
    small table only for a week-ahead plan. No code blocks.

    LOGGING FOOD AND WEIGHT. When food context appears above, the user logs by TELLING YOU, and you are \
    the main way they do it. Take the work off them: read what they ate, work out the macros, and hand back \
    something to confirm. End the reply with one action block and nothing after it:
    {"noop_food_action": {"actions": [ … ]}}
    Each entry is one of:
    {"action": "log",    "itemId": "<id from SAVED FOODS or current EATEN block>", "portion": 1, "day": "today"}
    {"action": "create", "name": "...", "servingLabel": "...", "kcal": 0, "protein": 0, "carbs": 0, \
    "fat": 0, "fiber": 0, "portion": 1, "day": "today"}
    {"action": "save",   "name": "...", "servingLabel": "...", "kcal": 0, "protein": 0, "carbs": 0, "fat": 0}
    {"action": "edit",   "itemId": "<id>", "kcal": 0, "protein": 0, "carbs": 0, "fat": 0}
    {"action": "weight", "kg": 72.4, "day": "today"}
    {"action": "cook",   "name": "...", "recipeId": "<optional id from SAVED FOODS>", "kcal": 0, \
    "protein": 0, "carbs": 0, "fat": 0, "note": "what was different this time", "portion": 0.6, "day": "today"}
    {"action": "log_batch",   "batchId": "<key from OPEN COOKS>", "portion": 0.4}
    {"action": "close_batch", "batchId": "<key from OPEN COOKS>"}

    COOKING A DISH, AS OPPOSED TO EATING A FOOD. When they have MADE something in a quantity they will eat \
    over more than one sitting — a pot, a tray, a batch — use `cook`, not `create`. Its macros are the \
    WHOLE thing, and `portion` is the FRACTION of it eaten now: 0.6 means they ate 60% of what they made. \
    This is what makes the leftovers findable later; a `create` logs one meal and leaves the rest of the \
    pot with no record at all. `portion` may be 0 — "I made a curry, haven't eaten it yet" is a real thing \
    to say. A single plated meal they ate all of is NOT a cook; that is `create`.
    `recipeId` points at a saved recipe when this is a making OF one. The recipe itself never changes: if \
    this cook differed, put the difference in `note` and let the macros reflect it. That is the point — a \
    recipe is a template, and a cook that used 400 g of chicken instead of 500 g is still that recipe.
    OPEN COOKS above lists what is still in the fridge, with what is left of each. Use `log_batch` to eat \
    more of one. For "I finished it" / "I had the rest", send "portion": null — the app reads the actual \
    remainder at the moment they confirm, which is more accurate than any fraction you could work out. Use \
    `close_batch` only when they say the rest was thrown away.

    Keys in EATEN can also be used with `log` to repeat a historical food, including one never saved. \
    Use ONLY keys from the CURRENT context; history keys can change as foods are added. Historical \
    macros describe the stated portion, not an arbitrary weight: scale from that portion, or use `create` \
    when the ingredients or quantity have changed. EATEN entries marked "from cook" must use \
    `log_batch` with the key from OPEN COOKS, so their leftovers are reduced. \
    Only SAVED FOODS can be edited with `edit`. \
    A proposal is not logged until the user confirms its card. Do not claim it has already been saved.

    WHAT YOU CAN SEE about their diet, when those blocks are present above: their saved foods, their \
    recipes and what each is made of, EVERYTHING THEY HAVE EATEN IN THE LAST SEVEN DAYS (each food listed \
    once, with the occurrences referencing it by key), what is still in the fridge from past cooks, where \
    the day stands against their budget, their full macro targets, and their weight trend. Use it. Refer \
    to meals they have already logged rather than asking what they have had, do not propose logging \
    something that is already there, and answer "am I losing weight" from the trend line — including its \
    caveat: if that range includes zero, say it cannot be told from no change yet rather than calling it a \
    loss. Because you can see a WEEK, you can answer "what did I have on Tuesday" and "how much karahi is \
    left" directly — do not ask them to remind you of something that is listed above.

    ESTIMATE THE MACROS YOURSELF. You know roughly what food contains — use that. "Two scrambled eggs on \
    sourdough", "a flat white", "chicken katsu curry from Wasabi" are all things you can price to within \
    the accuracy this app needs, and the user came to you precisely so they do not have to look it up. \
    Never tell them to check another app, a website, or a database; there is no food database here and \
    sending them away is a dead end. Give your best figures, say in one short clause how confident you are \
    ("packet figures", "standard recipe", "rough — restaurant portions vary"), and let them correct you. \
    They see every number on a card before anything is saved, so a wrong estimate costs one tap.
    Do ask when the AMBIGUITY IS ABOUT WHICH FOOD, not about its macros: if "an Oikos" matches two saved \
    foods, name both and ask which, and emit no action that turn. Guessing the wrong food logs the wrong \
    meal; guessing its calories slightly wrong is what this feature expects. Also ask when a portion is \
    genuinely unguessable in a way that changes the answer a lot ("a bowl of pasta" could be 300 or 900) — \
    offer your assumption rather than a blank question: "I'll call it a large bowl, ~700, say if it was \
    smaller."
    Rules:
    • SEVERAL FOODS IN ONE REPLY. "Eggs, toast and a coffee" is three entries in one actions array, not \
    three conversations. Up to six. But see the one-dish rule below: separate ITEMS, not the parts of one.
    • ONLY WHAT THEY JUST TOLD YOU. Emit actions for the message you are replying to and nothing else. Do \
    NOT re-emit an action from an earlier turn — if they logged a banana this morning and now mention an \
    apple, the reply carries the apple alone. The EATEN block above already shows you what is logged; \
    repeating it tries to log their breakfast twice.
    • `log` with an id from SAVED FOODS whenever the food is already there — prefer it over `create`, and \
    if the list says some foods were not shown, ask before assuming something is new.
    • `create` logs a food. `save` only adds it to their library and logs NOTHING: use it when they ask to \
    save something for later, or want to log it against a day themselves.
    • THE DAY ROLLS OVER AT SLEEP, NOT MIDNIGHT. If they are still up at 00:30 and eat something, "today" \
    already means the day they have been awake for — the app works that out. So do not ask which day they \
    want it on, and do not reach for "yesterday" just because the clock has passed midnight. Only use \
    `yesterday` when they are talking about a day they have since slept through.
    • `day` is "today" (the default), "yesterday", or "YYYY-MM-DD". Use it when they say when they ate. \
    Never invent a date from a vague phrase — if they say "a few days ago", ask which day.
    • `meal` is "breakfast", "lunch", "dinner" or "snack". NEVER ASK which meal something was — just omit \
    the field and the app works it out from the time. Set it only when they volunteer it ("for lunch I \
    had…") or when they are logging a PAST day, which has no usable time to infer from. A question about \
    which meal an apple was is a question that costs more than the answer is worth.
    • ONE DISH IS ONE ENTRY. When they describe a single dish by its parts — "a katsu curry with rice, \
    chicken, sauce and salad" — that is ONE `create` whose macros are the whole plate, named after the \
    dish. Four entries for four components is wrong: they ate one thing, and it makes their log unreadable \
    and their recent-foods list useless. Only emit separate entries for things eaten SEPARATELY — a main \
    and a drink and a pudding are three.
    • `edit` corrects a saved food's numbers. Never `edit` a food marked recipe.
    • Macros are PER SERVING; `portion` is how many servings. Your kcal must agree with your own macros \
    (4 kcal/g protein and carbs, 9 kcal/g fat) within about 10%, or the entry is discarded — so do the \
    arithmetic rather than stating a remembered calorie count beside unrelated macros.
    • COACH THE DIET, not just the logging. You can see their budget, what is left, and their protein \
    target. Say something useful about it in a line or two — whether that fits what is left, whether \
    protein is short with one meal to go, what would make the rest of the day work. Keep it brief and \
    specific to the numbers in front of you, and do not moralise about food.
    • Say in plain words what you are proposing. The user sees your text and a confirmation card, never the \
    block itself, so do not mention it, the ids, or JSON. Nothing is saved until they confirm — so never \
    say you HAVE logged anything, only that it is ready.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSystemPrompt
    }

    /// True when a CUSTOM prompt is stored that does not teach the food-logging protocol.
    ///
    /// The protocol lives in `defaultSystemPrompt`, and a stored override replaces that wholesale — so a
    /// user who edited their prompt before this feature existed keeps a coach that will discuss food
    /// cheerfully and never once propose logging any. The failure is completely silent from the outside:
    /// the coach answers, the answer is sensible, and no card ever appears.
    ///
    /// Surfaced so the settings screen can say so, rather than leaving it to be deduced. Detected by the
    /// sentinel rather than by comparing against the default, because a prompt that has been edited AND
    /// carries the protocol is perfectly fine and must not be nagged about.
    var customPromptMissesFoodProtocol: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return false }
        return !stored.contains(FoodActionParse.sentinel)
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// Contextual suggestion chips for the composer, derived from today's bands via `CoachSuggestions`.
    /// Reads only on-device `repo.days`; pure, byte-identical to the Android twin. Returns the stable
    /// generic fallback when there is no usable data for today.
    var suggestions: [String] { CoachSuggestions.suggestions(for: repo.days.last, recent: repo.days) }

    /// K7: Follow-up suggestion chips shown after each assistant reply. These are generic
    /// conversational follow-ups (not data-derived) so the user can dig deeper without typing.
    /// Byte-identical to the Android twin's `followUpSuggestions`.
    static let followUpSuggestions: [String] = [
        "Tell me more about that",
        "What should I do next?",
        "How does today compare to this week?",
        "Give me a specific action plan",
    ]

    /// K12: Rough token estimate for the next send, based on the current draft + context size.
    /// Uses the standard ~4 chars/token heuristic. This is an estimate only — actual token counts
    /// vary by tokenizer. Returns nil when the engine isn't configured (no context to estimate).
    func estimatedTokens(forDraft draft: String) -> Int? {
        guard isConfigured else { return nil }
        // Estimate the context size: system prompt + data context (rough — we don't build the
        // full context here to avoid a DB read on every keystroke). Use the last known context
        // size or a reasonable default.
        let systemPromptTokens = systemPrompt.count / 4
        // The data context is typically ~2000-4000 chars depending on the user's data.
        // Use a conservative estimate of 3000 chars (750 tokens) when consent is on.
        let contextTokens = dataConsent ? 750 : 50
        // History tokens: sum of all message texts in the windowed history.
        let historyTokens = windowedMessages().reduce(0) { $0 + $1.text.count / 4 }
        let draftTokens = draft.count / 4
        return systemPromptTokens + contextTokens + historyTokens + draftTokens
    }

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    /// A session with timeouts a REASONING model can live inside.
    ///
    /// `URLSession.shared` allows 60 s, and that is what was killing gpt-5: a reasoning model routinely
    /// sends nothing at all for longer than a minute while it thinks, and for a streamed response the
    /// request timeout measures the gap BETWEEN arrivals — so the connection died before the first token.
    /// The user saw "thinking" forever and then a timeout, five times over.
    ///
    /// Generous rather than unbounded: a request that has produced nothing in three minutes is stuck, and
    /// the resource ceiling stops a wedged stream holding on for the whole session.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    init(repo: Repository, session: URLSession? = nil) {
        self.repo = repo
        self.session = session ?? AICoachEngine.makeSession()

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customAuthHeader = AIProvider.customAuthHeader
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
        self.multimodalChartEnabled = UserDefaults.standard.bool(forKey: Self.multimodalChartKey)
    }

    // MARK: Key management

    /// True when a key is present in the Keychain.
    var hasKey: Bool { AIKeyStore.read() != nil }

    /// True once the coach can actually send: a stored key for the cloud providers, or, for the
    /// Custom (local) provider, a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`.
    private var resolvedKey: String? {
        if let k = AIKeyStore.read() {
            // Only send the stored key to the provider it was SAVED for, never Bearer one provider's
            // key (e.g. a cloud OpenAI/Anthropic secret) to another provider's endpoint, above all the
            // arbitrary user-typed Custom URL. A legacy key with no recorded owner is assumed to belong
            // to a cloud provider, so it is never auto-sent to Custom.
            let owner = AIKeyStore.ownerProvider
            if owner == provider.rawValue { return k }
            if owner == nil && provider != .custom { return k }
        }
        return provider == .custom ? "" : nil
    }

    /// Commit the Custom (local) provider once the user has entered a server URL. Optionally stores a
    /// key first if they pasted one. Pulls the server's live model list so the picker isn't empty.
    func connectCustom() {
        let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        errorText = nil
        customConnected = true
        // Pull the server's model list; if the user hasn't picked one yet, default to the first.
        Task {
            await refreshModels()
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = availableModels.first {
                model = first
            }
        }
    }

    /// Disconnect entirely: forget any stored key and un-commit the Custom provider. The base URL is
    /// kept so reconnecting pre-fills it.
    func disconnect() {
        AIKeyStore.clear()
        customConnected = false
        // Retire the transcript with the connection. Kotlin has done this since the method existed
        // (CoachViewModel.disconnect) and this side never did, so returning to the setup screen on Apple
        // left the whole conversation sitting behind it — including whatever the user had told a coach
        // they were in the middle of disconnecting from.
        messages = []
        // The error belongs to the connection being retired, so it goes with it. Kotlin has cleared it
        // here since the method existed and this side never did: harmless while only the chat rendered
        // an error, and a visible defect the moment the setup card does too, because the card this
        // returns to would open carrying "That API key was rejected" above an empty key field, reading
        // as a verdict on the key about to be typed.
        errorText = nil
        keyRejected = false
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error. If the Keychain write fails the
    /// key is NOT saved, so surface that to the UI instead of silently proceeding (#872).
    func setKey(_ key: String) {
        guard AIKeyStore.save(key, owner: provider.rawValue) else {
            errorText = AICoachError.keySaveFailed.errorDescription
            objectWillChange.send()
            return
        }
        errorText = nil
        // A stored key is no longer the rejected one. Deliberately leaves the transcript alone:
        // correcting a mistyped key is not a reason to lose the conversation, which is what routing
        // this through `disconnect` used to cost. Twin of the Kotlin `saveKey`.
        keyRejected = false
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET
        // egresses to the provider the MOMENT a key is saved (IP + request timing + key-validity) — before
        // any send, in an app that is zero-network by default. The picker shows the curated models; the LIVE
        // list is pulled only when the user taps Refresh (an explicit action that is its own consent) or
        // sends. Local Custom servers still refresh on Connect.
    }

    /// Forget the stored key.
    func clearKey() {
        AIKeyStore.clear()
        // Same reasoning as `disconnect`: clearing the key returns the user to the setup screen, and
        // Kotlin empties the transcript when it does. Leaving it meant a "clear my key" on Apple removed
        // the credential and kept the conversation.
        messages = []
        // The error belongs to the connection being retired, so it goes with it. Kotlin has cleared it
        // here since the method existed and this side never did: harmless while only the chat rendered
        // an error, and a visible defect the moment the setup card does too, because the card this
        // returns to would open carrying "That API key was rejected" above an empty key field, reading
        // as a verdict on the key about to be typed.
        errorText = nil
        keyRejected = false
        objectWillChange.send()
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Test seam (DEBUG only): lets a test stand in for the live `fetchModels` network call so it can
    /// control timing and which provider's ids come back. Production never sets this, so the real path
    /// below is byte-identical in release builds.
    #if DEBUG
    var fetchModelsOverride: ((_ provider: AIProvider, _ key: String) async throws -> [String])?
    #endif

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    /// When the live catalogue was last pulled for `provider`, keyed per provider so switching does
    /// not hide one provider's stale list behind another's refresh. Kotlin twin:
    /// `NoopPrefs.coachModelsRefreshedAt`.
    static func modelsRefreshedKey(_ provider: AIProvider) -> String {
        "ai.modelsRefreshed.\(provider.rawValue)"
    }

    /// How long a pulled catalogue is trusted. Kotlin twin: `MODEL_REFRESH_INTERVAL_MS`.
    static let modelRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a catalogue last pulled at `last` is due another pull at `now`.
    ///
    /// Split out and `static` so the rule can be pinned without an engine: it decides how often the app
    /// talks to a provider unasked. A never-pulled catalogue (0) is stale, so the first visit fetches. A
    /// clock moved BACKWARDS gives a negative age and reads as fresh, keeping the cached list rather
    /// than refetching every visit until the clock catches up. Kotlin twin:
    /// `CoachViewModel.isCatalogueStale`.
    static func isCatalogueStale(last: TimeInterval, now: TimeInterval) -> Bool {
        now - last >= modelRefreshInterval
    }

    /// Pull the live catalogue at most once a week, so the picker offers what the provider sells today
    /// without this app shipping a build for every model release.
    ///
    /// Quiet about FAILURE: it passes `silent`, so `refreshModels` leaves the error surface untouched
    /// in both directions rather than this restoring it afterwards. Restoring would have raced — there
    /// is no re-entrancy guard here, so a manual Refresh tapped during the await would have had its
    /// result stomped by a stale snapshot on resume. Not touching the state cannot race with anything.
    ///
    /// Requires a stored key, so it cannot fire during first-run setup where there is nothing to
    /// authenticate with. Custom is excluded: `connectCustom()` already pulls its list, and its server
    /// is the user's own machine rather than a vendor catalogue.
    ///
    /// Only the LIST moves. The selected model is never changed underneath the user. Kotlin twin:
    /// `CoachViewModel.refreshModelsIfStale`.
    func refreshModelsIfStale() async {
        guard provider != .custom, hasKey else { return }
        let last = UserDefaults.standard.double(forKey: Self.modelsRefreshedKey(provider))
        guard Self.isCatalogueStale(last: last, now: Date().timeIntervalSince1970) else { return }
        await refreshModels(silent: true)
    }

    /// `silent` leaves the error surface entirely alone, in both directions: an automatic refresh must
    /// neither wipe a message the user is still reading nor raise one they never asked for. Kotlin twin:
    /// the `silent` parameter on `CoachViewModel.refreshModels`.
    func refreshModels(silent: Bool = false) async {
        guard let key = resolvedKey else {
            if !silent { errorText = AICoachError.noKey.errorDescription }
            return
        }
        if !silent { errorText = nil }

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                if !silent { errorText = AICoachError.decode.errorDescription }
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
            // Stamp only on a SUCCESSFUL pull, so a provider that is down does not buy itself a week
            // of silence from `refreshModelsIfStale()`.
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: Self.modelsRefreshedKey(capturedProvider))
        } catch let e as AICoachError {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider, !silent else { return }
            // Typed first, because this used to report EVERY failure as a network problem, including a
            // key the provider had just turned away. Refresh is one of the two places a wrong key shows
            // itself, and it was the one that blamed the wrong thing: the wearer read "Network problem"
            // and went looking at their connection. It now says what happened and, for a rejection,
            // opens the field to fix it.
            errorText = e.errorDescription
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
            return
        } catch {
            guard provider == capturedProvider, !silent else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
            return
        }
    }

    // MARK: Sending

    /// Hard rolling cap on the STORED transcript. The network payload is separately windowed by
    /// `windowedMessages()` (`maxHistoryMessages`); this bounds the in-memory `messages` array — and the
    /// SwiftUI transcript rendered from it — so a long-lived session can't grow it without bound. `coach`
    /// is a single app-lifetime instance on `AppModel`, so before this an active chat grew `messages`
    /// until the process was killed: the "gets laggy the longer the app runs, reopening fixes it, feels
    /// like RAM" report. Cap >> the wire window, so it never changes what's sent. (parity with Android)
    private static let maxStoredMessages = 40
    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxStoredMessages {
            messages.removeFirst(messages.count - Self.maxStoredMessages)
        }
    }

    // MARK: - K2: persisted conversation history

    /// Guards `loadPersistedMessagesIfNeeded()` so it only ever runs once per app launch, even if the
    /// Coach screen's `.task` re-fires (e.g. a tab re-select).
    private var didLoadPersistedMessages = false

    /// Load the conversation persisted by a PRIOR launch (PRD-K2), so relaunching doesn't lose it.
    /// Called from the Coach screen's `.task` (mirroring `startBriefIfNeeded`) rather than `init`,
    /// which is synchronous and runs for every screen the app builds, not just Coach. Best-effort: a
    /// store failure just leaves the transcript empty, matching pre-K2 behaviour — never crashes.
    func loadPersistedMessagesIfNeeded(now: Date = Date()) async {
        guard !didLoadPersistedMessages else { return }
        didLoadPersistedMessages = true
        guard messages.isEmpty, let store = await repo.storeHandle() else { return }
        guard let rows = try? await store.coachMessages(), !rows.isEmpty else { return }
        let newest = rows.map(\.createdAt).max()
        guard !CoachConversationBoundary.shouldRetire(
            lastMessage: newest, now: Int(now.timeIntervalSince1970),
            sleepWindows: await repo.coachSleepWindows(now: now)) else { return }
        messages = rows
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { ChatMessage(id: UUID(uuidString: $0.id) ?? UUID(),
                                role: ChatMessage.Role(rawValue: $0.role) ?? .user,
                                text: $0.text, sentAt: $0.createdAt) }
    }

    /// Replace the ENTIRE persisted conversation with the current in-memory `messages`. Called once
    /// per completed send/brief (not per streamed chunk) so a streamed reply's several in-place text
    /// mutations don't hammer the store. Fire-and-forget; a store failure never blocks the UI — the
    /// in-memory transcript (what the user sees) is unaffected either way.
    private func persistMessages() {
        let snapshot = messages
        let providerId = provider.rawValue
        Task {
            guard let store = await repo.storeHandle() else { return }
            let rows = snapshot.enumerated().map { index, m in
                // `m.sentAt`, NOT `Date()`. Re-stamping on every save re-dated the whole transcript to
                // the moment of the latest turn, which both lost the history and made the chat's time
                // dividers claim every message arrived at once.
                CoachMessageRow(id: m.id.uuidString, role: m.role.rawValue, text: m.text,
                                 provider: providerId, createdAt: m.sentAt,
                                 orderIndex: index)
            }
            try? await store.replaceCoachMessages(rows)
        }
    }

    /// The Coach toolbar's "Clear conversation" action: wipes both the in-memory transcript and the
    /// persisted table. Fire-and-forget on the store side; the in-memory clear is immediate.
    func clearConversation() {
        messages = []
        droppedSummary = nil      // K13: reset the summary cache on clear
        droppedSummaryKey = []
        Task { try? await repo.storeHandle()?.clearCoachMessages() }
    }

    /// K5: surface a brief generated by the SCHEDULED morning-brief notification as the first Coach
    /// message, with no network call — called once when the app opens via a tap on that notification.
    /// No-op if a conversation already exists, so it never duplicates into an active chat.
    func surfaceScheduledBrief(_ text: String) {
        guard messages.isEmpty else { return }
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        persistMessages()
    }

    /// Recheck on opening, foregrounding, sync, and send: sleep may arrive after the first screen load.
    func retireStaleConversationIfNeeded(now: Date = Date()) async {
        guard !sending, let newest = messages.map(\.sentAt).max() else { return }
        let windows = await repo.coachSleepWindows(now: now)
        // A new turn or a clear during the read must not be erased by an older decision.
        guard !sending, messages.map(\.sentAt).max() == newest,
              CoachConversationBoundary.shouldRetire(lastMessage: newest,
                  now: Int(now.timeIntervalSince1970), sleepWindows: windows) else { return }
        messages = []
        droppedSummary = nil
        droppedSummaryKey = []
    }

    /// K5: append an explicitly-generated brief (the Coach settings "Generate now" button) as a new
    /// assistant message, unconditionally — unlike `surfaceScheduledBrief`, this always appends so a
    /// mid-conversation tap still shows the fresh brief.
    func appendGeneratedBrief(_ text: String) async {
        await retireStaleConversationIfNeeded()
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        persistMessages()
    }

    /// K11: An optional chart image (base64-encoded PNG) to send with the next user message.
    /// Set by the composer's "Attach chart" toggle when multimodal is enabled and the provider
    /// is Gemini. Consumed (cleared) on the next send. nil when no image is attached.
    @Published var pendingChartImage: String?

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        // The master switch, checked at the EGRESS rather than only on the routes in. Every way into Coach
        // is gated, but "gated everywhere I thought of" is what #2254 got wrong once: a revoked consent
        // survived in memory because the conversation never re-read it. A wearer can be STANDING on this
        // screen when the switch goes off, and that path passes no tab. Refusing here makes "the AI is off"
        // true however the screen was reached.
        guard CoachBriefScheduler.coachMasterEnabled else { return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        // A transcript from before the latest night is retired before the new turn is appended (#1542,
        // originally midnight-based). `messages` outlives a night — the engine is held for the app's
        // lifetime — so without this the coach answers TODAY's question inside YESTERDAY's
        // conversation. The DATA was never stale: buildFullContext() re-reads on every send. It is the
        // assistant's own earlier turns stating yesterday's figures, and the model staying consistent
        // with them, which reads as "the coach only talks about my imported data" after a night of
        // fresh strap data.
        //
        // Placed AFTER the guards on purpose: a send that never happens must not wipe a transcript.
        await retireStaleConversationIfNeeded()

        errorText = nil
        let userTurn = ChatMessage(role: .user, text: trimmed)
        let userId = userTurn.id
        appendMessage(userTurn)
        sending = true
        // K2: persist once the turn is fully settled (success, mid-stream error, or empty-stream
        // removal) — not per streamed chunk, so a long reply doesn't hammer the store.
        defer { sending = false; persistMessages() }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let snapshot = dataConsent ? await buildFullContextSnapshot() : (text: noConsentNote, references: [:])
        let context = snapshot.text
        let foodReferences = snapshot.references
        // K13: if the conversation overflows the sliding window, summarize the dropped middle so
        // the model retains context continuity. Best-effort; failure degrades to the old gap.
        await summarizeDroppedMiddleIfNeeded(key: key)
        var wire = wireMessages(context: context)

        // K11: If a chart image is pending and the provider is Gemini, attach it to the last
        // user turn as inline_data. Non-Gemini providers can't accept images, so the image is
        // silently dropped (the text question still goes through). Cleared after consumption.
        let imageBase64 = pendingChartImage
        pendingChartImage = nil

        // K1: Stream the reply. Append a placeholder assistant message, then mutate its text as
        // chunks arrive by replacing the last element in `messages`. The transcript re-renders on
        // each update (SwiftUI binds to `messages`). On error mid-stream, keep the partial text and
        // append a "(stream interrupted)" marker — never a crash.
        let placeholder = ChatMessage(role: .assistant, text: "")
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire, inlineImage: imageBase64) { delta in
                accumulated += delta
                // Replace the last message's text with the accumulated stream so far. Routed through
                // `displayText` so a proposal block is hidden WHILE IT ARRIVES — otherwise the user
                // watches raw JSON type itself across the screen at the exact moment the feature works.
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        id: placeholder.id, role: .assistant,
                        text: FoodActionParse.displayText(accumulated)
                    )
                }
            }
            // Finalize: strip any proposal block, trim, and resolve the action against the library.
            //
            // The reply can be ALL block and no prose (a terse model that just emits the action), which
            // would otherwise render as an empty bubble above the card. `fallbackProposalNote` covers
            // that case so the turn always says something.
            let proposals = await resolveProposals(in: accumulated, recentFoods: foodReferences)
            let clean = FoodActionParse.strippingAction(from: accumulated)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                let text: String
                if !clean.isEmpty { text = clean }
                else if !proposals.isEmpty { text = String(localized: "Here's what I've got:") }
                else {
                    // "(no reply)" said nothing about WHY, and on a reasoning model there is a specific
                    // likely cause worth naming: the token cap covers reasoning as well as the answer, so a
                    // model that thinks too hard returns nothing at all. Marked as a failure so the retry
                    // affordance appears — re-asking is the actual remedy, and the user had been
                    // copy-pasting instead.
                    text = AIModelParams.needsModernParams(model: model)
                        ? String(localized: "The model used its whole budget thinking and sent no answer. Send again — it usually succeeds on a second try.")
                        : String(localized: "The model returned an empty reply. Send again.")
                    markFailed(userMessageId: userId,
                               reason: String(localized: "Empty reply from \(model)."))
                }
                messages[lastIdx] = ChatMessage(id: placeholder.id, role: .assistant,
                                                text: text, proposals: proposals)
            }
        } catch let e as AICoachError {
            // Mid-stream error: keep the partial text + an interrupted marker (PRD K1 acceptance).
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                // No text received at all — remove the empty placeholder.
                messages.remove(at: lastIdx)
            }
            errorText = e.errorDescription
            // Marked on the USER's turn, which is what lets the UI offer a retry instead of leaving the
            // user to copy their own text out and paste it back in.
            markFailed(userMessageId: userId, reason: e.errorDescription)
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages.remove(at: lastIdx)
            }
            let described = AICoachError.network(error.localizedDescription).errorDescription
            errorText = described
            markFailed(userMessageId: userId, reason: described)
            keyRejected = false
        }
    }

    /// Flag a user turn as unsent, by id.
    private func markFailed(userMessageId: UUID, reason: String?) {
        guard let idx = messages.firstIndex(where: { $0.id == userMessageId }) else { return }
        messages[idx].failure = reason ?? String(localized: "Couldn't send.")
    }

    /// Re-send a turn that failed, without adding a second copy of it.
    ///
    /// THE POINT: retrying by retyping appended ANOTHER user message, and the engine sends the whole
    /// running history — so the five identical turns in one exported transcript were also five growing
    /// requests, each slower than the last. This drops everything from the failed turn onwards and replays
    /// it, so the history stays the length it was.
    ///
    /// Anything after the failed turn is discarded deliberately: a reply to a later message cannot be
    /// correct when an earlier one never arrived, and leaving it would make the transcript claim a
    /// conversation that did not happen.
    func retry(messageId: UUID) async {
        guard !sending,
              let idx = messages.firstIndex(where: { $0.id == messageId }),
              messages[idx].role == .user else { return }
        let text = messages[idx].text
        messages.removeSubrange(idx...)
        persistMessages()
        await send(text)
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    /// K1: streams the brief the same way `send` does.
    func startBriefIfNeeded() async {
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false; persistMessages() }

        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]

        let prefix = "Today's brief\n\n"
        let placeholder = ChatMessage(role: .assistant, text: prefix)
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire,
                                     overridingSystemPrompt: Self.briefPrompt) { delta in
                accumulated += delta
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        // Same hide-while-streaming treatment the chat path gets, so a block the model
                        // emits anyway never types itself out in front of the user.
                        id: placeholder.id, role: .assistant,
                        text: prefix + FoodActionParse.displayText(accumulated)
                    )
                }
            }
            let clean = FoodActionParse.strippingAction(from: accumulated)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(id: placeholder.id, role: .assistant, text: prefix + clean)
            }
        } catch let e as AICoachError {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = e.errorDescription
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// K5: The brief instruction shared by the interactive `startBriefIfNeeded()` (streamed into the
    /// chat) and the headless `generateBrief()` below (used by the scheduled morning-brief notification).
    /// Kept in one place so the two paths never drift.
    /// What the brief asks for.
    ///
    /// REWRITTEN TO BE ACTUALLY BRIEF. The old version asked for three parts including "exactly what
    /// training to do today and what to avoid" and "one specific thing to improve my charge", and got
    /// precisely that: a prescribed six-exercise session and a wind-down routine, every morning, unasked.
    /// A brief that has to be read is not a brief — and the training plan was the least wanted part,
    /// because it is advice nobody requested about a session that may not be happening.
    ///
    /// So: what the numbers say, what it means for today's effort, and nothing else. Anything more is a
    /// question the user can ask, and asking is one tap away.
    private static let briefInstruction = """
    Give me today's brief in at most THREE SHORT LINES, under 45 words total.
    Line 1: readiness — the charge number and whether it is high, normal or low for me.
    Line 2: what that means for effort today, in a clause. Not a session plan, not a list of exercises.
    Line 3: ONLY if something in the data genuinely stands out (a bad night, a big effort debt, a trend) —
    otherwise omit it entirely.
    No headings, no numbered parts, no bullet lists, no sign-off. If a line is not worth reading, leave it
    out. I will ask if I want more.
    """

    /// The brief's persona, deliberately NOT the full coach prompt.
    ///
    /// The coach prompt carries the food-logging protocol, so a brief generated under it emitted an action
    /// block — `{"noop_food_action": {"actions": []}}` appeared verbatim at the end of a user's morning
    /// brief, because the brief path never stripped it. Giving the brief its own prompt removes the reason
    /// for the block to exist rather than only cleaning up after it; the strip is kept as a safety net.
    ///
    /// Same shape as `macroEstimatePrompt`: a narrow persona for a narrow job.
    static let briefPrompt = """
    You are a performance coach writing a one-glance morning brief from the wearer's own wearable data. \
    Charge is the daily recovery/readiness score (0-100), effort is cardiovascular load, rest is sleep \
    quality. A dash means NOT MEASURED — say so rather than treating it as zero.
    BE SHORT. Three lines at most, under 45 words. Cite their actual numbers. No headings, no bullets, no \
    markdown beyond **bold** for a figure, no sign-off, no encouragement padding.
    You are NOT logging food and must NEVER output JSON, an action block, or anything machine-readable. \
    You are not a doctor; do not diagnose.
    """

    /// K5: Generate today's coaching brief WITHOUT touching the visible chat transcript. Used by the
    /// scheduled morning-brief notification (`CoachBriefScheduler`), which can run with no Coach screen
    /// open and must never append to (or duplicate into) `messages`. Non-streaming (a background/BGTask
    /// context has no UI to stream into). Returns nil when not configured/consented, on any network
    /// failure, or when the reply is empty — the caller treats nil as "brief unavailable"; never throws.
    /// The macro-estimation persona. Deliberately NOT the coach prompt — see `callProvider`.
    ///
    /// Asks for bare JSON and for honest uncertainty. The "say what you assumed" line matters: a model
    /// guessing at portion size will otherwise present the guess as fact, and the user needs to see the
    /// assumption to correct it.
    static let macroEstimatePrompt = """
    You estimate the nutrition of a described food. Reply with ONE JSON object and nothing else — no     prose, no markdown fence, no explanation.

    Keys: kcal, protein, carbs, fat, fiber. All numbers, grams for the macros.

    Rules:
    - Make the macros consistent with the calories (protein 4 kcal/g, carbs 4, fat 9). A reply whose     numbers do not add up will be discarded.
    - Estimate for the portion described. If no portion is given, assume one ordinary serving.
    - Do not refuse, and do not ask clarifying questions. An approximate answer is the expected answer.
    """

    /// Ask the user's provider to estimate macros for a plain-text food description.
    ///
    /// Modelled on `generateBrief()`: returns nil rather than throwing, so a provider failure surfaces as
    /// "couldn't estimate" in the sheet instead of an error propagating into a view.
    ///
    /// The gate stack is checked HERE rather than at the button, for the reason #2254 established: the
    /// screen can already be open when the master switch goes off, and that path passes no tab. Refusing
    /// at the egress makes "the AI is off" true however the sheet was reached.
    func estimateMacros(describing text: String) async -> Result<MacroTotals, MacroEstimateParse.Failure>? {
        guard CoachBriefScheduler.coachMasterEnabled else { return nil }
        guard isConfigured, dataConsent, let key = resolvedKey else { return nil }
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }

        // Snapshot the provider before the await: an estimate taking a few seconds while the user changes
        // provider in another tab would otherwise apply a reply from the old one (#873's race).
        let capturedProvider = provider
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, description)]
        guard let reply = try? await callProvider(key: key, messages: wire,
                                                  overridingSystemPrompt: Self.macroEstimatePrompt),
              capturedProvider == provider else { return nil }
        return MacroEstimateParse.macros(fromReply: reply)
    }

    func generateBrief() async -> String? {
        // Same master-switch gate as `send`, because this entry has NO UI at all: it is what the scheduler
        // calls, and a caller that skipped the scheduler's own gate would otherwise reach a provider with
        // the AI switched off.
        guard CoachBriefScheduler.coachMasterEnabled else { return nil }
        guard isConfigured, dataConsent, let key = resolvedKey else { return nil }
        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]
        guard let reply = try? await callProvider(key: key, messages: wire,
                                                  overridingSystemPrompt: Self.briefPrompt)
        else { return nil }
        // Stripped as well as prevented. The persona above tells it not to emit an action block, but a
        // model that does so anyway must not put raw JSON in front of the user — which is exactly what
        // happened when this path had neither guard.
        let clean = FoodActionParse.strippingAction(from: reply)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    func buildFullContext() async -> String {
        (await buildFullContextSnapshot()).text
    }

    /// Keep the text and its history references together across suspension points and concurrent briefs.
    private func buildFullContextSnapshot() async -> (text: String, references: [String: FoodDigestEntry]) {
        var ctx = buildContext()
        ctx += "\n\n" + (await recentWorkoutsBlock())
        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Gated here under `dataConsent` (the caller only reaches buildFullContext()
        // with consent on), so it rides the SAME consent + text-only channel as the HRV/RHR summary, a
        // derived number, never raw R-R egress. Omitted when there aren't enough clean beats yet.
        if let line = await stressIndexLine() { ctx += "\n\n" + line }
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { ctx += "\n\n" + block }
        }
        // The food library and where today stands, so "just had an Oikos" can be answered with a
        // question about WHICH Oikos rather than a guess. Gated on the food-logging feature itself
        // rather than a switch of its own: a user who has not turned food logging on has no library to
        // describe, and a second toggle for a block that would be empty anyway is just a thing to find.
        let food = await foodContextBlock()
        if !food.text.isEmpty { ctx += "\n\n" + food.text }
        return (ctx, food.references)
    }

    /// Parse a reply for a food action and resolve it against the CURRENT library.
    ///
    /// Resolved at finalize time rather than at render time, deliberately: the card must describe the
    /// library as it was when the coach spoke. Resolving lazily in the view would re-resolve on every
    /// redraw, so a food deleted while the card sat on screen would turn a valid proposal into an
    /// "unrecognised food" the user never did anything to deserve.
    ///
    /// nil for the ordinary conversational turn, which is most of them.
    func resolveProposals(in reply: String,
                          recentFoods: [String: FoodDigestEntry]) async -> [FoodProposal] {
        guard case .success(let requests) = FoodActionParse.actions(fromReply: reply) else { return [] }
        let library = await repo.foodLibrary()
        let recipeIds = await repo.recipeItemIds()
        // The user's own recent weight, which is the only thing that can tell a 160 kg measurement from a
        // 160 lb figure stated in the wrong unit. nil on a first weigh-in, which is correct: there is
        // nothing for it to be inconsistent with.
        let lastWeight = await repo.weightHistory(days: 60).last?.kg
        // The diet day, so "I just had an apple" at 00:15 lands on the day being lived rather than opening
        // a fresh budget fifteen minutes old.
        let dietToday = await repo.dietDayKey()
        // The pots still in the fridge, so a `log_batch` handle resolves and "the rest" can be read from
        // the CURRENT remainder rather than from whatever the model assumed when it spoke.
        let cooks = await repo.openCooks()
        // Everything this conversation has already WRITTEN. Models repeat their own previous structured
        // output — mention an apple after logging a banana and the reply carries both — so the check is
        // against what was applied rather than against what was merely proposed. A proposal the user
        // declined is not a duplicate; they may well say it again on purpose.
        let applied = Set(messages
            .flatMap(\.proposals)
            .filter { $0.state == .applied }
            .compactMap(\.dedupeKey))

        return requests.compactMap { request -> FoodProposal? in
            guard let resolved = FoodProposal.resolve(request,
                                                      library: library,
                                                      recipeIds: recipeIds,
                                                      // The same default the Add food sheet uses, so a food
                                                      // created by either route reads identically in the log.
                                                      defaultServingLabel: String(localized: "1 serving"),
                                                      lastKnownWeightKg: lastWeight,
                                                      cooks: cooks,
                                                      recentFoods: recentFoods,
                                                      todayKey: dietToday) else { return nil }
            guard let key = resolved.dedupeKey, applied.contains(key) else { return resolved }
            return FoodProposal(kind: .duplicate(of: resolved.displayName),
                                dayKey: resolved.dayKey, dayLabel: resolved.dayLabel)
        }
    }

    /// Mark a proposal applied (or dismissed) in place, so the card cannot fire twice.
    ///
    /// By message id rather than index: the transcript grows while a card is on screen — a reply can
    /// arrive, or a stale conversation can be retired — and an index captured at render time would by
    /// then point at somebody else's turn.
    func updateProposalState(messageId: UUID, proposalId: UUID, to state: FoodProposal.State) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              let pIdx = messages[idx].proposals.firstIndex(where: { $0.id == proposalId })
        else { return }
        messages[idx].proposals[pIdx].state = state
    }

    /// The saved-food library plus one line on today, formatted by `FoodLibraryDigest`.
    ///
    /// The formatting lives in the pure package so it is CI-covered and twinnable; this is only the
    /// read. Recipes are marked, because a recipe is the one food whose macros the coach must not offer
    /// to edit directly — they come from its ingredients.
    ///
    /// Returns empty text when food logging is off, so the block never says "you have no
    /// saved foods" — an absent statement and a stated absence are different claims, and the second one
    /// invites a model to insist the user has never eaten anything.
    func foodContextBlock() async -> (text: String, references: [String: FoodDigestEntry]) {
        guard UserDefaults.standard.bool(forKey: FoodLogStore.enabledKey) else { return ("", [:]) }

        var blocks: [String] = []
        let library = FoodLibrary.sorted(await repo.foodLibrary())
        let recipeIds = await repo.recipeItemIds()

        // NOT gated on the library being non-empty, which it used to be. A user who only ever quick-adds
        // one-off meals has an empty library and a perfectly full day of logs, and that early return threw
        // away everything below — their whole diet was invisible to the coach.
        if !library.isEmpty {
            blocks.append(FoodLibraryDigest.block(entries: library.map {
                FoodDigestEntry(id: $0.id.uuidString, name: $0.name, servingLabel: $0.servingLabel,
                                macros: $0.macros, isRecipe: recipeIds.contains($0.id))
            }))
        }

        // The recipes' INGREDIENTS. The library block only marks which foods are recipes; without the parts
        // the coach cannot reason about one or suggest a change to it.
        let recipes = await repo.recipes(library: library)
        if !recipes.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
            let lines = FoodLibraryDigest.recipeLines(recipes.map { recipe in
                (name: recipe.item.name,
                 handle: FoodLibraryDigest.handle(for: recipe.item.id.uuidString),
                 parts: recipe.parts.map { part in
                     (name: part.name(in: byId) ?? String(localized: "deleted ingredient"),
                      quantity: part.quantity)
                 })
            })
            if !lines.isEmpty { blocks.append(lines) }
        }

        // WHAT WAS ACTUALLY EATEN TODAY, which was the glaring omission: the coach knew the totals and the
        // library but not what the day consisted of, so it could neither refer to a meal already logged nor
        // avoid proposing it twice.
        // The DIET day, so the block describes the same day a "today" action would write to. Describing the
        // calendar day while writing to the diet day is the two-readouts failure with the coach as victim:
        // it would be told the day is empty and then add to yesterday's total.
        let today = await repo.dietDayKey()
        let entries = await repo.foodEntries(day: today)

        // A WEEK, NOT A DAY. The coach used to be handed today and nothing else, which is why a user who
        // ate 60% of a karahi last night and asked about the leftover got a model that had never heard of
        // it — the entry was on disk the whole time and simply never sent. That was a bug, not a missing
        // feature.
        //
        // Keyed rather than listed: see `FoodWeekDigest`. The saving is that repetition gets cheap, not
        // that the model can skim keys and look up details on demand — there is no lookup inside a
        // request, and every token here is read and billed on every turn.
        let weekStart = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -(FoodWeekDigest.days - 1),
                                  to: Date()) ?? Date())
        let weekEntries = await repo.foodEntriesWithDays(from: weekStart, to: today)
        let todayEpochDay = Repository.epochDay(dayKey: today) ?? Repository.epochDay(Date())
        let digestEntries = weekEntries.map { record in
            let entry = record.entry
            // A backfill's loggedAt is the confirmation time; its stored day is when the food was eaten.
            return WeekEntryDigest(
                daysAgo: todayEpochDay - (Repository.epochDay(dayKey: record.day) ?? todayEpochDay),
                itemId: entry.itemId?.uuidString,
                batchId: entry.batchId?.uuidString,
                name: entry.nameSnapshot,
                portion: entry.portion,
                macros: entry.effectiveMacros,
                meal: entry.mealType?.rawValue)
        }
        let references = FoodWeekDigest.foodReferences(entries: digestEntries)
        blocks.append(FoodWeekDigest.block(entries: digestEntries,
            savedFoodIds: Set(library.map { $0.id.uuidString })))

        // WHAT IS STILL IN THE FRIDGE. Separate from the week above because it answers a different
        // question: the week says what was eaten, this says what can still BE eaten without cooking.
        // Carries the REMAINING macros rather than the whole cook's, since that is the figure a decision
        // gets made against.
        let openCooks = await repo.openCooks()
        if !openCooks.isEmpty {
            blocks.append(FoodWeekDigest.openCooksBlock(openCooks.map { cook in
                OpenCookDigest(
                    batchId: cook.id.uuidString,
                    name: cook.name,
                    note: cook.note,
                    daysAgo: todayEpochDay - (Repository.epochDay(dayKey: cook.cookedOn) ?? todayEpochDay),
                    remainingFraction: cook.remainingFraction,
                    remainingMacros: cook.remainingMacros)
            }))
        }

        // Where the day stands, and the full macro targets rather than protein alone.
        let totals = FoodEntries.total(entries)
        let budget = await repo.bankedBudgetKcal()
        let goal = await repo.currentDietGoal()
        var targets: MacroTargetSet?
        if let rate = goal?.proteinGPerKg, let budget {
            // CURRENT weight, not the goal's start weight, which is what this used before: a goal set eight
            // kilos ago would otherwise keep pricing the protein target at the old mass.
            targets = MacroTargets.targets(budgetKcal: budget, weightKg: profileWeightKg,
                                           proteinGPerKg: rate)
        }
        blocks.append(FoodLibraryDigest.todayLine(consumedKcal: totals.kcal,
                                                  budgetKcal: budget,
                                                  proteinG: totals.protein,
                                                  proteinTargetG: targets?.proteinG))
        if let targets { blocks.append(FoodLibraryDigest.targetsLine(targets)) }

        // The weight trend, with its interval — the other half of whether the diet is working, and absent
        // entirely before, so the coach could not answer "am I losing" at all.
        blocks.append(await weightContextLine())

        return (blocks.filter { !$0.isEmpty }.joined(separator: "\n\n"), references)
    }

    /// The body mass the macro targets are priced at.
    ///
    /// Read from the profile's stored scalar rather than taken from the goal's `startWeightKg`, which is
    /// what this used before: a goal set eight kilos ago would keep pricing the protein target at the old
    /// mass. `logWeight` writes this scalar on every weigh-in, so it is the current figure.
    ///
    /// Falls back to 0, which `MacroTargets.targets` already treats as unusable and answers with zeros
    /// rather than a NaN — so an install with no profile weight gets no targets instead of nonsense ones.
    private var profileWeightKg: Double {
        UserDefaults.standard.double(forKey: "profile.weightKg")
    }

    /// The weight line, assembled from the same fit `WeightView` renders.
    func weightContextLine() async -> String {
        let rows = await repo.weightHistory(days: 120)
        let readings = rows.compactMap { row -> WeightReading? in
            guard let idx = Repository.dayIndex(row.day) else { return nil }
            return WeightReading(dayIndex: idx, kg: row.kg)
        }
        let fit = WeightTrend.fit(readings)
        return FoodLibraryDigest.weightLine(latestKg: rows.last?.kg,
                                            trendKg: WeightTrend.smoothed(readings).last?.kg,
                                            slopeKgPerWeek: fit?.slopeKgPerWeek,
                                            marginKgPerWeek: fit?.weeklyMarginKg,
                                            isDistinguishable: fit?.isDistinguishableFromZero ?? false,
                                            weighInDays: rows.count)
    }

    /// One derived stress line for the coach context: the Baevsky Stress Index over TODAY's R-R, read
    /// via the same device-aware repository R-R union as `StressView`,
    /// then summarised to a single number with `StressIndex.stressIndex(rr:)`. Returns nil when the
    /// store is unavailable or there are too few clean beats (the histogram needs >= 20), so the line is
    /// simply absent, never a fabricated value. Summary-only: the raw R-R never leaves the device.
    func stressIndexLine() async -> String? {
        let cal = Calendar.current
        let from = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        guard let si = StressIndex.stressIndex(rr: rr) else { return nil }
        return Self.stressIndexSummary(si: si)
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index over today's R-R; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controls: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controls[e.question, default: []].insert(e.day) }
        }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, controls: controls,
                                           outcomeByDay: outcomeByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(3)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
        }

        // 2. Lab Book markers roll-up (count + latest of a few, never the full history).
        if let store = await repo.storeHandle() {
            var markerSummaries: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                let byKey = Dictionary(grouping: rows, by: { $0.markerKey })
                for (key, kRows) in byKey {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key)) \(latest.unit)" } ?? latest.valueText ?? "—"
                    markerSummaries.append("\(name) \(value)")
                }
            }
            if !markerSummaries.isEmpty {
                lines.append("")
                lines.append("LAB BOOK (the user's own logged health numbers — not medical advice; do not interpret as clinical findings):")
                lines.append("  " + markerSummaries.prefix(8).joined(separator: ", "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Dispatch to the user's chosen provider client.
    /// `overridingSystemPrompt` lets a non-chat caller supply its own persona.
    ///
    /// Defaulted so every existing caller is untouched. It exists because the coach prompt is wrong for
    /// anything that is not a conversation — it ends with "No code blocks", which actively fights a
    /// request for JSON, and it instructs the model to be a motivating coach citing the wearer's
    /// numbers, which has nothing to do with reading a food label.
    ///
    /// The previous workaround (`summarizeDroppedMiddleIfNeeded`) stuffs its instruction into the USER
    /// turn and leaves the coach persona in the system slot. That is tolerable for a summary and not for
    /// structured output, where the system prompt's formatting rules are the thing being overridden.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)],
                              overridingSystemPrompt: String? = nil) async throws -> String {
        try await provider.client.send(
            key: key,
            model: model,
            systemPrompt: overridingSystemPrompt ?? systemPrompt,
            messages: messages,
            session: session
        )
    }

    /// K1: Dispatch to the user's chosen provider client's streaming method. The default
    /// `AIProviderClient.stream` falls back to `send` + a single delta, so providers without
    /// streaming still work. K11: when an inline image is present, dispatches to
    /// `streamWithImage` instead (Gemini overrides it; others ignore the image).
    /// `overridingSystemPrompt` mirrors `callProvider`'s parameter of the same name, so a narrow persona
    /// works on the streamed path too. Without it the streamed brief had to run under the full coach
    /// prompt — food-logging protocol included — which is why a brief ever emitted an action block.
    private func streamProvider(key: String,
                                messages: [(role: ChatMessage.Role, content: String)],
                                inlineImage: String? = nil,
                                overridingSystemPrompt: String? = nil,
                                onDelta: (String) -> Void) async throws {
        try await provider.client.streamWithImage(
            key: key,
            model: model,
            systemPrompt: overridingSystemPrompt ?? systemPrompt,
            messages: messages,
            inlineImage: inlineImage,
            session: session,
            onDelta: onDelta
        )
    }

    ///
    /// K13: when the middle is dropped, a one-line summary of the dropped turns is prepended to the
    /// first user turn so the model retains context continuity (instead of seeing a gap). The summary
    /// is generated via the same provider, with a short prompt; on failure it degrades to the old
    /// behaviour (no summary, just the windowed set).
    private static let maxHistoryMessages = 10
    /// K13: the cached summary of the dropped middle, regenerated when the dropped set changes.
    private var droppedSummary: String?
    private var droppedSummaryKey: [String] = []

    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        // K13: inject the summary of the dropped middle by prepending it to the first user turn,
        // so the model sees continuity instead of a gap. We don't use a separate system message
        // because the Role enum only has .user/.assistant (providers map those to API roles).
        var windowed = [messages[firstUser]]
        if let summary = droppedSummary {
            let first = windowed[0]
            windowed[0] = ChatMessage(id: first.id, role: first.role, text: "\(summary)\n\n---\n\n\(first.text)")
        }
        windowed.append(contentsOf: messages[recentStart...])
        return windowed
    }

    /// K13: When the conversation overflows the sliding window, summarize the dropped middle turns
    /// into a single system message. Called before each send when the window would drop messages.
    /// Best-effort: on any failure, leaves `droppedSummary` nil (the old gap behaviour).
    private func summarizeDroppedMiddleIfNeeded(key: String) async {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return }
        let recentStart = messages.count - Self.maxHistoryMessages
        guard firstUser < recentStart else { return }

        // The dropped middle is messages[firstUser+1 ..< recentStart]. Cache on its identity so we
        // don't re-summarize the same set on every send.
        let dropped = Array(messages[(firstUser + 1)..<recentStart])
        let keySignature = dropped.map { "\($0.role.rawValue):\($0.text)" }
        guard droppedSummaryKey != keySignature else { return }
        droppedSummaryKey = keySignature

        // Build a compact transcript of the dropped turns for the summarizer.
        let transcript = dropped.map { m in
            "\(m.role == .user ? "User" : "Coach"): \(m.text)"
        }.joined(separator: "\n")

        let summaryPrompt = """
        Summarize the following conversation in 2-3 sentences, preserving the key advice and \
        any specific numbers or recommendations. This summary will be shown to you as context \
        for the ongoing conversation.\n\n\(transcript)
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [
            (.user, "You are a concise summarizer. Summarize the conversation in 2-3 sentences.\n\n\(summaryPrompt)"),
        ]
        if let summary = try? await callProvider(key: key, messages: wire) {
            droppedSummary = "Summary of earlier conversation: \(summary.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        for m in windowedMessages() {
            if m.role == .user && !contextInjected {
                contextInjected = true
                out.append((.user, context + "\n\n---\n\nQuestion: " + m.text))
            } else {
                out.append((m.role, m.text))
            }
        }
        return out
    }

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        guard !days.isEmpty else {
            return """
            USER BIOMETRIC SUMMARY:
            No wearable data is available yet. Acknowledge this and give general, encouraging guidance \
            while inviting the user to sync their device so future advice can reference real numbers.
            """
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        lines.append("")
        lines.append("Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), "
                     + "deep/REM/light(h), eff(%), HRV(ms), RHR(bpm). A dash means NOT MEASURED, not zero:")
        for d in recent {
            lines.append("  " + dayLine(d))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  charge: \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        let bodySystem = UnitSystem(
            rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let distanceSystem = UnitPrefs.resolveDistance(
            system: bodySystem,
            override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM {
                parts.append(UnitFormatter.distanceFromMeters(dist, system: distanceSystem))
            }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    /// `internal`, not private, so `AICoachSleepContextTests` can assert the emitted line directly.
    /// Swift's `buildContext()` takes no arguments (it reads the repo), unlike the Kotlin twin which is
    /// handed the day list — so without this the formatter has no seam and the Swift half of a change
    /// with fifteen Kotlin tests would ship untested.
    func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
        parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        // The stage breakdown and efficiency, which the coach could not see at all: a user asked why it
        // said it had no access to sleep stages, and it was answering honestly — `rest 7.8h` was every
        // word it got about a night. These four sit on the SAME DailyMetric the line already reads, so
        // nothing new is plumbed; they were simply never included. (#124 widened this context once
        // before, for the same reason.)
        //
        // Always emitted, "—" when absent, like every other field here. A night with no staging then
        // says so rather than going quiet, which matters more than line length: the alternative — only
        // appending stages when present — gives the model a schema that changes shape between days and
        // invites it to read a missing field as a zero.
        parts.append("deep " + hoursOrDash(d.deepMin))
        parts.append("REM " + hoursOrDash(d.remMin))
        parts.append("light " + hoursOrDash(d.lightMin))
        parts.append("eff " + efficiencyPercentOrDash(d.efficiency))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
    }

    /// Minutes as "1.4h", or "—" when the night has no value. Matches the `rest` field's format so a
    /// stage total and the total it is part of read on the same scale.
    private func hoursOrDash(_ minutes: Double?) -> String {
        minutes.map { String(format: "%.1fh", $0 / 60) } ?? "—"
    }

    /// Efficiency as a percentage, NORMALISING the stored value first.
    ///
    /// `DailyMetric.efficiency` is not reliably a 0–1 fraction: it "arrives as % on some import paths",
    /// which `SleepView` and `StagesCard` each guard against inline with this same `> 1.5` test. A bare
    /// `* 100` would therefore hand the coach "eff 9400%" for an imported night — and a model given a
    /// nonsense number reasons about it confidently rather than ignoring it.
    ///
    /// 1.5 rather than 1.0 because a genuine fraction can exceed 1.0 only by floating-point noise, while
    /// a genuine percentage is 30–100 and nowhere near the threshold. Android's two copies of this guard
    /// split at 1.0 instead, which is a pre-existing divergence and not this change's to settle.
    func efficiencyPercentOrDash(_ raw: Double?) -> String {
        guard var e = raw, e > 0 else { return "—" }
        if e > 1.5 { e /= 100 }
        guard e > 0, e <= 1 else { return "—" }
        return "\(Int((e * 100).rounded()))%"
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
