import Foundation

// MARK: - Calorie target: what to eat, derived from what is spent
//
//     BMR × activity  +  step NEAT  +  measured workout kcal  =  expenditure
//     expenditure − deficit                                   =  the day's budget
//
// WHY THIS EXISTS RATHER THAN READING NOOP'S OWN CALORIE FIGURE. `Calories.estimateDayEnergy`
// (WorkoutDetector.swift) is Harris–Benedict BMR plus Keytel active energy, but the active half only
// counts samples above 50% heart-rate reserve — a gate set deliberately high because Keytel over-counts
// ordinary daytime heart rate. Everything below it, which is all of NEAT, is discarded. So that figure is
// roughly BMR + workouts, short by the band that separates a resting metabolism from a real sedentary
// day. Eating to it means eating at a deficit several hundred kcal deeper than intended, every day that
// does not contain a workout.
//
// This model reconstructs the missing band explicitly instead: a multiplier for baseline living, measured
// steps for the movement above it, and measured heart rate for the workouts — each from the input that
// actually knows about it. NOOP's own figure is left untouched and shown ALONGSIDE this one, because a
// model must not overwrite a measurement.
//
// NONE OF IT IS TRUSTED FOR LONG. `AdaptiveExpenditureEngine` reads true expenditure back out of logged
// intake and the weight trend within a few weeks, and that empirical figure supersedes this estimate.
// What follows is a starting point, chosen to be defensible rather than exact.

/// The baseline multiplier applied to resting energy.
///
/// THE DIET PATH ALWAYS USES `.sedentary`, AND THERE IS NO PICKER. That is deliberate, and it is the one
/// thing about this model most likely to be "fixed" back into a bug by someone adding the familiar
/// activity tiers.
///
/// A conventional activity factor is a STAND-IN for movement nobody measured. Here movement IS measured —
/// steps above a baseline, plus heart-rate-derived workout energy — so letting the user also declare
/// themselves active charges for the same movement twice. Concretely, at a 1,681 kcal BMR the step from
/// ×1.2 to ×1.375 adds 294 kcal, which at 0.0004 kcal/step/kg is a claim of roughly **ten thousand extra
/// steps a day** — steps the pedometer then counts again.
///
/// So `.sedentary` is not a description of the user's job. It is "a day with no measured movement in it",
/// which is exactly the floor that `StepNeat`'s baseline subtraction and the measured workout term are
/// designed to build on top of.
///
/// `.lightlyActive` is kept for one reason: the goal row records which multiplier produced a past
/// target, and deleting the case would make old rows undecodable. Nothing in the diet path selects it.
///
/// The genuine gap this leaves — someone who STANDS all day without walking, where steps under-report
/// real expenditure — is small (a few tens of kcal) and is exactly what `AdaptiveExpenditureEngine`
/// corrects empirically within a few weeks. Far better than a picker that silently inflates the budget
/// for everyone who touches it.
public enum ActivityLevel: String, Equatable, Sendable, CaseIterable {
    /// A day with no measured movement — the floor that measured steps and workouts are added to.
    case sedentary
    /// Retained so historical goal rows decode. NOT offered, and not selected by the diet path: it
    /// double-counts movement the step counter already sees.
    case lightlyActive

    /// Multiplier applied to BMR. The standard activity factors.
    public var multiplier: Double {
        switch self {
        case .sedentary: return 1.2
        case .lightlyActive: return 1.375
        }
    }

    /// The only level the diet path may use. Named rather than spelled `.sedentary` at each call site, so
    /// the reason travels with the choice.
    public static let measuredMovementBaseline = ActivityLevel.sedentary
}

/// One day's expenditure, broken into the parts it was built from.
///
/// Kept as components rather than a single total so a screen can show its working. A user who is told
/// "2,322 kcal" and disagrees has nowhere to go; one who can see 2,017 + 155 + 150 can tell which part is
/// wrong — and with three different estimators in play, being able to say WHICH one is off is most of
/// the diagnostic value.
public struct DayExpenditure: Equatable, Sendable {
    /// Mifflin-St Jeor resting energy.
    public let bmrKcal: Double
    /// BMR × activity multiplier — baseline living, incidental movement included.
    public let baselineKcal: Double
    /// Energy from steps ABOVE the sedentary baseline, excluding steps taken inside workouts.
    public let stepNeatKcal: Double
    /// Measured workout energy, heart-rate derived.
    public let workoutKcal: Double

