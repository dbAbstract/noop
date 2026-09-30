import Foundation

// MARK: - Weight trend: separating real change from water
//
// A single weigh-in is mostly noise. Water, glycogen (each gram binds roughly three of water), gut
// contents and sodium move scale weight by far more, day to day, than fat does. Comparing two readings —
// or even two weekly averages — therefore answers a different question than the one being asked.
//
// The number that matters is the SLOPE of the trend, and the honest companion to it is that slope's
// uncertainty. Those two together are what decide whether a deficit is working, and — crucially — whether
// it is yet possible to tell. At a 400 kcal/day deficit the expected change clears the noise inside a
// fortnight; at 150 kcal/day it does not clear it for over a month, and any verdict delivered sooner is
// reading water. That is not a preference about review cadence, it is arithmetic.
//
// So this file computes three things and refuses to guess at any of them:
//   • a smoothed trend weight (time-aware EWMA, so gaps between weigh-ins are handled honestly),
//   • the trend's slope WITH its standard error,
//   • how long a given deficit needs before its effect becomes distinguishable from that person's own
//     measured scatter.
//
// Pure arithmetic: no store, no UI, no clock. Every window and date is supplied by the caller.

/// One weigh-in, as days-since-epoch plus kilograms. Day-resolution because a scale reading is a daily
/// event; two readings on one morning are one day's evidence about a trend, not two.
public struct WeightReading: Equatable, Sendable {
    public let dayIndex: Int
    public let kg: Double

    public init(dayIndex: Int, kg: Double) {
        self.dayIndex = dayIndex
        self.kg = kg
    }
}

/// A fitted weight trend plus the uncertainty that says how much to believe it.
public struct WeightTrendFit: Equatable, Sendable {
    /// Kilograms per day. Negative is losing.
    public let slopeKgPerDay: Double
    /// Standard error of that slope, in kg/day. The whole point of the struct — a slope without it
    /// cannot be told apart from zero.
    public let standardError: Double
    /// Residual scatter about the fitted line (kg). This is the person's OWN measured noise, which is
    /// what makes the detectability answer theirs rather than a textbook figure.
    public let scatterKg: Double
    /// Distinct days that carried a reading.
    public let dayCount: Int
    /// Calendar span the readings cover, inclusive.
    public let spanDays: Int

    public init(slopeKgPerDay: Double, standardError: Double, scatterKg: Double,
                dayCount: Int, spanDays: Int) {
        self.slopeKgPerDay = slopeKgPerDay
        self.standardError = standardError
        self.scatterKg = scatterKg
        self.dayCount = dayCount
        self.spanDays = spanDays
    }

    /// Whether the slope is distinguishable from "no change" at roughly 95% confidence.
    ///
    /// The comparison the rest of the app should make before saying anything about progress. A slope of
    /// -0.02 kg/day means nothing if its standard error is 0.03.
    public var isDistinguishableFromZero: Bool {
        standardError > 0 && abs(slopeKgPerDay) >= WeightTrend.confidenceK * standardError
    }

    /// Kilograms per week, the unit a human actually thinks in.
    public var slopeKgPerWeek: Double { slopeKgPerDay * 7 }

    /// The ± band on the weekly figure, same confidence as `isDistinguishableFromZero`.
    public var weeklyMarginKg: Double { WeightTrend.confidenceK * standardError * 7 }
}

public enum WeightTrend {

    /// Energy density of body-mass change — the textbook 7,700 kcal/kg. Deliberately the SAME constant
    /// `AdaptiveExpenditureEngine.kcalPerKg` uses: the two answer opposite halves of one question
    /// (expenditure from weight, and weight from a deficit) and would contradict each other on screen if
    /// they disagreed on the conversion.
    public static let kcalPerKg = AdaptiveExpenditureEngine.kcalPerKg

    /// ~95% two-sided. Used both to decide `isDistinguishableFromZero` and to size the wait in
    /// `daysToDetect`, so the promise and the verdict are made on the same terms.
    public static let confidenceK = 1.96

    /// Half-life for the smoothed trend weight, in days.
    ///
    /// Ten days is the usual compromise: short enough that a genuine change shows within a fortnight,
    /// long enough that a single salty dinner does not move the line. The trend is for READING; every
    /// decision below is made from the regression, not from this.
    public static let trendHalfLifeDays = 10.0

    // MARK: - Smoothed trend weight

    /// Time-aware exponentially-weighted moving average over the readings, oldest first.
    ///
    /// Time-aware rather than index-based because weigh-ins are irregular: after a four-day gap the next
    /// reading should carry roughly four days' worth of weight, not one. An index-based EWMA would let
    /// somebody who weighs in twice a week drift far behind reality while appearing perfectly smooth.
    ///
    /// Returns one smoothed point per input reading, in the same order.
    public static func smoothed(_ readings: [WeightReading],
                                halfLifeDays: Double = trendHalfLifeDays) -> [WeightReading] {
        let ordered = readings.sorted { $0.dayIndex < $1.dayIndex }
        guard let first = ordered.first, halfLifeDays > 0 else { return ordered }
        var out: [WeightReading] = [first]
        var trend = first.kg
        var lastDay = first.dayIndex
        for r in ordered.dropFirst() {
            let gap = max(1, r.dayIndex - lastDay)
            // α for an elapsed gap: one half-life halves the weight carried by the old value.
            let alpha = 1 - exp(-Double(gap) * log(2) / halfLifeDays)
            trend += alpha * (r.kg - trend)
            out.append(WeightReading(dayIndex: r.dayIndex, kg: trend))
            lastDay = r.dayIndex
        }
        return out
    }

