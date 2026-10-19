import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The flex-HR / heart-rate-reserve bout model and the per-minute off-mask it is priced with.
final class SportEnergyTests: XCTestCase {

    // The wearer the model was checked against: male, 72.8 kg, 174 cm, 27; Tanaka HRmax 189.1; resting 52.
    // Uth VO₂max = 15.3 × 189.1 / 52 = 55.64 → METmax 15.90; flex HR = 52 + 0.25 × 137.1 = 86.3 bpm.
    private let profile = UserProfile(weightKg: 72.8, heightCm: 174, age: 27, sex: "male")
    private func inputs(_ sport: String = "Soccer", restingHR: Double? = 52) -> SportEnergy.Inputs {
        SportEnergy.inputs(profile: profile, hrmax: 189.1, restingHR: restingHR, sport: sport)
    }

    /// `minutes` of 1 Hz readings at `bpm`, starting at `start`.
    private func steady(_ bpm: Int, minutes: Int, start: Int = 0) -> [HRSample] {
        (0..<(minutes * 60)).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    // MARK: - The curve

    func testInputsDeriveUthAndTheFlexPoint() {
        let i = inputs()
        XCTAssertEqual(i.vo2max, 55.64, accuracy: 0.01)
        XCTAssertEqual(i.metMax, 15.90, accuracy: 0.01)
        XCTAssertEqual(i.flexHRBPM, 86.28, accuracy: 0.01)
        XCTAssertFalse(i.restingHRWasDefaulted)
        XCTAssertEqual(i.traits.sportClass, .intermittent)
        XCTAssertEqual(i.traits.ceilingMET, 10)
    }

    /// Against the wearer's own WHOOP history (312 sessions, kcal/min by 10-bpm bin, bin centre quoted):
    /// the model tracks a VARYING input across the whole exercise range rather than matching one point.
    /// Tolerance is ±25 %: WHOOP is itself an estimate, and 90–120 bpm is where the two models disagree most
    /// (the curve runs 10–20 % above it there, within ±6 % from 130 bpm up).
    func testCurveTracksTheWhoopReferenceAcrossHeartRates() {
        let i = inputs()
        let whoopKcalPerMin: [(bpm: Double, kcal: Double)] = [
            (105, 3.72), (115, 5.37), (125, 7.15), (135, 9.61), (145, 10.90), (155, 13.18), (165, 15.24),
        ]
        for point in whoopKcalPerMin {
            let model = SportEnergy.met(bpm: point.bpm, inputs: i) * 72.8 / 60
            XCTAssertEqual(model / point.kcal, 1.0, accuracy: 0.25, "at \(point.bpm) bpm: model \(model), WHOOP \(point.kcal)")
        }
        // And the shape: strictly rising, continuous through the flex point, pinned at both anchors.
        XCTAssertEqual(SportEnergy.met(bpm: 52, inputs: i), 1.0)
        XCTAssertEqual(SportEnergy.met(bpm: 86.28, inputs: i), 1.0, accuracy: 0.001)
        XCTAssertEqual(SportEnergy.met(bpm: 87, inputs: i), 1.0, accuracy: 0.15, "no jump at the flex point")
        XCTAssertEqual(SportEnergy.met(bpm: 189.1, inputs: i), 15.90, accuracy: 0.01)
        XCTAssertEqual(SportEnergy.met(bpm: 210, inputs: i), 15.90, accuracy: 0.01, "capped at HRmax")
    }

    /// Where the Keytel intercept failed: an easy minute. At 105 bpm Keytel priced ~7 kcal/min for this
    /// wearer; the curve prices 4.5, WHOOP 3.7.
    func testEasyMinutesAreNoLongerPricedAtDouble() {
        let model = SportEnergy.met(bpm: 105, inputs: inputs()) * 72.8 / 60
        XCTAssertLessThan(model, 5.0)
        XCTAssertGreaterThan(model, 3.0)
    }

    func testMissingRestingHRDefaultsToSixtyAndSaysSo() {
        let i = inputs(restingHR: nil)
        XCTAssertTrue(i.restingHRWasDefaulted)
        XCTAssertEqual(i.restingHR, 60)
        XCTAssertEqual(SportEnergy.met(bpm: 60, inputs: i), 1.0)
    }

    // MARK: - Sport traits

    func testTraitsClassifyTheWearersSports() {
        XCTAssertEqual(SportEnergy.Traits.resolve("Soccer"), .init(sportClass: .intermittent, ceilingMET: 10))
        XCTAssertEqual(SportEnergy.Traits.resolve("futsal"), .init(sportClass: .intermittent, ceilingMET: 10))
        XCTAssertEqual(SportEnergy.Traits.resolve("Weightlifting"), .init(sportClass: .resistance, ceilingMET: 6))
        XCTAssertEqual(SportEnergy.Traits.resolve("Strength Trainer"), .init(sportClass: .resistance, ceilingMET: 6))
        XCTAssertEqual(SportEnergy.Traits.resolve("Cycling"), .init(sportClass: .steady, ceilingMET: 12))
        XCTAssertEqual(SportEnergy.Traits.resolve("Snowboarding"), .init(sportClass: .alpine, ceilingMET: 8))
        XCTAssertEqual(SportEnergy.Traits.resolve("Running"), .init(sportClass: .steady, ceilingMET: 14))
        XCTAssertEqual(SportEnergy.Traits.resolve("Walking"), .init(sportClass: .steady, ceilingMET: 6))
        XCTAssertEqual(SportEnergy.Traits.resolve("Thrill Ride"), .init(sportClass: .unknown, ceilingMET: nil))
        XCTAssertNil(SportEnergy.Traits.resolve("Cycling").offMET, "only intermittent sports have off minutes")
        XCTAssertEqual(SportEnergy.Traits.resolve("Basketball").offMET, 2.0)
    }

    // MARK: - Pricing

    /// 10 min steady at 140 bpm, unknown sport: gross = MET(140) × 72.8 × 10/60. MET(140) = 1 + ((88/137.1 −
    /// 0.25)/0.75) × 14.90 = 8.783 → 106.57 kcal. Resting 12.13; active = gross − resting.
    func testSteadyBoutPricesTheCurveOverRealSeconds() throws {
        let i = inputs("Thrill Ride")
        let b = try XCTUnwrap(SportEnergy.estimate(samples: steady(140, minutes: 10), startTs: 0, endTs: 600,
                                                   profile: profile, hrmax: 189.1, restingHR: 52,
                                                   sport: "Thrill Ride", offMask: nil))
        let met = SportEnergy.met(bpm: 140, inputs: i)
        XCTAssertEqual(met, 8.783, accuracy: 0.01)
        // 599 readings carry 1 s to the next; the last carries 1 s: 600 s exactly.
        XCTAssertEqual(b.coveredSeconds, 600)
        XCTAssertEqual(b.grossKcal, met * 72.8 * 600 / 3_600, accuracy: 0.01)
        XCTAssertEqual(b.restingKcal, 72.8 * 600 / 3_600, accuracy: 0.001)
        XCTAssertEqual(b.activeKcal, b.grossKcal - b.restingKcal, accuracy: 0.001)
        XCTAssertEqual(b.onMinutes, 10)
        XCTAssertEqual(b.offMinutes, 0)
        XCTAssertEqual(b.ceilingHitMinutes, 0)
        XCTAssertEqual(b.maskSource, .none)
        XCTAssertEqual(b.meanOnMET, met, accuracy: 0.001)
    }

    /// Weights at 150 bpm: the curve says 9.9 METs, the pressor-inflated heart rate does not mean that
    /// oxygen cost, and the resistance ceiling prices the minute at 6.
    func testResistanceCeilingBoundsAPressorHeartRate() throws {
        let b = try XCTUnwrap(SportEnergy.estimate(samples: steady(150, minutes: 5), startTs: 0, endTs: 300,
                                                   profile: profile, hrmax: 189.1, restingHR: 52,
                                                   sport: "Weightlifting", offMask: nil))
        XCTAssertEqual(b.ceilingHitMinutes, 5)
        XCTAssertEqual(b.grossKcal, 6 * 72.8 * 300 / 3_600, accuracy: 0.01)
        XCTAssertGreaterThan(b.meanOnMET, 9, "the mean reports the curve, the kcal reports the ceiling")
    }

    func testUnknownSportHasNoCeiling() throws {
        let b = try XCTUnwrap(SportEnergy.estimate(samples: steady(185, minutes: 5), startTs: 0, endTs: 300,
                                                   profile: profile, hrmax: 189.1, restingHR: 52,
                                                   sport: "Thrill Ride", offMask: nil))
        XCTAssertEqual(b.ceilingHitMinutes, 0)
        XCTAssertGreaterThan(b.meanOnMET, 15)
    }

    /// A bench minute at 130 bpm costs 2 METs, not the curve's 7.6: that is the whole point of the mask.
    func testOffMinutesArePricedAtRecoveryWhateverTheHeartRate() throws {
        let i = inputs()
        let samples = steady(130, minutes: 4)
        let ledger = try XCTUnwrap(SportEnergy.ledger(samples: samples, startTs: 0, endTs: 240, inputs: i))
        let all = SportEnergy.price(ledger, inputs: i, offMask: nil)
        let half = SportEnergy.price(ledger, inputs: i, offMask: [false, true, false, true], maskSource: .confirmedPlayedTime)
        let met = SportEnergy.met(bpm: 130, inputs: i)
        XCTAssertEqual(all.grossKcal, met * 72.8 * 240 / 3_600, accuracy: 0.01)
        XCTAssertEqual(half.onMinutes, 2)
        XCTAssertEqual(half.offMinutes, 2)
        XCTAssertEqual(half.offKcal, 2.0 * 72.8 * 120 / 3_600, accuracy: 0.01)
        XCTAssertEqual(half.onKcal, met * 72.8 * 120 / 3_600, accuracy: 0.01)
        XCTAssertEqual(half.maskSource, .confirmedPlayedTime)
        XCTAssertLessThan(half.grossKcal, all.grossKcal)
    }

    /// A steady sport has no off minutes, so a mask handed to it is ignored and reported as such; so is a
    /// mask of the wrong length.
    func testMaskIsIgnoredForASteadySportOrAWrongLength() throws {
        let samples = steady(130, minutes: 4)
        let cycling = inputs("Cycling")
        let l1 = try XCTUnwrap(SportEnergy.ledger(samples: samples, startTs: 0, endTs: 240, inputs: cycling))
        let c = SportEnergy.price(l1, inputs: cycling, offMask: [true, true, true, true])
        XCTAssertEqual(c.offMinutes, 0)
        XCTAssertEqual(c.maskSource, .none)

        let soccer = inputs()
        let l2 = try XCTUnwrap(SportEnergy.ledger(samples: samples, startTs: 0, endTs: 240, inputs: soccer))
        let s = SportEnergy.price(l2, inputs: soccer, offMask: [true, true, true])
        XCTAssertEqual(s.offMinutes, 0)
        XCTAssertEqual(s.maskSource, .none)
    }

    /// An on minute with no reading costs resting over its nominal length — not a guess, not nothing.
    func testUncoveredOnMinutesCostRestingAndAreCounted() throws {
        let i = inputs("Cycling")
        // Readings only in minutes 0 and 2; minute 1 is a dropout; the 150 s gap cap keeps minute 0 from
        // carrying the whole gap: its last reading carries min(gap 61 s, 150 s) = 61 s.
        let samples = steady(130, minutes: 1) + steady(130, minutes: 1, start: 120)
        let ledger = try XCTUnwrap(SportEnergy.ledger(samples: samples, startTs: 0, endTs: 180, inputs: i))
        XCTAssertEqual(ledger.minutes[0].seconds, 59 + 61, accuracy: 0.001)
        XCTAssertEqual(ledger.minutes[1].seconds, 0)
        let b = SportEnergy.price(ledger, inputs: i, offMask: nil)
        XCTAssertEqual(b.uncoveredOnMinutes, 1)
        XCTAssertEqual(b.onMinutes, 3)
    }

    /// A wear gap beyond 150 s is capped, exactly as the Keytel bout path caps it.
    func testAWearGapIsCappedNotCreditedInFull() throws {
        let i = inputs("Cycling")
        let samples = [HRSample(ts: 0, bpm: 140), HRSample(ts: 1_000, bpm: 140)]
        let ledger = try XCTUnwrap(SportEnergy.ledger(samples: samples, startTs: 0, endTs: 1_000, inputs: i))
        XCTAssertEqual(ledger.coveredSeconds, 150 + 1, accuracy: 0.001)
    }

    func testTooFewSamplesGiveNoLedger() {
        let i = inputs()
        XCTAssertNil(SportEnergy.ledger(samples: [HRSample(ts: 5, bpm: 120)], startTs: 0, endTs: 600, inputs: i))
        XCTAssertNil(SportEnergy.ledger(samples: steady(120, minutes: 2, start: 10_000), startTs: 0, endTs: 600, inputs: i),
                     "readings outside the window do not count")
        XCTAssertNil(SportEnergy.ledger(samples: steady(120, minutes: 2), startTs: 100, endTs: 100, inputs: i))
    }

    // MARK: - The off-mask

    /// One session of `blocks` × (play minutes at 0.7, bench minutes at 0.05), sampled at 1 Hz.
    private func rotation(play: Int, bench: Int, blocks: Int) -> (samples: [(ts: Int, dynAccel: Double)], end: Int) {
        var out: [(ts: Int, dynAccel: Double)] = []
        var t = 0
        for _ in 0..<blocks {
            for _ in 0..<(play * 60) { out.append((t, 0.7)); t += 1 }
            for _ in 0..<(bench * 60) { out.append((t, 0.05)); t += 1 }
        }
        return (out, t)
    }

    /// Unconfirmed: the threshold decides. The 3-minute smoothing marks the minute either side of a
    /// transition the way the suggestion always has, so the on-count matches `playedSeconds` exactly.
    func testThresholdMaskMatchesTheSuggestion() throws {
        let r = rotation(play: 10, bench: 5, blocks: 8)
        let activity = try XCTUnwrap(PlayedTimeEstimate.minuteActivity(samples: r.samples, startTs: 0, endTs: r.end))
        XCTAssertEqual(activity.count, 120)
        let mask = try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: nil))
        let on = mask.filter { !$0 }.count
        XCTAssertEqual(Double(on * 60), PlayedTimeEstimate.playedSeconds(samples: r.samples, startTs: 0, endTs: r.end))
        XCTAssertEqual(on, 80)
    }

    /// Confirmed: the wearer's total is honoured minute by minute — the N most-active minutes are on.
    func testConfirmedPlayedTimeSelectsTheMostActiveMinutes() throws {
        let activity: [Double?] = [0.9, 0.1, 0.5, nil, 0.7, 0.05]
        let two = try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: 2 * 60))
        XCTAssertEqual(two, [false, true, true, true, false, true])
        let four = try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: 4 * 60))
        XCTAssertEqual(four, [false, false, false, true, false, true], "a minute without data ranks last")
        let all = try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: 99_999))
        XCTAssertEqual(all.filter { $0 }.count, 0, "more than the session clamps to every minute on")
        let none = try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: 0))
        XCTAssertEqual(none.filter { !$0 }.count, 0)
        // Rounding: 89 s → 1 minute on, 91 s → 2.
        XCTAssertEqual(try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: 89)).filter { !$0 }.count, 1)
        XCTAssertEqual(try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: 91)).filter { !$0 }.count, 2)
    }

    func testNoMotionMeansNoMask() {
        XCTAssertNil(PlayedTimeEstimate.offMask(minuteActivity: nil, playedS: 30 * 60))
        XCTAssertNil(PlayedTimeEstimate.offMask(minuteActivity: [], playedS: nil))
        let r = rotation(play: 10, bench: 5, blocks: 8)
        let sparse = r.samples.filter { $0.ts < 60 * 60 }
        XCTAssertNil(PlayedTimeEstimate.minuteActivity(samples: sparse, startTs: 0, endTs: r.end))
    }
}
