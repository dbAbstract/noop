import Foundation

// MARK: - Which diet day an instant belongs to
//
// A calendar day is the wrong unit for eating. Something at 00:15, before going to bed, belongs to the day
// still being lived — not to a new one that began fifteen minutes ago while its owner was awake and hungry.
// Under a midnight boundary that snack lands on a fresh budget with nothing spent against it, which reads
// as a free 2,000 kcal and leaves the day it actually belonged to under-reported.
//
// SO THE DAY ROLLS OVER AT SLEEP, NOT AT MIDNIGHT. The rule is deliberately data-driven rather than a fixed
// cutoff hour: NOOP knows when its wearer slept, so "have you slept since the last calendar day began"
// answers this exactly, where any fixed hour is a guess about someone's schedule.
//
// TWO BOUNDS, BOTH LOAD-BEARING:
//
//   • The shift only applies in the SMALL HOURS (before `latestRolloverMinute`). Past that, a day with no
//     recorded sleep is someone whose strap was flat, not someone who has been up for thirty hours — and
//     pinning the diet day to yesterday all through today would put every meal on the wrong date.
//   • A nap does not end the day. The sleep has to be at least `minimumNightHours` to count as the night,
//     or dozing on the sofa at 23:30 would roll the day over and then the real night would roll it again.
//
// THIS DOES NOT MOVE ANY OTHER DAY KEY. `Repository.localDayKey` stays midnight-based for every other
// series in the app — recovery, strain, sleep, steps. Only the diet path asks this question, because only
// the diet path is about a budget someone is spending while awake.
//
// Pure: minute-of-day plus a measured sleep duration. The caller resolves the calendar.

public enum DietDayBoundary {

    /// Latest minute-of-day the diet day may still be yesterday's. 04:00.
    ///
    /// Past this the answer is always today, whatever sleep says. The question "have you slept yet" stops
    /// being meaningful once the morning is underway: an unworn strap would otherwise read as a day that
    /// never ended, and every meal would be filed a day early for as long as the gap lasted.
    public static let latestRolloverMinute = 4 * 60

    /// Sleep short of this does not count as the night. 3 hours.
    ///
    /// Generous on purpose — a genuinely short night is still a night, and the figure only has to exclude
    /// dozing. Without it, a nap before midnight would roll the day over and the real night would roll it
    /// again, giving two diet days to one calendar day.
    public static let minimumNightHours = 3.0

    /// How many calendar days back the diet day sits.
    ///
    /// - Parameters:
    ///   - minuteOfDay: minutes since local midnight, now.
    ///   - hoursSleptSinceMidnight: measured sleep inside the current calendar day. The caller clips
    ///     sessions to the day, so a night running 23:30 → 07:00 contributes only its post-midnight part.
    ///   - sleepIsKnown: false when there is no sleep data at all for the window — an unworn strap, or a
    ///     night not yet offloaded. Distinct from zero hours, which is a measurement.
    /// - Returns: 0 for today, 1 for yesterday.
    public static func daysBack(minuteOfDay: Int,
                                hoursSleptSinceMidnight: Double,
                                sleepIsKnown: Bool) -> Int {
        guard minuteOfDay >= 0, minuteOfDay < latestRolloverMinute else { return 0 }
        // No data is NOT evidence of being awake. Without a measurement the honest fallback is the calendar,
        // because the alternative — assuming the user is still up — silently backdates every entry on any
        // night the strap missed.
        guard sleepIsKnown else { return 0 }
        // Slept the night already: it is a new day even though it is still early. Someone who went to bed at
        // 21:00 and is eating at 03:00 has had their night, and that snack belongs to the day they woke into.
        guard hoursSleptSinceMidnight < minimumNightHours else { return 0 }
        return 1
    }

    /// Whether an instant falls in the window where the diet day can differ from the calendar day. For a UI
    /// that wants to explain itself rather than silently disagree with the clock.
    public static func isInRolloverWindow(minuteOfDay: Int) -> Bool {
        minuteOfDay >= 0 && minuteOfDay < latestRolloverMinute
    }
}
