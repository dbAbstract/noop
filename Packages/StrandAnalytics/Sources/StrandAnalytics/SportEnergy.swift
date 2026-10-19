import Foundation
import WhoopProtocol

// MARK: - Sport-aware bout energy (flex-HR / heart-rate-reserve model)
//
// FORK-LOCAL (Apple). The shared `Calories.estimateBoutCalories` (Keytel 2005) stays as it is: the day path,
// the detector and the Kotlin twin still read it. This file is the model the Apple app prices a strap-recorded
// workout with, and the one the diet budget re-prices every such workout from.
//
// Why a second model. Checked against one wearer's 312 WHOOP-exported sessions (same body, same heart rates),
// Keytel ran 1.9× WHOOP at 100 bpm, 1.6× at 110, 1.4× at 120, 1.2× at 140 and 1.06× at 160. The shape of the
// error is the equation's intercept: the moment a reading crosses the 30 % heart-rate-reserve gate the rate
// jumps from resting (~1.2 kcal/min) to ~5.5 kcal/min, so every easy minute is priced at about double. WHOOP's
// own curve is the same for every sport (its slope per bpm is alike for soccer, weights, snowboarding and
// walking) and its per-sport means land on Compendium values, which makes it a usable reference even though
// it is itself an estimate.
//
// The model here is the classic flex-HR method (Ceesay et al. 1989) with the %HRR ≈ %VO₂-reserve relation
// (Swain & Leutholtz 1997) above the flex point:
//
//     hrr  = (hr − resting) / (HRmax − resting), clamped to [0, 1]
//     MET  = 1 + max(0, (hrr − flex) / (1 − flex)) × (METmax − 1)        METmax = Uth VO₂max / 3.5
//     kcal = min(MET, sport ceiling) × kg × hours                          1 MET = 1 kcal·kg⁻¹·h⁻¹
//
// Anchored at both ends — resting at the flex point, VO₂max at HRmax — and continuous between, so there is no
// jump to explain. With flex = 0.25 it sits within ±6 % of WHOOP's per-bpm curve from 130 bpm up and 10–20 %
// above it at 90–120 bpm for the wearer it was checked on.
//
// What is sport-specific is NOT the curve but the handling of minutes where heart rate and oxygen uptake come
// apart:
//   - intermittent play (futsal, basketball…): between matches the heart stays near 130 while the wearer sits,
//     so an "off" minute — from the strap's motion, or the wearer's confirmed played time — is priced at a
//     recovery MET whatever the heart rate says;
//   - resistance work: a pressor response lifts heart rate far above the oxygen cost, so a per-minute ceiling
//     at the Compendium's vigorous value bounds it;
//   - alpine (snowboarding): a lift ride is sitting still in the cold. The lift/ride split is a follow-up that
//     waits for one real day of strap data; until then the sport is priced as steady with a ceiling.
// Every ceiling is a Compendium vigorous value, so a sport cannot be priced above what it can plausibly cost.
public enum SportEnergy {

    public enum SportClass: String, Equatable, Sendable {
        case steady, intermittent, resistance, alpine, unknown
    }

    /// What the model knows about a sport: how to treat time off, and the most a minute of it may cost.
    public struct Traits: Equatable, Sendable {
        public let sportClass: SportClass
        /// Per-minute ceiling on the mean MET, or nil when the sport is unknown.
        public let ceilingMET: Double?

        public init(sportClass: SportClass, ceilingMET: Double?) {
            self.sportClass = sportClass
            self.ceilingMET = ceilingMET
        }

        /// The MET an "off" minute is priced at, or nil when the sport has no off minutes.
        public var offMET: Double? { sportClass == .intermittent ? SportEnergy.offMET : nil }

