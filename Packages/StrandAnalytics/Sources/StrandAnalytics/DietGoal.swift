import Foundation

// MARK: - Diet goal: a target weight and a timeline, from which the deficit is derived
//
// People think in "73 kg to 69 kg by March", not in "169 kcal/day". So the goal is stated the way it is
// actually held, and the deficit — the number the rest of the model needs — falls out of it:
//
//     kg to lose ÷ days  ×  7,700 kcal/kg  =  daily deficit
//
// Stating it this way is also what makes the guardrail legible. A timeline is a slider, and as it shortens
// the implied rate climbs; somewhere it stops being a diet and starts being a crash. Because the rate is
// DERIVED, that boundary can be shown on the slider itself as the user drags, rather than surfacing as an
// error after they commit to something unsafe.
//
// Pure arithmetic: no clock, no store. The caller supplies current weight, target, height and span.

/// How a goal's implied rate of loss reads against ordinary safety guidance.
///
/// Three bands rather than a bool, because "safe / not safe" hides the middle: a 0.8%/week cut is
/// sustainable for a few weeks and miserable for six months, and the user deserves to see which one they
/// have picked before they pick it.
public enum DietGoalRate: String, Equatable, Sendable {
    /// At or under ~0.5% of bodyweight per week. Slow, sustainable, and hard to fail.
    case gradual
    /// Up to ~1%/week. Works, but it is a push and lean mass starts to be at stake.
    case aggressive
    /// Faster than ~1%/week. Refused: past this the loss is increasingly not fat, and the deficit needed
    /// to sustain it is not compatible with eating adequately.
    case unsafe
}

/// A goal, plus everything derived from it. Every field is computed, so a screen can render the whole
/// consequence of a slider position without doing arithmetic of its own.
public struct DietGoalPlan: Equatable, Sendable {
    public let startWeightKg: Double
    public let targetWeightKg: Double
    public let months: Int
    /// Positive when losing.
    public let kgToLose: Double
    public let kgPerWeek: Double
    /// Share of CURRENT bodyweight lost per week — the figure the safety bands are defined on, because a
    /// kilo a week means something very different at 60 kg than at 120.
    public let percentBodyweightPerWeek: Double
    /// Daily kcal deficit this pace requires. Always ≥ 0.
    public let dailyDeficitKcal: Double
    public let rate: DietGoalRate

    public init(startWeightKg: Double, targetWeightKg: Double, months: Int, kgToLose: Double,
                kgPerWeek: Double, percentBodyweightPerWeek: Double, dailyDeficitKcal: Double,
                rate: DietGoalRate) {
        self.startWeightKg = startWeightKg
        self.targetWeightKg = targetWeightKg
        self.months = months
        self.kgToLose = kgToLose
        self.kgPerWeek = kgPerWeek
        self.percentBodyweightPerWeek = percentBodyweightPerWeek
        self.dailyDeficitKcal = dailyDeficitKcal
        self.rate = rate
    }

    /// Whether this plan may be committed. `unsafe` is the only refusal — `aggressive` is the user's call.
    public var isAllowed: Bool { rate != .unsafe }
}

/// Why a target weight was rejected. Separate from `DietGoalRate` because these are about the DESTINATION
/// being sound, not about the pace of getting there.
public enum DietGoalRejection: String, Equatable, Sendable, Error {
    /// The target is at or above the current weight — this model only describes loss.
    case notALoss
    /// The target sits below a BMI of 18.5. NOOP will not help someone plan their way into underweight.
    case belowHealthyBMI
    /// Height, weight or span was zero, negative or non-finite.
    case invalidInput
}

public enum DietGoal {

    /// Energy per kilogram of body mass. The same constant `AdaptiveExpenditureEngine` uses, deliberately:
    /// one converts a deficit into expected loss and the other reads expenditure back out of observed loss.
    /// If they disagreed, the app would predict one thing and then measure itself as having missed.
    public static let kcalPerKg = AdaptiveExpenditureEngine.kcalPerKg

