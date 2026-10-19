import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// "How this was estimated": the workout screen's account of its calorie figure, and of what the diet
/// budget counts from it.
///
/// Reads the SAME `DietWorkoutCredit` the budget screen prices from (`Repository.workoutCredit`), so the
/// card can never describe a figure the budget would not produce. Everything on it is a model input or
/// output printed as it was used — HRmax, resting HR, the VO₂max estimate, minutes on and off, the sport
/// ceiling — because a calorie figure with no working shown is a number to argue with, not to trust.
struct WorkoutEnergyBreakdownView: View {
    let item: DietWorkoutCredit

    private var durationMinutes: Int { max(0, (item.row.endTs - item.row.startTs) / 60) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How this was estimated", overline: "Calories")
            NoopCard(tint: StrandPalette.metricAmber) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let b = item.breakdown {
                        traced(b)
                    } else {
                        imported
                    }
                }
            }
        }
    }

    // MARK: - A strap-recorded session, priced from its trace

    @ViewBuilder private func traced(_ b: SportEnergy.Breakdown) -> some View {
        let i = b.inputs
        // What the curve was drawn with.
        line("Heart rate", "\(Int(i.flexHRBPM.rounded()))–\(Int(i.hrmax.rounded())) bpm",
             note: i.restingHRWasDefaulted
                ? String(localized: "From resting \(Int(i.restingHR)) bpm (default, no measured resting HR) to your HRmax; below the lower figure a minute costs resting energy")
                : String(localized: "From resting \(Int(i.restingHR)) bpm to your HRmax; below the lower figure a minute costs resting energy"))
        line("Fitness", String(localized: "VO₂max ≈ \(Int(i.vo2max.rounded())) · \(String(format: "%.1f", i.metMax)) METs at HRmax"),
             note: String(localized: "Estimated from HRmax and resting HR, for \(Int(i.weightKg.rounded())) kg"))
        if let ceiling = i.traits.ceilingMET {
            line("Sport ceiling", String(localized: "\(String(format: "%.0f", ceiling)) METs per minute"),
                 note: b.ceilingHitMinutes > 0
                    ? String(localized: "Held \(b.ceilingHitMinutes) min at the most \(WorkoutSource.displaySport(item.row.sport)) can plausibly cost")
                    : String(localized: "The most \(WorkoutSource.displaySport(item.row.sport)) can plausibly cost; not reached"))
        }

        Divider().overlay(StrandPalette.hairline)

        // What the session did.
        let covered = Int((b.coveredSeconds / 60).rounded())
        if b.offMinutes > 0 {
            line(String(localized: "Playing · \(b.onMinutes) min"), "\(kcal(b.onKcal)) kcal",
                 note: String(localized: "\(String(format: "%.1f", b.meanOnMET)) METs on average from heart rate"))
            line(String(localized: "Off the pitch · \(b.offMinutes) min"), "\(kcal(b.offKcal)) kcal",
                 note: maskNote(b))
        } else {
            line(String(localized: "Active · \(b.onMinutes) min"), "\(kcal(b.onKcal)) kcal",
                 note: String(localized: "\(String(format: "%.1f", b.meanOnMET)) METs on average from heart rate"))
        }
        if b.uncoveredOnMinutes > 0 || covered < durationMinutes {
            line("Heart rate coverage", String(localized: "\(min(covered, durationMinutes)) of \(durationMinutes) min"),
                 note: b.uncoveredOnMinutes > 0
                    ? String(localized: "\(b.uncoveredOnMinutes) min without a reading, counted at resting")
                    : nil)
        }
        line("Total", "\(kcal(b.grossKcal)) kcal", emphasis: true,
             note: String(localized: "Includes \(kcal(b.restingKcal)) kcal of resting energy over the session"))

        Divider().overlay(StrandPalette.hairline)

        // What the budget takes, and why it differs from the tile above.
        line("Diet budget counts", "\(kcal(item.credit.creditedKcal)) kcal", emphasis: true,
             note: budgetNote)
        if item.credit.isRepriced {
            line("Recorded", "\(kcal(item.credit.recordedKcal)) kcal",
                 note: item.row.energyKcal == nil
                    ? String(localized: "No figure stored yet; the strap's next sync scores it")
                    : String(localized: "Saved with the model in use at the time. Confirming your playing time rewrites it with the figure above"))
        }
    }

    private func maskNote(_ b: SportEnergy.Breakdown) -> String {
        switch b.maskSource {
        case .confirmedPlayedTime:
            return String(localized: "Your confirmed playing time; off minutes at \(String(format: "%.0f", b.inputs.traits.offMET ?? SportEnergy.offMET)) METs whatever the heart rate")
        case .motionThreshold:
            return String(localized: "From your strap's movement, unconfirmed; off minutes at \(String(format: "%.0f", b.inputs.traits.offMET ?? SportEnergy.offMET)) METs whatever the heart rate")
        case .none:
            return String(localized: "Off minutes at \(String(format: "%.0f", b.inputs.traits.offMET ?? SportEnergy.offMET)) METs")
        }
    }

    private var budgetNote: String {
        if item.credit.isCapped {
            return String(localized: "Capped by the sport's played-time ceiling; the resting share is already in your baseline")
        }
        return String(localized: "The resting share is already in your baseline, so only the energy above it is added")
    }

    // MARK: - An import

    @ViewBuilder private var imported: some View {
        line("Recorded", "\(kcal(item.credit.recordedKcal)) kcal",
             note: String(localized: "An imported figure from \(WorkoutSource.sourceLabel(item.row)); the app does not re-price it"))
        line("Diet budget counts", "\(kcal(item.credit.creditedKcal)) kcal", emphasis: true,
             note: budgetNote)
    }

    // MARK: - Pieces

    private func line(_ label: String, _ value: String, emphasis: Bool = false, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(value)
                    .font(emphasis ? StrandFont.headline : StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if let note {
                Text(note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func kcal(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.grouping(.automatic))
    }
}
