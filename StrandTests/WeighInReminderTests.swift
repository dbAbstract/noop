import XCTest
@testable import Strand

/// When a weigh-in nudge is owed.
///
/// Every condition is a reason NOT to fire, which is the right default for anything that interrupts. The
/// weigh-in is the input people skip because its window is narrow — same time each morning, before eating —
/// and unlike a food log it cannot be reconstructed at 11pm.
@MainActor
final class WeighInReminderTests: XCTestCase {

    private func shouldFire(weighed: Bool = false, woke: Bool = true, sinceWake: Int? = 45,
                            briefFired: Bool = false, lastFired: String? = nil,
                            enabled: Bool = true) -> Bool {
        WeighInReminder.shouldFire(isEnabled: enabled, hasWeighedToday: weighed, wokeToday: woke,
                                   minutesSinceWake: sinceWake, briefFiredToday: briefFired,
                                   lastFiredDay: lastFired, today: "2026-10-07", delayMinutes: 30)
    }

    func testFiresWhenUpAndNotYetWeighed() {
        XCTAssertTrue(shouldFire())
    }

    /// SELF-SILENCING. By lunchtime on a normal day this simply never becomes due, which is better than a
    /// setting nobody finds.
    func testDoesNotFireOnceWeighed() {
        XCTAssertFalse(shouldFire(weighed: true))
    }

    /// ONE NOTIFICATION A MORNING. The brief carries more, so it outranks this — two notifications about the
    /// same morning train the user to dismiss both.
    func testStandsDownWhenTheBriefAlreadyFired() {
        XCTAssertFalse(shouldFire(briefFired: true))
    }

    func testWaitsForTheDelayAfterWaking() {
        XCTAssertFalse(shouldFire(sinceWake: 5), "they have just opened their eyes")
        XCTAssertTrue(shouldFire(sinceWake: 30), "the boundary is inclusive")
    }

    /// No detected wake means no evidence they are up. Firing anyway would be a 04:00 alert on a night the
    /// strap was flat.
    func testDoesNotFireWithoutADetectedWake() {
        XCTAssertFalse(shouldFire(woke: false))
        XCTAssertFalse(shouldFire(sinceWake: nil))
    }

    /// A stale wake belongs to a previous day; the caller passes `wokeToday: false` for it.
    func testDoesNotFireTwiceInOneDay() {
        XCTAssertFalse(shouldFire(lastFired: "2026-10-07"))
        XCTAssertTrue(shouldFire(lastFired: "2026-10-06"), "yesterday's firing must not block today")
    }

    func testRespectsTheSwitch() {
        XCTAssertFalse(shouldFire(enabled: false))
    }

    /// On by default: it costs at most one notification a day, only on days the scales were not used, and
    /// it guards the input whose absence silently blocks a verdict.
    func testDefaultsToOn() {
        UserDefaults.standard.removeObject(forKey: "noop.weighInReminder.enabled")
        XCTAssertTrue(WeighInReminder.isEnabled)
    }
}