    public init(bmrKcal: Double, baselineKcal: Double, stepNeatKcal: Double, workoutKcal: Double) {
        self.bmrKcal = bmrKcal
        self.baselineKcal = baselineKcal
        self.stepNeatKcal = stepNeatKcal
        self.workoutKcal = workoutKcal
    }

    public var totalKcal: Double { baselineKcal + stepNeatKcal + workoutKcal }

    /// The part of the day's spend that came from MOVING, as opposed to existing.
    ///
    /// Named and derived here rather than re-added at each call site, because it is one half of a
    /// subtraction that has to be exact: a measured average TDEE already contains the calibration
    /// window's average activity, so deriving a baseline from it means subtracting precisely this. Two
    /// spellings of "activity" — one here and one in the deriving code — is how a double-count gets in.
    public var activityKcal: Double { stepNeatKcal + workoutKcal }

    /// What may be eaten today to hit the deficit. Never negative: a deficit larger than the day's
    /// expenditure is a broken plan, not a negative budget, and the clamp keeps a nonsense input from
    /// rendering as a nonsense instruction.
    public func budgetKcal(deficitKcal: Double) -> Double {
        max(0, totalKcal - max(0, deficitKcal))
    }
}

public enum CalorieTarget {

    // MARK: - Tuning surface
    //
    // Named and public on purpose. These are the numbers that get revised once there are weeks of real
    // data to revise them against, and burying them as literals is how that becomes archaeology.

    /// Floor on an adjusted deficit. NOTE: the user's backend used 200, which is ABOVE the small deficit a
    /// late-stage plateau calls for — so this is deliberately lower, and the goal-derived deficit is not
    /// clamped by it at all. It bounds only the Stage 2 recalibration, to stop a noisy week walking the
    /// target somewhere absurd.
    public static let minAdjustedDeficitKcal = 50.0

    /// Ceiling on an adjusted deficit. The user's backend figure, unchanged.
    public static let maxAdjustedDeficitKcal = 750.0

    /// How much of a detected shortfall to apply per adjustment. Half, so the loop converges instead of
    /// oscillating: weight data is noisy enough that a full correction would routinely overshoot and then
    /// correct back. The user's backend figure, unchanged.
    public static let correctionDamping = 0.5

    // MARK: - BMR