        /// Matched on the lowercased label, as `WorkoutBudgetCredit.intermittentSportMET` is — sport names are
        /// free text. The intermittent set is READ from that function rather than repeated here, so the class
        /// and the budget's cap cannot disagree about which sports rotate.
        public static func resolve(_ sport: String) -> Traits {
            if let met = WorkoutBudgetCredit.intermittentSportMET(sport) {
                return Traits(sportClass: .intermittent, ceilingMET: met)
            }
            let s = sport.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if s.contains("weight") || s.contains("strength") || s.contains("bodybuilding")
                || s.contains("powerlifting") || s.contains("lifting") {
                return Traits(sportClass: .resistance, ceilingMET: 6.0)
            }
            if s.contains("snowboard") || s.contains("skiing") || s.contains("ski ") || s == "ski" {
                return Traits(sportClass: .alpine, ceilingMET: 8.0)
            }
            if s.contains("cycling") || s.contains("cycle") || s.contains("biking") || s.contains("spinning") {
                return Traits(sportClass: .steady, ceilingMET: 12.0)
            }
            if s.contains("running") || s.contains("treadmill run") || s == "run" {
                return Traits(sportClass: .steady, ceilingMET: 14.0)
            }
            if s.contains("walking") || s.contains("treadmill walk") || s == "walk" {
                return Traits(sportClass: .steady, ceilingMET: 6.0)
            }
            if s.contains("hiking") || s == "hike" {
                return Traits(sportClass: .steady, ceilingMET: 8.0)
            }
            return Traits(sportClass: .unknown, ceilingMET: nil)
        }
    }

    /// Fraction of heart-rate reserve below which a reading is priced at resting. The flex point of the
    /// flex-HR method; 0.25 is where the wearer's WHOOP history put it.
    public static let flexHRRFraction = 0.25
    /// Bench, between-match minutes. Above resting on purpose: the wearer stands, walks about and repays the
    /// last match's oxygen debt. The budget's cap uses the same figure (`WorkoutBudgetCredit.recoveryMET`).
    public static let offMET = 2.0
    /// When no resting HR is known. The same default the Keytel path and `StrainScorer` use.
    public static let defaultRestingHR = 60.0
    /// When no HRmax is known. The same default `Calories.estimateBoutCalories` uses.
    public static let defaultHRmax = 220.0
    /// Resting oxygen uptake, ml·kg⁻¹·min⁻¹ per MET.
    public static let mlPerKgPerMinPerMET = 3.5

    /// Everything the curve was drawn with, kept on the result so a screen can print it.
    public struct Inputs: Equatable, Sendable {
        public let hrmax: Double
        public let restingHR: Double
        public let vo2max: Double
        public let metMax: Double
        public let weightKg: Double
        /// The flex point in bpm: readings at or below it cost 1 MET.
        public let flexHRBPM: Double
        public let traits: Traits
        /// True when no resting HR was supplied and `defaultRestingHR` stood in — the screen says so.
        public let restingHRWasDefaulted: Bool

        public init(hrmax: Double, restingHR: Double, vo2max: Double, metMax: Double, weightKg: Double,
                    flexHRBPM: Double, traits: Traits, restingHRWasDefaulted: Bool) {
            self.hrmax = hrmax; self.restingHR = restingHR; self.vo2max = vo2max; self.metMax = metMax
            self.weightKg = weightKg; self.flexHRBPM = flexHRBPM; self.traits = traits
            self.restingHRWasDefaulted = restingHRWasDefaulted
        }
    }

    /// Resolve the curve's inputs. Missing figures fall back exactly as `Calories.estimateBoutCalories` does
    /// (70 kg, 220 HRmax, 60 resting), so a cold start prices the same way on both paths.
    public static func inputs(profile: UserProfile, hrmax: Double?, restingHR: Double?, sport: String) -> Inputs {
        let weight = profile.weightKg.isFinite && profile.weightKg > 0 ? profile.weightKg : 70.0
        let max = (hrmax?.isFinite == true && hrmax! > 0) ? hrmax! : defaultHRmax
        let defaulted = !(restingHR?.isFinite == true && restingHR! > 0)
        var rest = defaulted ? defaultRestingHR : restingHR!
        // A resting HR at or above HRmax leaves no reserve to price on; treat it as the default instead.
        if rest >= max { rest = min(defaultRestingHR, max - 1) }
        let vo2 = Calories.vo2maxFor(hrmax: max, restingHR: rest) ?? (15.3 * max / rest)
        let reserve = max - rest
        return Inputs(hrmax: max, restingHR: rest, vo2max: vo2, metMax: vo2 / mlPerKgPerMinPerMET,
                      weightKg: weight, flexHRBPM: rest + flexHRRFraction * reserve,
                      traits: Traits.resolve(sport), restingHRWasDefaulted: defaulted)
    }