    // MARK: - Regression

    /// Least-squares fit of weight against day, with the slope's standard error and the residual scatter.
    ///
    /// nil when there is nothing to fit: fewer than three distinct days (two points fit a line exactly and
    /// leave no residual, so the error would come out zero and claim certainty it has not earned), or every
    /// reading on one day.
    ///
    /// Several readings on one day are averaged first. Two weigh-ins one morning are one day of evidence,
    /// and counting both would shrink the standard error as if the scale had bought real information.
    public static func fit(_ readings: [WeightReading]) -> WeightTrendFit? {
        var byDay: [Int: [Double]] = [:]
        for r in readings where r.kg.isFinite && r.kg > 0 {
            byDay[r.dayIndex, default: []].append(r.kg)
        }
        let points = byDay
            .map { (x: Double($0.key), y: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.x < $1.x }
        let n = Double(points.count)
        guard points.count >= 3, let lo = points.first?.x, let hi = points.last?.x, hi > lo else {
            return nil
        }

        let meanX = points.reduce(0.0) { $0 + $1.x } / n
        let meanY = points.reduce(0.0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0
        for p in points {
            let dx = p.x - meanX
            sxx += dx * dx
            sxy += dx * (p.y - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX

        // Residual standard deviation, n-2 degrees of freedom (a slope and an intercept were spent).
        var rss = 0.0
        for p in points {
            let e = p.y - (intercept + slope * p.x)
            rss += e * e
        }
        let scatter = (rss / (n - 2)).squareRoot()
        let se = (scatter * scatter / sxx).squareRoot()

        return WeightTrendFit(slopeKgPerDay: slope,
                              standardError: se,
                              scatterKg: scatter,
                              dayCount: points.count,
                              spanDays: Int(hi - lo) + 1)
    }

    // MARK: - Detectability

    /// The weight change a sustained daily deficit predicts, in kg/day. Negative for a deficit.
    public static func expectedRateKgPerDay(deficitKcal: Double) -> Double {
        -deficitKcal / kcalPerKg
    }

    /// How many DAILY weigh-ins are needed before a deficit's effect clears a person's own scatter.
    ///
    /// For n evenly spaced daily points the regression's leverage term is Σ(x-x̄)² = n(n²-1)/12, so
    ///
    ///     SE(slope) = σ / √(n(n²−1)/12)
    ///
    /// and the effect is distinguishable once |rate| ≥ k · SE. Solving for n has no closed form, so this
    /// walks n upward — cheap, exact against the same formula `fit` uses, and it cannot disagree with the
    /// verdict the way a closed-form approximation eventually would.
    ///
    /// Returns nil when the question is unanswerable rather than guessing: no deficit, no scatter to clear,
    /// or a target so small that `maxDays` of daily weighing still would not settle it — for which the
    /// honest answer is "not on any timescale worth planning around", not a number.
    ///
    /// ASSUMES A READING EVERY DAY. Weighing three times a week stretches the calendar wait by roughly the
    /// inverse of that rate; `daysToDetect(fit:deficitKcal:)` below accounts for the observed cadence.
    public static func requiredDailyReadings(deficitKcal: Double,
                                             scatterKg: Double,
                                             maxDays: Int = 120) -> Int? {
        let rate = abs(expectedRateKgPerDay(deficitKcal: deficitKcal))
        guard rate > 0, scatterKg > 0, scatterKg.isFinite else { return nil }
        var n = 3
        while n <= maxDays {
            let d = Double(n)
            let sxx = d * (d * d - 1) / 12
            let se = scatterKg / sxx.squareRoot()
            if rate >= confidenceK * se { return n }
            n += 1
        }
        return nil
    }

    /// Calendar days still to wait before this deficit becomes measurable, given what has been logged.
    ///
    /// Scales the required reading count by the OBSERVED weigh-in cadence, because the regression is fed
    /// by readings and not by dates: at three weigh-ins a week, thirty readings take seventy days to
    /// gather. Returns 0 once there is already enough, and nil when the answer is unknowable (no fit yet,
    /// or no deficit to detect).
    public static func daysToDetect(fit: WeightTrendFit?, deficitKcal: Double,
                                    maxDays: Int = 120) -> Int? {
        guard let fit, fit.spanDays > 0 else { return nil }
        guard let needed = requiredDailyReadings(deficitKcal: deficitKcal,
                                                 scatterKg: fit.scatterKg,
                                                 maxDays: maxDays) else { return nil }
        if fit.dayCount >= needed && fit.isDistinguishableFromZero { return 0 }
        let cadence = Double(fit.dayCount) / Double(fit.spanDays)   // readings per calendar day
        guard cadence > 0 else { return nil }
        let remainingReadings = Double(max(0, needed - fit.dayCount))
        return Int((remainingReadings / cadence).rounded(.up))
    }
}
