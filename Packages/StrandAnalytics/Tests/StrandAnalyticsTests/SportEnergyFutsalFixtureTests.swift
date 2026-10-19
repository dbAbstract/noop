import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The 2026-10-15 futsal session the model was built on, as a fixture: 121 session minutes (7,205 s), each
/// row the minute's mean heart rate and mean dynamic acceleration from the strap (7,205 HR readings, 7,185
/// motion readings in the original trace). Saginuma, 3 teams on one pitch, so about two thirds played.
///
/// The per-second trace stays out of git; expanding minute means back to 1 Hz is an approximation, which is
/// why the energy assertion carries a tolerance. On the exact trace the model priced 1,022 kcal gross against
/// the 1,720 the Keytel bout path stored.
final class SportEnergyFutsalFixtureTests: XCTestCase {

    private static let startTs = 1_792_058_357
    private static let endTs = 1_792_065_562

    // (mean bpm, mean dynAccel in g) per minute.
    private static let minutes: [(hr: Int, accel: Double)] = [
        (121, 1.108), (151, 0.531), (137, 0.216), (137, 0.895), (173, 1.064), (163, 0.353),
        (162, 1.144), (167, 0.9), (174, 0.562), (166, 0.175), (143, 0.104), (136, 0.113),
        (123, 0.135), (123, 0.081), (120, 0.069), (132, 0.317), (149, 0.258), (146, 0.084),
        (147, 0.313), (171, 0.614), (167, 0.473), (170, 0.742), (173, 0.539), (180, 0.807),
        (177, 0.934), (175, 0.983), (158, 0.418), (166, 0.478), (157, 0.19), (142, 0.03),
        (134, 0.252), (121, 0.138), (114, 0.049), (112, 0.109), (125, 0.189), (134, 0.479),
        (136, 0.579), (163, 1.166), (167, 0.817), (174, 1.197), (172, 0.492), (168, 0.504),
        (181, 1.335), (177, 0.673), (178, 0.676), (183, 0.876), (183, 0.965), (179, 0.726),
        (164, 0.147), (148, 0.358), (133, 0.128), (126, 0.081), (123, 0.082), (120, 0.08),
        (131, 0.249), (136, 0.213), (142, 0.201), (163, 0.533), (167, 0.632), (176, 1.048),
        (185, 0.764), (157, 0.323), (126, 0.129), (122, 0.197), (128, 0.169), (134, 0.28),
        (154, 0.86), (172, 0.652), (173, 0.774), (183, 0.797), (163, 0.206), (135, 0.038),
        (125, 0.035), (121, 0.054), (114, 0.072), (118, 0.059), (137, 0.623), (163, 0.688),
        (157, 0.656), (141, 0.334), (167, 0.966), (169, 0.531), (163, 0.326), (163, 0.671),
        (175, 1.461), (190, 0.82), (182, 1.003), (176, 0.55), (174, 0.546), (149, 0.17),
        (126, 0.143), (119, 0.072), (118, 0.024), (117, 0.044), (116, 0.065), (124, 0.235),
        (145, 0.951), (181, 1.05), (186, 0.425), (159, 0.318), (155, 0.384), (158, 0.546),
        (156, 0.641), (160, 0.476), (160, 0.513), (169, 0.807), (181, 0.835), (168, 0.593),
        (146, 0.193), (133, 0.119), (131, 0.024), (127, 0.031), (121, 0.066), (126, 0.228),
        (153, 0.57), (163, 1.332), (162, 0.339), (152, 0.551), (152, 0.854), (148, 0.276),
        (146, 0.331),
    ]

    /// Expanded to 1 Hz: each minute's mean repeated for its seconds.
    private static var hrSamples: [HRSample] {
        var out: [HRSample] = []
        for (m, row) in minutes.enumerated() {
            for s in 0..<60 where startTs + m * 60 + s <= endTs {
                out.append(HRSample(ts: startTs + m * 60 + s, bpm: row.hr))
            }
        }
        return out
    }

    private static var motion: [(ts: Int, dynAccel: Double)] {
        var out: [(ts: Int, dynAccel: Double)] = []
        for (m, row) in minutes.enumerated() {
            for s in 0..<60 where startTs + m * 60 + s < endTs {
                out.append((startTs + m * 60 + s, row.accel))
            }
        }
        return out
    }

