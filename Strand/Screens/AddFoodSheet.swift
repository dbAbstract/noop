import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Add food (v0)
//
// Two ways in, one exit: pick a saved item from the library, or type a new one. Either way the sheet hands
// back a `FoodItem` plus a portion, and the caller saves the item and logs the entry. Picking an existing
// item re-saves it unchanged, which is what stamps `lastUsedAt` and keeps the recents list meaningful.
//
// Every macro here is typed by the user. There is no food database, no barcode lookup and no network call,
// so a number on this screen is never something NOOP invented — matching the rest of the app's posture.
//
// DEFERRED (v1): `estimateMacros` below is the seam where the Coach LLM will fill these fields from a plain
// description. It is deliberately left unimplemented rather than stubbed with a fake, because a silently
// fabricated macro is exactly the failure this codebase refuses elsewhere.
struct AddFoodSheet: View {
    let library: [FoodItem]
    /// The recipes among `library`, already composed against it. Passed in rather than fetched here so
    /// this sheet stays a pure view over data the caller loaded in one consistent read.
    let recipes: [Recipe]
    /// Called with the food, the portion, and whether to keep it in the library.
    let onLog: (FoodItem, Double, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coach: AICoachEngine

    @State private var estimating = false
    @State private var estimateNote: String?
    /// Set once an estimate fills the fields, cleared the moment the user edits any of them — at which
    /// point the numbers are theirs, not the model's, and the provenance would be a lie.
    @State private var macrosAreEstimated = false

    @State private var query = ""
    @State private var selected: FoodItem?
    @State private var portionDraft = "1"
    /// Log-time ingredient quantities for a selected recipe, keyed by part id.
    ///
    /// LOCAL TO THIS LOG, deliberately. "I made the shake with two scoops today" is a different meal, not
    /// a correction to the recipe — so this never writes back, and the saved recipe is untouched. Seeded
    /// from the recipe on selection and discarded when the sheet closes.
    @State private var partDrafts: [UUID: String] = [:]

    // New-item fields
    @State private var name = ""
    @State private var servingLabel = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var fiber = ""

    /// Opt-IN, default off. Most meals are eaten once; saving each would fill the library with one-time
    /// entries and make the picker useless for the few foods actually repeated. The log is identical
    /// either way — this only decides whether it can be re-logged in one tap later.
    @State private var saveForReuse = false

    /// The user admits this is a guess — a restaurant meal, a day out, something with no label.
    ///
    /// Exists to compete with the real alternative, which is logging NOTHING. An omitted day is worse
    /// evidence than a bad guess twice over: it holes the coverage the adaptive engine gates on, and it
    /// biases that engine DOWNWARD, because the days people skip are the big ones. Marking the guess is
    /// what lets the engine widen its interval honestly rather than treating the figure as a label.
    @State private var isRoughGuess = false

    /// Which half of the sheet is showing.
    ///
    /// It used to open straight onto the CREATE form with the saved-food list below it, so the first thing
    /// you saw was a blank macro form — and whether you were logging something new or picking something old
    /// was genuinely unclear. Picking is the common case by a wide margin, so it is the default and creating
    /// is a deliberate step away from it.
    enum Mode { case pick, create }
    @State private var mode: Mode = .pick

    private var isCreating: Bool { selected == nil }

    /// The selected item as a recipe, if it is one. Having parts IS being a recipe — there is no flag.
    private var selectedRecipe: Recipe? {
        guard let selected else { return nil }
        return recipes.first { $0.item.id == selected.id }
    }

    /// What one serving of the selected recipe comes to under the CURRENT log-time quantities.
    ///
    /// Recomposed from the drafts rather than read off the item, so the figure on screen is the figure
    /// that gets logged — the two-readouts-must-not-disagree rule applied to a tweak the user just made.
    private var tweakedRecipeMacros: MacroTotals? {
        guard let recipe = selectedRecipe else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        return RecipeMath.compose(recipe.parts.map { part in
            // Resolved through the part, so an unsaved ingredient contributes its own macros while a
            // library reference still resolves live.
            RecipePart(macrosPerServing: part.macrosPerServing(in: byId) ?? .zero,
                       quantity: Double((partDrafts[part.id] ?? "").trimmingCharacters(in: .whitespaces)) ?? 0)
        })
    }

    /// True once a log-time quantity differs from the recipe's own, so the UI can say the log will not
    /// match the saved recipe — a silent divergence is the thing to avoid, not the divergence itself.
    private var recipeIsTweaked: Bool {
        guard let recipe = selectedRecipe else { return false }
        return recipe.parts.contains { part in
            let draft = Double((partDrafts[part.id] ?? "").trimmingCharacters(in: .whitespaces)) ?? 0
            return abs(draft - part.quantity) > 1e-9
        }
    }

    private var portion: Double? {
        let p = Double(portionDraft.trimmingCharacters(in: .whitespaces))
        guard let p, p.isFinite, p > 0 else { return nil }
        return p
    }

    /// The macros as typed. Blank fields read as 0 rather than as an error — a food with no fibre listed is
    /// the common case, and forcing a 0 into every box is friction for no gain.
    private var draftMacros: MacroTotals {
        MacroTotals(kcal: number(kcal), protein: number(protein), carbs: number(carbs),
                    fat: number(fat), fiber: number(fiber))
    }

    private var canLog: Bool {
        guard portion != nil else { return false }
        if let selected { return !selected.macros.isEmpty }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && !draftMacros.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                sheetTitle
                switch mode {
                case .pick:
                    if selected != nil { selectedSection }
                    if selectedRecipe != nil { recipeTweakSection }
                    librarySection
                    newFoodEntry
                case .create:
                    newItemSection
                }
                // Only once something is actually chosen or typed — a portion stepper above an empty form
                // is a control for a quantity of nothing.
                if selected != nil || mode == .create { portionSection }
                actions
            }
            .padding(NoopMetrics.screenPadding)
            // Space under the title, which sat hard against the status bar.
            .padding(.top, 8)
        }
        // Tap anywhere off a field to put the keyboard away. The macro fields are a numeric pad with no
        // return key, so without this there is no way to dismiss it at all.
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .frame(minWidth: 360, minHeight: 520)
    }

    private var sheetTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(mode == .pick ? "Log food" : "New food")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(mode == .pick
                 ? "Pick something you have logged before, or add something new."
                 : "Enter it once and it is yours to log in a tap next time.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The way into creating, from the picking half.
    private var newFoodEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoopButton("Add something new", systemImage: "plus", kind: .secondary) {
                dismissKeyboard()
                selected = nil
                mode = .create
            }
            if library.isEmpty {
                Text("Nothing saved yet — add your first food and it will be here next time.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        #endif
    }

    // MARK: - Library picker

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Or pick a saved food", overline: "Library")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    TextField("Search saved foods", text: $query)
                        .textFieldStyle(.roundedBorder)

                    let matches = FoodLibrary.matching(library, query: query)
                    if matches.isEmpty {
                        Text("No saved food matches that. Type a new one below.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        ForEach(matches.prefix(8)) { item in
                            let recipe = recipes.first { $0.item.id == item.id }
                            Button {
                                // Selecting swaps the sheet out of create-mode; tapping the same row again
                                // returns to it, so there is always a way back to typing a new food.
                                selected = (selected?.id == item.id) ? nil : item
                                seedPartDrafts()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(StrandFont.body)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        // A recipe row says so, because its kcal figure means something
                                        // different from a typed one: it is the sum of other rows in this
                                        // same list, and changing one of those changes this.
                                        Text(recipe.map { "\($0.parts.count) ingredients · \(item.servingLabel)" }
                                             ?? item.servingLabel)
                                            .font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    Spacer()
                                    Text("\(Int((recipe?.effectiveMacros ?? item.macros).kcal.rounded())) kcal")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                    if selected?.id == item.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(StrandPalette.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var selectedSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Selected", overline: "Food")
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected?.name ?? "")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(macroSummary(selected?.macros ?? .zero, per: selected?.servingLabel ?? ""))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Enter a different food instead") {
                        selected = nil
                        partDrafts = [:]
                    }
                        .buttonStyle(.plain)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    // MARK: - Recipe ingredients, tweakable for this log only

    /// Lets the user say "two scoops today" without editing the recipe.
    ///
    /// This is the snapshot principle the food log already runs on, one level down: the entry stores what
    /// it stored, and the library keeps its own definition. A tweak here changes the macros that get
    /// snapshotted into THIS entry and nothing else — which is why the sheet states, rather than hides,
    /// that the log and the saved recipe have parted company.
    @ViewBuilder
    private var recipeTweakSection: some View {
        if let recipe = selectedRecipe {
            let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Ingredients", overline: "This log only")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        ForEach(recipe.parts) { part in
                            let ingredientName = part.name(in: byId)
                            let hasMacros = part.macrosPerServing(in: byId) != nil
                            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ingredientName ?? "Missing ingredient")
                                        .font(StrandFont.body)
                                        .foregroundStyle(hasMacros ? StrandPalette.textPrimary
                                                                   : StrandPalette.textTertiary)
                                    Text(part.servingLabel(in: byId) ?? "Deleted from your library")
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer(minLength: 8)
                                TextField("1", text: partBinding(part))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                    .accessibilityLabel("Quantity of \(ingredientName ?? "missing ingredient")")
                            }
                        }
                        if recipeIsTweaked {
                            Text("This log uses your changed amounts. The saved recipe keeps its own — editing it is a separate step on the food log screen.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Change an amount to log a one-off variation. The saved recipe is never altered from here.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func partBinding(_ part: RecipePartRef) -> Binding<String> {
        Binding(get: { partDrafts[part.id] ?? "" },
                set: { partDrafts[part.id] = $0 })
    }

    /// Reset the log-time quantities to whatever the newly selected recipe defines. Clearing them for a
    /// non-recipe matters as much: a stale draft from a previously selected recipe must not survive into
    /// a plain food's log.
    private func seedPartDrafts() {
        guard let recipe = selectedRecipe else {
            partDrafts = [:]
            return
        }
        partDrafts = Dictionary(uniqueKeysWithValues:
            recipe.parts.map { ($0.id, RecipeBuilderSheet.format($0.quantity)) })
    }

    // MARK: - New item

    private var newItemSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What did you eat?", overline: "Per serving")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    // Only meaningful for something being saved: a one-off is logged at one portion of
                    // itself, so asking "what is one serving?" is a question with no consequence.
                    if saveForReuse {
                        TextField("One serving is… (e.g. 1 scoop, 100 g)", text: $servingLabel)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider().overlay(StrandPalette.hairline)

                    estimateRow
                    macroField(String(localized: "Calories (kcal)"), $kcal)
                    macroField(String(localized: "Protein (g)"), $protein)
                    macroField(String(localized: "Carbs (g)"), $carbs)
                    macroField(String(localized: "Fat (g)"), $fat)
                    macroField(String(localized: "Fibre (g)"), $fiber)

                    // The second opinion, never a correction. `NutritionMath` computes what the typed
                    // macros imply by Atwater; if that disagrees with the typed calories by more than the
                    // tolerance, say so and leave both numbers exactly as entered.
                    Divider().overlay(StrandPalette.hairline)
                    Toggle(isOn: $saveForReuse) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save for next time")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Only worth it for something you eat often — it'll show up in your list to log in one tap.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)

                    Divider().overlay(StrandPalette.hairline)
                    Toggle(isOn: $isRoughGuess) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This is a rough guess")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            // States WHY it is worth ticking rather than skipping the day, because that is
                            // the actual decision being made here and the honest answer is unobvious.
                            Text("For a restaurant meal or a day out. A wide guess is much better than logging nothing — a skipped day both leaves a gap and quietly drags your measured burn down. Flagging it lets NOOP widen its own margin instead of trusting the number.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)

                    if NutritionMath.kcalLooksInconsistent(draftMacros) {
                        let derived = Int(NutritionMath.kcalFromMacros(draftMacros).rounded())
                        Text("Those macros come to about \(derived) kcal. Both numbers are kept as you typed them — this is just a heads-up in case one is a slip.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The AI estimate affordance.
    ///
    /// Shown only when the Coach is actually usable, so a user who has never set a key is not offered a
    /// button that cannot work. User-initiated by construction — nothing estimates on appear or on a
    /// field change, because nothing may reach the network as a side effect of typing.
    @ViewBuilder private var estimateRow: some View {
        if coach.isConfigured && coach.dataConsent && CoachBriefScheduler.coachMasterEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        Task { await runEstimate() }
                    } label: {
                        Label(estimating ? "Estimating…" : "Estimate from the name",
                              systemImage: "sparkles")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(estimating || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if estimating { ProgressView().controlSize(.small) }
                }
                if let estimateNote {
                    Text(estimateNote)
                        .font(StrandFont.caption)
                        .foregroundStyle(macrosAreEstimated ? StrandPalette.textTertiary
                                                            : StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Fills the macro fields from the model, leaving them EDITABLE.
    ///
    /// The fields are pre-filled rather than applied, because the user tapping Log is what turns an
    /// estimate into a figure they have stated. Nothing is logged without passing under their eyes.
    private func runEstimate() async {
        estimating = true
        estimateNote = nil
        defer { estimating = false }

        guard let result = await coach.estimateMacros(describing: name) else {
            estimateNote = String(localized: "Couldn't reach your AI provider. Check it in Settings, or just type the numbers.")
            return
        }
        switch result {
        case .success(let m):
            kcal = trimmed(m.kcal)
            protein = trimmed(m.protein)
            carbs = trimmed(m.carbs)
            fat = trimmed(m.fat)
            fiber = trimmed(m.fiber)
            macrosAreEstimated = true
            estimateNote = String(localized: "Estimated — check these against the label if you have one, and edit anything that looks off.")
        case .failure(let why):
            // Each reason gets its own line, because the user's remedy differs: retrying helps a
            // truncated reply and will not help a model that cannot do this at all.
            macrosAreEstimated = false
            switch why {
            case .inconsistent:
                estimateNote = String(localized: "The estimate contradicted itself, so it was discarded rather than shown. Try again, or type the numbers.")
            case .truncated:
                estimateNote = String(localized: "The reply was cut off. Try again — if it keeps happening, the model's context may be too small.")
            case .noJSON, .noCalories:
                estimateNote = String(localized: "Couldn't read an estimate from that reply. Try rephrasing, or type the numbers.")
            }
        }
    }

    private func trimmed(_ v: Double) -> String {
        guard v > 0 else { return "" }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func macroField(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            TextField("0", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
                // Any hand edit makes these the user's numbers, so the estimate marker has to go — a
                // corrected figure labelled "AI estimate" would be the wrong provenance, recorded
                // permanently.
                .onChangeCompat(of: binding.wrappedValue) { _ in macrosAreEstimated = false }
            #if os(iOS)
                .keyboardType(.decimalPad)
            #endif
        }
    }

    // MARK: - Portion + actions

    private var portionSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Portion", overline: "Servings")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space2) {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { p in
                            Button(p == p.rounded() ? String(Int(p)) : String(format: "%.1f", p)) {
                                portionDraft = p == p.rounded() ? String(Int(p)) : String(p)
                            }
                            .buttonStyle(NoopButtonStyle(.secondary))
                        }
                        TextField("Servings", text: $portionDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 90)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                    }

                    // Shows exactly what will be stored, so the portion multiplier is never a hidden step.
                    if let p = portion {
                        // Tweaked recipe macros win over the item's stored figure — otherwise the preview
                        // would state one number and the entry would store another.
                        let base = tweakedRecipeMacros ?? selected?.macros ?? draftMacros
                        let scaled = NutritionMath.scaled(base, portion: p)
                        Text("Logs \(Int(scaled.kcal.rounded())) kcal · \(Int(scaled.protein.rounded()))P \(Int(scaled.carbs.rounded()))C \(Int(scaled.fat.rounded()))F")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(NoopButtonStyle(.secondary))
            Spacer()
            Button("Log") {
                guard let p = portion else { return }
                // A TWEAKED recipe logs as a one-off: `saveToLibrary: false` records the meal in full but
                // writes nothing back to the library. That is load-bearing, not a nicety — the caller
                // re-saves the item it is handed in order to stamp `lastUsedAt`, so passing `true` here
                // would push today's two-scoop macros onto the saved recipe and quietly redefine it for
                // every future log. One-off is also exactly what this flag already means elsewhere in the
                // sheet, so the tweak reuses a path rather than inventing one.
                let keep = !recipeIsTweaked && (selected != nil || saveForReuse)
                onLog(resolvedItem(), p, keep)
                dismiss()
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .disabled(!canLog)
        }
    }

    /// The item to save + log: the picked one unchanged, or a new one built from the typed fields.
    private func resolvedItem() -> FoodItem {
        if var selected {
            // A tweaked recipe logs its tweaked macros. Only the returned COPY carries them — the caller
            // re-saves the picked item to stamp `lastUsedAt`, so handing back the original macros here is
            // what keeps "this log only" true.
            if let tweaked = tweakedRecipeMacros, recipeIsTweaked {
                selected.macros = tweaked
            }
            return selected
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedServing = servingLabel.trimmingCharacters(in: .whitespaces)
        // A rough guess takes precedence over the AI marker. Both say "not a label figure", but the
        // user's own admission is the one that should survive, and it is what the engine reads.
        let source = isRoughGuess ? FoodMacroSource.roughGuess
                   : (macrosAreEstimated ? FoodMacroSource.aiEstimate : nil)
        return FoodItem(macroSource: source,
                        name: trimmedName,
                        // A blank serving label would make the logged row read "1 × serving" with no idea
                        // what a serving is; a plain default at least states the unit is unspecified.
                        servingLabel: trimmedServing.isEmpty ? String(localized: "1 serving") : trimmedServing,
                        macros: draftMacros)
    }

    private func macroSummary(_ m: MacroTotals, per serving: String) -> String {
        let head = serving.isEmpty ? "" : "\(serving) · "
        return "\(head)\(Int(m.kcal.rounded())) kcal · \(Int(m.protein.rounded()))P \(Int(m.carbs.rounded()))C \(Int(m.fat.rounded()))F"
    }

    /// Blank/invalid reads as 0 — see `draftMacros`.
    private func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    // MARK: - v1 seam
    //
    // Estimate macros for a free-text description ("two scrambled eggs on sourdough") via the Coach LLM.
    //
    // Reuses `AIProviderClient.send(key:model:systemPrompt:messages:session:)`, which already accepts an
    // arbitrary system prompt, with `AICoachEngine.generateBrief()` as the precedent for a headless call
    // that never touches the visible transcript. Three things must be built before this is safe:
    //
    //   1. A structured-output path. Nothing in this codebase asks an LLM for JSON today, and the default
    //      coach system prompt says "No code blocks", so this needs its own prompt plus tolerant parsing of
    //      fenced/prose-wrapped JSON into `MacroTotals`, with clamping.
    //   2. The egress gates, honoured in this order: `noop.coachEnabled` checked AT EGRESS (not just at the
    //      UI), a user-supplied key, and `ai.dataConsent`.
    //   3. A visible provenance marker on the resulting item, so an estimated macro is never mistaken for
    //      one off a label. An estimate that looks like a measurement is the failure mode to avoid.
}
