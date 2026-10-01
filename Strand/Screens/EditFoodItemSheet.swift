import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Edit a saved food
//
// Fixing a food you got wrong. Without this a mistyped calorie count is wrong forever AND wrong every
// time it is logged again, which is the worse half.
//
// The two fields behave differently on purpose, and the sheet says so rather than leaving it to be
// discovered:
//
//   • The NAME is a label for a thing. Correcting "protein yogurt" to "Danone protein yogurt" describes
//     the same yogurt better, so every past entry picks it up — they are resolved live from the library
//     (see `Repository.foodEntries`), not rewritten, so there is no migration and nothing to half-apply.
//   • The MACROS are a measurement of what was eaten. Changing them affects only FUTURE logs; past
//     entries keep the snapshot they were logged with. Rewriting those would change the record rather
//     than its description.
//
// None of this touches any total: every figure comes from the entry's own snapshot, never from the item.
struct EditFoodItemSheet: View {
    let item: FoodItem
    let onSaved: () -> Void
    let onDeleted: () -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var servingLabel: String
    @State private var kcal: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var fiber: String
    @State private var confirmDelete = false

    init(item: FoodItem, onSaved: @escaping () -> Void, onDeleted: @escaping () -> Void) {
        self.item = item
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: item.name)
        _servingLabel = State(initialValue: item.servingLabel)
        _kcal = State(initialValue: Self.field(item.macros.kcal))
        _protein = State(initialValue: Self.field(item.macros.protein))
        _carbs = State(initialValue: Self.field(item.macros.carbs))
        _fat = State(initialValue: Self.field(item.macros.fat))
        _fiber = State(initialValue: Self.field(item.macros.fiber))
    }

    private var draftMacros: MacroTotals {
        MacroTotals(kcal: number(kcal), protein: number(protein), carbs: number(carbs),
                    fat: number(fat), fiber: number(fiber))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !draftMacros.isEmpty
    }

    private var nameChanged: Bool {
        name.trimmingCharacters(in: .whitespaces) != item.name
    }

    private var macrosChanged: Bool { draftMacros != item.macros }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                fieldsSection
                effectSection
                actions
            }
            .padding(NoopMetrics.screenPadding)
        }
        .frame(minWidth: 360, minHeight: 480)
        .alert("Delete \(item.name)?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await repo.deleteFoodItem(id: item.id)
                    onDeleted()
                    dismiss()
                }
            }
        } message: {
            // Says the part people fear: deleting does NOT erase what they ate.
            Text("Removes it from your saved foods. Days you already logged it keep their entries and their numbers.")
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Edit food", overline: "Per serving")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("One serving is… (e.g. 1 scoop, 100 g)", text: $servingLabel)
                        .textFieldStyle(.roundedBorder)
                    Divider().overlay(StrandPalette.hairline)
                    macroField(String(localized: "Calories (kcal)"), $kcal)
                    macroField(String(localized: "Protein (g)"), $protein)
                    macroField(String(localized: "Carbs (g)"), $carbs)
                    macroField(String(localized: "Fat (g)"), $fat)
                    macroField(String(localized: "Fibre (g)"), $fiber)

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

    /// Spells out what the edit will and will not reach, BEFORE saving. The asymmetry is deliberate but
    /// not guessable, and someone correcting a label deserves to know it reaches their history while
    /// someone correcting a calorie count deserves to know it does not.
    @ViewBuilder private var effectSection: some View {
        if nameChanged || macrosChanged {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("What this changes", overline: "Before you save")
                NoopCard(tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        if nameChanged {
                            note("Renaming updates this food everywhere, including days you already logged it — the same food, better described.",
                                 icon: "textformat")
                            note("If this is actually a different food rather than a better name for this one, cancel and log that one separately instead.",
                                 icon: "exclamationmark.triangle", warn: true)
                        }
                        if macrosChanged {
                            note("New numbers apply from now on. Days you already logged keep what they were logged with, so your history stays a record of what you actually ate.",
                                 icon: "number")
                        }
                    }
                }
            }
        }
    }

    private func note(_ text: String, icon: String, warn: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(StrandFont.caption)
                .foregroundStyle(warn ? StrandPalette.statusWarning : StrandPalette.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(warn ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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

    private var actions: some View {
        HStack {
            Button("Delete") { confirmDelete = true }
                .buttonStyle(NoopButtonStyle(.destructive))
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(NoopButtonStyle(.secondary))
            Button("Save") {
                var edited = item
                edited.name = name.trimmingCharacters(in: .whitespaces)
                let trimmedServing = servingLabel.trimmingCharacters(in: .whitespaces)
                edited.servingLabel = trimmedServing.isEmpty ? item.servingLabel : trimmedServing
                edited.macros = draftMacros
                Task {
                    await repo.saveFoodItem(edited)
                    onSaved()
                    dismiss()
                }
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .disabled(!canSave)
        }
    }

    private func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Whole numbers lose their ".0" so a field opens as "120" rather than "120.0".
    private static func field(_ v: Double) -> String {
        guard v > 0 else { return "" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }
}
