import Foundation

/// One day's inputs for the retrospective expenditure estimate. Both fields are optional because the two
/// series are independently sparse — a day with a weigh-in and no food log is common, and inventing a
/// value for the missing one is exactly what this engine must not do.
public struct AdaptiveExpenditureDay: Equatable, Sendable {
    public let day: String          // "yyyy-MM-dd", the app's day key
    public let caloriesIn: Double?
    public let weightKg: Double?
    /// The day's intake was logged as an admitted GUESS — a restaurant meal, a day out — rather than
    /// read off labels.
    ///
    /// Counts toward coverage, which is the entire point of having it: the alternative behaviour is
    /// omitting the day, and an omitted day is both a coverage hole AND a silent bias, because the days
    /// people fail to log are the big ones. A wide guess is strictly better evidence than no guess.
    ///
    /// It does widen the interval, upward. Defaulted so every existing caller and test is untouched.
    public let intakeIsRough: Bool

    public init(day: String, caloriesIn: Double? = nil, weightKg: Double? = nil,
                intakeIsRough: Bool = false) {
        self.day = day; self.caloriesIn = caloriesIn; self.weightKg = weightKg
        self.intakeIsRough = intakeIsRough
    }
}

/// How much the estimate below deserves to be trusted. Deliberately coarse — the inputs do not support
/// a percentage, and a number would imply a precision this method does not have.
public enum AdaptiveExpenditureConfidence: String, Equatable, Sendable {
    case building, moderate, high
}

/// A retrospective estimate of average daily energy expenditure, with an interval.
///
/// Never a single number: the method's error is dominated by things this engine cannot see (hydration
/// swings, an under-logged weekend), so a bare figure would be the fabrication the rest of NOOP refuses
/// to make. The interval is the honest output and the caller should render it as one.
public struct AdaptiveExpenditureEstimate: Equatable, Sendable {
    public let estimatedDailyKcal: Double
    public let lowerKcal: Double
    public let upperKcal: Double
    public let meanIntakeKcal: Double
    public let weightSlopeKgPerDay: Double
    public let intakeDays: Int
    public let weightReadings: Int
    public let windowDays: Int
    public let confidence: AdaptiveExpenditureConfidence
    /// How many of the logged days were admitted guesses.
    public let roughIntakeDays: Int

    /// True when the interval is deliberately LOPSIDED upward, because unlogged or rough days make this
    /// estimate more likely to be too low than too high.
    ///
    /// Exposed rather than left for a caller to infer from the bounds: a screen that wants to say "your
    /// real burn is probably at or above this" must not have to re-derive why, and a second derivation
    /// is free to disagree with this one.
    public var isLikelyUnderstated: Bool {
        (upperKcal - estimatedDailyKcal) - (estimatedDailyKcal - lowerKcal) > 1
    }

    public init(estimatedDailyKcal: Double, lowerKcal: Double, upperKcal: Double, meanIntakeKcal: Double,
                weightSlopeKgPerDay: Double, intakeDays: Int, weightReadings: Int, windowDays: Int,
                confidence: AdaptiveExpenditureConfidence, roughIntakeDays: Int = 0) {
        self.estimatedDailyKcal = estimatedDailyKcal; self.lowerKcal = lowerKcal; self.upperKcal = upperKcal
        self.meanIntakeKcal = meanIntakeKcal; self.weightSlopeKgPerDay = weightSlopeKgPerDay
        self.intakeDays = intakeDays; self.weightReadings = weightReadings; self.windowDays = windowDays
        self.confidence = confidence; self.roughIntakeDays = roughIntakeDays
    }
}

/// Average daily expenditure inferred from logged intake and the weight trend (TDEE by energy balance).
///
/// `expenditure = intake − change in stored energy`, with the conventional 7,700 kcal per kg of body mass.
/// The identity is exact; the inputs are not. Day-to-day weight is mostly water, and food logs are
/// under-reported by a wide and person-specific margin, so this is meaningful only over weeks and only as
/// a range.
///
/// DELIBERATELY NOT AN INPUT TO ANYTHING. It never feeds Charge, the calorie card, or the workout
/// calorie estimate: those come from measured heart rate through Keytel, and quietly overwriting a
/// measurement with an inference from a food diary would be a strictly worse number wearing the same
/// label. This answers a question the user asks explicitly, and returns nil rather than guess.
///
/// Kotlin twin: `AdaptiveExpenditureEngine`.
public enum AdaptiveExpenditureEngine {
    /// Energy density of body-mass change. The textbook 7,700 kcal/kg (≈3,500 kcal/lb) figure, which
    /// assumes the change is adipose; it over-states early loss, when a real share of it is glycogen and
    /// its bound water. That bias is one reason the output is an interval.
    public static let kcalPerKg = 7_700.0

