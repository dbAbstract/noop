import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - The card that turns a coach proposal into a logged meal
//
// THE TAP IS THE WRITE. The model proposed; nothing has happened yet. This is the one place a
// conversational action reaches the food log, and it is reachable only from a button the user presses —
// see the header of `FoodActionParse` for why that boundary is the entire design rather than a courtesy.
//
// WHAT THE CARD MUST STATE, because a number the user cannot check is a number they have to trust: the
// food's name, what one serving is, the portion, and the macros that will actually be banked. An
// estimate that reads like a label figure is the failure this whole feature could most easily cause.
//
// It is also marked as coach-proposed and carries the same `aiEstimate` provenance the typed-estimate
// path does, so a guessed macro stays identifiable in the log long after the conversation is gone.
struct FoodProposalCard: View {
    let proposal: FoodProposal
    /// The turn this card belongs to — the handle used to mark it applied, since an index would drift as
    /// the transcript grows beneath it.
    let messageId: UUID

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    /// Handed to `applyFoodProposal` so a weigh-in updates the profile's weight scalar too — every calorie
    /// estimate reads it, so a weigh-in that moved the trend but not the profile would leave the budget
    /// pricing an old mass.
    @EnvironmentObject private var profile: ProfileStore

    @State private var working = false
    @State private var failed = false
    @State private var roughGuess: Bool

    init(proposal: FoodProposal, messageId: UUID) {
        self.proposal = proposal
        self.messageId = messageId
        _roughGuess = State(initialValue: proposal.roughGuess)
    }

    private var logsFood: Bool {
        switch proposal.kind {
        case .log, .create, .logBatch: return true
        case .cook(_, _, _, _, let portion): return portion > 0
        default: return false
        }
    }

