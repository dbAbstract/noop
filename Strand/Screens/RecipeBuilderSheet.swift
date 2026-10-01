import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Build a recipe out of saved foods
//
// A recipe is a food whose macros nobody types. Its numbers come from its ingredients, recomputed every
// time one of them is corrected — so fixing the whey's protein fixes every shake that contains it, and
// there is no second figure to go stale.
//
// WHAT THIS SCREEN DOES NOT HAVE is a macro entry form. That is the whole point: the totals panel is
// read-only and derived, because a typed total beside computed ingredients is two answers to one question
// and the repo's hard rules say not to show the fact twice.
//
// AN INGREDIENT NEED NOT BE SAVED. Two ways to add one:
//
//   • Pick a SAVED food — its macros then resolve live, so correcting that food corrects every recipe
//     containing it. The right choice for anything you also eat on its own.
//   • Type an UNSAVED one — its macros are held by the recipe itself. The right choice for anything that
//     exists only as part of this dish. A bulgogi marinade is soy sauce, oyster sauce, sesame oil and
//     sugar; forcing each into the library to build one recipe would fill the food picker with things
//     nobody logs on their own, which is the same reason one-off meals default to not being saved.
//
// The trade is explicit and stated in the UI: an unsaved ingredient cannot be corrected in one place
// later, because there is no one place. It also cannot go missing, for the same reason.
struct RecipeBuilderSheet: View {
    /// nil creates a new recipe; non-nil edits an existing one.
    let existing: Recipe?
    /// The library, which is also the pool of possible ingredients.
    let library: [FoodItem]
    let onSaved: () -> Void
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository

    @State private var name = ""
    @State private var servingLabel = ""
    @State private var parts: [RecipePartRef] = []
    /// Per-part quantity text, keyed by part id. Text rather than Double so a half-typed "0." does not
    /// momentarily read as an invalid quantity and get dropped mid-keystroke.
    @State private var quantityDrafts: [UUID: String] = [:]
    @State private var query = ""
    @State private var saving = false
    @State private var confirmingDelete = false

    // Unsaved-ingredient draft. Its own fields rather than a nested sheet: a second modal over a
    // half-built recipe is how you lose the recipe when the inner one is cancelled.
    @State private var addingInline = false
    @State private var inlineName = ""
    @State private var inlineServing = ""
    @State private var inlineKcal = ""
    @State private var inlineProtein = ""
    @State private var inlineCarbs = ""
    @State private var inlineFat = ""
    @State private var inlineFiber = ""

    private var byId: [UUID: FoodItem] {
        Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
    }

    private var inlineMacros: MacroTotals {
        MacroTotals(kcal: number(inlineKcal), protein: number(inlineProtein), carbs: number(inlineCarbs),
                    fat: number(inlineFat), fiber: number(inlineFiber))
    }

    private var canAddInline: Bool {
        !inlineName.trimmingCharacters(in: .whitespaces).isEmpty && !inlineMacros.isEmpty
    }

    /// Blank reads as 0 — a sauce with no fibre listed is the common case, and forcing a 0 into every
    /// box is friction for no gain. Matches `AddFoodSheet`.
    private func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// A recipe may not contain itself, and an ingredient already in the list is added by bumping its
    /// quantity rather than appearing twice.
    private var candidates: [FoodItem] {
        let used = Set(parts.compactMap { $0.foodItemId })
        return FoodLibrary.matching(library, query: query)
            .filter { $0.id != existing?.item.id && !used.contains($0.id) }
    }