    /// The curve: METs at one heart-rate reading. Never below 1, never above `metMax`.
    public static func met(bpm: Double, inputs: Inputs) -> Double {
        guard bpm.isFinite else { return 1.0 }
        let reserve = inputs.hrmax - inputs.restingHR
        guard reserve > 0 else { return 1.0 }
        let hrr = min(1.0, max(0.0, (min(bpm, inputs.hrmax) - inputs.restingHR) / reserve))
        let above = max(0.0, (hrr - flexHRRFraction) / (1.0 - flexHRRFraction))
        return 1.0 + above * (inputs.metMax - 1.0)
    }

    /// One session minute's heart-rate evidence: how many seconds of readings landed in it and their MET
    /// weighted by those seconds. `seconds` can exceed 60 when a gap (≤ 150 s) is carried by one reading.
    public struct Minute: Equatable, Sendable {
        public let seconds: Double
        public let metSeconds: Double
        public init(seconds: Double, metSeconds: Double) { self.seconds = seconds; self.metSeconds = metSeconds }
        /// Mean MET over the covered seconds, or nil for a minute with no reading.
        public var meanMET: Double? { seconds > 0 ? metSeconds / seconds : nil }
    }

    /// A session's heart-rate evidence folded per minute, independent of any played-time decision. Pricing
    /// it for a given off-mask is a pure fold (`price`), which is what lets a coach card quote the figure the
    /// budget will then produce without a second read of the store.
    public struct Ledger: Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public let minutes: [Minute]
        public init(startTs: Int, endTs: Int, minutes: [Minute]) {
            self.startTs = startTs; self.endTs = endTs; self.minutes = minutes
        }
        public var durationS: Double { Double(max(0, endTs - startTs)) }
        public var coveredSeconds: Double { minutes.reduce(0) { $0 + $1.seconds } }
        public var minuteCount: Int { minutes.count }
    }

    /// Number of session minutes, the last one possibly partial.
    public static func minuteCount(startTs: Int, endTs: Int) -> Int {
        let duration = max(0, endTs - startTs)
        return (duration + 59) / 60
    }

    /// Fold HR samples inside [startTs, endTs] into the per-minute ledger. nil under two samples.
    ///
    /// Each reading carries the elapsed time to the next one, capped at `WorkoutDetector.mergeGapS` (150 s),
    /// the last one a single second — the same weighting the Keytel bout path uses, for the same reason: a
    /// sparse WHOOP 5/MG stream is counted over real seconds, a wear gap cannot inflate one reading.
    public static func ledger(samples: [HRSample], startTs: Int, endTs: Int, inputs: Inputs) -> Ledger? {
        let count = minuteCount(startTs: startTs, endTs: endTs)
        guard count > 0 else { return nil }
        let ordered = samples.filter { $0.ts >= startTs && $0.ts <= endTs }.sorted { $0.ts < $1.ts }
        guard ordered.count >= 2 else { return nil }
        var seconds = [Double](repeating: 0, count: count)
        var metSeconds = [Double](repeating: 0, count: count)
        for i in ordered.indices {
            let dur: Double
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - ordered[i].ts)
                dur = gap > 0 ? min(gap, WorkoutDetector.mergeGapS) : 1.0
            } else {
                dur = 1.0
            }
            let m = min(count - 1, (ordered[i].ts - startTs) / 60)
            seconds[m] += dur
            metSeconds[m] += met(bpm: Double(ordered[i].bpm), inputs: inputs) * dur
        }
        return Ledger(startTs: startTs, endTs: endTs,
                      minutes: (0..<count).map { Minute(seconds: seconds[$0], metSeconds: metSeconds[$0]) })
    }

    /// Where an off-mask came from — printed beside the figure, because the three mean different things.
    public enum MaskSource: String, Equatable, Sendable {
        /// No mask: every minute priced on its heart rate.
        case none
        /// The strap's motion split, not yet confirmed by the wearer.
        case motionThreshold
        /// The wearer confirmed (or typed) the played time; the mask is the most-active minutes to that total.
        case confirmedPlayedTime
    }

    public struct Breakdown: Equatable, Sendable {
        /// Resting + active over the session, the figure a workout row stores.
        public let grossKcal: Double
        /// 1 MET over the whole session.
        public let restingKcal: Double
        /// Gross minus resting, floored at zero.
        public let activeKcal: Double
        public let onKcal: Double
        public let offKcal: Double
        public let onMinutes: Int
        public let offMinutes: Int
        /// On minutes with no heart-rate reading; priced at resting rather than guessed.
        public let uncoveredOnMinutes: Int
        /// On minutes the sport ceiling, not the heart rate, priced.
        public let ceilingHitMinutes: Int
        /// Mean MET over the covered on minutes (before the ceiling), or 0 with none.
        public let meanOnMET: Double
        public let durationS: Double
        public let coveredSeconds: Double
        public let maskSource: MaskSource
        public let inputs: Inputs

        public init(grossKcal: Double, restingKcal: Double, activeKcal: Double, onKcal: Double, offKcal: Double,
                    onMinutes: Int, offMinutes: Int, uncoveredOnMinutes: Int, ceilingHitMinutes: Int,
                    meanOnMET: Double, durationS: Double, coveredSeconds: Double, maskSource: MaskSource,
                    inputs: Inputs) {
            self.grossKcal = grossKcal; self.restingKcal = restingKcal; self.activeKcal = activeKcal
            self.onKcal = onKcal; self.offKcal = offKcal; self.onMinutes = onMinutes; self.offMinutes = offMinutes
            self.uncoveredOnMinutes = uncoveredOnMinutes; self.ceilingHitMinutes = ceilingHitMinutes
            self.meanOnMET = meanOnMET; self.durationS = durationS; self.coveredSeconds = coveredSeconds
            self.maskSource = maskSource; self.inputs = inputs
        }
    }

    /// Price a ledger. `offMask[m] == true` marks minute m as off (bench); it is ignored — and the source
    /// reported as `.none` — when the sport has no off minutes or the mask's length is not the ledger's.
    ///
    /// An on minute costs its mean MET (capped at the sport ceiling) over the seconds it was observed, or
    /// 1 MET over its nominal length when nothing was observed. An off minute costs `offMET` over its nominal
    /// length whatever the heart rate: that is the whole point of marking it off.
    public static func price(_ ledger: Ledger, inputs: Inputs, offMask: [Bool]?,
                             maskSource: MaskSource = .none) -> Breakdown {
        let kgPerS = inputs.weightKg / 3_600
        let count = ledger.minuteCount
        let mask: [Bool]?
        let source: MaskSource
        if let offMask, inputs.traits.offMET != nil, offMask.count == count {
            mask = offMask; source = maskSource == .none ? .motionThreshold : maskSource
        } else {
            mask = nil; source = .none
        }
        let offMET = inputs.traits.offMET ?? offMET
        var on = 0, off = 0, uncovered = 0, hit = 0
        var onKcal = 0.0, offKcal = 0.0, onMETSeconds = 0.0, onSeconds = 0.0
        for m in 0..<count {
            let nominal = min(60.0, max(0.0, ledger.durationS - Double(m) * 60))
            if mask?[m] == true {
                off += 1
                offKcal += offMET * nominal * kgPerS
                continue
            }
            on += 1
            let minute = ledger.minutes[m]
            guard let mean = minute.meanMET else {
                uncovered += 1
                onKcal += 1.0 * nominal * kgPerS
                continue
            }
            onMETSeconds += minute.metSeconds
            onSeconds += minute.seconds
            var priced = mean
            if let ceiling = inputs.traits.ceilingMET, mean > ceiling { priced = ceiling; hit += 1 }
            onKcal += priced * minute.seconds * kgPerS
        }
        let gross = onKcal + offKcal
        let resting = 1.0 * ledger.durationS * kgPerS
        return Breakdown(grossKcal: gross, restingKcal: resting, activeKcal: max(0, gross - resting),
                         onKcal: onKcal, offKcal: offKcal, onMinutes: on, offMinutes: off,
                         uncoveredOnMinutes: uncovered, ceilingHitMinutes: hit,
                         meanOnMET: onSeconds > 0 ? onMETSeconds / onSeconds : 0,
                         durationS: ledger.durationS, coveredSeconds: ledger.coveredSeconds,
                         maskSource: source, inputs: inputs)
    }

    /// Ledger + price in one call, for a caller that has no use for the ledger itself. nil under two samples.
    public static func estimate(samples: [HRSample], startTs: Int, endTs: Int, profile: UserProfile,
                                hrmax: Double?, restingHR: Double?, sport: String,
                                offMask: [Bool]?, maskSource: MaskSource = .none) -> Breakdown? {
        let inputs = inputs(profile: profile, hrmax: hrmax, restingHR: restingHR, sport: sport)
        guard let ledger = ledger(samples: samples, startTs: startTs, endTs: endTs, inputs: inputs) else { return nil }
        return price(ledger, inputs: inputs, offMask: offMask, maskSource: maskSource)
    }
}
