import XCTest
@testable import StrandAnalytics

/// How much of a recorded workout the diet budget may spend, and the motion split that prices bench time.
final class WorkoutBudgetCreditTests: XCTestCase {

    // The 2026-10-15 futsal session's wearer: male, 72.8 kg, 174 cm, 27.
    // Mifflin: 10(72.8) + 6.25(174) − 5(27) + 5 = 728 + 1087.5 − 135 + 5 = 1685.5
    private let weight = 72.8
    private var bmr: Double { CalorieTarget.mifflinBMR(sex: "male", weightKg: 72.8, heightCm: 174, age: 27) }

    // MARK: - The session this was built for

    /// 120 min, recorded 1,720, 78 min played.
    /// resting = 1685.5 / 86400 × 7200 = 140.46 → net 1579.54
    /// cap = 9 × 72.8 × 78/60 + 1 × 72.8 × 42/60 = 851.76 + 50.96 = 902.72
    func testFutsalWithConfirmedPlayedTimeIsCappedNearNineHundred() {
        let c = WorkoutBudgetCredit.credit(recordedKcal: 1_720, basis: .gross, sport: "Soccer",
                                           durationS: 7_200, playedS: 78 * 60,
                                           weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertEqual(c.netKcal, 1_579.54, accuracy: 0.01)
        XCTAssertEqual(c.capKcal ?? .nan, 902.72, accuracy: 0.01)
        XCTAssertEqual(c.creditedKcal, 902.72, accuracy: 0.01)
        XCTAssertTrue(c.isCapped)
        XCTAssertEqual(c.recordedKcal, 1_720, "the stored figure is reported unchanged")
    }

    /// Before the user confirms played time the whole session prices as play: 9 × 72.8 × 2 = 1310.4.
    /// Still a ceiling on the implausible figure, but bench time is credited generously until confirmed.
    func testUnconfirmedPlayedTimePricesTheWholeSessionAsPlay() {
        let c = WorkoutBudgetCredit.credit(recordedKcal: 1_720, basis: .gross, sport: "Soccer",
                                           durationS: 7_200, playedS: nil,
                                           weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertEqual(c.creditedKcal, 1_310.4, accuracy: 0.01)
        XCTAssertEqual(c.playedS ?? .nan, 7_200, accuracy: 0.001)
    }

    // MARK: - Where the cap must not bite

    /// A sport with no entry is only made net of resting: 45 min, 600 recorded → 600 − 1685.5/86400 × 2700.
    func testUnknownSportIsOnlyNetOfResting() {
        let c = WorkoutBudgetCredit.credit(recordedKcal: 600, basis: .gross, sport: "Running",
                                           durationS: 2_700, playedS: nil,
                                           weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertNil(c.capKcal)
        XCTAssertFalse(c.isCapped)
        XCTAssertEqual(c.creditedKcal, 600 - 1_685.5 / 86_400 * 2_700, accuracy: 0.01)
    }

    /// A plausible soccer figure stays the HR model's: 60 min, 500 gross → net ≈ 429.8, cap 655.2.
    func testPlausibleSoccerFigureIsNotCapped() {
        let c = WorkoutBudgetCredit.credit(recordedKcal: 500, basis: .gross, sport: "soccer",
                                           durationS: 3_600, playedS: nil,
                                           weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertFalse(c.isCapped)
        XCTAssertEqual(c.creditedKcal, c.netKcal, accuracy: 0.0001)
    }

    /// Apple Health workout energy is already active-only; subtracting resting would remove it twice.
    func testActiveBasisPassesThroughUnsubtracted() {
        let c = WorkoutBudgetCredit.credit(recordedKcal: 500, basis: .active, sport: "Basketball",
                                           durationS: 3_600, playedS: nil,
                                           weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertEqual(c.netKcal, 500)
        XCTAssertEqual(c.creditedKcal, 500)
    }

    // MARK: - Sport matching

    func testSportMatchingCoversFreeTextAndAvoidsOtherFootballs() {
        XCTAssertEqual(WorkoutBudgetCredit.intermittentSportMET("Futsal"), 10.0)
        XCTAssertEqual(WorkoutBudgetCredit.intermittentSportMET("  soccer "), 10.0)
        XCTAssertEqual(WorkoutBudgetCredit.intermittentSportMET("Football"), 10.0)
        XCTAssertNil(WorkoutBudgetCredit.intermittentSportMET("American football"))
        XCTAssertNil(WorkoutBudgetCredit.intermittentSportMET("Australian football"))
        XCTAssertEqual(WorkoutBudgetCredit.intermittentSportMET("Sand volleyball"), 8.0)
        XCTAssertEqual(WorkoutBudgetCredit.intermittentSportMET("Volleyball"), 6.0)
        XCTAssertNil(WorkoutBudgetCredit.intermittentSportMET("Cycling"))
    }

    // MARK: - Edges

    func testDegenerateInputsNeverCreditBelowZeroOrExceedTheSession() {
        let negative = WorkoutBudgetCredit.credit(recordedKcal: -50, basis: .gross, sport: "Soccer",
                                                  durationS: 600, playedS: nil,
                                                  weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertEqual(negative.creditedKcal, 0)

        let tiny = WorkoutBudgetCredit.credit(recordedKcal: 5, basis: .gross, sport: "Running",
                                              durationS: 600, playedS: nil,
                                              weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertEqual(tiny.creditedKcal, 0, "resting larger than the record floors at zero")

        let overPlayed = WorkoutBudgetCredit.credit(recordedKcal: 1_720, basis: .gross, sport: "Soccer",
                                                    durationS: 7_200, playedS: 99_999,
                                                    weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertEqual(overPlayed.playedS ?? .nan, 7_200, accuracy: 0.001, "played time clamps to the session")

        let zeroDuration = WorkoutBudgetCredit.credit(recordedKcal: 100, basis: .gross, sport: "Soccer",
                                                      durationS: 0, playedS: nil,
                                                      weightKg: weight, bmrKcalPerDay: bmr)
        XCTAssertNil(zeroDuration.capKcal)
        XCTAssertEqual(zeroDuration.creditedKcal, 100)
    }

    // MARK: - Played time from motion

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

    /// Recovers MORE THAN ONE injected ratio, per the repo's rule for raw-sensor estimates: a 3-team format
    /// (10 on, 5 off → 2/3 played) and a 4-team format (10 on, 10 off → 1/2 played).
    func testMotionSplitRecoversBothRotationFormats() {
        let three = rotation(play: 10, bench: 5, blocks: 8)       // 120 min, 80 played
        XCTAssertEqual(PlayedTimeEstimate.playedSeconds(samples: three.samples, startTs: 0, endTs: three.end),
                       80 * 60)
        let four = rotation(play: 10, bench: 10, blocks: 5)       // 100 min, 50 played
        XCTAssertEqual(PlayedTimeEstimate.playedSeconds(samples: four.samples, startTs: 0, endTs: four.end),
                       50 * 60)
    }

    /// A strap with little or no motion (a 4.0, a dropout) gets no suggestion rather than a guessed one.
    func testThinMotionCoverageOffersNoSplit() {
        let full = rotation(play: 10, bench: 5, blocks: 8)
        let sparse = full.samples.filter { $0.ts < 60 * 60 }      // half the session
        XCTAssertNil(PlayedTimeEstimate.playedSeconds(samples: sparse, startTs: 0, endTs: full.end))
        XCTAssertNil(PlayedTimeEstimate.playedSeconds(samples: [], startTs: 0, endTs: full.end))
        XCTAssertNil(PlayedTimeEstimate.playedSeconds(samples: full.samples, startTs: 100, endTs: 100))
    }
}
