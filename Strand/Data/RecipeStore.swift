import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Recipes: a food whose macros nobody typed
//
// A recipe is an ordinary `FoodItem` that happens to have `recipeComponent` rows. There is NO flag on the
// item saying "this is a recipe" — having parts IS being a recipe. That is deliberate: a flag is a second
// answer to a question the components already answer, and the two can disagree (a flag set on an item
// whose last ingredient was removed, a recipe whose flag never got written). The derived form cannot.
//
// The item's own stored `macros` are not used while the recipe is complete — `RecipeMath` composes the
// total from the parts on every read, so correcting an ingredient corrects every recipe containing it.
// The stored macros are kept in sync anyway, as a CACHE for exactly one case: the food picker renders the
// whole library at once, and a recipe whose ingredient has since been deleted has no computable total.
// Rather than show a blank row there, the last-known figure is shown and marked incomplete.
//
// LOGGING A RECIPE SNAPSHOTS, like any other food. The computed total is copied into the entry at log
// time, so fixing the whey's protein next month cannot rewrite what last Tuesday says you ate — and a
// log-time quantity tweak therefore affects only that log, never the saved recipe.

/// A recipe as the UI handles it: the item, its parts, and what they add up to.
struct Recipe: Identifiable, Equatable {
    var item: FoodItem
    /// Ingredients in the user's arranged order. Each pairs a library item id with its quantity.
    var parts: [RecipePartRef]
    /// The composed total, or nil when an ingredient has been deleted from the library.
    var composed: MacroTotals?
    /// Ingredient ids named by the recipe but no longer in the library.
    var missingIngredientIds: [UUID]

    var id: UUID { item.id }
    var isComplete: Bool { missingIngredientIds.isEmpty }

    /// What to log, or show, for one serving.
    ///
    /// Falls back to the item's cached macros when a part is missing — see the file header. A stale
    /// figure the user can be TOLD is stale beats a blank row they cannot interpret, and the
    /// `isComplete` flag travels alongside so the UI never presents it as current.
    var effectiveMacros: MacroTotals { composed ?? item.macros }
}

/// One ingredient reference, as stored.
struct RecipePartRef: Identifiable, Equatable {
    let id: UUID
    var foodItemId: UUID
    var quantity: Double

    init(id: UUID = UUID(), foodItemId: UUID, quantity: Double) {
        self.id = id
        self.foodItemId = foodItemId
        self.quantity = quantity
    }
}

extension Repository {

    // MARK: - Reading

