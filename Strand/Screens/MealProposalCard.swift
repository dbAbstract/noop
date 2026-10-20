import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - One card for a described meal
//
// FORK-LOCAL. "8 salmon, an eel, the tempura, two otoro and the beef" is one meal, and five cards with five
// Log buttons made it five decisions. When one coach turn proposes two or more foods, they render here as a
// single card: the items, the meal's total, and one tap to log it.
//
// STILL ONE ENTRY PER ITEM. The tap writes each food through the same `applyFoodProposal` the single card
// uses, so every item keeps its own figures, its PDF citation and its place in the library, and can be
// edited alone in the food log afterwards. Only the decision is grouped. An item can be dropped with its ×
// before logging; a dropped item is recorded as declined, exactly as "No" on its own card would.
//
// THE TAP IS THE WRITE, as on `FoodProposalCard`: nothing here logs until the user presses Log meal.
struct MealProposalCard: View {
    let proposals: [FoodProposal]
    let messageId: UUID

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var profile: ProfileStore

    @State private var excluded: Set<UUID> = []
    @State private var working = false
    @State private var failed = false

    /// Whether `proposal` can sit in a meal card: it logs food and is not a cook, whose leftovers need
    /// their own card.
    static func groups(_ proposal: FoodProposal) -> Bool {
        switch proposal.kind {
        case .log, .create, .documentLog, .logBatch: return true
        default: return false
        }
    }

    private var pending: Bool { proposals.contains { $0.state == .pending } }
    private var included: [FoodProposal] { proposals.filter { !excluded.contains($0.id) } }
    private var shown: [FoodProposal] { pending ? included : proposals.filter { $0.state == .applied } }

    var body: some View {
        NoopCard(padding: 14, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    ForEach(proposals) { item in row(item) }
                }
                Divider()
                totals
                if proposals.contains(where: estimated) {
                    Text("≈ Calories from your PDF; protein, carbs and fat estimated by Coach.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pending { actions } else {
                    Text(settledText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fork.knife")
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(mealTitle)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            // The day, when it is not today: the most consequential thing a logging card can hide.
            if let first = proposals.first, first.targetsAnotherDay(today: Repository.localDayKey(Date())) {
                Text(first.dayLabel)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
            }
            Spacer(minLength: 8)
            Text("Coach proposed")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// The meal every item names, or a plain "MEAL" when they disagree or name none.
    private var mealTitle: String {
        let meals = Set(proposals.map(\.meal))
        guard meals.count == 1, let meal = meals.first ?? nil else { return String(localized: "MEAL") }
        switch meal {
        case .breakfast: return String(localized: "BREAKFAST")
        case .lunch: return String(localized: "LUNCH")
        case .dinner: return String(localized: "DINNER")
        case .snack: return String(localized: "SNACKS")
        }
    }

    private func row(_ item: FoodProposal) -> some View {
        let out = excluded.contains(item.id) || (!pending && item.state != .applied)
        return HStack(alignment: .top, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .strikethrough(out)
                    .fixedSize(horizontal: false, vertical: true)
                Text(rowDetail(item))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            if pending {
                Button {
                    if excluded.contains(item.id) { excluded.remove(item.id) } else { excluded.insert(item.id) }
                } label: {
                    Image(systemName: out ? "arrow.uturn.backward" : "xmark")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(working)
                .accessibilityLabel(out ? Text("Include \(item.displayName)") : Text("Remove \(item.displayName)"))
            }
        }
        .opacity(out ? 0.45 : 1)
    }

    private func rowDetail(_ item: FoodProposal) -> String {
        let kcal = Int((item.loggedMacros?.kcal ?? 0).rounded())
        return "\(portionLine(item)) · \(kcal) kcal" + (estimated(item) ? " ≈" : "")
    }

    private var totals: some View {
        let sum = NutritionMath.total(shown.compactMap(\.loggedMacros))
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(shown.count) items · \(Int(sum.kcal.rounded())) kcal")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("\(Int(sum.protein.rounded()))P \(Int(sum.carbs.rounded()))C \(Int(sum.fat.rounded()))F")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Log meal", kind: .primary) { logMeal() }
                    .disabled(working || included.isEmpty)
                NoopButton("No", kind: .secondary) {
                    for p in proposals where p.state == .pending {
                        coach.updateProposalState(messageId: messageId, proposalId: p.id, to: .dismissed)
                    }
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

    private var settledText: String {
        let logged = proposals.filter { $0.state == .applied }.count
        guard logged > 0, let day = proposals.first?.dayLabel else { return String(localized: "Not logged.") }
        return String(localized: "Logged \(logged) items to \(day.lowercased()).")
    }

    // MARK: - Helpers

    private func estimated(_ item: FoodProposal) -> Bool {
        if case .documentLog(_, _, _, _, let source, _) = item.kind { return source.macrosEstimated == true }
        return false
    }

    private func portionLine(_ item: FoodProposal) -> String {
        let serving: String
        let portion: Double
        switch item.kind {
        case .log(let food, let p): serving = food.servingLabel; portion = p
        case .create(_, let s, _, let p), .documentLog(_, let s, _, let p, _, _): serving = s; portion = p
        // A cook's portion is a fraction of the pot, not a count of servings.
        case .logBatch(_, let p): return "\(Int((p * 100).rounded()))%"
        default: return ""
        }
        let label = serving.isEmpty ? String(localized: "1 serving") : serving
        if abs(portion - 1) < 0.001 { return String(localized: "1 × \(label)") }
        let p = portion.rounded() == portion ? String(Int(portion)) : String(format: "%g", portion)
        return "\(p) × \(label)"
    }

    /// Log every included item, in order. A failure stops the run and leaves that item and the rest pending,
    /// so the card can be tapped again; items already written are marked logged and are not written twice.
    private func logMeal() {
        working = true
        failed = false
        let toLog = included.filter { $0.state == .pending }
        let dropped = proposals.filter { excluded.contains($0.id) && $0.state == .pending }
        Task {
            for p in toLog {
                let ok = await repo.applyFoodProposal(p, saveToLibrary: false, profile: profile)
                guard ok else { failed = true; break }
                coach.updateProposalState(messageId: messageId, proposalId: p.id, to: .applied, roughGuess: p.roughGuess)
            }
            if !failed {
                for p in dropped { coach.updateProposalState(messageId: messageId, proposalId: p.id, to: .dismissed) }
            }
            working = false
        }
    }
}
