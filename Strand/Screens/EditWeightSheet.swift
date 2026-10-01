import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Correct or remove a weigh-in
//
// The weight trend is a regression through these points, so a single mistyped reading — 7.3 instead of
// 73 — drags the slope badly and CANNOT be out-voted by logging more. Averaging does not rescue an
// outlier that large; only removing it does.
//
// That is why delete is offered beside edit, and why neither is buried. Everything the efficacy half of
// this feature concludes rests on a handful of numbers, and a wrong one has to be removable.
struct EditWeightSheet: View {
    let day: String
    let kg: Double
    let onDone: () -> Void

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String
    @State private var confirmDelete = false

    init(day: String, kg: Double, onDone: @escaping () -> Void) {
        self.day = day
        self.kg = kg
        self.onDone = onDone
        _draft = State(initialValue: String(format: "%.1f", kg))
    }

    private var parsed: Double? {
        let v = Double(draft.trimmingCharacters(in: .whitespaces))
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    /// A plausibility band, not a hard rule — it is the user's body, and the point is to catch a decimal
    /// slip rather than to argue with them. Saving stays enabled.
    private var looksImplausible: Bool {
        guard let v = parsed else { return false }
        return v < 30 || v > 300
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            SectionHeader(LocalizedStringKey(day), overline: "Weigh-in")

            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack {
                        TextField("Weight in kg", text: $draft)
                            .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                        Text("kg")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if looksImplausible {
                        Text("That's outside the usual range — worth a second look in case a decimal slipped.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The weight trend is fitted through these readings, so one wrong number moves the line more than the rest can correct for.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Delete") { confirmDelete = true }
                    .buttonStyle(NoopButtonStyle(.destructive))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(NoopButtonStyle(.secondary))
                Button("Save") {
                    guard let v = parsed else { return }
                    Task {
                        // Only stamps the profile when correcting TODAY: the profile weight is what the
                        // expenditure model prices the body at right now, and a fix to a reading from
                        // three weeks ago says nothing about today's mass.
                        let isToday = day == Repository.localDayKey(Date())
                        await repo.logWeight(kg: v, day: day, profile: isToday ? profile : nil)
                        onDone()
                        dismiss()
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(parsed == nil)
            }
            Spacer()
        }
        .padding(NoopMetrics.screenPadding)
        .frame(minWidth: 320, minHeight: 300)
        .alert("Remove this weigh-in?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                Task {
                    await repo.deleteWeight(day: day)
                    onDone()
                    dismiss()
                }
            }
        } message: {
            Text("The trend will be refitted without it.")
        }
    }
}

/// `String` is not `Identifiable`, and `.sheet(item:)` needs it to be. Scoped to this file rather than
/// extended globally: a blanket `extension String: Identifiable` would silently give every string in the
/// app an identity equal to itself, which is wrong far more often than it is right.
struct WeightEditTarget: Identifiable, Equatable {
    let day: String
    var id: String { day }
}
