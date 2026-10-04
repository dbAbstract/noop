import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Food log (v0) — opt-in, local-only food & macro logging
//
// The day's logged foods, their running macro totals, and a hand-entered weigh-in. Items come from the
// user's own saved library (`AddFoodSheet`); there is no food database and nothing is looked up online —
// every number on this screen is one the user typed, which is why the screen never rounds a macro away or
// infers one it was not given.
//
// The day totals are banked into `metricSeries` by `Repository.rebankFoodTotals`, so Trends / Compare /
// Explore pick them up with no extra wiring. This screen re-reads after every mutation via `reloadTick`,
// the same pattern `HydrationView` uses.
//
// DEFERRED (v1): recipes (multi-ingredient items tweakable at log time) and LLM macro estimation. The seam
// for the latter is `AddFoodSheet.estimateMacros`.
struct FoodLogView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    /// Injected app-wide on both roots; the sheet needs it for the estimate button.
    @EnvironmentObject var coach: AICoachEngine

    @State private var entries: [FoodEntry] = []
    @State private var totals: MacroTotals = .zero
    @State private var history: [(day: String, kcal: Double)] = []
    @State private var library: [FoodItem] = []
    /// Recipes, composed against `library` in the same reload — so a recipe can never be shown resolving
    /// against a different library than the one on screen beside it.
    @State private var recipes: [Recipe] = []
    @State private var reloadTick = 0

    @State private var showAddSheet = false
    /// `.some(nil)` opens the builder for a NEW recipe; `.some(recipe)` edits one. A plain `Recipe?`
    /// could not express "create", since nil would mean "closed".
    @State private var buildingRecipe: RecipeEditTarget?
    @State private var editingEntry: FoodEntry?
    @State private var editingItem: FoodItem?

    /// Which day is being logged to. Days BACK from today, so 0 is today and 1 is yesterday — the
    /// direction the UI moves in, and it makes "never in the future" a type-level fact rather than a
    /// check someone has to remember.
    ///
    /// This exists because a missed day was otherwise unfixable: the engine that judges whether the diet
    /// is working needs 70% intake coverage over three weeks, and four forgotten days put that out of
    /// reach permanently. Backfilling is the difference between a gap and a dead end.
    @State private var dayOffset = 0
    /// An instant inside the current DIET day, which in the small hours may be yesterday. Resolved on load
    /// because the answer needs a sleep read; nil means "not yet asked", and the calendar day stands in.
    @State private var dietDayAnchor: Date?

    /// How far back logging may reach, in days. Two weeks: the coverage window this protects is three
    /// weeks, and beyond that someone is reconstructing rather than remembering. Shared by the stepper
    /// and the history chart so the two cannot disagree about what is reachable.
    private static let maxDayOffset = 13

    /// The day everything on this screen reads and writes.
    ///
    /// Offset from the DIET day rather than the calendar day, so a 00:15 snack lands on the day still being
    /// lived — see `DietDayBoundary`. `dietDayAnchor` is resolved asynchronously on load and falls back to
    /// the calendar day until it is, which is correct outside the small hours and is the only time this
    /// screen is opened in them.
    private var selectedDay: String {
        let anchor = dietDayAnchor ?? Date()
        return Repository.localDayKey(anchor.addingTimeInterval(-Double(dayOffset) * 86_400))
    }

    private var isToday: Bool { dayOffset == 0 }

    /// "Card transparency" (0–100), shared with every other card surface.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    /// When false this renders its sections BARE, for composition inside another screen's scaffold.
    ///
    /// The diet screen hosts this as its "Day" half, and two nested `ScreenScaffold`s would mean two scroll
    /// views fighting over one gesture. Defaults to true so the standalone route — the food-log reminder's
    /// tap-through — is unchanged.
    var ownsScaffold: Bool = true

    var body: some View {
        Group {
            if ownsScaffold {
                ScreenScaffold(title: "Food",
                               subtitle: "What you ate today, on \(Platform.deviceNounPhrase) only. Nothing is looked up online.",
                               onRefresh: { await reload() }) {
                    sections
                }
            } else {
                sections
            }
        }
        .task(id: "\(reloadTick)-\(dayOffset)") { await reload() }
        .sheet(isPresented: $showAddSheet) {
            AddFoodSheet(library: library, recipes: recipes) { item, portion, save in
                Task {
                    if save { await repo.saveFoodItem(item) }
                    await repo.logFood(item: item, portion: portion, day: selectedDay,
                                       at: logTimestamp, saveToLibrary: save)
                    reloadTick += 1
                }
            }
            .environmentObject(coach)
        }
        .sheet(item: $editingItem) { item in
            EditFoodItemSheet(item: item, onSaved: { reloadTick += 1 }, onDeleted: { reloadTick += 1 })
                .environmentObject(repo)
        }
        .sheet(item: $buildingRecipe) { target in
            RecipeBuilderSheet(existing: target.recipe, library: library,
                               onSaved: { reloadTick += 1 }, onDeleted: { reloadTick += 1 })
                .environmentObject(repo)
        }
        .sheet(item: $editingEntry) { entry in
            EditPortionSheet(entry: entry) { newPortion in
                Task {
                    await repo.updateFoodEntry(id: entry.id, portion: newPortion, day: selectedDay)
                    reloadTick += 1
                }
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            daySection
            totalsSection
            entriesSection
            recipesSection
            quickAddSection
            historySection
        }
    }

    // MARK: - Which day

    /// Backfilled entries are stamped at MIDDAY of that day, not "now".
    ///
    /// Entries sort by `loggedAt`, so stamping a backfill with the current clock would file yesterday's
    /// breakfast after yesterday's dinner. Midday is a deliberate admission that the real time is
    /// unknown rather than a guess dressed as one, and it keeps a backfilled day's ordering stable.
    private var logTimestamp: Date {
        guard !isToday else { return Date() }
        let start = Date().addingTimeInterval(-Double(dayOffset) * 86_400)
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
    }

    @ViewBuilder private var daySection: some View {
        // Hidden entirely on today, which is almost every use. A day picker permanently occupying the
        // top of the screen would make the common case pay for the rare one.
        if !isToday {
            NoopCard(tint: StrandPalette.statusWarning) {
                HStack {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Logging to \(dayLabel)")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Not today — anything you add lands on that day.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Button("Today") { dayOffset = 0 }
                        .buttonStyle(NoopButtonStyle(.secondary))
                }
            }
            .opacity(cardOpacity)
        }
    }

    /// The day stepper, kept in the entries card so the common path stays uncluttered.
    private var dayStepper: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button { dayOffset = min(Self.maxDayOffset, dayOffset + 1) } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            // Two weeks back is the practical limit: the coverage window this protects is three weeks,
            // and beyond that someone is reconstructing rather than remembering.
            .disabled(dayOffset >= Self.maxDayOffset)
            .accessibilityLabel("Previous day")

            Text(dayLabel)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minWidth: 90)

            Button { dayOffset = max(0, dayOffset - 1) } label: {
                Image(systemName: "chevron.right")
                    .font(StrandFont.footnote)
                    .foregroundStyle(dayOffset == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(dayOffset == 0)
            .accessibilityLabel("Next day")
        }
    }

    private var dayLabel: String {
        switch dayOffset {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            let d = Date().addingTimeInterval(-Double(dayOffset) * 86_400)
            return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .locale(AppLanguage.activeLocale))
        }
    }

    // MARK: - Today's totals

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(LocalizedStringKey(dayLabel), overline: "Intake")
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(intString(totals.kcal))
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("kcal")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }

                    HStack(spacing: NoopMetrics.space3) {
                        macroPill(String(localized: "Protein"), totals.protein)
                        macroPill(String(localized: "Carbs"), totals.carbs)
                        macroPill(String(localized: "Fat"), totals.fat)
                        macroPill(String(localized: "Fibre"), totals.fiber)
                    }

                    if entries.isEmpty {
                        Text("Nothing logged yet today.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .opacity(cardOpacity)
        }
    }

    private func macroPill(_ label: String, _ grams: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("\(intString(grams)) g")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Logged entries

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Logged", overline: LocalizedStringKey(dayLabel))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("Add food", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(NoopButtonStyle(.primary))
                        Spacer()
                        dayStepper
                    }

                    if entries.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                        Text(isToday
                             ? "Nothing logged yet today."
                             : "Nothing logged for this day.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        // Grouped by meal, with a subtotal each. "Dinner was 680" is a far more useful fact
                        // than six rows that happen to sum to it — and only non-empty groups render, so a
                        // skipped breakfast leaves no heading implying something was missed.
                        ForEach(mealGroups, id: \.meal) { group in
                            Divider().overlay(StrandPalette.hairline)
                            mealHeader(group)
                            ForEach(group.items) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                }
            }
            .opacity(cardOpacity)
        }
    }

    /// The day's entries in meal groups. Derived rather than stored, so it cannot drift from `entries`.
    private var mealGroups: [MealGrouping.Group<FoodEntry>] {
        MealGrouping.grouped(entries, meal: { $0.displayMeal }, macros: { $0.effectiveMacros })
    }

    @ViewBuilder
    private func mealHeader(_ group: MealGrouping.Group<FoodEntry>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(mealTitle(group.meal))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: NoopMetrics.space2)
            Text("\(intString(group.total.kcal)) kcal")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mealTitle(group.meal)), \(intString(group.total.kcal)) kilocalories")
    }

    private func mealTitle(_ meal: Meal) -> String {
        switch meal {
        case .breakfast: return String(localized: "BREAKFAST")
        case .lunch: return String(localized: "LUNCH")
        case .dinner: return String(localized: "DINNER")
        case .snack: return String(localized: "SNACKS")
        // Not "OTHER" or "UNKNOWN", which sound like something went wrong. These are entries added after
        // the fact, which is a normal thing to do and the day stepper exists to support.
        case .unassigned: return String(localized: "ADDED LATER")
        }
    }

    private func entryRow(_ entry: FoodEntry) -> some View {
        let macros = entry.effectiveMacros
        return HStack(alignment: .top, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.nameSnapshot)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    // Marks a figure a model guessed at. Small and quiet — it is a caveat on the number,
                    // not a warning about the food — but permanent, because weeks later "was that one
                    // estimated?" is unanswerable without it.
                    if entry.macroSource == FoodMacroSource.aiEstimate {
                        Image(systemName: "sparkles")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityLabel("Estimated macros")
                    }
                    // The user's own admitted guess, marked for the same reason and distinctly: weeks
                    // later, "was that the restaurant day I guessed at?" is exactly the question a tight
                    // measured budget sends you back here to answer.
                    if entry.macroSource == FoodMacroSource.roughGuess {
                        Image(systemName: "questionmark.circle")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityLabel("Rough guess")
                    }
                }
                // The portion is spelled out rather than implied, because the stored macros are the
                // item's PER-SERVING figures and the row shows the scaled ones — without this the two
                // numbers look inconsistent to anyone checking the arithmetic.
                Text(portionSummary(entry))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: NoopMetrics.space2)
            Text("\(intString(macros.kcal)) kcal")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Button {
                editingEntry = entry
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit portion for \(entry.nameSnapshot)")
            Button {
                Task {
                    await repo.deleteFoodEntry(id: entry.id)
                    reloadTick += 1
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusCritical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.nameSnapshot)")
        }
    }

    private func portionSummary(_ entry: FoodEntry) -> String {
        let p = portionString(entry.portion)
        let m = entry.effectiveMacros
        let macros = String(localized: "\(p) × serving · \(intString(m.protein))P \(intString(m.carbs))C \(intString(m.fat))F")
        // The time, but ONLY when it is a real one. A backfilled entry's timestamp is the midday sentinel,
        // and printing "12:00" on it would state a time nobody recorded — the same guess-dressed-as-a-fact
        // the sentinel itself exists to avoid.
        guard !FoodEntries.isBackfillSentinel(entry.loggedAt) else { return macros }
        let time = entry.loggedAt.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale))
        return "\(time) · \(macros)"
    }

    // MARK: - Recipes

    /// Recipes get their own section rather than sitting in Recent, because what you do with one is
    /// usually EDIT it — the whole reason a recipe exists is that its parts change — whereas Recent is
    /// a one-tap log. Mixing the two would mean one list with two meanings per row.
    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recipes", overline: recipes.isEmpty ? "None yet" : "\(recipes.count)")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if recipes.isEmpty {
                        Text("A recipe is a food built from other saved foods — a shake, a bowl, a standing dinner. Its calories come from its ingredients, so correcting one ingredient corrects every recipe using it.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(recipes) { recipe in
                            Button {
                                buildingRecipe = RecipeEditTarget(recipe: recipe)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recipe.item.name)
                                            .font(StrandFont.body)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        // States the ingredient count, and says so when one has gone
                                        // missing — a recipe quietly showing a smaller number is the
                                        // failure `RecipeMath` refuses to compute and this refuses to hide.
                                        Text(recipe.isComplete
                                             ? "\(recipe.parts.count) ingredients · per \(recipe.item.servingLabel)"
                                             : "\(recipe.missingIngredientIds.count) ingredient(s) deleted — total is the last known one")
                                            .font(StrandFont.caption)
                                            .foregroundStyle(recipe.isComplete
                                                             ? StrandPalette.textTertiary
                                                             : StrandPalette.strain066)
                                    }
                                    Spacer(minLength: 8)
                                    Text("\(intString(recipe.effectiveMacros.kcal)) kcal")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                    Image(systemName: "chevron.right")
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            if recipe.id != recipes.last?.id {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                    NoopButton("New recipe", systemImage: "plus", kind: .secondary) {
                        buildingRecipe = RecipeEditTarget(recipe: nil)
                    }
                    .disabled(library.isEmpty)
                    if library.isEmpty {
                        Text("Save a food or two first — a recipe is made of them.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Quick add (recents)

    @ViewBuilder private var quickAddSection: some View {
        // Only worth a section once there is something to repeat — an empty "recent foods" card is noise
        // on a fresh install.
        if !library.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Recent", overline: "Log again")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Tap to log one serving. Use Add food to change the portion.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(library.prefix(6)) { item in
                            Button {
                                Task {
                                    await repo.logFood(item: item, portion: 1, day: selectedDay,
                                                       at: logTimestamp)
                                    reloadTick += 1
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(StrandFont.body)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        Text(item.servingLabel)
                                            .font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    Spacer()
                                    Text("\(intString(item.macros.kcal)) kcal")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                    Image(systemName: "plus.circle")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.accent)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Log one serving of \(item.name)")
                            // Editing is the rarer action, so it stays out of the way of the one-tap log
                            // rather than competing with it for the row.
                            .contextMenu {
                                Button { editingItem = item } label: {
                                    Label("Edit \(item.name)", systemImage: "pencil")
                                }
                            }
                        }
                    }
                }
                .opacity(cardOpacity)
            }
        }
    }

    // MARK: - Weight lives elsewhere now
    //
    // Weigh-ins used to sit at the bottom of this screen, behind the day stepper. That was the wrong place
    // twice over: they are not food, and they are the input `AdaptiveExpenditureEngine` gates on just as
    // hard as intake — so the half of the calibration people skip most was also the hardest to reach.
    //
    // They now have `WeightView`, a Today card, and their own quick-action row. Nothing is logged from here
    // any more; this note exists so the next reader looks there rather than assuming it was dropped.

    // MARK: - History

    @ViewBuilder private var historySection: some View {
        // Only shown once at least one day in the window has a figure — a row of empty bars says nothing.
        if history.contains(where: { $0.kcal > 0 }) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last 14 days", overline: "Intake")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        // TAPPABLE, which is the point of this section now rather than it being a
                        // decorative sparkline: the day stepper was the only way back to yesterday and it
                        // lives as two small chevrons in the card above, so nobody found it. A bar you can
                        // tap is how you notice the days are reachable at all.
                        HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                            let peak = max(1, history.map(\.kcal).max() ?? 1)
                            ForEach(Array(history.enumerated()), id: \.element.day) { idx, row in
                                // history is oldest→newest and dayOffset counts backwards from today,
                                // so the offset is the distance from the END of the array.
                                let offset = history.count - 1 - idx
                                Button {
                                    dayOffset = offset
                                } label: {
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(barColor(row.kcal, isSelected: offset == dayOffset))
                                            .frame(height: max(3, 64 * (row.kcal / peak)))
                                        Text(dayInitial(row.day))
                                            .font(StrandFont.caption)
                                            .foregroundStyle(offset == dayOffset
                                                             ? StrandPalette.textPrimary
                                                             : StrandPalette.textTertiary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                // Names the figure AND whether anything was logged, because an empty bar
                                // and a small one are the distinction this whole section exists to show.
                                .accessibilityLabel(row.kcal > 0
                                    ? "\(row.day): \(intString(row.kcal)) kcal — tap to open"
                                    : "\(row.day): nothing logged — tap to open")
                            }
                        }
                        .frame(height: 88, alignment: .bottom)

                        // A day with NO entries is the one worth finding — it is the gap that stops the
                        // expenditure engine reaching a verdict. Stated in words rather than left to be
                        // inferred from a bar that is short for two different reasons.
                        let blanks = history.filter { $0.kcal <= 0 }.count
                        if blanks > 0 {
                            Text(blanks == 1
                                 ? "1 of these days has nothing logged. Tap it to fill it in."
                                 : "\(blanks) of these days have nothing logged. Tap one to fill it in.")
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

    /// A bar's colour carries two facts: whether the day has intake, and whether it is the day on screen.
    /// The selected day is accented so tapping a bar visibly does something — without it the only feedback
    /// is the card above quietly changing its contents.
    private func barColor(_ kcal: Double, isSelected: Bool) -> Color {
        if isSelected { return StrandPalette.accent }
        return kcal > 0 ? StrandPalette.accent.opacity(0.45) : StrandPalette.hairline
    }

    // MARK: - Data

    private func reload() async {
        entries = await repo.foodEntries(day: selectedDay)
        totals = FoodEntries.total(entries)
        dietDayAnchor = await repo.dietDayAnchor()
        library = await repo.foodLibrary()
        // After the library, and passed it explicitly: composing a recipe needs the same snapshot of the
        // library the rest of this screen is rendering.
        recipes = await repo.recipes(library: library)
        // 14 days, matching how far the day stepper will go — a chart that showed a week while the
        // stepper reached two would leave the second week navigable but invisible.
        history = await repo.foodHistory(days: 14)
    }

    // MARK: - Formatting

    private func intString(_ v: Double) -> String {
        String(Int(v.rounded()))
    }

    /// Portions read as "1", "1.5", "0.5" — a trailing ".0" on a whole serving is noise.
    private func portionString(_ p: Double) -> String {
        p == p.rounded() ? String(Int(p)) : String(format: "%.2g", locale: AppLanguage.activeLocale, p)
    }

    /// First letter of the weekday for a `yyyy-MM-dd` key, for the history bars' axis.
    private func dayInitial(_ dayKey: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dayKey) else { return "" }
        let out = DateFormatter()
        out.locale = AppLanguage.activeLocale
        out.dateFormat = "EEEEE"
        return out.string(from: date)
    }
}

// MARK: - Edit portion sheet

/// Re-portion an already-logged entry. Setting it to zero deletes the entry, which is the contract
/// `FoodEntries.updating` holds, so the sheet does not need a separate delete button.
private struct EditPortionSheet: View {
    let entry: FoodEntry
    let onSave: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(entry: FoodEntry, onSave: @escaping (Double) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _draft = State(initialValue: entry.portion == entry.portion.rounded()
                       ? String(Int(entry.portion))
                       : String(entry.portion))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            SectionHeader(LocalizedStringKey(entry.nameSnapshot), overline: "Portion")

            Text("Servings eaten. Set to 0 to remove this entry.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)

            TextField("Servings", text: $draft)
                .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .keyboardType(.decimalPad)
            #endif

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(NoopButtonStyle(.secondary))
                Spacer()
                Button("Save") {
                    if let p = Double(draft.trimmingCharacters(in: .whitespaces)) {
                        onSave(p)
                    }
                    dismiss()
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(Double(draft.trimmingCharacters(in: .whitespaces)) == nil)
            }
            Spacer()
        }
        .padding(NoopMetrics.screenPadding)
        .frame(minWidth: 320, minHeight: 260)
    }
}
