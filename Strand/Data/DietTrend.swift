import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Is it working?
//
// The other half of the question. `DietExpenditure` answers "what should I eat today"; this answers
// "is what I've been doing actually moving the weight" — and, far more often in the early weeks,
// "not yet, and here's when".
//
// That refusal is the feature, not a limitation of it. At a 150 kcal deficit the predicted change is
// ~0.14 kg/week while ordinary weigh-in scatter is ±0.3 kg, so any verdict delivered in the first month
// is reading water. Saying so — with a date — is strictly more useful than a confident number that
// happens to be noise, and it is the thing a weekly review cannot do.

/// Everything the trend section needs, resolved together so the verdict and the numbers behind it can
/// never disagree about which window they describe.
struct DietTrendReading: Equatable {
    /// nil until there are three distinct weigh-in days to fit through.
    let fit: WeightTrendFit?
    /// The deficit the goal asks for, in kcal/day. nil without a goal.
    let targetDeficitKcal: Double?
    /// What that deficit predicts, kg/week (negative = losing).
    let expectedKgPerWeek: Double?
    /// Calendar days still needed before the effect clears this person's own scatter. 0 when there is
    /// already enough; nil when unknowable.
    let daysToDetect: Int?
    /// The empirical expenditure estimate, once intake and weight coverage allow one.
    let adaptive: AdaptiveExpenditureEstimate?
    /// Distinct days with a logged intake in the window — the input the adaptive estimate gates hardest on.
    let intakeDays: Int
    let windowDays: Int
    /// Mean per-day ACTIVITY energy (step NEAT + workouts) across the same window the adaptive estimate
    /// used. nil when no day in the window banked one.
    ///
    /// Carried here rather than recomputed by the caller because it is one half of a subtraction that has
    /// to use the SAME window as the estimate: a mean over a different span silently shifts the derived
    /// baseline by however much the two windows' activity differed, and nothing would show that.
    let meanActivityKcal: Double?

    /// The measured BASELINE — average TDEE with the window's mean activity removed, so per-day steps and
    /// workouts can ride on top without the average being charged twice.
    ///
    /// nil whenever the estimate or the activity mean is missing. Deliberately derived here, once, beside
    /// the two figures it comes from.
    var measuredBaselineKcal: Double? {
        guard let adaptive, let meanActivityKcal else { return nil }
        return CalorieTarget.measuredBaseline(measuredTdeeKcal: adaptive.estimatedDailyKcal,
                                              meanActivityKcal: meanActivityKcal)
    }

    /// Whether the measured trend can be told apart from no change at all.
    var hasVerdict: Bool { fit?.isDistinguishableFromZero == true }

    /// Measured rate, kg/week. Present even without a verdict — but must not be shown as fact then.
    var actualKgPerWeek: Double? { fit?.slopeKgPerWeek }

    /// Losing MORE slowly than the deficit predicts means true expenditure is below the estimate.
    /// Positive = behind. nil unless both are known AND the measurement is trustworthy.
    var shortfallKgPerWeek: Double? {
        guard hasVerdict, let expected = expectedKgPerWeek, let actual = actualKgPerWeek else { return nil }
        // Both are negative when losing; the shortfall is how much less was lost than predicted.
        return (-expected) - (-actual)
    }
}

extension Repository {

    /// How far back the trend looks.
    ///
    /// Six weeks is `AdaptiveExpenditureEngine.maxWindowDays` and the ceiling for the same reason: beyond
    /// it the body's own expenditure has adapted, so an average stops describing the present.
    static let dietTrendWindowDays = AdaptiveExpenditureEngine.maxWindowDays

    /// Fit the trend, size the window, and run the empirical estimate — all over one window.
    func dietTrend(now: Date = Date()) async -> DietTrendReading {
        let window = Self.dietTrendWindowDays
        let goal = await currentDietGoal()

        // Weigh-ins → day-index readings. The index is days-since-epoch so gaps are real gaps; feeding
        // the regression consecutive indices for irregular weigh-ins would compress the x-axis and
        // overstate the slope.
        let weights = await weightHistory(days: window, now: now)
        let readings = weights.compactMap { row -> WeightReading? in
            guard let idx = Self.dayIndex(row.day) else { return nil }
            return WeightReading(dayIndex: idx, kg: row.kg)
        }
        let fit = WeightTrend.fit(readings)

        let deficit = goal?.dailyDeficitKcal
        let expected = deficit.map { WeightTrend.expectedRateKgPerDay(deficitKcal: $0) * 7 }
        let toDetect = deficit.flatMap { WeightTrend.daysToDetect(fit: fit, deficitKcal: $0) }

        // The empirical check. Intake and weight are independently sparse, so they are merged by day
        // rather than zipped — a day with a weigh-in and no food log is common and must not drop the
        // weigh-in.
        let intake = await foodHistory(days: window, now: now)
        var byDay: [String: (kcal: Double?, kg: Double?)] = [:]
        for row in intake where row.kcal > 0 { byDay[row.day, default: (nil, nil)].kcal = row.kcal }
        for row in weights { byDay[row.day, default: (nil, nil)].kg = row.kg }
        let adaptiveDays = byDay.map { AdaptiveExpenditureDay(day: $0.key, caloriesIn: $0.value.kcal,
                                                              weightKg: $0.value.kg) }
        let adaptive = AdaptiveExpenditureEngine.estimate(days: adaptiveDays)

        // The window the ESTIMATE actually used, not the one requested: `estimate` keeps only the most
        // recent `maxWindowDays` and reports what it kept. Averaging activity over a longer span than the
        // estimate spans would misprice the baseline by the difference.
        let activityWindow = adaptive?.windowDays ?? window
        let meanActivity = await meanDietActivityKcal(days: activityWindow, now: now)

        return DietTrendReading(fit: fit,
                                targetDeficitKcal: deficit,
                                expectedKgPerWeek: expected,
                                daysToDetect: toDetect,
                                adaptive: adaptive,
                                intakeDays: intake.filter { $0.kcal > 0 }.count,
                                windowDays: window,
                                meanActivityKcal: meanActivity)
    }

    /// A proposed new daily deficit, or nil when none is earned.
    ///
    /// Deliberately returns nil far more often than not. It requires a MEASURED trend — not merely a
    /// fitted one — so a proposal can never be made from noise, which is the failure this whole approach
    /// exists to avoid. A proposal that cannot be justified is worse than none, because the user has no
    /// way to tell the two apart once it is on screen.
    func proposedDeficit(from reading: DietTrendReading) -> Double? {
        guard reading.hasVerdict,
              let current = reading.targetDeficitKcal,
              let expected = reading.expectedKgPerWeek,
              let actual = reading.actualKgPerWeek else { return nil }
        let next = CalorieTarget.adjustedDeficit(currentDeficitKcal: current,
                                                 expectedKgPerWeek: -expected,
                                                 actualKgPerWeek: -actual)
        // A change smaller than this is inside the noise that produced it — proposing it would be
        // theatre, and accepting it would move the target for no reason the data supports.
        guard abs(next - current) >= 25 else { return nil }
        return next
    }

    /// Days since the unix epoch for a `yyyy-MM-dd` local day key.
    ///
    /// The regression's x-axis. Using a row's position in the array instead would make a fortnight's gap
    /// look like one day and badly overstate the slope.
    static func dayIndex(_ dayKey: String) -> Int? {
        guard let bounds = dayBounds(dayKey) else { return nil }
        return bounds.start / 86_400
    }
}