    /// The live total, composed from the current drafts — so the panel always describes what would be
    /// saved, not what was saved last.
    private var composed: MacroTotals {
        RecipeMath.compose(parts.map {
            RecipePart(macrosPerServing: $0.macrosPerServing(in: byId) ?? .zero,
                       quantity: quantity(of: $0))
        })
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !parts.isEmpty
            && parts.allSatisfy { RecipeMath.isValidQuantity(quantity(of: $0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                detailsSection
                ingredientsSection
                totalsSection
                addIngredientSection
                actions
            }
            .padding(NoopMetrics.screenPadding)
        }
        .frame(minWidth: 380, minHeight: 560)
        .onAppear(perform: seed)
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(existing == nil ? "New recipe" : "Edit recipe", overline: "Recipe")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    TextField("Name — e.g. Protein shake", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("One serving is — e.g. 1 glass", text: $servingLabel)
                        .textFieldStyle(.roundedBorder)
                    Text("The serving label is what a portion of 1 means when you log this. The macros come from the ingredients below — you never type them here.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Ingredients

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Ingredients", overline: "\(parts.count)")
            NoopCard {
                if parts.isEmpty {
                    Text("No ingredients yet. Pick saved foods below — a recipe with no parts has nothing to add up.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        ForEach(parts) { part in
                            ingredientRow(part)
                            if part.id != parts.last?.id {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ingredientRow(_ part: RecipePartRef) -> some View {
        // Resolved through the part, so a library reference and an unsaved ingredient render the same way
        // without this view needing to know which it has. nil means ONLY the one case that matters: a
        // reference whose food has been deleted.
        let resolvedName = part.name(in: byId)
        let macros = part.macrosPerServing(in: byId)
        let isInline = part.foodItemId == nil
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // A deleted ingredient is NAMED as missing rather than dropped from the list. Dropping
                    // it would make the recipe's total quietly shrink to a plausible wrong number; saying
                    // so leaves a problem the user can fix.
                    Text(resolvedName ?? "Missing ingredient")
                        .font(StrandFont.body)
                        .foregroundStyle(macros == nil ? StrandPalette.textTertiary
                                                       : StrandPalette.textPrimary)
                    // Marks which ingredients live only in this recipe, because that decides where you
                    // go to correct one later.
                    if isInline {
                        Text("unsaved")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Text(macros.map { m in
                        let per = part.servingLabel(in: byId) ?? ""
                        return per.isEmpty
                            ? "\(Int(m.kcal.rounded())) kcal"
                            : "per \(per) · \(Int(m.kcal.rounded())) kcal"
                     } ?? "This food was deleted from your library")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            TextField("1", text: quantityBinding(part))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .accessibilityLabel("Quantity of \(resolvedName ?? "missing ingredient")")
            Button {
                remove(part)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(resolvedName ?? "missing ingredient")")
        }
    }

    // MARK: - Derived totals

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("One serving", overline: "Computed")
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(composed.kcal.rounded())) kcal")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(String(format: "P %.0f g · C %.0f g · F %.0f g · fibre %.0f g",
                                composed.protein, composed.carbs, composed.fat, composed.fiber))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Derived from the ingredients, never stored as its own figure. Correct an ingredient and every recipe using it follows.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Adding

    private var addIngredientSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Add an ingredient", overline: "Saved or not")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if !library.isEmpty {
                        TextField("Search saved foods", text: $query)
                            .textFieldStyle(.roundedBorder)
                        if candidates.isEmpty {
                            Text(query.isEmpty
                                 ? "Everything in your library is already in this recipe."
                                 : "No saved food matches that — add it as an unsaved ingredient below.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(candidates.prefix(8)) { item in
                            Button {
                                add(item)
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
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(StrandPalette.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Divider().overlay(StrandPalette.hairline)
                    }

                    inlineDraft
                }
            }
        }
    }

    /// Add an ingredient that is NOT in the library and will not be added to it.
    ///
    /// Inline rather than a nested sheet, deliberately: a second modal over a half-built recipe is how
    /// the recipe gets lost when the inner one is cancelled.
    @ViewBuilder
    private var inlineDraft: some View {
        if addingInline {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Unsaved ingredient")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                TextField("Name — e.g. Soy sauce", text: $inlineName)
                    .textFieldStyle(.roundedBorder)
                TextField("One serving is — e.g. 1 tbsp", text: $inlineServing)
                    .textFieldStyle(.roundedBorder)
                // Per SERVING, matching every other macro entry in the app, so one convention covers
                // both ingredient kinds and `RecipeMath` can scale them identically.
                HStack(spacing: NoopMetrics.space2) {
                    macroField("kcal", $inlineKcal)
                    macroField("P", $inlineProtein)
                    macroField("C", $inlineCarbs)
                    macroField("F", $inlineFat)
                    macroField("Fib", $inlineFiber)
                }
                Text("Macros per serving. This ingredient lives in this recipe only — it will not appear in your food library, and correcting it later means editing this recipe.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Cancel", kind: .secondary) { resetInlineDraft() }
                    NoopButton("Add", kind: .primary) { addInline() }
                        .disabled(!canAddInline)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                NoopButton("Add an unsaved ingredient", systemImage: "plus", kind: .secondary) {
                    addingInline = true
                }
                Text("For something that only exists in this dish — a sauce, a marinade component. Nothing is added to your food library.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func macroField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            TextField("0", text: binding)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .accessibilityLabel(label)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Cancel", kind: .secondary) { dismiss() }
                NoopButton(existing == nil ? "Create recipe" : "Save recipe", kind: .primary) { save() }
                    .disabled(!canSave || saving)
            }
            if existing != nil {
                if confirmingDelete {
                    // Two-step, because deleting a recipe is not undoable from here. Logged history
                    // survives regardless — every entry carries its own snapshot — and the copy says so,
                    // since "delete" on a food log reasonably reads as "lose my data".
                    Text("Delete this recipe? Days you have already logged keep their entries — each one stored its own numbers when you logged it.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: NoopMetrics.space3) {
                        NoopButton("Keep it", kind: .secondary) { confirmingDelete = false }
                        NoopButton("Delete", kind: .destructive) { delete() }
                    }
                } else {
                    Button("Delete recipe") { confirmingDelete = true }
                        .buttonStyle(.plain)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: - Editing helpers

    private func seed() {
        guard let existing, parts.isEmpty else { return }
        name = existing.item.name
        servingLabel = existing.item.servingLabel
        parts = existing.parts
        quantityDrafts = Dictionary(uniqueKeysWithValues:
            existing.parts.map { ($0.id, Self.format($0.quantity)) })
    }

    private func quantity(of part: RecipePartRef) -> Double {
        Double((quantityDrafts[part.id] ?? "").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func quantityBinding(_ part: RecipePartRef) -> Binding<String> {
        Binding(get: { quantityDrafts[part.id] ?? "" },
                set: { quantityDrafts[part.id] = $0 })
    }

    private func add(_ item: FoodItem) {
        let part = RecipePartRef(source: .library(item.id), quantity: 1)
        parts.append(part)
        quantityDrafts[part.id] = "1"
        query = ""
    }

    private func addInline() {
        let part = RecipePartRef(
            source: .inline(name: inlineName.trimmingCharacters(in: .whitespaces),
                            // A blank serving label would make the row read "1 ×" with no unit; a plain
                            // default at least states the unit is unspecified. Matches `AddFoodSheet`.
                            servingLabel: inlineServing.trimmingCharacters(in: .whitespaces).isEmpty
                                ? String(localized: "1 serving")
                                : inlineServing.trimmingCharacters(in: .whitespaces),
                            macros: inlineMacros),
            quantity: 1)
        parts.append(part)
        quantityDrafts[part.id] = "1"
        resetInlineDraft()
    }

    private func resetInlineDraft() {
        addingInline = false
        inlineName = ""; inlineServing = ""
        inlineKcal = ""; inlineProtein = ""; inlineCarbs = ""; inlineFat = ""; inlineFiber = ""
    }

    private func remove(_ part: RecipePartRef) {
        parts.removeAll { $0.id == part.id }
        quantityDrafts[part.id] = nil
    }

    private func save() {
        saving = true
        // The quantity the STORE sees is the parsed draft, so what is persisted is exactly what the
        // totals panel was showing — rather than the stale `quantity` the part was created with.
        let resolved = parts.map {
            RecipePartRef(id: $0.id, source: $0.source, quantity: quantity(of: $0))
        }
        let item = FoodItem(id: existing?.item.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespaces),
                            servingLabel: servingLabel.trimmingCharacters(in: .whitespaces),
                            macros: composed,
                            createdAt: existing?.item.createdAt ?? Date(),
                            lastUsedAt: existing?.item.lastUsedAt)
        Task {
            await repo.saveRecipe(item: item, parts: resolved, library: library)
            onSaved()
            dismiss()
        }
    }

    private func delete() {
        guard let existing else { return }
        Task {
            await repo.deleteRecipe(id: existing.item.id)
            onDeleted()
            dismiss()
        }
    }

    /// Trim a trailing ".0" so an integer quantity reads as "2" rather than "2.0" in a text field.
    static func format(_ q: Double) -> String {
        q == q.rounded() && abs(q) < 1e9 ? String(Int(q)) : String(format: "%g", q)
    }
}

/// What the builder sheet is open for. `.sheet(item:)` needs an `Identifiable`, and a bare `Recipe?`
/// cannot express "create a new one" — nil would mean the sheet is closed. Mirrors `WeightEditTarget`.
struct RecipeEditTarget: Identifiable, Equatable {
    /// nil = create.
    let recipe: Recipe?
    var id: String { recipe?.item.id.uuidString ?? "new" }
}
