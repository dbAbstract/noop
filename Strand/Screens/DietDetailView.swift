import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Diet detail
//
// Three things, in the order they answer questions:
//
//   1. Today's budget, broken into the parts it was built from. A user told "2,322 kcal" who disagrees
//      has nowhere to go; one who can see 2,017 + 155 + 150 can say WHICH part is wrong — and with three
//      estimators in play, that is most of the diagnostic value.
//   2. Adherence — intake against target, day by day. Behavioural, and meaningful on a weekly view
//      regardless of how small the deficit is.
//   3. The two burn figures side by side: this model's, and NOOP's own heart-rate estimate. They answer
//      the same question differently and neither is allowed to stand in for the other.
//
// What is NOT here yet: whether the diet is WORKING. That needs the weight trend and an evaluation window
// sized to the deficit, and at a small deficit it cannot be answered in under a month — so it is Stage 2,
// deliberately, rather than a number invented now.
struct DietDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    @State private var energy: DietDayEnergy?
    @State private var goal: DietGoalRow?
    @State private var consumedToday: Double = 0
    @State private var history: [DietDay] = []
    @State private var showGoalSheet = false
    @State private var reloadTick = 0

    /// One day's intake against the target that governed it, plus both burn figures.
    struct DietDay: Identifiable, Equatable {
        let day: String
        let intake: Double
        let target: Double?
        let modelledBurn: Double?
        let noopBurn: Double?
        var id: String { day }

        /// A day counts as adherent when it had a target and stayed at or under it.
        var isAdherent: Bool? {
            guard let target, target > 0, intake > 0 else { return nil }
            return intake <= target
        }
    }

    var body: some View {
        ScreenScaffold(title: "Diet",
                       subtitle: "What you ate against what you spent.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                todaySection
                goalSection
                adherenceSection
                burnComparisonSection
                historySection
            }
        }
        .task(id: "\(repo.foodSeq)-\(repo.refreshSeq)-\(reloadTick)") { await reload() }
        .sheet(isPresented: $showGoalSheet) {
            DietGoalSheet(existing: goal) { reloadTick += 1 }
                .environmentObject(repo)
                .environmentObject(profile)
        }
    }

    // MARK: - Today, with its working shown

    @ViewBuilder private var todaySection: some View {
        if let e = energy, let budget = e.budgetKcal() {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Today", overline: "Budget")
                NoopCard(tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(int(max(0, budget - consumedToday)))
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(budget - consumedToday < 0 ? "kcal over" : "kcal left")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Divider().overlay(StrandPalette.hairline)

                        // The working. Each line is a different estimator, so naming them separately is
                        // what lets a wrong total be traced to the part that is wrong.
                        line("Baseline", int(e.expenditure.baselineKcal),
                             note: "resting energy × your usual day")
                        line("Steps", int(e.expenditure.stepNeatKcal),
                             note: stepNote(e))
                        line("Training", int(e.expenditure.workoutKcal),
                             note: "measured from heart rate")
                        Divider().overlay(StrandPalette.hairline)
                        line("Spent", int(e.expenditure.totalKcal), emphasis: true)
                        line("Deficit", "−\(int(e.deficitKcal ?? 0))")
                        line("Budget", int(budget), emphasis: true)
                        line("Eaten", int(consumedToday))
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    /// Spells out the step accounting, because "steps: 155 kcal" on a day with a 40-minute run looks
    /// wrong until you know the run's steps were removed and counted at their real intensity instead.
    ///
    /// "No step data yet" is deliberately distinct from "0 steps". The first means the strap has not
    /// answered — a 4.0 has no counter, a 5.0 has nothing until the window offloads — and the budget is
    /// short its NEAT until it does. The second means it answered and you did not move. Rendering both as
    /// "0 of 0 steps" would hide a missing input behind a plausible reading.
    private func stepNote(_ e: DietDayEnergy) -> String {
        guard let daily = e.dailySteps else {
            return String(localized: "No step data yet — this budget is resting energy and training only")
        }
        if e.workoutSteps > 0 {
            return String(localized: "\(e.neatSteps) of \(daily) steps — \(e.workoutSteps) counted with training instead")
        }
        return String(localized: "\(e.neatSteps) of \(daily) steps, above a \(StepNeat.sedentaryBaselineSteps)-step baseline")
    }

    // MARK: - Goal

    @ViewBuilder private var goalSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Goal", overline: goal == nil ? "Not set" : "Current")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let g = goal {
                        line("Target", String(format: "%.1f kg", locale: AppLanguage.activeLocale, g.targetWeightKg))
                        line("From", String(format: "%.1f kg", locale: AppLanguage.activeLocale, g.startWeightKg))
                        line("Over", "\(g.months) \(g.months == 1 ? "month" : "months")")
                        line("Daily deficit", "\(int(g.dailyDeficitKcal)) kcal")
                        Button("Change goal") { showGoalSheet = true }
                            .buttonStyle(NoopButtonStyle(.secondary))
                    } else {
                        Text("No goal set. Without one there is no budget to eat toward.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Button("Set a goal") { showGoalSheet = true }
                            .buttonStyle(NoopButtonStyle(.primary))
                    }
                }
            }
            .opacity(cardOpacity)
        }
    }

    // MARK: - Adherence — the question weekly CAN answer

    @ViewBuilder private var adherenceSection: some View {
        let judged = history.compactMap { d -> Bool? in d.isAdherent }
        if !judged.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last 7 days", overline: "Adherence")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        let onTarget = judged.filter { $0 }.count
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(onTarget) of \(judged.count)")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("days on target")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        let logged = history.filter { $0.intake > 0 }
                        if !logged.isEmpty {
                            let mean = logged.reduce(0.0) { $0 + $1.intake } / Double(logged.count)
                            line("Average intake", "\(int(mean)) kcal")
                        }
                        line("Days logged", "\(logged.count) of \(history.count)")

                        // Names the limit of what this section claims. Adherence is behaviour; whether the
                        // weight is moving is a different question on a much longer clock, and conflating
                        // them is exactly what makes a weekly review misleading at a small deficit.
                        Text("This is what you did, not whether it's working — weight moves too slowly at a small deficit to read week by week.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    // MARK: - Two burn figures, neither replacing the other

    @ViewBuilder private var burnComparisonSection: some View {
        if let e = energy {
            let noop = repo.days.first(where: { $0.day == Repository.localDayKey(Date()) })?.activeKcalEst
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Burn", overline: "Two estimates")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        line("This model", "\(int(e.expenditure.totalKcal)) kcal",
                             note: "resting + steps + training")
                        line("NOOP's estimate", noop.map { "\(int($0)) kcal" } ?? "—",
                             note: "heart rate only")
                        if let noop, noop > 0 {
                            let gap = e.expenditure.totalKcal - noop
                            line("Difference", "\(gap >= 0 ? "+" : "")\(int(gap)) kcal", emphasis: true)
                        }
                        // The gap is the point of the card, so it is explained rather than left to be
                        // read as one of them being broken.
                        Text("NOOP counts active energy only above 50% heart-rate reserve, so ordinary walking and standing don't reach it. This model adds those back from your step count. Neither figure overwrites the other.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    // MARK: - History

    @ViewBuilder private var historySection: some View {
        let withIntake = history.filter { $0.intake > 0 }
        if !withIntake.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Intake vs target", overline: "Last 7 days")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                            let peak = max(1, history.flatMap { [$0.intake, $0.target ?? 0] }.max() ?? 1)
                            ForEach(history) { d in
                                VStack(spacing: 4) {
                                    ZStack(alignment: .bottom) {
                                        // The target as a faint backdrop with the intake drawn over it:
                                        // under/over is then a shape, readable without a legend.
                                        if let t = d.target, t > 0 {
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(StrandPalette.hairline)
                                                .frame(height: max(2, 84 * (t / peak)))
                                        }
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(d.isAdherent == false ? StrandPalette.statusWarning : StrandPalette.accent)
                                            .frame(height: max(2, 84 * (d.intake / peak)))
                                    }
                                    .frame(height: 84, alignment: .bottom)
                                    Text(dayInitial(d.day))
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(barLabel(d))
                            }
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    private func barLabel(_ d: DietDay) -> String {
        guard let t = d.target else { return "\(d.day): \(int(d.intake)) kcal" }
        return "\(d.day): \(int(d.intake)) of \(int(t)) kcal"
    }

    // MARK: - Data

    private func reload() async {
        goal = await repo.currentDietGoal()
        consumedToday = await repo.foodTotals().kcal
        energy = await repo.refreshDietDay(profile: profile)

        let intake = await repo.foodHistory(days: 7)
        var targets: [String: Double] = [:]
        var modelled: [String: Double] = [:]
        if let store = await repo.storeHandle(), let first = intake.first?.day, let last = intake.last?.day {
            for p in (try? await store.metricSeries(deviceId: DietStore.sourceId,
                                                    key: DietStore.Keys.target,
                                                    from: first, to: last)) ?? [] {
                targets[p.day] = p.value
            }
            for p in (try? await store.metricSeries(deviceId: DietStore.sourceId,
                                                    key: DietStore.Keys.expenditure,
                                                    from: first, to: last)) ?? [] {
                modelled[p.day] = p.value
            }
        }
        let noopByDay = Dictionary(uniqueKeysWithValues: repo.days.compactMap { d in
            d.activeKcalEst.map { (d.day, $0) }
        })
        history = intake.map { row in
            DietDay(day: row.day, intake: row.kcal, target: targets[row.day],
                    modelledBurn: modelled[row.day], noopBurn: noopByDay[row.day])
        }
    }

    // MARK: - Formatting

    private func line(_ label: String, _ value: String, note: String? = nil,
                      emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(value)
                    .font(emphasis ? StrandFont.headline : StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if let note {
                Text(note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func int(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.grouping(.automatic))
    }

    private func dayInitial(_ dayKey: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dayKey) else { return "" }
        let out = DateFormatter(); out.locale = AppLanguage.activeLocale; out.dateFormat = "EEEEE"
        return out.string(from: date)
    }
}
