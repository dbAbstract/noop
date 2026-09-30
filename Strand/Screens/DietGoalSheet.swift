import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Set a diet goal
//
// The goal is a DESTINATION AND A TIMELINE — "73 kg to 69 kg by March" — because that is how it is
// actually held. The deficit and the daily target are derived and shown, never typed.
//
// The slider is the whole point of the screen. Because the rate falls out of the timeline, dragging it
// shows the consequence live: the implied weekly loss, the deficit it demands, and the point where it
// stops being a diet. That boundary is MARKED rather than enforced after the fact — the user can see
// where the unsafe region begins before they reach it, instead of being refused once they are in it.
struct DietGoalSheet: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    /// Existing goal to edit, or nil to create one.
    let existing: DietGoalRow?
    let onSaved: () -> Void

    @State private var targetWeight: Double
    @State private var months: Double
    @State private var activity: ActivityLevel
    @State private var saving = false

    init(existing: DietGoalRow?, onSaved: @escaping () -> Void) {
        self.existing = existing
        self.onSaved = onSaved
        _targetWeight = State(initialValue: existing?.targetWeightKg ?? 0)   // resolved on appear
        _months = State(initialValue: Double(existing?.months ?? 6))
        _activity = State(initialValue: ActivityLevel(rawValue: existing?.activityLevel ?? "") ?? .sedentary)
    }

    private var startWeight: Double { profile.weightKg }

    /// The floor a target may not go under, so the stepper bounds itself rather than validating after.
    private var minTarget: Double {
        DietGoal.minTargetWeightKg(heightCm: profile.heightCm).map { (($0 * 10).rounded(.up)) / 10 } ?? 40
    }

    private var planResult: Result<DietGoalPlan, DietGoalRejection> {
        DietGoal.plan(startWeightKg: startWeight, targetWeightKg: targetWeight,
                      heightCm: profile.heightCm, months: Int(months))
    }

    private var plan: DietGoalPlan? {
        if case .success(let p) = planResult { return p }
        return nil
    }

    /// Where the unsafe region starts, so the slider can mark it.
    private var fastestSafe: Int? {
        DietGoal.fastestSafeMonths(startWeightKg: startWeight, targetWeightKg: targetWeight,
                                   heightCm: profile.heightCm)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                destinationSection
                timelineSection
                activitySection
                outcomeSection
                actions
            }
            .padding(NoopMetrics.screenPadding)
        }
        .frame(minWidth: 380, minHeight: 560)
        .onAppear {
            // Default to a round number below the current weight rather than 0, so the sheet opens on a
            // plausible goal instead of an invalid one the user has to fix before it says anything.
            if targetWeight <= 0 {
                targetWeight = max(minTarget, (startWeight - 4).rounded())
            }
        }
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Goal weight", overline: "Destination")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack {
                        Text("Now")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text(kg(startWeight))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Target")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Button { targetWeight = max(minTarget, targetWeight - 0.5) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(targetWeight - 0.5 < minTarget)
                        Text(kg(targetWeight))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 80)
                        Button { targetWeight = min(startWeight - 0.5, targetWeight + 0.5) } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(targetWeight + 0.5 > startWeight - 0.5)
                    }

                    // The floor is stated rather than merely enforced — a disabled button with no reason
                    // reads as a bug.
                    Text("Lowest healthy target for your height is \(kg(minTarget)).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Timeline", overline: "How long")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(months))")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(Int(months) == 1 ? "month" : "months")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Slider(value: $months, in: 1...12, step: 1)
                        .tint(sliderTint)
                        .accessibilityLabel("Months to reach your goal")

                    // The boundary, named. Marking where the unsafe region starts is the difference
                    // between a limit you can plan around and a wall you walk into.
                    if let fastest = fastestSafe, fastest > 1 {
                        Text("Under \(fastest) \(fastest == 1 ? "month" : "months") is faster than is safe for this goal.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Amber for a push, critical for refused, accent otherwise — the slider itself carries the verdict.
    private var sliderTint: Color {
        switch plan?.rate {
        case .unsafe: return StrandPalette.statusCritical
        case .aggressive: return StrandPalette.statusWarning
        default: return StrandPalette.accent
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Your usual day", overline: "Baseline")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Picker("Activity", selection: $activity) {
                        Text("Sedentary").tag(ActivityLevel.sedentary)
                        Text("Lightly active").tag(ActivityLevel.lightlyActive)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Everyday activity level")

                    // Says explicitly that exercise is NOT in this choice, because every other app's
                    // activity picker folds it in — and here it would double-count against the measured
                    // workout calories that are added separately.
                    Text(activity == .sedentary
                         ? "Desk job, driving or transit, minimal walking. Workouts and steps are counted separately and added on top."
                         : "On your feet through the day — retail, teaching, nursing, an active commute. Workouts and steps are still counted separately.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Outcome

    @ViewBuilder private var outcomeSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What that means", overline: "Derived")
            NoopCard(tint: outcomeTint) {
                switch planResult {
                case .success(let p):
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        row("To lose", kg(p.kgToLose))
                        row("Pace", "\(oneDp(p.kgPerWeek)) kg/week")
                        row("Daily deficit", "\(Int(p.dailyDeficitKcal.rounded())) kcal")
                        Divider().overlay(StrandPalette.hairline)
                        row("Eat about", "\(Int(estimatedTarget(p).rounded())) kcal/day", emphasis: true)
                        // The estimate is framed as a starting point on purpose: it will be corrected
                        // from real data, and promising precision it does not have is the failure mode
                        // this whole model is built to avoid.
                        Text("A starting estimate from your height, weight and age, plus the steps and workouts NOOP measures. It gets corrected as you log.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if p.rate == .unsafe {
                            warning("That pace is faster than is safe. Give yourself more time, or set a nearer target.")
                        } else if p.rate == .aggressive {
                            warning("That's an aggressive pace — workable for a short block, hard to hold for months.")
                        }
                    }
                case .failure(let why):
                    Text(message(for: why))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var outcomeTint: Color? {
        switch plan?.rate {
        case .unsafe: return StrandPalette.statusCritical
        case .aggressive: return StrandPalette.statusWarning
        case .gradual: return StrandPalette.accent
        case nil: return nil
        }
    }

    /// The daily target a typical day would carry — baseline only, since steps and workouts are not yet
    /// known for a day that has not happened.
    private func estimatedTarget(_ p: DietGoalPlan) -> Double {
        let bmr = CalorieTarget.mifflinBMR(sex: profile.sex, weightKg: startWeight,
                                           heightCm: profile.heightCm, age: Double(profile.age))
        return max(0, CalorieTarget.baselineKcal(bmrKcal: bmr, activity: activity) - p.dailyDeficitKcal)
    }

    private func row(_ label: String, _ value: String, emphasis: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value)
                .font(emphasis ? StrandFont.headline : StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func message(for why: DietGoalRejection) -> String {
        switch why {
        case .notALoss:
            return String(localized: "Set a target below your current weight.")
        case .belowHealthyBMI:
            return String(localized: "That target is below a healthy weight for your height. NOOP won't plan toward it.")
        case .invalidInput:
            return String(localized: "Check your height and weight in Settings — a goal can't be worked out without them.")
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            if existing != nil {
                Button("Stop") {
                    Task {
                        await repo.clearDietGoal()
                        onSaved()
                        dismiss()
                    }
                }
                .buttonStyle(NoopButtonStyle(.destructive))
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(NoopButtonStyle(.secondary))
            }
            Spacer()
            Button(saving ? "Saving…" : "Set goal") {
                guard let p = plan, p.isAllowed else { return }
                saving = true
                Task {
                    await repo.setDietGoal(startWeightKg: p.startWeightKg,
                                           targetWeightKg: p.targetWeightKg,
                                           months: p.months,
                                           activity: activity,
                                           dailyDeficitKcal: p.dailyDeficitKcal)
                    await repo.refreshDietDay(profile: profile)
                    saving = false
                    onSaved()
                    dismiss()
                }
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .disabled(saving || !(plan?.isAllowed ?? false))
        }
    }

    // MARK: - Formatting

    private func kg(_ v: Double) -> String {
        String(format: "%.1f kg", locale: AppLanguage.activeLocale, v)
    }

    private func oneDp(_ v: Double) -> String {
        String(format: "%.2f", locale: AppLanguage.activeLocale, v)
    }
}