    /// Every recipe in the library, composed against it.
    ///
    /// Takes the library as a parameter rather than re-reading it, because every caller already has it
    /// loaded and a second read could observe a different library than the one on screen — which is how
    /// a recipe would appear to be missing an ingredient that is visibly present two rows down.
    func recipes(library: [FoodItem]) async -> [Recipe] {
        guard let store = await storeHandle(),
              let grouped = try? await store.allRecipeComponents(deviceId: FoodLogStore.sourceId),
              !grouped.isEmpty else { return [] }

        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id.uuidString, $0) })
        let built = grouped.compactMap { recipeId, rows -> Recipe? in
            guard let item = byId[recipeId] else { return nil }   // recipe item itself deleted
            return Recipe.make(item: item, rows: rows, byId: byId)
        }
        // Ordered by the SAME rule the food picker sorts the library with (recents first, then name), so
        // a recipe does not jump position depending on which list it is being shown in. Sorting the items
        // through the shared helper and reindexing is what keeps the two in step — reimplementing the
        // comparator here is how they would drift.
        let order = Dictionary(uniqueKeysWithValues:
            FoodLibrary.sorted(built.map { $0.item }).enumerated().map { ($1.id, $0) })
        return built.sorted { (order[$0.item.id] ?? 0) < (order[$1.item.id] ?? 0) }
    }

    /// One recipe, or nil if the item has no parts (i.e. is a plain food).
    func recipe(id: UUID, library: [FoodItem]) async -> Recipe? {
        guard let store = await storeHandle(),
              let rows = try? await store.recipeComponents(deviceId: FoodLogStore.sourceId,
                                                           recipeId: id.uuidString),
              !rows.isEmpty,
              let item = library.first(where: { $0.id == id }) else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id.uuidString, $0) })
        return Recipe.make(item: item, rows: rows, byId: byId)
    }

    /// Which library items are recipes. One query, for a picker that has to badge rows as it scrolls.
    func recipeItemIds() async -> Set<UUID> {
        guard let store = await storeHandle(),
              let grouped = try? await store.allRecipeComponents(deviceId: FoodLogStore.sourceId)
        else { return [] }
        return Set(grouped.keys.compactMap(UUID.init(uuidString:)))
    }

    // MARK: - Writing

    /// Create or update a recipe: its item row, its parts, and the cached total.
    ///
    /// Parts are written wholesale (`replaceRecipeComponents`) rather than diffed — the user edits a
    /// recipe as a list, and reconciling adds/moves/removes individually is more code with more ways to
    /// leave it half-applied.
    ///
    /// Invalid quantities are dropped rather than stored, using the same `RecipeMath.isValidQuantity`
    /// the editor validates with, so a value the UI would reject cannot arrive by another route. Ordinals
    /// are renumbered dense on every save, because gaps left by deletions accumulate until two
    /// ingredients collide and `ORDER BY ord` stops preserving the arrangement.
    @discardableResult
    func saveRecipe(item: FoodItem, parts: [RecipePartRef], library: [FoodItem]) async -> Recipe? {
        guard let store = await storeHandle() else { return nil }
        let kept = parts.filter { RecipeMath.isValidQuantity($0.quantity) }
        let ords = RecipeMath.renumbered(kept.count)

        // Cache the composed total onto the item, for the picker's deleted-ingredient fallback only.
        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id.uuidString, $0) })
        let composition = RecipeMath.resolve(
            componentIds: kept.map { $0.foodItemId.uuidString },
            quantities: kept.map { $0.quantity },
            lookup: { byId[$0]?.macros })
        var saved = item
        if let m = composition.macros { saved.macros = m }

        // Parts first, item last. `saveFoodItem` is what posts the change notification, so writing it
        // last means observers wake to a recipe whose item and ingredients already agree — rather than
        // to an item advertising a total its parts have not been written for yet.
        _ = try? await store.replaceRecipeComponents(
            deviceId: FoodLogStore.sourceId,
            recipeId: saved.id.uuidString,
            with: zip(kept, ords).map { part, ord in
                RecipeComponentRow(id: part.id.uuidString,
                                   deviceId: FoodLogStore.sourceId,
                                   recipeId: saved.id.uuidString,
                                   foodItemId: part.foodItemId.uuidString,
                                   quantity: part.quantity,
                                   ord: ord)
            })
        await saveFoodItem(saved)
        return Recipe(item: saved, parts: kept, composed: composition.macros,
                      missingIngredientIds: composition.missingIngredientIds.compactMap(UUID.init(uuidString:)))
    }

    /// Delete a recipe: its parts and its item row.
    ///
    /// Logged history survives, because every entry carries its own name and macro snapshot — the same
    /// reason deleting a plain food item is safe. Deleting an INGREDIENT, by contrast, deliberately does
    /// not cascade: the recipe keeps naming it and reports itself incomplete, which is a visible problem
    /// the user can fix rather than a total that silently shrank.
    func deleteRecipe(id: UUID) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.deleteRecipeComponents(deviceId: FoodLogStore.sourceId,
                                                    recipeId: id.uuidString)
        _ = try? await store.deleteFoodItem(deviceId: FoodLogStore.sourceId, id: id.uuidString)
        noteFoodChanged()
    }
}

extension Recipe {

    /// Build a recipe from its stored rows, composing against the supplied library.
    static func make(item: FoodItem, rows: [RecipeComponentRow], byId: [String: FoodItem]) -> Recipe {
        let parts = rows.map {
            RecipePartRef(id: UUID(uuidString: $0.id) ?? UUID(),
                          foodItemId: UUID(uuidString: $0.foodItemId) ?? UUID(),
                          quantity: $0.quantity)
        }
        let composition = RecipeMath.resolve(componentIds: rows.map { $0.foodItemId },
                                            quantities: rows.map { $0.quantity },
                                            lookup: { byId[$0]?.macros })
        return Recipe(item: item,
                      parts: parts,
                      composed: composition.macros,
                      missingIngredientIds: composition.missingIngredientIds.compactMap(UUID.init(uuidString:)))
    }
}
