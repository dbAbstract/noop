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
    /// Called with the food, the portion, and whether to keep it in the library.
    let onLog: (FoodItem, Double, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: FoodItem?
    @State private var portionDraft = "1"

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

    private var isCreating: Bool { selected == nil }

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
                if isCreating { newItemSection } else { selectedSection }
                if !library.isEmpty { librarySection }
                portionSection
                actions
            }
            .padding(NoopMetrics.screenPadding)
        }
        .frame(minWidth: 360, minHeight: 520)
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
                            Button {
                                // Selecting swaps the sheet out of create-mode; tapping the same row again
                                // returns to it, so there is always a way back to typing a new food.
                                selected = (selected?.id == item.id) ? nil : item
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
                                    Text("\(Int(item.macros.kcal.rounded())) kcal")
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
                    Button("Enter a different food instead") { selected = nil }
                        .buttonStyle(.plain)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
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

    private func macroField(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            TextField("0", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
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
                        let base = selected?.macros ?? draftMacros
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
                onLog(resolvedItem(), p, selected != nil || saveForReuse)
                dismiss()
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .disabled(!canLog)
        }
    }

    /// The item to save + log: the picked one unchanged, or a new one built from the typed fields.
    private func resolvedItem() -> FoodItem {
        if let selected { return selected }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedServing = servingLabel.trimmingCharacters(in: .whitespaces)
        return FoodItem(name: trimmedName,
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
