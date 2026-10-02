import Foundation

// MARK: - When a wake-triggered brief is due
//
// The fixed-time brief fires at 07:00 whether you got up at 05:30 or 09:00. This decides the other
// option: a brief timed off the wake NOOP actually detected.
//
// THE HARD PART IS NOT THE ARITHMETIC, IT IS THAT NOOP LEARNS ABOUT WAKE LATE. A strap's night is
// detected when it offloads, not when the wearer opens their eyes, so by the time `endTs` exists the
// target moment may be hours gone. Three cases, and they need different answers:
//
//   • The target is still ahead → wait for it.
//   • The target just passed → fire now. This is the normal case on a phone that synced over breakfast,
//     and firing a few minutes late is exactly what the user asked for.
//   • The target passed hours ago → DO NOT fire. A "here is your day ahead" briefing arriving at 16:00,
//     triggered by a sync on the commute home, is not a late morning brief — it is a wrong one. The
//     cutoff is a wall-clock time rather than an elapsed duration, because what makes it absurd is that
//     it is no longer morning, not that it has been a while.
//
// The cutoff is tunable and can be pushed to the end of the day by anyone who would rather have a late
// brief than none. That is a real preference and not a mistake, so it is a setting, not a constant.
//
// Pure arithmetic over minute-of-day integers. No Calendar, no timezone handling, no store — the caller
// resolves wall-clock into minutes and days, the same convention `WindDownNudge` and `CoachBriefScheduler`
// already use.

public enum WakeBriefWindow {

    /// Minutes after detected wake before the brief is due. 30 — long enough to be out of bed and
    /// interested, short enough that the day's plan is still ahead of you.
    public static let defaultDelayMinutes = 30

    /// Latest minute-of-day a wake-triggered brief may still fire. 11:00.
    ///
    /// Past this, a morning brief has missed its morning. Tunable to 23:59 for anyone who would rather
    /// have it late than not at all.
    public static let defaultLatestMinutes = 11 * 60

    /// What should happen right now.
    public enum Verdict: Equatable, Sendable {
        /// Generate and notify.
        case due
        /// The target has not arrived yet. Carries minutes remaining, so a caller can schedule rather
        /// than poll.
        case waiting(minutesAway: Int)
        /// Too late to be a morning brief. Deliberately distinct from `waiting` — a caller must not
        /// treat this as "check again soon", because it will never become due today.
        case missedTheMorning
        /// Already generated for this day.
        case alreadyRan
        /// No detected wake to time anything off. The caller falls back to the fixed-time path rather
        /// than inventing a wake.
        case noWakeDetected
    }

    /// Decide whether a wake-triggered brief is due.
    ///
    /// All times are minutes since local midnight, and all days are opaque day keys compared only for
    /// equality — so this never has to know what a timezone is.
    ///
    /// - Parameters:
    ///   - wakeMinutes: minute-of-day of the detected wake, or nil if no wake is known.
    ///   - wakeDay: the local day the wake belongs to.
    ///   - nowMinutes: minute-of-day now.
    ///   - today: the current local day.
    ///   - lastRunDay: the day a brief last generated, or nil.
    ///   - delayMinutes: minutes to wait after wake.
    ///   - latestMinutes: last minute-of-day this may fire.
    public static func verdict(wakeMinutes: Int?,
                               wakeDay: String?,
                               nowMinutes: Int,
                               today: String,
                               lastRunDay: String?,
                               delayMinutes: Int = defaultDelayMinutes,
                               latestMinutes: Int = defaultLatestMinutes) -> Verdict {
        // Checked BEFORE the wake lookup: once today has a brief, nothing about the wake can change the
        // answer, and reporting `noWakeDetected` for a day that already ran would send the caller to the
        // fixed-time fallback to run a second one.
        if let lastRunDay, lastRunDay == today { return .alreadyRan }

        guard let wakeMinutes, let wakeDay else { return .noWakeDetected }
        // A wake from an earlier day is last night's only if "last night" means today. A stale session —
        // the strap unworn for two nights, say — must not trigger today's brief off a Tuesday wake.
        guard wakeDay == today else { return .noWakeDetected }

        let target = wakeMinutes + delayMinutes

        // The cutoff is checked against the TARGET first, and before the waiting check. A target already
        // past the cutoff can never become due, so reporting `waiting` for it would be a lie a caller
        // acts on — scheduling a wake-up for 11:20 that will then refuse to fire. This is the case of
        // someone who slept until 10:50: their brief is not late, it is cancelled.
        guard target <= latestMinutes else { return .missedTheMorning }
        if nowMinutes < target { return .waiting(minutesAway: target - nowMinutes) }
        // Past the target and the target was in time. The remaining question is whether WE are — the
        // afternoon-sync case, where a 07:00 wake is discovered at 16:00.
        guard nowMinutes <= latestMinutes else { return .missedTheMorning }
        return .due
    }

    /// Clamp a user-set delay. Zero is allowed — "the moment you're up" is a legitimate choice — and the
    /// ceiling keeps "after wake" meaning something.
    public static func clampedDelay(_ minutes: Int) -> Int {
        min(max(minutes, 0), 4 * 60)
    }

    /// Clamp a user-set cutoff to a valid minute of the day.
    public static func clampedLatest(_ minutes: Int) -> Int {
        min(max(minutes, 0), 24 * 60 - 1)
    }
}
