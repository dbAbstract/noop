import Foundation
import XCTest
@testable import StrandAnalytics

/// TDEE by energy balance — the twin of the Kotlin `AdaptiveExpenditureEngineTest`, asserting the same
/// cases with the same inputs so the two cannot drift.
///
/// The identity is `expenditure = intake - stored-energy change`. Most of what matters here is refusing
/// to answer: the method is meaningful only over weeks, and most installs will never log enough intake.
final class AdaptiveExpenditureEngineTests: XCTestCase {

    /// A synthetic history: `days` long, intake every `logEvery` days, weight every `weighEvery`.
    private func history(days: Int, intake: Double = 2_400, startKg: Double = 80,
                         kgPerDay: Double = 0, logEvery: Int = 1,
                         weighEvery: Int = 3) -> [AdaptiveExpenditureDay] {
        (0..<days).map { i in
            AdaptiveExpenditureDay(
                day: dayKey(i),
                caloriesIn: i % logEvery == 0 ? intake : nil,
                weightKg: i % weighEvery == 0 ? startKg + kgPerDay * Double(i) : nil)
        }
    }

    /// Sequential "yyyy-MM-dd" keys from 2026-01-01, so the engine's own date maths is exercised.
    private func dayKey(_ offset: Int) -> String {
        var c = DateComponents(); c.year = 2026; c.month = 1; c.day = 1 + offset
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: c)!
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Weight flat ⇒ expenditure equals intake. The simplest reading of the identity.
    func testStableWeightPutsExpenditureAtIntake() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 30)))
        XCTAssertEqual(est.estimatedDailyKcal, 2_400, accuracy: 1)
        XCTAssertEqual(est.weightSlopeKgPerDay, 0, accuracy: 1e-9)
    }

    /// Losing weight ⇒ expenditure EXCEEDED intake, so the estimate is ABOVE what was eaten. The sign is
    /// the classic error in this formula, so both directions are pinned rather than one.
    func testLosingWeightPutsExpenditureAboveIntake() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 30, kgPerDay: -0.05)))
        // 0.05 kg/day * 7700 = 385 kcal/day of stored energy released.
        XCTAssertEqual(est.estimatedDailyKcal, 2_400 + 385, accuracy: 2)
        XCTAssertGreaterThan(est.estimatedDailyKcal, est.meanIntakeKcal)
    }

    /// And the mirror: gaining weight means expenditure fell SHORT of intake.
    func testGainingWeightPutsExpenditureBelowIntake() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 30, kgPerDay: 0.05)))
        XCTAssertEqual(est.estimatedDailyKcal, 2_400 - 385, accuracy: 2)
        XCTAssertLessThan(est.estimatedDailyKcal, est.meanIntakeKcal)
    }

    /// Under three weeks the method is not meaningful, so it declines rather than answering.
    func testShortHistoryYieldsNothing() {
        XCTAssertNil(AdaptiveExpenditureEngine.estimate(days: history(days: 20)))
    }

    /// The gate that matters most in practice: someone logs hard for a fortnight of a long window and
    /// stops. The skipped days are not a random sample of their eating, so a mean over them would read
    /// as a large false deficit.
    func testSparseIntakeLoggingYieldsNothing() {
        XCTAssertNil(AdaptiveExpenditureEngine.estimate(days: history(days: 40, logEvery: 3)))
    }

    /// Weight is the other half of the identity; too few readings cannot establish a trend.
    func testTooFewWeighInsYieldsNothing() {
        XCTAssertNil(AdaptiveExpenditureEngine.estimate(days: history(days: 30, weighEvery: 10)))
    }

    /// The output is a RANGE, and the estimate must sit inside it.
    func testEstimateIsBracketedByItsInterval() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 30)))
        XCTAssertLessThan(est.lowerKcal, est.estimatedDailyKcal)
        XCTAssertGreaterThan(est.upperKcal, est.estimatedDailyKcal)
    }

    /// Confidence rises with the window, coverage and weigh-ins — never with the value itself.
    func testConfidenceReflectsCoverageNotTheAnswer() throws {
        let full = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 35, weighEvery: 2)))
        XCTAssertEqual(full.confidence, .high)
        let thin = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 22, weighEvery: 3)))
        XCTAssertNotEqual(thin.confidence, .high)
    }

    /// The window must hold exactly the days it claims. `dayCount` is inclusive, so a strict `<` in the
    /// recency filter drops the oldest day while still reporting the full window — losing a day of data
    /// and understating coverage, both silently. Every other case here logs every day, so a one-day loss
    /// crosses no gate and nothing else would notice.
    func testFullyLoggedWindowKeepsEveryDayItReports() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 30)))
        XCTAssertEqual(est.windowDays, 30)
        XCTAssertEqual(est.intakeDays, est.windowDays)
    }

    /// A duplicated day must not buy confidence. Coverage is "share of the window that was logged", so
    /// it cannot exceed 1 — but a caller that merged its two sparse series badly could pass a day twice,
    /// and an unclamped ratio above 1 both shrinks the interval and lifts the confidence, making the
    /// answer look more certain than its data. That is the one direction this engine must never err in.
    func testDuplicatedDaysCannotBuyANarrowerIntervalOrHigherConfidence() throws {
        let clean = history(days: 30)
        let duped = clean + clean          // every day twice
        let a = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: clean))
        let b = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: duped))
        XCTAssertEqual(a.upperKcal - a.lowerKcal, b.upperKcal - b.lowerKcal, accuracy: 1e-6,
                       "a duplicate must not narrow the interval")
        XCTAssertEqual(a.confidence, b.confidence, "nor raise the confidence")
        XCTAssertLessThan(b.lowerKcal, b.estimatedDailyKcal)
        XCTAssertGreaterThan(b.upperKcal, b.estimatedDailyKcal)
    }

    /// A bad day key must not be read as 1970 and stretch the window by twenty thousand days.
    func testUnparseableDayKeyIsRefusedNotTreatedAs1970() {
        XCTAssertNil(AdaptiveExpenditureEngine.dayCount(from: "not-a-day", to: "2026-01-01"))
        XCTAssertNil(AdaptiveExpenditureEngine.dayCount(from: "2026-01-01", to: ""))
    }

    /// Readings that all share one day cannot yield a slope; zero variance must return nil.
    func testSingleDayWeightClusterHasNoSlope() {
        XCTAssertNil(AdaptiveExpenditureEngine.leastSquaresSlope([(3, 80.0), (3, 80.5), (3, 79.5)]))
    }
}