    private let profile = UserProfile(weightKg: 72.8, heightCm: 174, age: 27, sex: "male")

    /// The 3-team format: the motion split lands at 79 of 121 minutes on (the exact trace gave 78 of 120;
    /// the fixture's 121st minute is the 5-second tail).
    func testMotionSplitMatchesTheRotationFormat() throws {
        let activity = try XCTUnwrap(PlayedTimeEstimate.minuteActivity(samples: Self.motion,
                                                                       startTs: Self.startTs, endTs: Self.endTs))
        XCTAssertEqual(activity.count, 121)
        let mask = try XCTUnwrap(PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: nil))
        XCTAssertEqual(mask.filter { !$0 }.count, 79)
        XCTAssertEqual(mask.filter { $0 }.count, 42)
    }

    /// Recorded 1,720. Priced with the split: ≈ 1,023 gross on the fixture (1,022 on the exact trace), of
    /// which 146 is the session's resting share — so the budget's net is about 880.
    func testPricedWithTheSplitLandsNearATenthOfTheRecordedOvercount() throws {
        let activity = PlayedTimeEstimate.minuteActivity(samples: Self.motion, startTs: Self.startTs, endTs: Self.endTs)
        let mask = PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: nil)
        let b = try XCTUnwrap(SportEnergy.estimate(samples: Self.hrSamples, startTs: Self.startTs, endTs: Self.endTs,
                                                   profile: profile, hrmax: 189.1, restingHR: 52,
                                                   sport: "Soccer", offMask: mask, maskSource: .motionThreshold))
        XCTAssertEqual(b.onMinutes, 79)
        XCTAssertEqual(b.offMinutes, 42)
        XCTAssertEqual(b.maskSource, .motionThreshold)
        XCTAssertEqual(b.grossKcal, 1_022, accuracy: 1_022 * 0.03)
        XCTAssertEqual(b.restingKcal, 72.8 * 7_205 / 3_600, accuracy: 0.01)
        XCTAssertEqual(b.offKcal, 2.0 * 72.8 * 42 * 60 / 3_600, accuracy: 0.01)
        // Match minutes run 160–185 bpm, which the curve reads as 11–15 METs for this wearer's Uth VO₂max;
        // the soccer ceiling is what holds them at 10, and it did real work on this session.
        XCTAssertGreaterThan(b.meanOnMET, 10.5)
        XCTAssertLessThan(b.meanOnMET, 14)
        XCTAssertGreaterThan(b.ceilingHitMinutes, 30)
    }

    /// Without the split every minute is on: the bench at ~130 bpm is priced at match pace, and the figure
    /// rises by about a quarter. The gap between the two IS the bench problem, in kcal.
    func testWithoutTheSplitTheBenchIsPricedAtMatchPace() throws {
        let b = try XCTUnwrap(SportEnergy.estimate(samples: Self.hrSamples, startTs: Self.startTs, endTs: Self.endTs,
                                                   profile: profile, hrmax: 189.1, restingHR: 52,
                                                   sport: "Soccer", offMask: nil))
        XCTAssertEqual(b.offMinutes, 0)
        XCTAssertGreaterThan(b.grossKcal, 1_250)
        XCTAssertLessThan(b.grossKcal, 1_400)
        XCTAssertLessThan(b.grossKcal, 1_720, "and still well under what Keytel stored")
    }

    /// The wearer confirms 70 minutes: the 70 most-active minutes are on, and the figure follows.
    func testAConfirmedTotalRepricesMinuteByMinute() throws {
        let activity = PlayedTimeEstimate.minuteActivity(samples: Self.motion, startTs: Self.startTs, endTs: Self.endTs)
        let mask = PlayedTimeEstimate.offMask(minuteActivity: activity, playedS: 70 * 60)
        let b = try XCTUnwrap(SportEnergy.estimate(samples: Self.hrSamples, startTs: Self.startTs, endTs: Self.endTs,
                                                   profile: profile, hrmax: 189.1, restingHR: 52,
                                                   sport: "Soccer", offMask: mask, maskSource: .confirmedPlayedTime))
        XCTAssertEqual(b.onMinutes, 70)
        XCTAssertEqual(b.offMinutes, 51)
        XCTAssertEqual(b.maskSource, .confirmedPlayedTime)
        XCTAssertLessThan(b.grossKcal, 1_000)
        XCTAssertGreaterThan(b.grossKcal, 850)
    }
}
