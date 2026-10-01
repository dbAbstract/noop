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

    @State private var working = false
    @State private var failed = false

    var body: some View {
        NoopCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header
                if case .unresolved(let handle) = proposal.kind {
                    unresolvedBody(handle)
                } else {
                    detail
                    if proposal.state == .pending { actions } else { settled }
                }
            }
        }
    }

    // MARK: - Header

    private var tint: Color {
        switch proposal.kind {
        case .unresolved: return StrandPalette.strain066
        case .edit: return StrandPalette.chargeColor
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
            Spacer(minLength: 8)
            // Says WHO proposed this. A card that looked like the app's own arithmetic would hide the
            // one fact the user needs to decide how hard to check it.
            Text("Coach proposed")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var icon: String {
        switch proposal.kind {
        case .log: return "plus.circle"
        case .create: return "sparkles"
        case .edit: return "pencil"
        case .unresolved: return "questionmark.circle"
        }
    }

    private var overline: String {
        switch proposal.kind {
        case .log: return String(localized: "LOG")
        case .create: return String(localized: "NEW FOOD")
        case .edit: return String(localized: "CORRECT A FOOD")
        case .unresolved: return String(localized: "COULDN'T MATCH")
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
            case .unresolved:
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
                    coach.updateProposalState(messageId: messageId, to: .dismissed)
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
        if case .edit = proposal.kind { return String(localized: "Saved food updated.") }
        return String(localized: "Logged.")
    }

    private func apply(save: Bool) {
        working = true
        failed = false
        Task {
            // Marked aiEstimate wherever macros came from the model, so a guess stays identifiable in the
            // log long after this conversation has scrolled away.
            let ok = await repo.applyFoodProposal(proposal, saveToLibrary: save)
            working = false
            if ok {
                coach.updateProposalState(messageId: messageId, to: .applied)
            } else {
                // Left PENDING on failure. A card that said "Logged." over a write that did not happen
                // would be the worst outcome available here.
                failed = true
            }
        }
    }
}
