import Foundation

// MARK: - Step NEAT: the energy NOOP's heart-rate model throws away
//
// Non-Exercise Activity Thermogenesis — walking to the shop, standing, pacing on a call. It is the single
// largest source of variation in daily expenditure between two people of the same size, and NOOP cannot
// see it: `Calories.estimateDayEnergy` only counts active energy above 50% heart-rate reserve, and none
// of this comes close to that. The gate is right for its own purpose (Keytel over-counts ordinary daytime
// heart rate) and wrong for this one.
//
// Steps are the honest instrument here. A WHOOP 5.0/MG counts them directly, the relationship between
// steps and energy is roughly linear over ordinary walking, and it scales with bodyweight in a way that
// needs no calibration.
//
// TWO THINGS THIS MUST NOT DO, both of which would over-count:
//
//   1. Charge for steps the activity multiplier has already paid for. `ActivityLevel.sedentary` at ×1.2
//      is not a person lying still — it describes a day containing a few thousand incidental steps. So a
//      baseline is subtracted first, and only the excess is charged.
//
//   2. Charge for steps taken inside a workout. Those are already counted, properly, by heart rate — and
//      at their true intensity. Two thousand steps on an incline treadmill and two thousand walking to
//      the shop are not the same energy, and a flat per-step rate cannot tell them apart. The caller
//      subtracts workout-window steps before calling in (`DietExpenditure`).
//
// Pure arithmetic. The caller resolves which steps qualify.

public enum StepNeat {

    /// Steps an ordinary day contains before it counts as movement worth charging for.
    ///
    /// 3,000 is the user's own working figure, and it lines up with what a ×1.2 sedentary multiplier is
    /// usually taken to represent. Tunable because it is a description of a person's baseline, not a
    /// constant of nature.
    public static let sedentaryBaselineSteps = 3_000

    /// Net energy per step per kilogram of bodyweight.
    ///
    /// Derivation, so this is a figure rather than a magic number. Walking at an ordinary pace is about
    /// 3.5 METs. A MET is a multiple of resting metabolism, so the energy ABOVE resting — which is all
    /// that should be charged here, since resting is already in the BMR term — is (3.5 − 1) = 2.5 METs.
    ///
    ///     kcal/min = METs × 3.5 × weightKg / 200
    ///     net kcal/min at 2.5 METs = 2.5 × 3.5 × weightKg / 200 = 0.04375 × weightKg
    ///
    /// At a typical ~110 steps/min that is 0.000398 kcal per step per kg, rounded here to 0.0004.
    ///
    /// For a 73 kg person: 0.0292 kcal/step, so 7,000 steps above baseline ≈ 204 kcal. That is the right
    /// order of magnitude for a day's incidental walking, and deliberately on the conservative side —
    /// over-crediting NEAT inflates the eating budget, which is the error that silently stalls a diet.
    public static let netKcalPerStepPerKg = 0.0004

    /// Steps that count toward NEAT: the daily total, less steps taken inside workouts, less the
    /// sedentary baseline. Floored at zero — a day quieter than baseline earns nothing, it does not go
    /// into debt against a multiplier that already assumed some movement.
    public static func stepsAboveBaseline(dailySteps: Int,
                                          workoutSteps: Int,
                                          baseline: Int = sedentaryBaselineSteps) -> Int {
        max(0, dailySteps - max(0, workoutSteps) - max(0, baseline))
    }

    /// Energy for steps already reduced to the qualifying count.
    ///
    /// Takes the reduced figure rather than doing the subtraction itself, so a caller cannot accidentally
    /// apply the baseline twice — the one arithmetic error in this file that would silently under-count
    /// rather than crash.
    public static func kcal(stepsAboveBaseline: Int,
                            weightKg: Double,
                            perStepPerKg: Double = netKcalPerStepPerKg) -> Double {
        guard stepsAboveBaseline > 0, weightKg.isFinite, weightKg > 0 else { return 0 }
        return Double(stepsAboveBaseline) * weightKg * perStepPerKg
    }

    /// The whole calculation in one call, for a caller that already knows both step figures.
    public static func kcal(dailySteps: Int,
                            workoutSteps: Int,
                            weightKg: Double,
                            baseline: Int = sedentaryBaselineSteps,
                            perStepPerKg: Double = netKcalPerStepPerKg) -> Double {
        kcal(stepsAboveBaseline: stepsAboveBaseline(dailySteps: dailySteps,
                                                    workoutSteps: workoutSteps,
                                                    baseline: baseline),
             weightKg: weightKg,
             perStepPerKg: perStepPerKg)
    }
}