// MARK: - The interval is lopsided on purpose

/// The days someone fails to log are not a random sample of their eating — they are the restaurant, the
/// day out, the holiday. So an estimate taken over logged days is biased LOW, and the interval has to say
/// so by widening UPWARD rather than evenly.
///
/// The previous version noted that asymmetry in a comment and then added the term to both bounds, which
/// presents a bias as if it were noise and hands out a budget that is systematically tight.
extension AdaptiveExpenditureEngineTests {

    /// A history with gaps: intake on 24 of 28 days (86% coverage), which is the user's own holiday shape.
    private func gappyHistory(days: Int = 28, unloggedCount: Int = 4,
                              intake: Double = 2_100) -> [AdaptiveExpenditureDay] {
        (0..<days).map { i in
            // The gaps are at the END so they fall inside the retained window rather than being trimmed.
            AdaptiveExpenditureDay(day: dayKey(i),
                                   caloriesIn: i >= days - unloggedCount ? nil : intake,
                                   weightKg: i % 2 == 0 ? 73 : nil)
        }
    }

    /// THE BUG FIX. Incomplete coverage must widen the interval upward, not evenly.
    func testIncompleteCoverageWidensTheIntervalUpwardOnly() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: gappyHistory()))
        let up = est.upperKcal - est.estimatedDailyKcal
        let down = est.estimatedDailyKcal - est.lowerKcal
        XCTAssertGreaterThan(up, down,
                             "unlogged days bias the estimate LOW, so the room must be above it")
        XCTAssertTrue(est.isLikelyUnderstated)
    }

    /// And the magnitude is the point, not just the direction: at 86% coverage the old symmetric term
    /// contributed ~29 kcal where the real bias is nearer 100.
    func testTheUpwardRoomIsLargeEnoughToMatter() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: gappyHistory()))
        let asymmetry = (est.upperKcal - est.estimatedDailyKcal) - (est.estimatedDailyKcal - est.lowerKcal)
        // 4/28 unlogged × 0.35 × 2,100 ≈ 105 kcal.
        XCTAssertEqual(asymmetry, 105, accuracy: 10)
    }

    /// INERT ON A COMPLETE LOG. Someone who logs every day must get exactly the even-handed interval they
    /// got before — the asymmetry is a statement about missing days, so with none it must not appear.
    func testACompleteLogKeepsASymmetricInterval() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 30)))
        let up = est.upperKcal - est.estimatedDailyKcal
        let down = est.estimatedDailyKcal - est.lowerKcal
        XCTAssertEqual(up, down, accuracy: 1e-9)
        XCTAssertFalse(est.isLikelyUnderstated)
    }

    /// The estimate itself must not move. This change is about the interval around it, and shifting the
    /// point estimate would silently rewrite every figure the screen already shows.
    func testThePointEstimateIsUnchangedByTheIntervalWork() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 30)))
        XCTAssertEqual(est.estimatedDailyKcal, 2_400, accuracy: 1)
    }

    // MARK: - Rough days

    private func roughHistory(days: Int = 28, roughCount: Int = 4,
                             intake: Double = 2_100) -> [AdaptiveExpenditureDay] {
        (0..<days).map { i in
            AdaptiveExpenditureDay(day: dayKey(i),
                                   caloriesIn: intake,
                                   weightKg: i % 2 == 0 ? 73 : nil,
                                   intakeIsRough: i >= days - roughCount)
        }
    }

    /// THE WHOLE POINT OF ROUGH DAYS. Guessing must be strictly better than omitting: the same four days
    /// cost less uncertainty when guessed, AND keep coverage intact.
    func testGuessingBeatsOmittingOnTheSameDays() throws {
        let omitted = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: gappyHistory()))
        let guessed = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: roughHistory()))

        let omittedUp = omitted.upperKcal - omitted.estimatedDailyKcal
        let guessedUp = guessed.upperKcal - guessed.estimatedDailyKcal
        XCTAssertLessThan(guessedUp, omittedUp, "a guess is poor evidence, but it is evidence")

        XCTAssertEqual(guessed.intakeDays, 28, "a rough day still counts toward coverage")
        XCTAssertEqual(omitted.intakeDays, 24)
    }

    /// Rough days are still an admitted guess, so they must widen the interval relative to a clean log —
    /// otherwise marking a day rough would be free and the marker would mean nothing.
    func testRoughDaysStillWidenTheIntervalUpward() throws {
        let clean = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: history(days: 28)))
        let rough = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: roughHistory()))
        XCTAssertFalse(clean.isLikelyUnderstated)
        XCTAssertTrue(rough.isLikelyUnderstated)
    }

    func testRoughDayCountIsReported() throws {
        let est = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(days: roughHistory(roughCount: 3)))
        XCTAssertEqual(est.roughIntakeDays, 3)
    }

    /// A rough day can rescue the COVERAGE GATE, which is the hard failure omission causes: 7 unlogged
    /// days in a 21-day window is 67%, below the 70% floor, so there is no verdict at all.
    func testRoughDaysRescueAVerdictOmissionWouldHaveLost() throws {
        let omitted = AdaptiveExpenditureEngine.estimate(
            days: gappyHistory(days: 21, unloggedCount: 7))
        XCTAssertNil(omitted, "67% coverage is below the gate — this is the case worth rescuing")

        let guessed = AdaptiveExpenditureEngine.estimate(
            days: roughHistory(days: 21, roughCount: 7))
        XCTAssertNotNil(guessed, "the same days, guessed, clear the gate")
    }

    /// The constants are pinned because `unloggedDayExcess` is the one genuinely ASSUMED figure here, and
    /// a silent change to it moves every interval the app shows.
    func testTheAssumedConstantsAreWhatTheDocSays() {
        XCTAssertEqual(AdaptiveExpenditureEngine.unloggedDayExcess, 0.35)
        XCTAssertEqual(AdaptiveExpenditureEngine.roughGuessDiscount, 0.4)
        XCTAssertEqual(AdaptiveExpenditureEngine.baseReportingError, 0.05)
        XCTAssertLessThan(AdaptiveExpenditureEngine.roughGuessDiscount, 1.0,
                          "a guess must cost less than a gap, or guessing is pointless")
    }
}