    /// Windows. Three weeks is the floor because a week of water retention can hide a 500 kcal/day gap,
    /// and six weeks is the ceiling because beyond that the body's own expenditure has adapted and the
    /// average stops describing today.
    public static let minWindowDays = 21
    public static let maxWindowDays = 42

    /// Coverage floors. Intake is the weak input, so it carries the strictest gate: a fortnight of logs
    /// AND 70% of the window, which together reject the common "logged hard for five days" pattern that
    /// would otherwise read as a huge deficit.
    public static let minIntakeDays = 14
    public static let minIntakeCoverage = 0.70
    public static let minWeightReadings = 6

    /// Symmetric reporting error, as a share of mean intake. A food log can be wrong in either
    /// direction even on a day someone tried, so this half of the margin stays even-handed.
    public static let baseReportingError = 0.05

    /// How much bigger an UNLOGGED day is assumed to be than a logged one, as a share of mean intake.
    ///
    /// 0.35. This is the only genuinely assumed figure in the engine and it is stated as one. It is not
    /// arbitrary: the days that go unlogged are the ones that are hard to log — eating out, travelling,
    /// a holiday — and those plainly run well above a normal day rather than beside it. 35% of a ~2,100
    /// kcal mean is ~735 kcal, which is a restaurant meal and a couple of drinks.
    ///
    /// It drives the UPWARD half of the interval only. Set it too low and the engine presents a biased
    /// figure as a precise one; too high and the interval is too wide to act on. If it is ever revised,
    /// revise it for the same reason it exists — evidence about what an unlogged day actually contains.
    public static let unloggedDayExcess = 0.35

    /// What fraction of the unlogged penalty a ROUGH day carries. 0.4 — a guess is poor evidence but it
    /// is evidence, and it is anchored to a real meal the user remembers eating.
    ///
    /// This number is what makes guessing worth doing rather than omitting: the same day costs 0.4 of the
    /// uncertainty when guessed that it costs when skipped, and it keeps coverage intact on top.
    public static let roughGuessDiscount = 0.4

