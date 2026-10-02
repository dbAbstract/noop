import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Weight: the second input the whole diet runs on
//
// Weigh-ins used to live at the bottom of the food log, behind a day stepper, which is the wrong place for
// them twice over. They are not food, and they are the input `AdaptiveExpenditureEngine` gates on just as
// hard as intake — a diet with perfect food logs and four weigh-ins gets no verdict at all. Something that
// load-bearing needs its own surface and its own entry point.
//
// WHAT THIS SCREEN IS FOR, in order: record today's, see whether the trend is actually moving, and fix a
// past day you fat-fingered. The trend is the reason the list is not enough — a single morning's figure is
// mostly water, and the only honest way to read a weigh-in is against the line through the others.
struct WeightView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var history: [(day: String, kg: Double)] = []
    @State private var trend: WeightTrendFit?
    @State private var smoothed: [WeightReading] = []
    @State private var draft = ""
    @State private var editingDay: WeightEditTarget?
    @State private var reloadTick = 0
    @State private var saving = false

    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    private var today: String { Repository.localDayKey(Date()) }
    private var loggedToday: Double? { history.first(where: { $0.day == today })?.kg }

    var body: some View {
        ScreenScaffold(title: "Weight",
                       subtitle: "What the scale says, and what the trend says.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                logSection
                trendSection
                historySection
            }
        }
        .task(id: "\(repo.foodSeq)-\(reloadTick)") { await reload() }
        .sheet(item: $editingDay) { target in
            EditWeightSheet(day: target.day,
                            kg: history.first(where: { $0.day == target.day })?.kg ?? 0,
                            onDone: { reloadTick += 1 })
                .environmentObject(repo)
                .environmentObject(profile)
        }
    }

    // MARK: - Logging

    private var logSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Today", overline: loggedToday == nil ? "Not yet" : "Logged")
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let w = loggedToday {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.1f", locale: AppLanguage.activeLocale, w))
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("kg")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        // A second reading on one morning is a CORRECTION, not another data point, and the
                        // engine counts distinct days precisely so a chatty scale cannot buy confidence.
                        // Saying so is what stops "log again" looking like the wrong button.
                        Text("Logging again today replaces this — a second reading on one morning is a correction, not another data point.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("A daily weigh-in is half of what NOOP needs to work out your real expenditure — the food log is the other half. Same time each morning is what makes the trend readable.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: NoopMetrics.space3) {
                        TextField("Weight in kg", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        NoopButton(saving ? "Saving…" : "Log", kind: .primary) { save() }
                            .disabled(saving || parsedDraft == nil)
                    }
                    if !draft.isEmpty && parsedDraft == nil {
                        Text("That doesn't read as a weight in kilograms.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                }
            }
            .opacity(cardOpacity)
        }
    }

    /// A weight the store will accept. Bounded by the same range the coach's weigh-in action uses, so a
    /// figure typed here and a figure spoken to Coach are held to one rule rather than two.
    private var parsedDraft: Double? {
        guard let kg = Double(draft.trimmingCharacters(in: .whitespaces)),
              kg.isFinite,
              kg >= FoodActionParse.minWeightKg, kg <= FoodActionParse.maxWeightKg else { return nil }
        return kg
    }

    private func save() {
        guard let kg = parsedDraft else { return }
        saving = true
        Task {
            // Today's weigh-in updates the profile scalar every calorie estimate reads; this screen only
            // logs today, so that is unconditional here. Backdated corrections go through
            // `EditWeightSheet`, which makes the same distinction.
            await repo.logWeight(kg: kg, profile: profile)
            draft = ""
            saving = false
            reloadTick += 1
        }
    }

    // MARK: - Trend

    /// The reason a list of numbers is not enough. A morning's figure is mostly water; the line through the
    /// others is the only honest reading of it.
    @ViewBuilder private var trendSection: some View {
        if let fit = trend {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Trend", overline: "\(fit.dayCount) weigh-in days")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%+.2f", locale: AppLanguage.activeLocale,
                                        fit.slopeKgPerWeek))
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("kg/week")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        // The interval, always. A fitted rate without one invites being read as exact, and
                        // this one goes through a handful of noisy points.
                        Text("± \(String(format: "%.2f", locale: AppLanguage.activeLocale, fit.weeklyMarginKg)) kg/week · your readings scatter ± \(String(format: "%.2f", locale: AppLanguage.activeLocale, fit.scatterKg)) kg")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)

                        if !fit.isDistinguishableFromZero {
                            // The honest state, named. A rate whose interval spans zero cannot be told from
                            // no change at all, and presenting it as movement is how someone concludes a
                            // diet is working or failing from noise.
                            Text("That range includes zero, so this can't yet be told apart from no change at all. More weigh-ins narrow it.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let latest = smoothed.last {
                            Divider().overlay(StrandPalette.hairline)
                            // The smoothed figure is what to judge progress by; the raw one is what the
                            // scale said. Both are shown because they answer different questions and
                            // showing only one invites the other to be inferred wrongly.
                            Text("Trend weight \(String(format: "%.1f", locale: AppLanguage.activeLocale, latest.kg)) kg — a smoothed figure, less jumpy than any single morning.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    // MARK: - History

    @ViewBuilder private var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Weigh-ins", overline: "\(history.count)")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        ForEach(history, id: \.day) { row in
                            Button { editingDay = WeightEditTarget(day: row.day) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.day == today ? String(localized: "Today") : row.day)
                                            .font(StrandFont.body)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        if let delta = change(onOrBefore: row.day) {
                                            Text(String(format: "%+.1f kg", locale: AppLanguage.activeLocale, delta))
                                                .font(StrandFont.caption)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                        }
                                    }
                                    Spacer()
                                    Text(String(format: "%.1f kg", locale: AppLanguage.activeLocale, row.kg))
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Image(systemName: "pencil")
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit weigh-in for \(row.day)")
                            if row.day != history.last?.day {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    /// Change from the PREVIOUS weigh-in, which may not be the previous day — a gap of four days makes a
    /// bigger jump unremarkable, and per-reading deltas are what the user is actually comparing.
    private func change(onOrBefore day: String) -> Double? {
        guard let idx = history.firstIndex(where: { $0.day == day }), idx + 1 < history.count else {
            return nil
        }
        return history[idx].kg - history[idx + 1].kg
    }

    // MARK: - Data

    private func reload() async {
        // Newest first for the list; the fit wants oldest first, so each gets the order it needs rather
        // than one order being reinterpreted downstream.
        let oldestFirst = await repo.weightHistory(days: 180)
        history = oldestFirst.reversed()
        // Same construction `DietTrend` uses: the x-axis is a real day index, not a row position, or a
        // fortnight's gap would look like one day and badly overstate the slope.
        let readings = oldestFirst.compactMap { row -> WeightReading? in
            guard let idx = Repository.dayIndex(row.day) else { return nil }
            return WeightReading(dayIndex: idx, kg: row.kg)
        }
        trend = WeightTrend.fit(readings)
        smoothed = WeightTrend.smoothed(readings)
    }
}
