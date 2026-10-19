import Foundation

// MARK: - Workout budget credit: how much of a recorded workout the diet budget may spend
//
// FORK-LOCAL (diet). A workout's stored `energyKcal` is the heart-rate model's answer to "what did this
// session cost?". This file answers a different question — "how much may today's food budget grow because
// of it?" — and the two must not share a number, for two reasons the 2026-10-15 futsal session made
// concrete (120 min, recorded 1,720 kcal):
//
//   1. RESTING ENERGY IS ALREADY IN THE BASELINE. The HR bout figure is GROSS: resting plus active. The
//      budget's baseline (BMR × 1.2, or a measured baseline) already pays for every resting minute of the
//      day, workout minutes included, so adding the gross figure charges those minutes twice. ~140 kcal
//      for that session.
//
//   2. KEYTEL DOES NOT FIT INTERMITTENT PLAY. The equation was fitted to steady exercise. Between matches
//      heart rate stays near 130 while the wearer sits, and the model bills those minutes at ~10.7 kcal/min
//      — jogging pace. The strap's own motion split that session into 78 played / 42 bench minutes, and the
//      bench alone carried ~450 kcal.
//
// The credit is min(priced − resting, sport cap). "Priced" is `SportEnergy`'s gross for a strap-recorded
// session whose heart-rate trace the budget re-priced (bench minutes at recovery pace, the sport's ceiling on
// the rest), or the stored figure for an import. The cap prices played time at the sport's Compendium MET and
// bench time at a recovery MET, both net of the 1 MET the baseline already covers; it stays as the safety net
// for a strap that recorded no motion. Sports with no entry get no cap. NOTHING HERE rewrites the stored
// workout: `energyKcal`, strain and the shared Keytel model (which has a Kotlin twin) are untouched, and the
// screen shows recorded beside credited.

public enum WorkoutBudgetCredit {

    /// What a source's stored energy figure contains.
    public enum EnergyBasis: Equatable, Sendable {
        /// Resting + active over the session: NOOP's own HR model, WHOOP imports, manual sessions.
        case gross
        /// Active energy only, resting already excluded: Apple Health workouts.
        case active
    }

    /// Bench / between-match minutes. Above resting (1 MET) on purpose: the wearer is standing, walking
    /// about and paying recovery oxygen debt from the last match — real cost, but a fraction of play's.
    /// The same figure `SportEnergy` prices an off minute at, so the cap and the model agree on the bench.
    public static let recoveryMET = SportEnergy.offMET

    /// Played-time MET for intermittent field and court sports, from the Adult Compendium of Physical
    /// Activities (competitive entries, so the cap is a ceiling rather than a typical value). nil = no cap.
    ///
    /// Matched on the lowercased label, because sport names are free text and the same game arrives as
    /// "Soccer", "soccer" or a typed "Futsal". Exact "football" only: "American football" and
    /// "Australian football" are different games with no entry here.
    public static func intermittentSportMET(_ sport: String) -> Double? {
        let s = sport.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("soccer") || s.contains("futsal") || s == "football" { return 10.0 }
        if s.contains("sand volleyball") || s.contains("beach volleyball") { return 8.0 }
        if s.contains("volleyball") { return 6.0 }
        if s.contains("basketball") { return 8.0 }
        if s.contains("handball") { return 8.0 }
        if s.contains("rugby") { return 8.3 }
        if s.contains("ice hockey") { return 8.0 }
        if s.contains("field hockey") { return 7.8 }
        if s.contains("lacrosse") { return 8.0 }
        return nil
    }

