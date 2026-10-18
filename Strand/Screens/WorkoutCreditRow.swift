import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// One workout's line under the diet budget's Training figure: what was recorded, what the budget counted,
/// and — for an intermittent sport — the played-time control the count is priced on.
///
/// Recorded and counted are shown TOGETHER on purpose. The workout screen still says 1,720 kcal; if the
/// budget only showed 913, the two screens would disagree with no way to see why. Here the gap carries its
/// reason beside it.
struct WorkoutCreditRow: View {
    @EnvironmentObject var repo: Repository
    let item: DietWorkoutCredit
    /// Called after the played time is confirmed, edited or reset, so the parent recomputes its budget.
    let onChange: () -> Void

    @State private var suggestion: Double?
    @State private var editing = false
    @State private var draftMinutes = 0
    @State private var saving = false

    private var durationMinutes: Int { max(0, (item.row.endTs - item.row.startTs) / 60) }
    private var playedMinutes: Int { Int(((item.credit.playedS ?? 0) / 60).rounded()) }
    private var sport: String { WorkoutSource.displaySport(item.row.sport) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(sport) · \(durationMinutes) min")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("\(kcal(item.credit.recordedKcal)) → \(kcal(item.credit.creditedKcal)) kcal")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Text(reason)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if item.credit.capKcal != nil { playedTimeControl }
        }
        .task(id: item.row.startTs) {
            suggestion = item.isPlayedTimeConfirmed ? nil : await repo.suggestedPlayedSeconds(for: item.row)
        }
    }

    /// Why counted differs from recorded. Only claims a cap when the cap actually set the figure.
    private var reason: String {
        if item.credit.isCapped {
            return item.isPlayedTimeConfirmed
                ? String(localized: "Capped for \(sport): \(playedMinutes) of \(durationMinutes) min played, time off the pitch counted at recovery pace")
                : String(localized: "Capped as if all \(durationMinutes) min were played. Confirm your playing time for a closer figure")
        }
        if item.credit.netKcal < item.credit.recordedKcal {
            return String(localized: "Resting energy during the session is already in your baseline")
        }
        return String(localized: "Counted as recorded")
    }

    @ViewBuilder private var playedTimeControl: some View {
        if editing {
            Stepper(value: $draftMinutes, in: 0...durationMinutes) {
                Text("Played \(draftMinutes) of \(durationMinutes) min")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            HStack(spacing: NoopMetrics.space2) {
                NoopButton("Save", systemImage: "checkmark", kind: .secondary) {
                    save(Double(draftMinutes * 60))
                }
                .disabled(saving)
                NoopButton("Cancel", kind: .tertiary) { editing = false }
            }
        } else if item.isPlayedTimeConfirmed {
            HStack(spacing: NoopMetrics.space2) {
                Text("Played \(playedMinutes) of \(durationMinutes) min")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                NoopButton("Edit", kind: .tertiary) { beginEdit(from: item.credit.playedS) }
                NoopButton("Reset", kind: .tertiary) { save(nil) }
                    .disabled(saving)
            }
        } else if let suggestion {
            // A suggestion from the strap's motion, never applied until confirmed (`PlayedTimeEstimate`).
            Text("Your strap's movement suggests \(Int((suggestion / 60).rounded())) of \(durationMinutes) min played")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space2) {
                NoopButton("Confirm", systemImage: "checkmark", kind: .secondary) { save(suggestion) }
                    .disabled(saving)
                NoopButton("Edit", kind: .tertiary) { beginEdit(from: suggestion) }
            }
        } else {
            NoopButton("Set playing time", kind: .tertiary) { beginEdit(from: nil) }
        }
    }

    private func beginEdit(from seconds: Double?) {
        draftMinutes = min(durationMinutes, Int(((seconds ?? Double(durationMinutes * 60)) / 60).rounded()))
        editing = true
    }

    private func save(_ seconds: Double?) {
        saving = true
        Task {
            _ = await repo.setConfirmedPlayedSeconds(seconds, for: item.row)
            saving = false
            editing = false
            onChange()
        }
    }

    private func kcal(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.grouping(.automatic))
    }
}
