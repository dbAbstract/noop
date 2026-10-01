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
    /// 4,000, raised from an initial 3,000 after checking it against the literature rather than intuition.
    /// Tudor-Locke & Bassett's widely used classification puts SEDENTARY at under 5,000 steps/day, with
    /// 5,000–7,499 as "low active" — characterised as someone doing no sport or exercise at all.
    /// Accelerometer studies of US adults land around 4,800–5,100/day.
    ///
    /// So 3,000 was not a generous baseline, it was a LOW one — and a low baseline credits too many steps
    /// as NEAT. 5,000 is arguably the better match for what a ×1.2 multiplier represents; 4,000 is the
    /// deliberately cautious middle, because the baseline and the multiplier describe the SAME incidental
    /// movement and moving one while assuming the other unchanged would subtract it twice.
    ///
    /// Tunable because it is a description of a person's baseline, not a constant of nature.
    public static let sedentaryBaselineSteps = 4_000

    /// Net energy per step per kilogram of bodyweight.
    ///
    /// 0.0003, revised DOWN from 0.0004. The original derivation priced every step as deliberate walking,
    /// which is not what the steps reaching this function are:
    ///
    ///     kcal/min = METs × 3.5 × weightKg / 200
    ///
    /// Purposeful walking at ~4.8 km/h is about 3.5 METs, so the energy above resting — all that should be
    /// charged here, since resting is already in the BMR term — is (3.5 − 1) = 2.5 METs, which at a
    /// typical ~110 steps/min gives 0.000398. That was the old figure.
    ///
    /// But the steps left HERE have already had workouts subtracted and the sedentary baseline removed, so
    /// what remains is pottering: kitchen, office, shop — slow and fragmented. That is 2.0–2.5 METs, so
    /// net-above-rest is 1.0–1.5, not 2.5. A slower cadence pushes the other way (fewer steps per minute
    /// means more kcal per step), and the two do not cancel: the MET over-estimate dominates by roughly
    /// 2×. The honest range is 0.00025–0.0003, and this takes the top of it — cautious without being
    /// punitive.
    ///
    /// For a 73 kg person: 0.0219 kcal/step, so 6,000 steps above baseline ≈ 131 kcal.
    ///
    /// WHY ERR LOW, explicitly. Over-crediting NEAT inflates the eating budget, and at a small deficit
    /// that is enough to erase it outright — a diet that stalls while every number on screen says it is
    /// working, which is the hardest failure to diagnose from the inside. Under-crediting is visible
    /// instead: you lose slightly faster than predicted. `AdaptiveExpenditureEngine` measures real
    /// expenditure from the scale once it has the data and overrides this estimate entirely, so these
    /// constants only govern the first few weeks — but that is exactly when someone is deciding whether
    /// the app can be trusted.
    public static let netKcalPerStepPerKg = 0.0003

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