    var body: some View {
        NoopCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header
                if case .unresolved(let handle) = proposal.kind {
                    unresolvedBody(handle)
                } else if case .implausibleWeight(let kg, let last) = proposal.kind {
                    implausibleWeightBody(kg: kg, last: last)
                } else if case .duplicate(let name) = proposal.kind {
                    duplicateBody(name)
                } else {
                    detail
                    if proposal.state == .pending {
                        if logsFood {
                            Toggle("This is a rough guess", isOn: $roughGuess)
                                .font(StrandFont.subhead)
                                .tint(StrandPalette.accent)
                                .disabled(working)
                            Text(proposal.roughGuess
                                ? String(localized: "Coach suggests this tag. Keep it for unweighed or uncertain portions; you can turn it off.")
                                : String(localized: "Unweighed or unsure of the portion? Tag it so NOOP treats this day's intake as less certain."))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        actions
                    } else {
                        settled
                        if logsFood, proposal.state == .applied, proposal.roughGuess {
                            Text("Rough guess")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var tint: Color {
        switch proposal.kind {
        case .unresolved, .implausibleWeight, .duplicate: return StrandPalette.strain066
        case .edit, .save: return StrandPalette.chargeColor
        default: return StrandPalette.accent
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(overline)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            // A day OTHER than today is stated in the header, not buried: the single most consequential
            // thing about a logging card is which day it moves, and it is invisible otherwise.
            if proposal.targetsAnotherDay(today: Repository.localDayKey(Date())) {
                Text(proposal.dayLabel)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
            }
            Spacer(minLength: 8)
            // Says WHO proposed this. A card that looked like the app's own arithmetic would hide the
            // one fact the user needs to decide how hard to check it.
            Text("Coach proposed")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// A weigh-in far enough from the user's own recent weight to be a unit mix-up rather than a reading.
    ///
    /// No confirm button. 160 kg is a real weight for somebody, so the pure parser cannot refuse it — only
    /// a comparison against THIS user's history can, and storing it would corrupt the one series the entire
    /// weight trend is fitted through.
    @ViewBuilder
    private func implausibleWeightBody(kg: Double, last: Double) -> some View {
        Text("That would be a \(Int(abs(kg - last).rounded())) kg change from your last weigh-in of \(String(format: "%.1f", last)) kg. Nothing has been saved — if you meant pounds, say the figure in kilos, or log it yourself if it really is right.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The coach re-proposed something this conversation already logged.
    ///
    /// No confirm button — tapping would log it twice. Said out loud rather than dropped, because a silent
    /// drop makes the model's repetition invisible AND leaves a genuine second helping looking broken; the
    /// copy therefore says how to log it anyway.
    @ViewBuilder
    private func duplicateBody(_ name: String) -> some View {
        Text("You already logged \(name) and the coach offered it again, so nothing was added. If you really did have another, say so and it will log a second one.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "60% of the cook · 40% left after this".
    ///
    /// States what REMAINS as well as what is eaten, because the remainder is the thing the user will be
    /// asked about tomorrow and a card that showed only the portion would make them work it out.
    private func cookPortionLine(portion: Double, remainingAfter: Double) -> String {
        let eaten = percentText(portion)
        guard remainingAfter > BatchRemainder.finishedEpsilon else {
            return String(localized: "\(eaten) of the cook · finishes it")
        }
        return String(localized: "\(eaten) of the cook · \(percentText(remainingAfter)) left after this")
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    private var icon: String {
        switch proposal.kind {
        case .log: return "plus.circle"
        case .create: return "sparkles"
        case .save: return "tray.and.arrow.down"
        case .edit: return "pencil"
        case .weight: return "scalemass"
        case .duplicate: return "doc.on.doc"
        case .cook: return "flame"
        case .logBatch: return "takeoutbag.and.cup.and.straw"
        case .closeBatch: return "trash"
        case .unresolved, .implausibleWeight: return "questionmark.circle"
        }
    }

    private var overline: String {
        switch proposal.kind {
        case .log: return String(localized: "LOG")
        case .create: return String(localized: "NEW FOOD")
        case .save: return String(localized: "SAVE ONLY")
        case .edit: return String(localized: "CORRECT A FOOD")
        case .weight: return String(localized: "WEIGH-IN")
        case .unresolved: return String(localized: "COULDN'T MATCH")
        case .implausibleWeight: return String(localized: "CHECK THE UNITS")
        case .duplicate: return String(localized: "ALREADY LOGGED")
        case .cook: return String(localized: "COOKED")
        case .logBatch: return String(localized: "LEFTOVERS")
        case .closeBatch: return String(localized: "BINNED")
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func unresolvedBody(_ handle: String) -> some View {
        // No confirm button, deliberately. The model named a food that does not resolve — possibly
        // invented, possibly a prefix two foods share. "Create it anyway" would log macros the user never
        // approved under a name the coach guessed.
        Text("The coach referred to a saved food I couldn't match (\(handle)). Nothing has been logged. Tell it the name again, or add the food yourself.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(proposal.displayName)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            switch proposal.kind {
            case .log(let item, let portion):
                Text(portionLine(servingLabel: item.servingLabel, portion: portion))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            case .create(_, let serving, _, let portion):
                Text(portionLine(servingLabel: serving, portion: portion))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            case .cook(_, let recipe, let macros, let note, let portion):
                // THE WHOLE COOK FIRST, because that is the thing being recorded; the portion is what is
                // being eaten OF it. Stating only the portion would leave the leftover unexplained
                // tomorrow.
                Text("Whole cook: \(macroLine(macros))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let recipe {
                    // THE BASELINE, SIDE BY SIDE. The model computed this cook's totals itself, and a
                    // figure with nothing to compare it against cannot be sanity-checked at a glance.
                    // Shown as the delta it is, so an arithmetic slip reads as one.
                    Text("Your \(recipe.name) recipe: \(macroLine(recipe.macros))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let note, !note.isEmpty {
                    Text("This cook: \(note)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if portion > 0 {
                    Text(cookPortionLine(portion: portion, remainingAfter: 1 - portion))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Nothing logged yet — the leftovers will be here when you eat it.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

            case .logBatch(let cook, let portion):
                let after = BatchRemainder.remainingFraction(
                    loggedPortions: cook.loggedPortions + [portion])
                Text(cookPortionLine(portion: portion, remainingAfter: after))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let note = cook.note, !note.isEmpty {
                    Text("That cook: \(note)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

            case .closeBatch(let cook):
                Text("The remaining \(percentText(cook.remainingFraction)) won't be logged. Nothing already eaten changes.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

            case .edit(let item, _, let macros):
                // Before AND after. A macro correction with no before-figure is impossible to
                // sanity-check, and this card is the only place the user gets to check it.
                Text("Now: \(macroLine(item.macros))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Proposed: \(macroLine(macros))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Only the saved food changes. Days you've already logged keep the numbers they were logged with.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .save(_, let serving, let macros):
                Text("per \(serving.isEmpty ? String(localized: "1 serving") : serving) · \(macroLine(macros))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                // Says plainly that nothing lands on a day, because "save" next to a macro figure reads
                // like logging to anyone not thinking about it.
                Text("Goes into your foods. Nothing is logged — you can add a portion from any day.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .weight:
                Text("Recorded as your weigh-in for \(proposal.dayLabel.lowercased()).")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .unresolved, .implausibleWeight, .duplicate:
                EmptyView()
            }

            // What actually lands on the day — the figure the budget will move by, stated plainly
            // rather than left to be inferred from a portion and a per-serving total.
            if let logged = proposal.loggedMacros {
                Text("Logs \(macroLine(logged))")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, 2)
            }
        }
    }

    private func portionLine(servingLabel: String, portion: Double) -> String {
        let serving = servingLabel.isEmpty ? String(localized: "1 serving") : servingLabel
        if abs(portion - 1) < 0.001 { return String(localized: "1 × \(serving)") }
        let p = portion.rounded() == portion ? String(Int(portion)) : String(format: "%g", portion)
        return "\(p) × \(serving)"
    }

    private func macroLine(_ m: MacroTotals) -> String {
        "\(Int(m.kcal.rounded())) kcal · \(Int(m.protein.rounded()))P \(Int(m.carbs.rounded()))C \(Int(m.fat.rounded()))F"
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: NoopMetrics.space3) {
                switch proposal.kind {
                case .save:
                    NoopButton("Save it", kind: .primary) { apply(save: true) }
                        .disabled(working)
                case .weight:
                    NoopButton("Record it", kind: .primary) { apply(save: false) }
                        .disabled(working)
                case .create:
                    // Log-only FIRST and primary. Most meals are eaten once, so saving every proposed
                    // food would fill the picker with things nobody logs again — the same default the
                    // Add food sheet settled on.
                    NoopButton("Log it", kind: .primary) { apply(save: false) }
                        .disabled(working)
                    NoopButton("Save & log", kind: .secondary) { apply(save: true) }
                        .disabled(working)
                case .edit:
                    NoopButton("Update it", kind: .primary) { apply(save: false) }
                        .disabled(working)
                default:
                    NoopButton("Log it", kind: .primary) { apply(save: false) }
                        .disabled(working)
                }
                NoopButton("No", kind: .secondary) {
                    coach.updateProposalState(messageId: messageId, proposalId: proposal.id,
                                              to: .dismissed)
                }
                .disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            if failed {
                Text("That didn't save. Nothing was logged — try again, or add it from the food log.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the card says once it has been acted on. It stays on screen — the transcript is the record —
    /// but it can no longer write, which is what stops a scroll-back double-tap logging twice.
    @ViewBuilder
    private var settled: some View {
        HStack(spacing: 6) {
            Image(systemName: proposal.state == .applied ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(proposal.state == .applied ? StrandPalette.accent
                                                            : StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text(settledText)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var settledText: String {
        guard proposal.state == .applied else { return String(localized: "Not logged.") }
        switch proposal.kind {
        case .edit: return String(localized: "Saved food updated.")
        case .save: return String(localized: "Saved to your foods.")
        case .weight: return String(localized: "Weigh-in recorded.")
        // Names the DAY once applied, because a card that scrolled back to says only "Logged." leaves the
        // one question worth asking later — logged to when? — unanswerable.
        default: return String(localized: "Logged to \(proposal.dayLabel.lowercased()).")
        }
    }

    private func apply(save: Bool) {
        working = true
        failed = false
        Task {
            // Marked aiEstimate wherever macros came from the model, so a guess stays identifiable in the
            // log long after this conversation has scrolled away.
            var selected = proposal
            selected.roughGuess = roughGuess
            let ok = await repo.applyFoodProposal(selected, saveToLibrary: save, profile: profile)
            working = false
            if ok {
                coach.updateProposalState(messageId: messageId, proposalId: proposal.id, to: .applied, roughGuess: selected.roughGuess)
            } else {
                // Left PENDING on failure. A card that said "Logged." over a write that did not happen
                // would be the worst outcome available here.
                failed = true
            }
        }
    }
}
