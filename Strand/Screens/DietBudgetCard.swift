import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Diet budget card
//
// The question this answers is "can I still eat something?", so it leads with what is LEFT, not with what
// has been consumed.
//
// Deliberately NOT a ring like Charge / Effort / Rest. Those three fill toward 100 and higher is better;
// eating has the opposite grammar — reaching 100% of a target is not an achievement and going past it is
// the failure, not extra credit. A filling ring would teach exactly the wrong instinct. A depleting bar
// reads the right way round: plenty left is good, empty means stop, and over is visibly over.
struct DietBudgetCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @AppStorage(FoodLogStore.enabledKey) private var foodEnabled = false
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent

    @State private var energy: DietDayEnergy?
    @State private var consumed: Double = 0
    @State private var macros: MacroTotals = .zero
    @State private var targets: MacroTargetSet?
    @State private var showGoalSheet = false
    @State private var reloadTick = 0

    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    /// Budget minus what has been eaten. Negative once over.
    private var remaining: Double? {
        energy?.budgetKcal().map { $0 - consumed }
    }

    var body: some View {
        Group {
            if foodEnabled {
                if energy?.deficitKcal == nil {
                    setGoalPrompt
                } else {
                    budgetCard
                }
            }
        }
        .task(id: "\(repo.foodSeq)-\(repo.refreshSeq)-\(reloadTick)-\(foodEnabled)") { await reload() }
        .sheet(isPresented: $showGoalSheet) {
            DietGoalSheet(existing: nil) { reloadTick += 1 }
                .environmentObject(repo)
                .environmentObject(profile)
        }
    }

    // MARK: - No goal yet

    private var setGoalPrompt: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Diet")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("Set a goal weight and a timeline, and NOOP works out what to eat each day from what you actually burn.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { showGoalSheet = true } label: {
                        Label("Set a goal", systemImage: "target")
                    }
                    .buttonStyle(NoopButtonStyle(.primary))
                }
            }
            .opacity(cardOpacity)
        }
    }

    // MARK: - The budget

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Diet")
            NavigationLink(value: TabRoute.diet) {
                NoopCard(tint: tint) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        headline
                        bar
                        breakdown
                        proteinRow
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
            .opacity(cardOpacity)
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(intText(abs(remaining ?? 0)))
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(isOver ? "kcal over" : "kcal left")
                .font(StrandFont.footnote)
                .foregroundStyle(isOver ? StrandPalette.statusWarning : StrandPalette.textTertiary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Depletes rather than fills. Once over, the bar is full and amber — there is no "more than full",
    /// and pretending otherwise would hide the overshoot.
    private var bar: some View {
        GeometryReader { geo in
            let frac = consumedFraction
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * frac))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(intText(consumed)) of \(intText(energy?.budgetKcal() ?? 0)) kcal")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            if let e = energy, e.expenditure.workoutKcal > 0 {
                // Named because it is the most surprising part of the number: the budget went UP because
                // of training, and a user who cannot see why will think it is wrong.
                Text("Includes \(intText(e.expenditure.workoutKcal)) kcal earned from training")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Protein alongside the calorie budget, because at a deficit the two together are the whole story:
    /// the kcal figure says whether you will lose weight, and this says whether it will be fat.
    ///
    /// Shown only when a protein target exists — a bar with no target would read as 0% of something.
    @ViewBuilder private var proteinRow: some View {
        if let t = targets, t.proteinG > 0 {
            let frac = MacroTargets.fraction(consumed: macros.protein, target: t.proteinG) ?? 0
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Protein")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Text("\(intText(macros.protein)) of \(intText(t.proteinG)) g")
                        .font(StrandFont.caption)
                        .foregroundStyle(frac >= 1 ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset)
                        Capsule()
                            // Green at target rather than amber: unlike calories, MORE protein is not a
                            // failure, so the bar filling is unambiguously good news.
                            .fill(frac >= 1 ? StrandPalette.statusPositive : StrandPalette.metricPurple)
                            .frame(width: max(2, geo.size.width * frac))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Protein \(intText(macros.protein)) of \(intText(t.proteinG)) grams")
        }
    }

    // MARK: - Derived

    private var isOver: Bool { (remaining ?? 0) < 0 }

    private var consumedFraction: Double {
        guard let budget = energy?.budgetKcal(), budget > 0 else { return 0 }
        return min(1, max(0, consumed / budget))
    }

    private var tint: Color {
        if isOver { return StrandPalette.statusWarning }
        return consumedFraction > 0.85 ? StrandPalette.metricAmber : StrandPalette.accent
    }

    private var accessibilitySummary: String {
        guard let r = remaining else { return String(localized: "Diet budget") }
        return r < 0
            ? String(localized: "\(Int(abs(r).rounded())) kilocalories over budget")
            : String(localized: "\(Int(r.rounded())) kilocalories left today")
    }

    private func intText(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.grouping(.automatic))
    }

    private func reload() async {
        guard foodEnabled else { energy = nil; return }
        macros = await repo.foodTotals()
        consumed = macros.kcal
        // Recomputes and banks the day's figures, so the series backing the detail screen stays current
        // without a second pass.
        energy = await repo.refreshDietDay(profile: profile)
        if let budget = energy?.budgetKcal(), let rate = await repo.currentDietGoal()?.proteinGPerKg {
            targets = MacroTargets.targets(budgetKcal: budget, weightKg: profile.weightKg,
                                           proteinGPerKg: rate)
        } else {
            targets = nil
        }
    }
}
