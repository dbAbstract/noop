import SwiftUI
import StrandAnalytics
import StrandDesign

/// Local reports remain accessible without a Coach provider or data-sharing consent.
struct WeeklyDietReviewView: View {
    let reports: [WeeklyDietReport]
    let onDiscuss: (WeeklyDietReport) -> Void
    let canDiscuss: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?
    @State private var visibleWeeks = 12

    private var report: WeeklyDietReport? { reports.first { $0.id == selected } ?? reports.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                HStack {
                    Text("Weekly diet reviews").font(StrandFont.title2)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(NoopButtonStyle(.secondary))
                }
                Text("Monday–Sunday. Reports update when you correct past logs.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if let report {
                    reportCard(report)
                    Button("Discuss this week with Coach") { onDiscuss(report) }
                        .buttonStyle(NoopButtonStyle(.primary)).disabled(!canDiscuss)
                    Text("Missing days are unknown. A logged day may still have missing meals. Calorie balance is an estimate, not a measurement of fat change.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Text("Previous weeks").font(StrandFont.headline)
                    LazyVStack(spacing: NoopMetrics.space3) {
                        ForEach(reports.prefix(visibleWeeks)) { week in
                            Button { selected = week.id } label: {
                                HStack {
                                    Text(verbatim: "\(week.startKey) – \(week.endKey)")
                                    Spacer()
                                    Text(verbatim: balance(week.fullWeekBalanceKcal))
                                }.font(StrandFont.body)
                            }.buttonStyle(NoopButtonStyle(.secondary))
                        }
                    }
                    if visibleWeeks < reports.count {
                        Button("Show older weeks") { visibleWeeks += 12 }
                            .buttonStyle(NoopButtonStyle(.secondary))
                    }
                } else {
                    Text("Your first weekly report will be ready after a completed week with diet data.")
                        .font(StrandFont.body)
                }
            }.padding(NoopMetrics.screenPadding)
        }
    }

    private func reportCard(_ r: WeeklyDietReport) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(verbatim: "\(r.startKey) – \(r.endKey)").font(StrandFont.headline)
                row("Logged calories in", value: kcal(r.intakeKcal))
                row("Average logged intake", value: kcal(r.intakeKcal.map { $0 / Double(r.intakeDays) }))
                row("Intake days", value: "\(r.intakeDays)/7")
                row("Rough-estimate days", value: "\(r.roughDays)/7")
                row("Estimated calories out", value: kcal(r.expenditureKcal))
                row("Average estimated expenditure", value: kcal(r.expenditureKcal.map { $0 / Double(r.expenditureDays) }))
                row("Expenditure days", value: "\(r.expenditureDays)/7")
                row("Formula / calibrated / unknown days", value: "\(r.formulaDays) / \(r.calibratedDays) / \(r.expenditureDays - r.formulaDays - r.calibratedDays)")
                row("Matched-day balance (in − out)", value: balance(r.pairedBalanceKcal))
                row("Average matched-day balance", value: kcal(r.pairedBalanceKcal.map { $0 / Double(r.pairedDays) }))
                row("Matched days", value: "\(r.pairedDays)/7")
                row("Full-week balance", value: balance(r.fullWeekBalanceKcal))
                row("Mean weight", value: kg(r.meanWeightKg))
                row("Weigh-in days", value: "\(r.weighInDays)/7")
                if let previous = reports.first(where: { $0.startDay == r.startDay - 7 }) {
                    row("Balance change from previous week", value: balance(r.fullWeekBalanceKcal.flatMap { current in previous.fullWeekBalanceKcal.map { current - $0 } }))
                    row("Average balance change from previous week", value: balance(r.pairedBalanceKcal.flatMap { current in previous.pairedBalanceKcal.map { current / Double(r.pairedDays) - $0 / Double(previous.pairedDays) } }))
                    row("Mean weight change from previous week", value: kg(r.meanWeightKg.flatMap { current in previous.meanWeightKg.map { current - $0 } }))
                }
                Text("Longer-term alignment").font(StrandFont.headline)
                Text(alignment(r.alignment)).font(StrandFont.body)
                if let reason = r.uncertainty {
                    Text(uncertainty(reason)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if let fit = r.fit {
                    row("Weight trend (kg/week)", value: "\(number(fit.slopeKgPerWeek)) ± \(number(fit.weeklyMarginKg))")
                    row("Weight scatter", value: kg(fit.scatterKg))
                    row("Calorie-predicted rate (kg/week)", value: r.expectedKgPerWeek.map(number) ?? unknown)
                    if let lo = r.evidenceStart, let hi = r.evidenceEnd {
                        Text(verbatim: "\(WeeklyDietReview.dayKey(lo)) – \(WeeklyDietReview.dayKey(hi))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        row("Weight / matched calorie days", value: "\(fit.dayCount) / \(r.evidencePairedDays)")
                    }
                }
                Text("Alignment needs at least three weeks of matched calories and recent weigh-ins with a clear trend. Rough estimates, missing data or unknown/calibrated burn sources prevent an independent conclusion.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private var unknown: String { String(localized: "Unknown") }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
    private func kcal(_ value: Double?) -> String { value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) kcal" } ?? unknown }
    private func balance(_ value: Double?) -> String { kcal(value) }
    private func kg(_ value: Double?) -> String { value.map { "\(number($0)) kg" } ?? unknown }
    private func alignment(_ value: WeeklyDietReport.Alignment) -> String {
        switch value {
        case .consistent: return String(localized: "Broadly consistent with the measured weight trend.")
        case .mismatch: return String(localized: "Possible mismatch. Discuss logging and expenditure estimates before changing the plan.")
        case .uncertain: return String(localized: "Too uncertain to conclude. More reliable evidence is needed.")
        }
    }
    private func uncertainty(_ reason: WeeklyDietReport.Uncertainty) -> String {
        switch reason {
        case .insufficientWeight: return String(localized: "At least six weigh-in days spanning three weeks are needed.")
        case .staleWeight: return String(localized: "The last weigh-in is too old for this review.")
        case .missingCalories: return String(localized: "Some days between weigh-ins are missing intake or expenditure.")
        case .unknownBurnSource: return String(localized: "The source of some historical burn estimates is unknown.")
        case .calibratedBurn: return String(localized: "Weight-calibrated burn cannot independently validate the same weight data.")
        case .roughEstimates: return String(localized: "Rough intake estimates limit the calorie comparison.")
        case .scatter: return String(localized: "Weight scatter is too high to distinguish the change reliably.")
        }
    }
    private func row(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(verbatim: value).multilineTextAlignment(.trailing)
        }.font(StrandFont.body)
    }
}
