import XCTest
@testable import StrandAnalytics

/// When a wake-triggered brief is due. The cases that matter are the late ones: NOOP learns about wake
/// when the strap offloads, not when the wearer gets up, so "the target already passed" is the normal
/// case and "it passed hours ago" must be told apart from it.
final class WakeBriefWindowTests: XCTestCase {

    private let today = "2026-10-02"
    private let yesterday = "2026-10-01"

    private func verdict(wake: Int?, wakeDay: String? = "2026-10-02", now: Int,
                         lastRun: String? = nil,
                         delay: Int = WakeBriefWindow.defaultDelayMinutes,
                         latest: Int = WakeBriefWindow.defaultLatestMinutes) -> WakeBriefWindow.Verdict {
        WakeBriefWindow.verdict(wakeMinutes: wake, wakeDay: wakeDay, nowMinutes: now, today: today,
                               lastRunDay: lastRun, delayMinutes: delay, latestMinutes: latest)
    }

    // MARK: - The ordinary cases

    /// Woke 07:00, it is 07:30, brief is due.
    func testDueExactlyAtTheTarget() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 7 * 60 + 30), .due)
    }

    func testWaitingBeforeTheTarget() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 7 * 60 + 10), .waiting(minutesAway: 20))
        XCTAssertEqual(verdict(wake: 7 * 60, now: 6 * 60), .waiting(minutesAway: 90))
    }

    /// THE NORMAL LATE CASE. The strap offloaded over breakfast, so the target is a few minutes gone.
    /// Firing now is exactly what "30 minutes after wake" asked for.
    func testFiresWhenTheTargetJustPassed() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 7 * 60 + 45), .due)
        XCTAssertEqual(verdict(wake: 6 * 60, now: 9 * 60), .due)
    }

    // MARK: - The late case that must NOT fire

    /// A sync on the commute home detects a 07:00 wake at 16:00. A "here's your day ahead" briefing then
    /// is not a late morning brief, it is a wrong one.
    func testDoesNotFireInTheAfternoon() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 16 * 60), .missedTheMorning)
    }

    /// `missedTheMorning` must be distinct from `waiting`: it will never become due today, and a caller
    /// that conflated them would keep re-checking all evening.
    func testMissedIsNotWaiting() {
        let v = verdict(wake: 7 * 60, now: 16 * 60)
        XCTAssertNotEqual(v, .waiting(minutesAway: 0))
        XCTAssertEqual(v, .missedTheMorning)
    }

    /// A very late WAKE is also refused, even though the clock is still inside the cutoff. Waking at 10:50
    /// puts the target at 11:20, past 11:00 — firing at 10:59 would be 9 minutes after waking, which is
    /// not what the delay means.
    func testALateWakeWhoseTargetExceedsTheCutoffDoesNotFire() {
        XCTAssertEqual(verdict(wake: 10 * 60 + 50, now: 10 * 60 + 59), .missedTheMorning)
    }

    /// Right on the cutoff still counts — the boundary is inclusive so a 10:30 wake is not lost to an
    /// off-by-one.
    func testTheCutoffIsInclusive() {
        XCTAssertEqual(verdict(wake: 10 * 60 + 30, now: 11 * 60), .due)
        XCTAssertEqual(verdict(wake: 10 * 60 + 31, now: 11 * 60), .missedTheMorning)
    }

    /// Pushing the cutoff to the end of the day is a real preference — late beats never, for some people.
    func testAUserWhoWantsItLateCanHaveIt() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 16 * 60, latest: 24 * 60 - 1), .due)
    }

    // MARK: - Day guards

    func testAlreadyRanTodayWins() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 7 * 60 + 30, lastRun: today), .alreadyRan)
    }

    /// Checked BEFORE the wake lookup. Reporting `noWakeDetected` for a day that already ran would send
    /// the caller to the fixed-time fallback and produce a second brief.
    func testAlreadyRanTakesPrecedenceOverAMissingWake() {
        XCTAssertEqual(verdict(wake: nil, wakeDay: nil, now: 9 * 60, lastRun: today), .alreadyRan)
    }

    func testYesterdaysRunDoesNotBlockToday() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 7 * 60 + 30, lastRun: yesterday), .due)
    }

    /// A wake belonging to an earlier day must not trigger today's brief — the strap unworn for a night
    /// leaves the most recent session two days old.
    func testAStaleWakeFromAnEarlierDayIsNotUsed() {
        XCTAssertEqual(verdict(wake: 7 * 60, wakeDay: yesterday, now: 9 * 60), .noWakeDetected)
    }

    /// No wake is reported as such rather than guessed at, so the caller can fall back to the fixed time
    /// instead of inventing a morning.
    func testNoWakeIsReportedNotInvented() {
        XCTAssertEqual(verdict(wake: nil, wakeDay: nil, now: 9 * 60), .noWakeDetected)
        XCTAssertEqual(verdict(wake: 7 * 60, wakeDay: nil, now: 9 * 60), .noWakeDetected)
    }

    // MARK: - Delay

    /// Zero delay is legitimate: "the moment I'm up" is a real choice.
    func testZeroDelayFiresAtWake() {
        XCTAssertEqual(verdict(wake: 7 * 60, now: 7 * 60, delay: 0), .due)
    }

    func testDelayIsClampedToSomethingThatStillMeansAfterWake() {
        XCTAssertEqual(WakeBriefWindow.clampedDelay(-10), 0)
        XCTAssertEqual(WakeBriefWindow.clampedDelay(30), 30)
        XCTAssertEqual(WakeBriefWindow.clampedDelay(10_000), 4 * 60)
    }

    func testLatestIsClampedToAValidMinuteOfDay() {
        XCTAssertEqual(WakeBriefWindow.clampedLatest(-1), 0)
        XCTAssertEqual(WakeBriefWindow.clampedLatest(11 * 60), 11 * 60)
        XCTAssertEqual(WakeBriefWindow.clampedLatest(99_999), 24 * 60 - 1)
    }

    // MARK: - Defaults

    func testDefaultsAreThirtyMinutesAndElevenAM() {
        XCTAssertEqual(WakeBriefWindow.defaultDelayMinutes, 30)
        XCTAssertEqual(WakeBriefWindow.defaultLatestMinutes, 11 * 60)
    }

    /// A very early riser must still get a brief — the cutoff is about lateness, not about a window.
    func testAnEarlyWakeIsFine() {
        XCTAssertEqual(verdict(wake: 4 * 60 + 30, now: 5 * 60), .due)
    }
}