    public struct Credit: Equatable, Sendable {
        /// The stored workout figure, unchanged.
        public let recordedKcal: Double
        /// The figure the credit was priced from: `SportEnergy`'s gross for a strap-recorded row whose trace
        /// was re-priced, otherwise the recorded figure itself.
        public let pricedKcal: Double
        /// Priced minus the resting energy the baseline already covers (equal to priced for `.active`).
        public let netKcal: Double
        /// The sport ceiling, or nil when the sport has no entry.
        public let capKcal: Double?
        /// What the budget actually receives.
        public let creditedKcal: Double
        /// Played seconds the cap was priced on; nil when uncapped. Equals the duration when no played
        /// time was supplied.
        public let playedS: Double?

        /// True when the ceiling, not the HR model, set the credit — the case the screen must explain.
        public var isCapped: Bool { capKcal.map { $0 < netKcal } ?? false }
        /// True when the budget priced the trace itself rather than taking the stored figure.
        public var isRepriced: Bool { abs(pricedKcal - recordedKcal) > 0.5 }
    }

    /// The budget credit for one workout.
    ///
    /// - Parameters:
    ///   - playedS: confirmed time actually playing. nil prices the whole duration as play, which still
    ///     caps an implausible figure but credits bench time generously until the user confirms.
    ///   - bmrKcalPerDay: the SAME resting figure the baseline uses (`CalorieTarget.mifflinBMR`), so what
    ///     is removed here is exactly what the baseline counted — not a second resting model's estimate.
    ///   - pricedKcal: `SportEnergy`'s gross for the session when the budget re-priced the trace; nil takes
    ///     the recorded figure. The recorded figure is carried through unchanged either way, so a screen can
    ///     show both. The cap still applies on top: it is the safety net for a session whose motion the strap
    ///     did not record (a 4.0) but whose played time the wearer confirmed.
    public static func credit(recordedKcal: Double, basis: EnergyBasis, sport: String, durationS: Double,
                              playedS: Double?, weightKg: Double, bmrKcalPerDay: Double,
                              pricedKcal: Double? = nil) -> Credit {
        let recorded = recordedKcal.isFinite ? max(0, recordedKcal) : 0
        let priced = pricedKcal.map { $0.isFinite ? max(0, $0) : 0 } ?? recorded
        let duration = durationS.isFinite ? max(0, durationS) : 0
        let net: Double
        switch basis {
        case .gross:
            let restingPerS = (bmrKcalPerDay.isFinite ? max(0, bmrKcalPerDay) : 0) / 86_400
            net = max(0, priced - restingPerS * duration)
        case .active:
            net = priced
        }

        guard let met = intermittentSportMET(sport), duration > 0, weightKg.isFinite, weightKg > 0 else {
            return Credit(recordedKcal: recorded, pricedKcal: priced, netKcal: net, capKcal: nil,
                          creditedKcal: net, playedS: nil)
        }
        let played = min(duration, max(0, (playedS?.isFinite == true ? playedS! : duration)))
        let bench = duration - played
        // kcal = MET × kg × hours; minus 1 MET because the baseline already pays the resting share.
        let cap = (met - 1) * weightKg * played / 3_600 + (recoveryMET - 1) * weightKg * bench / 3_600
        return Credit(recordedKcal: recorded, pricedKcal: priced, netKcal: net, capKcal: cap,
                      creditedKcal: min(net, cap), playedS: played)
    }
}

// MARK: - Played time from the strap's motion

/// Splits an intermittent session into played and bench minutes from the strap's dynamic acceleration.
///
/// Two readers, two rules. The DIET BUDGET applies the split as soon as the motion lands, labelled as the
/// strap's unconfirmed suggestion, because the alternative — pricing bench minutes at match pace until the
/// wearer gets round to a button — is the error this exists to remove. The STORED workout figure changes only
/// when the wearer confirms or edits the played time: that is their number, and an explicit act rewrites it.
/// The repo's rule for anything derived from raw sensor data is that one matching night is not validation;
/// this was checked on three sessions across two rotation formats — 3 teams on one pitch (78/120 played,
/// format predicts 67 %) and 4 teams on one pitch (47/99 and 61/114, format predicts 50 %).
///
/// Method: per-minute mean of `dynAccel`, smoothed over the minute and its neighbours (a sprint-stop-sprint
/// minute inside a match should not read as bench), then minutes above `playThreshold` count as play. When
/// the wearer has confirmed a total, the most-active minutes up to that total are the played ones, so the
/// confirmed figure and the minute-by-minute pricing describe the same session.
public enum PlayedTimeEstimate {

