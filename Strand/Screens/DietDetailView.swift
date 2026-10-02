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
    /// Needed only to hand on to `AddFoodSheet`, whose Estimate button lives behind the coach's own
    /// gates. This screen never calls the model itself.
    @EnvironmentObject var coach: AICoachEngine

    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    @State private var energy: DietDayEnergy?
    @State private var goal: DietGoalRow?
    @State private var consumedToday: Double = 0
    @State private var macrosToday: MacroTotals = .zero
    @State private var targets: MacroTargetSet?
    @State private var history: [DietDay] = []
    @State private var showGoalSheet = false
    @State private var showAddSheet = false
    @State private var library: [FoodItem] = []
    @State private var recipes: [Recipe] = []
    @State private var reloadTick = 0
    @State private var trend: DietTrendReading?
    @State private var proposed: Double?
    @State private var applying = false
    @State private var adoptingBaseline = false
    /// Dismissing the baseline card is per-session, not persisted. A persisted dismissal would need a
    /// re-offer schedule of its own, and the card already only appears when the measurement earns it.
    @State private var baselineCardDismissed = false

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
                macrosSection
                proposalSection
                measuredBaselineSection
                trendSection
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
        // Logging from here writes to TODAY. This screen is a read-out of where the diet stands, with no
        // day selector of its own — so there is no other day it could honestly mean, and inheriting one
        // invisibly is how an entry lands on the wrong date.
        .sheet(isPresented: $showAddSheet) {
            AddFoodSheet(library: library, recipes: recipes) { item, portion, save in
                Task {
                    if save { await repo.saveFoodItem(item) }
                    await repo.logFood(item: item, portion: portion, saveToLibrary: save)
                    reloadTick += 1
                }
            }
            .environmentObject(coach)
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
                        // Logging lives beside the figure it changes. This screen answers "how am I
                        // doing", and the answer is almost always followed by wanting to add something
                        // to it — until now that meant backing out to Today and finding the FAB.
                        NoopButton("Log food", systemImage: "plus.circle.fill", kind: .primary) {
                            showAddSheet = true
                        }

                        Divider().overlay(StrandPalette.hairline)

                        // The working. Each line is a different estimator, so naming them separately is
                        // what lets a wrong total be traced to the part that is wrong.
                        // The LABEL changes with the source, because the number does. A line reading
                        // "resting energy × your usual day" over a figure measured from the user's own
                        // weight trend would be the two-readouts-disagreeing failure in one row.
                        line(e.usesMeasuredBaseline ? "Baseline (measured)" : "Baseline",
                             int(e.expenditure.baselineKcal),
                             note: e.usesMeasuredBaseline
                                 ? "from your own logs and weigh-ins, not a formula"
                                 : "resting energy × your usual day")
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
                        // The empirical one, once there is enough logging to support it. It supersedes
                        // nothing — AdaptiveExpenditureEngine's own header forbids it feeding anything,
                        // and it is right: a figure inferred from a food diary must not quietly replace
                        // one measured from heart rate. It is here to be COMPARED, which is the only
                        // honest use for a third answer to the same question.
                        if let a = trend?.adaptive {
                            Divider().overlay(StrandPalette.hairline)
                            line("From your own results",
                                 "\(int(a.estimatedDailyKcal)) kcal",
                                 note: "±\(int((a.upperKcal - a.lowerKcal) / 2) ) · \(a.confidence.rawValue) confidence · \(a.intakeDays) days logged",
                                 emphasis: true)
                            Text("Worked back from what you ate and how your weight moved, rather than from a formula. This is the one that knows about you specifically — it just needs weeks of logging before it can say anything.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
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
        let t = await repo.dietTrend()
        trend = t
        proposed = repo.proposedDeficit(from: t)
        macrosToday = await repo.foodTotals()
        consumedToday = macrosToday.kcal
        // For the Add food sheet. Recipes compose against THIS library read, so the two cannot describe
        // different libraries.
        library = await repo.foodLibrary()
        recipes = await repo.recipes(library: library)
        energy = await repo.refreshDietDay(profile: profile)
        if let budget = energy?.budgetKcal(), let rate = goal?.proteinGPerKg {
            targets = MacroTargets.targets(budgetKcal: budget, weightKg: profile.weightKg,
                                           proteinGPerKg: rate)
        } else {
            targets = nil
        }

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

    /// The budget's composition. Protein has a target, fat has a floor, carbs are the remainder — three
    /// different kinds of number, so the rows say which is which rather than presenting them as a
    /// uniform set of goals to hit.
    @ViewBuilder private var macrosSection: some View {
        if let t = targets {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Macros", overline: "Today")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        macroRow("Protein", eaten: macrosToday.protein, target: t.proteinG,
                                 note: "aim for this", tint: StrandPalette.metricPurple)
                        macroRow("Fat", eaten: macrosToday.fat, target: t.fatFloorG,
                                 note: "a floor, not a ceiling", tint: StrandPalette.metricAmber)
                        macroRow("Carbs", eaten: macrosToday.carbs, target: t.carbsG,
                                 note: "whatever the budget has left", tint: StrandPalette.accent)
                        if t.isOverCommitted {
                            // Said plainly rather than rendered as 0 g of carbs, which would look like a
                            // rounding artefact instead of a plan that does not fit.
                            Text("Your protein target and the fat floor already use the whole budget. Either ease the deficit or lower the protein rate.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    private func macroRow(_ label: String, eaten: Double, target: Double,
                          note: String, tint: Color) -> some View {
        let frac = MacroTargets.fraction(consumed: eaten, target: target) ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("\(int(eaten)) of \(int(target)) g")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule().fill(tint).frame(width: max(2, geo.size.width * frac))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text(note)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(int(eaten)) of \(int(target)) grams, \(note)")
    }

    // MARK: - Is it working?

    /// Shows a verdict ONLY when the measurement supports one. The rest of the time it says when it will,
    /// which is the honest answer and the useful one — a number delivered before the signal clears the
    /// noise is reading water, and the user has no way to tell that from the real thing.
    @ViewBuilder private var trendSection: some View {
        if let t = trend, t.targetDeficitKcal != nil {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Is it working?", overline: "Trend")
                NoopCard(tint: t.hasVerdict ? StrandPalette.accent : nil) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        if t.hasVerdict, let actual = t.actualKgPerWeek, let fit = t.fit {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(kgPerWeek(actual))
                                    .font(StrandFont.title2)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("per week")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            // The interval, always. A rate without one invites being read as exact, and
                            // this one is fitted through a handful of noisy points.
                            line("Confidence", "± \(String(format: "%.2f", fit.weeklyMarginKg)) kg/week")
                            if let expected = t.expectedKgPerWeek {
                                line("Your target", kgPerWeek(expected))
                                Divider().overlay(StrandPalette.hairline)
                                Text(verdictText(expected: expected, actual: actual))
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            notYet(t)
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    /// The "not yet" state, with the arithmetic that justifies it. Showing the predicted rate beside the
    /// measured scatter is what makes the wait legible rather than arbitrary — the user can see that the
    /// signal is genuinely smaller than the noise, not that the app is being coy.
    @ViewBuilder private func notYet(_ t: DietTrendReading) -> some View {
        Text("Not enough to tell yet.")
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
        if let expected = t.expectedKgPerWeek {
            line("Your deficit predicts", kgPerWeek(expected))
        }
        if let fit = t.fit {
            line("Your weigh-ins scatter", "± \(String(format: "%.2f", fit.scatterKg)) kg")
            line("Weigh-in days", "\(fit.dayCount)")
        } else {
            line("Weigh-in days", "fewer than 3")
        }
        line("Days with food logged", "\(t.intakeDays)")
        Divider().overlay(StrandPalette.hairline)
        if let days = t.daysToDetect, days > 0 {
            Text("About \(days) more days of logging before a change can be told apart from normal fluctuation.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Log your weight most days and your food every day. Weight moves slower than a small deficit suggests, so this takes a few weeks before it can say anything honest.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func verdictText(expected: Double, actual: Double) -> String {
        let gap = (-expected) - (-actual)        // positive = losing slower than planned
        if abs(gap) < 0.05 {
            return String(localized: "That's on plan. Your real expenditure is close to the estimate.")
        }
        if gap > 0 {
            return String(localized: "You're losing more slowly than the plan predicts, which means you're spending less than the estimate assumed.")
        }
        return String(localized: "You're losing faster than the plan predicts, which means you're spending more than the estimate assumed.")
    }

    // MARK: - Recalibration

    /// Appears only when the trend is measurable AND the implied change is big enough to matter — never
    /// on a schedule. A proposal made from noise is worse than no proposal, because once it is on screen
    /// the user cannot tell which kind it is.
    @ViewBuilder private var proposalSection: some View {
        if let p = proposed, let t = trend, let current = t.targetDeficitKcal,
           let expected = t.expectedKgPerWeek, let actual = t.actualKgPerWeek {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Target review", overline: "Ready")
                NoopCard(tint: StrandPalette.metricAmber) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        line("Expected", kgPerWeek(expected))
                        line("Actual", kgPerWeek(actual))
                        Divider().overlay(StrandPalette.hairline)
                        line("Daily deficit", "\(int(current)) → \(int(p)) kcal", emphasis: true)
                        Text(proposalReason(current: current, proposed: p))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Keep current") { proposed = nil }
                                .buttonStyle(NoopButtonStyle(.secondary))
                            Spacer()
                            Button(applying ? "Applying…" : "Accept") { Task { await applyProposal(p) } }
                                .buttonStyle(NoopButtonStyle(.primary))
                                .disabled(applying)
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    // MARK: - The measured baseline

    /// Offers to cost the budget from the user's OWN measured expenditure instead of Mifflin-St Jeor.
    ///
    /// Opt-in, and the figure never moves anything until it is accepted. That is not caution for its own
    /// sake: the measurement is derived partly from the user's food log, so accepting it is a judgement
    /// about how good their logging has been — which is a judgement only they can make, and the card's job
    /// is to give them what they need to make it.
    ///
    /// Appears only when the measurement has earned it: moderate or high confidence, and a gap from the
    /// model worth acting on. Below that threshold the two figures disagree by less than the method's own
    /// error and switching would be theatre.
    @ViewBuilder private var measuredBaselineSection: some View {
        if let t = trend, let adaptive = t.adaptive, let measured = t.measuredBaselineKcal,
           let e = energy, !baselineCardDismissed,
           adaptive.confidence != .building,
           // Compared against the MODEL's baseline, which is the term being replaced — comparing whole
           // expenditures would fold in today's activity and make the gap look different every day.
           abs(measured - modelBaselineKcal(e)) >= Self.minBaselineGapKcal {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader(e.usesMeasuredBaseline ? "Measured burn" : "Use your measured burn?",
                              overline: adaptive.confidence == .high ? "High confidence" : "Moderate")
                NoopCard(tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        line("Model says", "\(int(modelBaselineKcal(e))) kcal")
                        line("Your data says", "\(int(measured)) kcal", emphasis: true)
                        // The interval, always — the estimate is a range and a bare figure would be the
                        // fabrication the rest of the app refuses to make.
                        line("Range", "\(int(adaptive.lowerKcal)) – \(int(adaptive.upperKcal)) kcal")

                        Divider().overlay(StrandPalette.hairline)

                        Text(baselineExplanation(adaptive: adaptive, measured: measured, energy: e))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Says which way the range leans and WHY, because an unlogged day biases the
                        // figure down rather than scattering it — so the honest reading of a lopsided
                        // range is "probably at least this", not "somewhere in here".
                        if adaptive.isLikelyUnderstated {
                            Text(understatementNote(adaptive))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.metricAmber)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if e.usesMeasuredBaseline {
                            HStack {
                                Text("In use")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                Spacer()
                                Button(adoptingBaseline ? "Reverting…" : "Back to the model") {
                                    Task { await adoptBaseline(nil) }
                                }
                                .buttonStyle(NoopButtonStyle(.secondary))
                                .disabled(adoptingBaseline)
                            }
                        } else {
                            HStack {
                                Button("Not now") { baselineCardDismissed = true }
                                    .buttonStyle(NoopButtonStyle(.secondary))
                                Spacer()
                                Button(adoptingBaseline ? "Applying…" : "Use mine") {
                                    Task { await adoptBaseline(measured) }
                                }
                                .buttonStyle(NoopButtonStyle(.primary))
                                .disabled(adoptingBaseline)
                            }
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    /// Below this the two figures disagree by less than the method's own error, and switching would be
    /// theatre that moved the user's budget for no reason the data supports.
    private static let minBaselineGapKcal = 50.0

    /// What the MODEL would put the baseline at — the term an override replaces.
    ///
    /// Re-derived from the reported BMR rather than read off `expenditure.baselineKcal`, because once an
    /// override is live that field holds the measured figure and the card must still be able to state what
    /// the model says. Reading it would make the card show the same number on both lines.
    private func modelBaselineKcal(_ e: DietDayEnergy) -> Double {
        CalorieTarget.baselineKcal(bmrKcal: e.expenditure.bmrKcal,
                                   activity: ActivityLevel(rawValue: goal?.activityLevel ?? "") ?? .sedentary)
    }

    private func baselineExplanation(adaptive: AdaptiveExpenditureEstimate,
                                     measured: Double, energy: DietDayEnergy) -> String {
        if energy.usesMeasuredBaseline {
            return String(localized: "Your budget is costed from your own \(adaptive.windowDays) days of food logs and weigh-ins, not from a population formula. Your steps and workouts still move it day to day on top of this.")
        }
        let direction = measured > modelBaselineKcal(energy)
            ? String(localized: "higher")
            : String(localized: "lower")
        return String(localized: "Worked out from \(adaptive.intakeDays) days of your own logs and \(adaptive.weightReadings) weigh-ins over \(adaptive.windowDays) days — your weight trend says what you actually spend, which is \(direction) than the formula guessed. Your steps and workouts would still move the budget day to day on top of this.")
    }

    /// Names the asymmetry in words. A lopsided range is easy to misread as a symmetric one, and the
    /// difference matters: it means the figure is more likely too LOW than too high.
    private func understatementNote(_ adaptive: AdaptiveExpenditureEstimate) -> String {
        if adaptive.roughIntakeDays > 0 && adaptive.intakeDays < adaptive.windowDays {
            return String(localized: "\(adaptive.windowDays - adaptive.intakeDays) days weren't logged and \(adaptive.roughIntakeDays) were a rough guess, so your real burn is likely at or above this range rather than in the middle of it.")
        }
        if adaptive.roughIntakeDays > 0 {
            return String(localized: "\(adaptive.roughIntakeDays) of these days were a rough guess, so your real burn is likely at or above this range rather than in the middle of it.")
        }
        return String(localized: "\(adaptive.windowDays - adaptive.intakeDays) days in this window weren't logged, and unlogged days are usually bigger ones — so your real burn is likely at or above this range rather than in the middle of it.")
    }

    /// Writes (or clears) the measured baseline on the open goal, then re-banks so every figure on screen
    /// comes from the new costing rather than a mix of the old and the new.
    private func adoptBaseline(_ kcal: Double?) async {
        adoptingBaseline = true
        await repo.setMeasuredBaseline(kcal)
        await repo.refreshDietDay(profile: profile)
        adoptingBaseline = false
        reloadTick += 1
    }

    private func proposalReason(current: Double, proposed: Double) -> String {
        proposed > current
            ? String(localized: "Eating a little less keeps you on the pace you set. The change is deliberately half of what the gap suggests, so a noisy fortnight can't swing your target.")
            : String(localized: "You're ahead of pace, so the deficit can ease off. The change is deliberately half of what the gap suggests, so a noisy fortnight can't swing your target.")
    }

    /// Supersedes the goal rather than editing it, so the day-by-day history still resolves against
    /// whichever target was actually in force at the time.
    private func applyProposal(_ newDeficit: Double) async {
        guard let g = goal else { return }
        applying = true
        await repo.setDietGoal(startWeightKg: g.startWeightKg,
                               targetWeightKg: g.targetWeightKg,
                               months: g.months,
                               activity: ActivityLevel(rawValue: g.activityLevel) ?? .sedentary,
                               dailyDeficitKcal: newDeficit)
        await repo.refreshDietDay(profile: profile)
        applying = false
        reloadTick += 1
    }

    private func kgPerWeek(_ v: Double) -> String {
        String(format: "%+.2f kg", locale: AppLanguage.activeLocale, v)
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
