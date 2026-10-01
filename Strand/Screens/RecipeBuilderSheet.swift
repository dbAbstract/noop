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
// INGREDIENTS MUST ALREADY BE IN THE LIBRARY. Adding a brand-new food from inside here would mean two
// nested creation flows and a half-saved recipe if the inner one is cancelled. Saving the ingredient
// first is one extra step on a screen the user visits rarely, and it keeps both flows atomic.
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

    private var byId: [UUID: FoodItem] {
        Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
    }

    /// A recipe may not contain itself, and an ingredient already in the list is added by bumping its
    /// quantity rather than appearing twice.
    private var candidates: [FoodItem] {
        let used = Set(parts.map { $0.foodItemId })
        return FoodLibrary.matching(library, query: query)
            .filter { $0.id != existing?.item.id && !used.contains($0.id) }
    }

    /// The live total, composed from the current drafts — so the panel always describes what would be
    /// saved, not what was saved last.
    private var composed: MacroTotals {
        RecipeMath.compose(parts.map {
            RecipePart(macrosPerServing: byId[$0.foodItemId]?.macros ?? .zero,
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
                if !candidates.isEmpty { addIngredientSection }
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
        let item = byId[part.foodItemId]
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                // A deleted ingredient is NAMED as missing rather than dropped from the list. Dropping it
                // would make the recipe's total quietly shrink to a plausible wrong number; saying so
                // leaves a problem the user can fix.
                Text(item?.name ?? "Missing ingredient")
                    .font(StrandFont.body)
                    .foregroundStyle(item == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text(item.map { "per \($0.servingLabel) · \(Int($0.macros.kcal.rounded())) kcal" }
                     ?? "This food was deleted from your library")
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
                .accessibilityLabel("Quantity of \(item?.name ?? "missing ingredient")")
            Button {
                remove(part)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item?.name ?? "missing ingredient")")
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
            SectionHeader("Add an ingredient", overline: "Library")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    TextField("Search saved foods", text: $query)
                        .textFieldStyle(.roundedBorder)
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
                    Text("Only foods already in your library can be ingredients. Save a food first, then add it here.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        let part = RecipePartRef(foodItemId: item.id, quantity: 1)
        parts.append(part)
        quantityDrafts[part.id] = "1"
        query = ""
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
            RecipePartRef(id: $0.id, foodItemId: $0.foodItemId, quantity: quantity(of: $0))
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