    /// Smoothed per-minute mean dynAccel above which a minute counts as played. Bench minutes in the
    /// validation sessions mostly sat at 0.02–0.25; match minutes at 0.3–1.5.
    public static let playThreshold = 0.30
    /// Fraction of the session's minutes that must carry motion before a split is offered. Below it the
    /// gaps would decide the answer, so say nothing rather than guess.
    public static let minCoverage = 0.8

    /// Smoothed per-minute motion: each entry is the mean dynAccel over the minute and the neighbours that
    /// carry data, nil for a minute with no data in it or beside it. nil as a whole when fewer than
    /// `minCoverage` of the minutes have any reading.
    public static func minuteActivity(samples: [(ts: Int, dynAccel: Double)], startTs: Int, endTs: Int) -> [Double?]? {
        let duration = endTs - startTs
        guard duration > 0 else { return nil }
        let minuteCount = (duration + 59) / 60
        var sum = [Double](repeating: 0, count: minuteCount)
        var n = [Int](repeating: 0, count: minuteCount)
        for s in samples where s.ts >= startTs && s.ts < endTs && s.dynAccel.isFinite {
            let m = (s.ts - startTs) / 60
            sum[m] += s.dynAccel
            n[m] += 1
        }
        let present = n.filter { $0 > 0 }.count
        guard Double(present) / Double(minuteCount) >= minCoverage else { return nil }

        let mean: [Double?] = (0..<minuteCount).map { n[$0] > 0 ? sum[$0] / Double(n[$0]) : nil }
        return (0..<minuteCount).map { m in
            // Neighbours that carry data only: a missing minute is unknown, not stillness.
            let window = [m - 1, m, m + 1].compactMap { $0 >= 0 && $0 < minuteCount ? mean[$0] : nil }
            return window.isEmpty ? nil : window.reduce(0, +) / Double(window.count)
        }
    }

    /// Per-minute off-mask for `SportEnergy.price` (true = bench). nil when there is no usable motion.
    ///
    /// With no confirmed total, a minute is on when its smoothed motion clears `playThreshold`; a minute
    /// without data is off, as the suggestion has always counted it. With a confirmed `playedS`, the
    /// `round(playedS / 60)` most-active minutes are on (minutes without data rank last, ties go to the
    /// earlier minute), so the wearer's total is honoured minute by minute.
    public static func offMask(minuteActivity: [Double?]?, playedS: Double?) -> [Bool]? {
        guard let activity = minuteActivity, !activity.isEmpty else { return nil }
        guard let playedS, playedS.isFinite else {
            return activity.map { !(($0 ?? 0) > playThreshold) }
        }
        let onCount = min(activity.count, max(0, Int((playedS / 60).rounded())))
        let ranked = activity.indices.sorted { a, b in
            let va = activity[a] ?? -Double.infinity, vb = activity[b] ?? -Double.infinity
            return va != vb ? va > vb : a < b
        }
        var off = [Bool](repeating: true, count: activity.count)
        for i in ranked.prefix(onCount) { off[i] = false }
        return off
    }

    /// Played seconds, or nil when motion coverage is too thin to say.
    public static func playedSeconds(samples: [(ts: Int, dynAccel: Double)], startTs: Int, endTs: Int) -> Double? {
        guard let mask = offMask(minuteActivity: minuteActivity(samples: samples, startTs: startTs, endTs: endTs),
                                 playedS: nil) else { return nil }
        let playedMinutes = mask.filter { !$0 }.count
        return min(Double(endTs - startTs), Double(playedMinutes * 60))
    }
}