    /// Mifflin-St Jeor resting energy, kcal/day.
    ///
    ///     male:   10W + 6.25H − 5A + 5
    ///     female: 10W + 6.25H − 5A − 161
    ///
    /// DELIBERATELY NOT the revised Harris–Benedict used by `Calories.restingKcalPerS`. Two BMR formulas
    /// now live in this package, which needs justifying: Mifflin is the better-validated of the two for
    /// contemporary populations, and it is what the user's own tracking has run on for months — changing
    /// the constant under a person mid-diet would move their target for no reason they could observe. The
    /// measured-calorie path keeps Harris–Benedict because changing it would move every historical score.
    ///
    /// For a nonbinary profile: the midpoint of the two constants, matching how `Calories.Coeffs` handles
    /// the same problem rather than silently defaulting to one.
    public static func mifflinBMR(sex: String, weightKg: Double, heightCm: Double, age: Double) -> Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * age
        let offset: Double
        switch sex.lowercased() {
        case "female": offset = -161
        case "nonbinary": offset = (5 + -161) / 2
        default: offset = 5
        }
        return max(0, base + offset)
    }

    // MARK: - Assembling the day

    /// Baseline living: resting energy scaled for how much ordinary movement the day contains.
    ///
    /// The multiplier already covers a modest amount of walking, which is exactly why `StepNeat` subtracts
    /// a sedentary baseline before charging for steps — without that, the first few thousand steps would
    /// be paid for twice.
    public static func baselineKcal(bmrKcal: Double, activity: ActivityLevel) -> Double {
        bmrKcal * activity.multiplier
    }

    /// One day's expenditure from its measured parts. Pure assembly — the caller has already resolved
    /// steps and workouts, because knowing which steps belong to a workout needs the store.
    public static func dayExpenditure(sex: String, weightKg: Double, heightCm: Double, age: Double,
                                      activity: ActivityLevel,
                                      neatSteps: Int,
                                      workoutKcal: Double,
                                      baselineOverrideKcal: Double? = nil) -> DayExpenditure {
        let bmr = mifflinBMR(sex: sex, weightKg: weightKg, heightCm: heightCm, age: age)
        return DayExpenditure(
            bmrKcal: bmr,
            // ONLY the baseline is overridable, and that is the whole design. The per-day activity terms
            // below stay exactly as they were, so a measured baseline does not freeze the budget — it
            // still rises with today's steps and workouts, which is the behaviour the budget needs.
            //
            // Overriding the TOTAL instead would do one of two wrong things: double-count today's
            // activity (because a measured average already contains the window's average activity), or
            // flatten the budget into a fixed number. See `measuredBaseline(from:)`.
            baselineKcal: sanitisedBaselineOverride(baselineOverrideKcal, bmrKcal: bmr)
                ?? baselineKcal(bmrKcal: bmr, activity: activity),
            stepNeatKcal: StepNeat.kcal(stepsAboveBaseline: neatSteps, weightKg: weightKg),
            workoutKcal: max(0, workoutKcal))
    }

    // MARK: - Turning a measured TDEE into a baseline

    /// The floor an override has to clear: resting metabolism itself.
    ///
    /// A measured baseline BELOW the user's BMR is not a slow metabolism, it is a food log that is missing
    /// meals — and acting on it would hand out a starvation budget derived from the user's own bad data,
    /// which is the single most harmful thing this feature could do. Refused rather than clamped: clamping
    /// to BMR would still be a figure nobody measured, presented as though it were.
    ///
    /// Returns nil for an absent, non-finite, or sub-BMR override, so the caller falls back to the model.
    public static func sanitisedBaselineOverride(_ override: Double?, bmrKcal: Double) -> Double? {
        guard let override, override.isFinite, bmrKcal.isFinite, override >= bmrKcal else { return nil }
        return override
    }

    /// Convert a measured average daily expenditure into a BASELINE the per-day terms can ride on.
    ///
    /// `AdaptiveExpenditureEngine` reports average TDEE across three to six weeks, which already contains
    /// that window's average steps and workouts. Adding today's activity on top of it would therefore
    /// charge the average twice. Subtracting the window's mean activity first leaves a baseline — what the
    /// body spent existing — and today's real activity then sits on top of it exactly as it does with the
    /// modelled baseline.
    ///
    ///     measuredBaseline = measuredTDEE − mean(stepNeat + workoutKcal) over the same window
    ///
    /// The subtraction MUST use the same window the estimate came from. A mean taken over a different
    /// span is a different number and the error would be invisible — the budget would simply be wrong by
    /// however much the two windows' activity differed.
    ///
    /// nil when either input is unusable, rather than a figure built from a non-finite.
    public static func measuredBaseline(measuredTdeeKcal: Double,
                                        meanActivityKcal: Double) -> Double? {
        guard measuredTdeeKcal.isFinite, meanActivityKcal.isFinite, meanActivityKcal >= 0 else {
            return nil
        }
        let baseline = measuredTdeeKcal - meanActivityKcal
        guard baseline.isFinite, baseline > 0 else { return nil }
        return baseline
    }

    // MARK: - Recalibration (used in Stage 2; the arithmetic belongs with the rest of the model)

    /// Nudge a deficit toward what the weight trend actually shows, damped and clamped.
    ///
    /// `expectedKgPerWeek` and `actualKgPerWeek` are both POSITIVE when losing. Losing slower than
    /// predicted means true expenditure is lower than assumed, so the deficit must grow to keep the same
    /// pace — and vice versa.
    ///
    /// Damped because weight is noisy and a full correction would oscillate; clamped because no single
    /// week's evidence should be allowed to walk the target somewhere unsafe.
    public static func adjustedDeficit(currentDeficitKcal: Double,
                                       expectedKgPerWeek: Double,
                                       actualKgPerWeek: Double,
                                       damping: Double = correctionDamping) -> Double {
        let shortfallKgPerWeek = expectedKgPerWeek - actualKgPerWeek
        let dailyAdjustment = shortfallKgPerWeek * AdaptiveExpenditureEngine.kcalPerKg / 7 * damping
        return min(max(currentDeficitKcal + dailyAdjustment, minAdjustedDeficitKcal),
                   maxAdjustedDeficitKcal)
    }
}
