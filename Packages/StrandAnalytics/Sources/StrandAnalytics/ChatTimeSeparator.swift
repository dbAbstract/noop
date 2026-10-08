import Foundation

// MARK: - When a chat transcript should show a time divider
//
// A coach conversation is not a sitting. It runs the length of a day — a brief at 07:00, breakfast logged
// at 08:30, a question about lunch at 13:00 — so consecutive bubbles can be six hours apart with nothing on
// screen to say so. Read back in the evening, "aim for 25–35 g protein at your next meal" is advice whose
// whole meaning depends on when it was given.
//
// SO A GAP GETS A DIVIDER, and a continuous exchange does not. The threshold is the entire design: too
// short and every pause while the model streams becomes a divider, which is noise; too long and a
// conversation resumed after lunch reads as one unbroken thought.
//
// THE DECISION IS PURE, THE WORDING IS NOT. Whether to divide and which day a message fell on are
// arithmetic; "Today" versus "Tuesday" versus "3 Oct" is calendar- and locale-dependent, so the caller
// formats. That split is what lets this be tested without a time zone and twinned in Kotlin without
// agreeing on a date format.
//
// Pure. Kotlin-twinnable.

public enum ChatTimeSeparator {

    /// Silence long enough to be a break rather than a pause. 15 minutes.
    ///
    /// Chosen against the slow end of the conversation, not the fast end: a reasoning model can take two
    /// minutes to answer and the user can take ten to read it and reply, and none of that is a break. The
    /// gaps this exists to mark are meal-sized — the hours between breakfast and lunch.
    public static let minimumGapSeconds = 15 * 60

    /// Whether a divider belongs ABOVE the message at `sentAt`.
    ///
    /// `previousSentAt` is nil for the first message in the transcript, which always gets one: it dates the
    /// conversation, and a transcript restored from yesterday would otherwise open with no indication that
    /// its "you've got ~1500 kcal left" is stale.
    ///
    /// A non-positive gap — equal stamps, or messages out of order — yields FALSE. Two streamed turns can
    /// share a second, and emitting a divider between them would put one in the middle of an exchange that
    /// never paused.
    public static func needsSeparator(previousSentAt: Int?, sentAt: Int) -> Bool {
        guard let previous = previousSentAt else { return true }
        let gap = sentAt - previous
        guard gap > 0 else { return false }
        return gap >= minimumGapSeconds
    }

    /// How a message's day relates to today, which is what decides the WORDING the caller picks.
    public enum DayBucket: Equatable, Sendable {
        case today
        case yesterday
        /// Anything older. The caller spells out the date; there is no "n days ago" case, because by the
        /// third day a weekday name stops being easier to read than the date itself.
        case earlier
    }

    /// Which bucket a message falls in.
    ///
    /// Takes LOCAL EPOCH DAYS — days since 1970 in the user's calendar — rather than instants, so the
    /// caller resolves the time zone once and the comparison here cannot straddle midnight differently
    /// from the rest of the app. `Repository.localDayKey` is the established way to get one.
    ///
    /// A day in the FUTURE buckets as `.today`. It means the clock moved backwards (a time-zone flight, a
    /// manual change), and labelling a message "tomorrow" would be stranger than treating it as current.
    public static func dayBucket(messageEpochDay: Int, todayEpochDay: Int) -> DayBucket {
        let delta = todayEpochDay - messageEpochDay
        if delta <= 0 { return .today }
        if delta == 1 { return .yesterday }
        return .earlier
    }
}
