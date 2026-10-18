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
// The remedy is a CEILING, not a replacement: credit = min(recorded − resting, sport cap). The cap prices
// played time at the sport's Compendium MET and bench time at a recovery MET, both net of the 1 MET the
// baseline already covers. Sports with no entry get no cap — this only intervenes where the failure is
// understood. NOTHING HERE rewrites the stored workout: `energyKcal`, strain and the shared Keytel model
// (which has a Kotlin twin) are untouched, and the screen shows recorded beside credited.

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
    public static let recoveryMET = 2.0

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
        /// Recorded minus the resting energy the baseline already covers (equal to recorded for `.active`).
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
    }

    /// The budget credit for one workout.
    ///
    /// - Parameters:
    ///   - playedS: confirmed time actually playing. nil prices the whole duration as play, which still
    ///     caps an implausible figure but credits bench time generously until the user confirms.
    ///   - bmrKcalPerDay: the SAME resting figure the baseline uses (`CalorieTarget.mifflinBMR`), so what
    ///     is removed here is exactly what the baseline counted — not a second resting model's estimate.
    public static func credit(recordedKcal: Double, basis: EnergyBasis, sport: String, durationS: Double,
                              playedS: Double?, weightKg: Double, bmrKcalPerDay: Double) -> Credit {
        let recorded = recordedKcal.isFinite ? max(0, recordedKcal) : 0
        let duration = durationS.isFinite ? max(0, durationS) : 0
        let net: Double
        switch basis {
        case .gross:
            let restingPerS = (bmrKcalPerDay.isFinite ? max(0, bmrKcalPerDay) : 0) / 86_400
            net = max(0, recorded - restingPerS * duration)
        case .active:
            net = recorded
        }

        guard let met = intermittentSportMET(sport), duration > 0, weightKg.isFinite, weightKg > 0 else {
            return Credit(recordedKcal: recorded, netKcal: net, capKcal: nil, creditedKcal: net, playedS: nil)
        }
        let played = min(duration, max(0, (playedS?.isFinite == true ? playedS! : duration)))
        let bench = duration - played
        // kcal = MET × kg × hours; minus 1 MET because the baseline already pays the resting share.
        let cap = (met - 1) * weightKg * played / 3_600 + (recoveryMET - 1) * weightKg * bench / 3_600
        return Credit(recordedKcal: recorded, netKcal: net, capKcal: cap,
                      creditedKcal: min(net, cap), playedS: played)
    }
}

// MARK: - Played time from the strap's motion

/// Splits an intermittent session into played and bench minutes from the strap's dynamic acceleration.
///
/// A SUGGESTION, never applied on its own: the user confirms it (or edits it) before the budget uses it.
/// The repo's rule for anything derived from raw sensor data is that one matching night is not validation;
/// this was checked on three sessions across two rotation formats — 3 teams on one pitch (78/120 played,
/// format predicts 67 %) and 4 teams on one pitch (47/99 and 61/114, format predicts 50 %) — which is
/// enough to pre-fill a control, not enough to act without asking.
///
/// Method: per-minute mean of `dynAccel`, smoothed over the minute and its neighbours (a sprint-stop-sprint
/// minute inside a match should not read as bench), then minutes above `playThreshold` count as play.
public enum PlayedTimeEstimate {

    /// Smoothed per-minute mean dynAccel above which a minute counts as played. Bench minutes in the
    /// validation sessions mostly sat at 0.02–0.25; match minutes at 0.3–1.5.
    public static let playThreshold = 0.30
    /// Fraction of the session's minutes that must carry motion before a split is offered. Below it the
    /// gaps would decide the answer, so say nothing rather than guess.
    public static let minCoverage = 0.8

    /// Played seconds, or nil when motion coverage is too thin to say.
    public static func playedSeconds(samples: [(ts: Int, dynAccel: Double)], startTs: Int, endTs: Int) -> Double? {
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
        var playedMinutes = 0
        for m in 0..<minuteCount {
            // Neighbours that carry data only: a missing minute is unknown, not stillness.
            let window = [m - 1, m, m + 1].compactMap { $0 >= 0 && $0 < minuteCount ? mean[$0] : nil }
            guard !window.isEmpty else { continue }
            if window.reduce(0, +) / Double(window.count) > playThreshold { playedMinutes += 1 }
        }
        return min(Double(duration), Double(playedMinutes * 60))
    }
}