    /// nil when the history cannot support an estimate — the normal answer for most installs, and the
    /// point of the gates. `days` need not be sorted or contiguous.
    public static func estimate(days: [AdaptiveExpenditureDay]) -> AdaptiveExpenditureEstimate? {
        let ordered = days.sorted { $0.day < $1.day }
        guard let first = ordered.first?.day, let last = ordered.last?.day,
              let span = dayCount(from: first, to: last), span >= minWindowDays else { return nil }
        let window = min(span, maxWindowDays)
        // Keep the most RECENT `window` days: an adapted metabolism makes the tail the honest part.
        let recent = ordered.filter { d in
            guard let back = dayCount(from: d.day, to: last) else { return false }
            // `dayCount` is INCLUSIVE — `dayCount(last, last)` is 1 — so the last `window` days are
            // `back <= window`. A strict `<` silently drops the oldest day while still reporting the
            // full `window`, which both loses data and understates coverage.
            return back <= window
        }

        let logged = recent.filter { ($0.caloriesIn ?? 0) > 0 }
        let intake = logged.compactMap { $0.caloriesIn }
        let roughCount = logged.filter { $0.intakeIsRough }.count
        let weights = recent.compactMap { d -> (Int, Double)? in
            guard let w = d.weightKg, w > 0, let i = dayCount(from: first, to: d.day) else { return nil }
            return (i, w)
        }
        guard intake.count >= minIntakeDays,
              min(1.0, Double(intake.count) / Double(window)) >= minIntakeCoverage,
              Set(weights.map { $0.0 }).count >= minWeightReadings,
              let slope = leastSquaresSlope(weights) else { return nil }

        let meanIntake = intake.reduce(0, +) / Double(intake.count)
        // The identity. A RISING weight means intake exceeded expenditure, so the stored-energy term is
        // subtracted — getting this sign backwards is the classic error and it is why the test pins both
        // directions rather than only a deficit.
        let estimate = meanIntake - slope * kcalPerKg

        // Interval. Half a kilo of water across the window is an everyday swing and translates directly
        // into an apparent daily gap.
        let waterKcalPerDay = (0.5 * kcalPerKg) / Double(window)
        // Clamped: `coverage` is "share of the window that was logged", so it cannot exceed 1. A caller
        // that merged its two sparse series badly and passed a day twice would otherwise push it above 1,
        // which SHRINKS the margin and RAISES the confidence — making the answer look more certain than
        // its data, the one direction this engine must never err in. Clamping rather than de-duplicating
        // on purpose: silently picking one of two conflicting values for a day would hide the caller's bug.
        let coverage = min(1.0, Double(intake.count) / Double(window))

        // THE INTERVAL IS DELIBERATELY LOPSIDED, and this is the part that was wrong before.
        //
        // Two of the three error sources are symmetric: water weight can swing either way, and a food
        // log can be over- as well as under-stated. The third is not. The days someone fails to log are
        // not a random sample of their eating — they are the restaurant, the day out, the holiday — so
        // `meanIntake` taken over LOGGED days understates true mean intake, which makes the estimate
        // biased LOW by (1 − coverage) × (how much bigger an unlogged day is).
        //
        // The previous version noted that asymmetry in a comment and then added the term to BOTH bounds,
        // which presents a bias as if it were noise and hands out a budget that is systematically tight.
        // At 86% coverage it contributed ~29 kcal where the real bias is nearer 100.
        let symmetricMargin = waterKcalPerDay + meanIntake * baseReportingError

        // Upward only. Unlogged days first, then rough days — a day logged as an admitted guess is better
        // evidence than no day at all, so it carries a FRACTION of the unlogged penalty rather than the
        // whole of it, which is what makes guessing worth doing.
        let unloggedShare = 1.0 - coverage
        let roughShare = Double(roughCount) / Double(window)
        let upwardMargin = meanIntake * unloggedDayExcess * unloggedShare
                         + meanIntake * unloggedDayExcess * roughGuessDiscount * roughShare

        // DISTINCT days, not readings. Two weigh-ins on one morning are one day of evidence about the
        // trend, and counting both would let a chatty scale — or a caller that passed a day twice — buy
        // the same confidence as a fortnight of extra data.
        let weightDays = Set(weights.map { $0.0 }).count
        let confidence: AdaptiveExpenditureConfidence
        if window >= 28 && coverage >= 0.90 && weightDays >= 12 { confidence = .high }
        else if window >= 21 && coverage >= 0.80 { confidence = .moderate }
        else { confidence = .building }

        return AdaptiveExpenditureEstimate(
            estimatedDailyKcal: estimate,
            lowerKcal: estimate - symmetricMargin,
            upperKcal: estimate + symmetricMargin + upwardMargin,
            meanIntakeKcal: meanIntake, weightSlopeKgPerDay: slope,
            intakeDays: min(intake.count, window), weightReadings: weightDays, windowDays: window,
            confidence: confidence, roughIntakeDays: roughCount)
    }

    /// Ordinary least-squares slope in kg per DAY. nil when every reading shares one day, which would
    /// divide by zero — a real case when a scale syncs several readings with one timestamp.
    static func leastSquaresSlope(_ points: [(Int, Double)]) -> Double? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let meanX = points.reduce(0.0) { $0 + Double($1.0) } / n
        let meanY = points.reduce(0.0) { $0 + $1.1 } / n
        var num = 0.0, den = 0.0
        for (x, y) in points {
            let dx = Double(x) - meanX
            num += dx * (y - meanY); den += dx * dx
        }
        guard den > 0 else { return nil }
        return num / den
    }

    /// Whole days between two "yyyy-MM-dd" keys, inclusive of the first.
    ///
    /// nil on an unparseable key. `AnalyticsEngine.dayStartUtcSeconds` is deliberately nil-tolerant and
    /// returns 0 for one (so a bad key cannot take down a scoring pass), which is indistinguishable from
    /// 1970 here — and a stray 0 would silently stretch the window by twenty thousand days. Treating a
    /// zero as unparseable is the difference between refusing to answer and answering nonsense.
    static func dayCount(from: String, to: String) -> Int? {
        let a = AnalyticsEngine.dayStartUtcSeconds(from)
        let b = AnalyticsEngine.dayStartUtcSeconds(to)
        guard a > 0, b > 0 else { return nil }
        return (b - a) / 86_400 + 1
    }
}