    /// Weeks per month, for turning a month-count slider into days. 30.44 days is the mean Gregorian month;
    /// using 30 would quietly overstate the required deficit by about 1.5%.
    public static let daysPerMonth = 30.44

    /// Upper bound on sustainable loss, as a share of bodyweight per week. The usual clinical guidance is
    /// 0.5–1%; this is the outer edge of it.
    public static let maxPercentPerWeek = 1.0

    /// Below this, the pace is gentle enough that adherence rather than safety is the limiting factor.
    public static let gradualPercentPerWeek = 0.5

    /// The BMI floor a target may not go under. 18.5 is the conventional underweight threshold.
    public static let minHealthyBMI = 18.5

    // MARK: - Plan

    /// Derive the full plan from a goal, or say why the destination is unacceptable.
    ///
    /// Note what this does NOT reject: an aggressive pace. That is returned as a plan the caller may show
    /// with a warning and still allow, because a short aggressive block is a legitimate choice. Only the
    /// destination is gated here, and only `unsafe` pace blocks commitment (`DietGoalPlan.isAllowed`).
    public static func plan(startWeightKg: Double,
                            targetWeightKg: Double,
                            heightCm: Double,
                            months: Int) -> Result<DietGoalPlan, DietGoalRejection> {
        guard startWeightKg.isFinite, targetWeightKg.isFinite, heightCm.isFinite,
              startWeightKg > 0, targetWeightKg > 0, heightCm > 0, months >= 1 else {
            return .failure(.invalidInput)
        }
        guard targetWeightKg < startWeightKg else { return .failure(.notALoss) }
        guard bmi(weightKg: targetWeightKg, heightCm: heightCm) >= minHealthyBMI else {
            return .failure(.belowHealthyBMI)
        }

        let kgToLose = startWeightKg - targetWeightKg
        let days = Double(months) * daysPerMonth
        let kgPerWeek = kgToLose / days * 7
        let percent = kgPerWeek / startWeightKg * 100
        let deficit = kgToLose * kcalPerKg / days

        let rate: DietGoalRate
        if percent > maxPercentPerWeek { rate = .unsafe }
        else if percent > gradualPercentPerWeek { rate = .aggressive }
        else { rate = .gradual }

        return .success(DietGoalPlan(startWeightKg: startWeightKg,
                                     targetWeightKg: targetWeightKg,
                                     months: months,
                                     kgToLose: kgToLose,
                                     kgPerWeek: kgPerWeek,
                                     percentBodyweightPerWeek: percent,
                                     dailyDeficitKcal: deficit,
                                     rate: rate))
    }

    /// The shortest timeline, in whole months, that stays inside the safe band for this goal.
    ///
    /// Lets a slider mark where the unsafe region begins instead of only refusing once the user is already
    /// in it — the difference between a boundary you can see and a wall you walk into. nil when the goal
    /// itself is unacceptable.
    public static func fastestSafeMonths(startWeightKg: Double,
                                         targetWeightKg: Double,
                                         heightCm: Double,
                                         maxMonths: Int = 12) -> Int? {
        for m in 1...max(1, maxMonths) {
            if case .success(let p) = plan(startWeightKg: startWeightKg, targetWeightKg: targetWeightKg,
                                           heightCm: heightCm, months: m), p.isAllowed {
                return m
            }
        }
        return nil
    }

    /// The lowest weight a target may be set to at this height — the BMI floor, in kilograms, so a picker
    /// can bound itself rather than validating after the fact.
    public static func minTargetWeightKg(heightCm: Double) -> Double? {
        guard heightCm.isFinite, heightCm > 0 else { return nil }
        let m = heightCm / 100
        return minHealthyBMI * m * m
    }

    public static func bmi(weightKg: Double, heightCm: Double) -> Double {
        let m = heightCm / 100
        guard m > 0 else { return 0 }
        return weightKg / (m * m)
    }
}
