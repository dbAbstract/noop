import XCTest
@testable import StrandAnalytics

final class BatchRemainderTests: XCTestCase {

    private let karahi = MacroTotals(kcal: 2_100, protein: 145, carbs: 120, fat: 95, fiber: 18)

    // MARK: - The walkthrough this feature exists for

    /// The user's actual evening, start to finish: a pot of karahi eaten down over three sittings.
    ///
    /// The SUM IDENTITY at the end is the assertion that matters — every portion logged against a cook
    /// must add up to exactly the cook, or the day totals quietly disagree with the thing that was cooked.
    func testKarahiEatenDownOverThreeSittings() {
        var logged: [Double] = []

        logged.append(0.6)
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: logged), 0.4, accuracy: 1e-9)

        logged.append(0.25)
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: logged), 0.15, accuracy: 1e-9)

        // "I had the rest" resolves from the remainder as it stands now.
        let rest = BatchRemainder.restPortion(loggedPortions: logged)
        XCTAssertEqual(rest, 0.15, accuracy: 1e-9)
        logged.append(rest)

        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: logged), 0, accuracy: 1e-9)
        XCTAssertFalse(BatchRemainder.isOpen(remaining: 0, isClosed: false,
                                             cookedEpochDay: 20_000, todayEpochDay: 20_001))

        // The identity: the portions reconstruct the whole cook.
        let eaten = logged.reduce(0, +)
        XCTAssertEqual(eaten, 1.0, accuracy: 1e-9)
        let consumed = BatchRemainder.remainingMacros(whole: karahi, fraction: eaten)
        XCTAssertEqual(consumed.kcal, karahi.kcal, accuracy: 1e-6)
        XCTAssertEqual(consumed.protein, karahi.protein, accuracy: 1e-6)
        XCTAssertEqual(consumed.carbs, karahi.carbs, accuracy: 1e-6)
        XCTAssertEqual(consumed.fat, karahi.fat, accuracy: 1e-6)
        XCTAssertEqual(consumed.fiber, karahi.fiber, accuracy: 1e-6)
    }

    // MARK: - Over-logging

    /// A double-log must be VISIBLE, not absorbed by the clamp.
    func testOverLoggingClampsTheRemainderAndReportsTheOverage() {
        let logged = [0.6, 0.6]
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: logged), 0, accuracy: 1e-9)
        XCTAssertEqual(BatchRemainder.overage(loggedPortions: logged), 0.2, accuracy: 1e-9)
    }

    /// A cook finished exactly is NOT an overage — which is the distinction the separate function buys.
    func testExactlyFinishedReportsNoOverage() {
        XCTAssertEqual(BatchRemainder.overage(loggedPortions: [0.5, 0.5]), 0, accuracy: 1e-9)
    }

    // MARK: - Why the remainder is derived

    /// Deleting an entry must RAISE the remainder. A stored fraction would still read 0.4 here, which is
    /// the drift this design exists to make impossible.
    func testDeletingAnEntryRestoresTheRemainder() {
        let withBoth = [0.6, 0.25]
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: withBoth), 0.15, accuracy: 1e-9)
        let afterDelete = [0.25]
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: afterDelete), 0.75, accuracy: 1e-9)
    }

    // MARK: - Openness

    func testFreshCookWithLeftoversIsOpen() {
        XCTAssertTrue(BatchRemainder.isOpen(remaining: 0.4, isClosed: false,
                                            cookedEpochDay: 20_000, todayEpochDay: 20_001))
    }

    /// An explicit close outranks a remainder: binning the rest is a statement, not an inference.
    func testClosedCookIsNotOpenEvenWithPlentyLeft() {
        XCTAssertFalse(BatchRemainder.isOpen(remaining: 0.9, isClosed: true,
                                             cookedEpochDay: 20_000, todayEpochDay: 20_000))
    }

    func testCookOlderThanTheLeftoverWindowDropsOut() {
        let cooked = 20_000
        XCTAssertTrue(BatchRemainder.isOpen(remaining: 0.4, isClosed: false, cookedEpochDay: cooked,
                                            todayEpochDay: cooked + BatchRemainder.maxLeftoverDays))
        XCTAssertFalse(BatchRemainder.isOpen(remaining: 0.4, isClosed: false, cookedEpochDay: cooked,
                                             todayEpochDay: cooked + BatchRemainder.maxLeftoverDays + 1))
    }

    /// Portions people say out loud do not land on 1.0 exactly; a 0.5% sliver is finished, not leftovers.
    func testSliverBelowEpsilonCountsAsFinished() {
        XCTAssertFalse(BatchRemainder.isOpen(remaining: 0.005, isClosed: false,
                                             cookedEpochDay: 20_000, todayEpochDay: 20_000))
    }

    /// A clock that moved backwards must not hide real food.
    func testFutureCookDateStaysOpen() {
        XCTAssertTrue(BatchRemainder.isOpen(remaining: 0.5, isClosed: false,
                                            cookedEpochDay: 20_002, todayEpochDay: 20_000))
    }

    // MARK: - Degenerate input

    func testEmptyLogIsAWholeCook() {
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: []), 1, accuracy: 1e-9)
    }

    func testNonFinitePortionsAreIgnoredRatherThanPoisoningTheSum() {
        let logged = [0.5, Double.nan, Double.infinity]
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: logged), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BatchRemainder.overage(loggedPortions: logged), 0, accuracy: 1e-9)
    }

    /// A negative portion must not report more than a whole pot remaining.
    func testNegativePortionCannotExceedAWholeCook() {
        XCTAssertEqual(BatchRemainder.remainingFraction(loggedPortions: [-0.5]), 1, accuracy: 1e-9)
    }

    func testRemainingMacrosRejectNonFiniteFraction() {
        let out = BatchRemainder.remainingMacros(whole: karahi, fraction: .nan)
        XCTAssertEqual(out.kcal, 0, accuracy: 1e-9)
        XCTAssertEqual(out.protein, 0, accuracy: 1e-9)
    }

    func testRemainingMacrosScaleEveryField() {
        let out = BatchRemainder.remainingMacros(whole: karahi, fraction: 0.5)
        XCTAssertEqual(out.kcal, 1_050, accuracy: 1e-9)
        XCTAssertEqual(out.protein, 72.5, accuracy: 1e-9)
        XCTAssertEqual(out.carbs, 60, accuracy: 1e-9)
        XCTAssertEqual(out.fat, 47.5, accuracy: 1e-9)
        XCTAssertEqual(out.fiber, 9, accuracy: 1e-9)
    }
}
