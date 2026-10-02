import Foundation

// MARK: - What has been spent SO FAR today
//
// The whole-day expenditure figure is a projection: it says what a day like this costs, which at 00:30 is
// not what has happened. This converts it into a running total.
//
// TWO THINGS MAKE THE NAIVE VERSION WRONG, and both matter by hundreds of kcal.
//
// 1. ONLY THE BASELINE IS A PROJECTION. Step NEAT comes from the day's step count so far and workout energy
//    from workouts already done — both are measured-to-date by construction. Prorating the whole figure
//    therefore discounts activity that has already fully happened: at 14:00 after a 07:00 500 kcal workout,
//    scaling everything gives ~1,481 where the honest answer is ~1,698.
//
// 2. THE ACTIVITY MULTIPLIER IS A DAILY AVERAGE THAT ALREADY CONTAINS SLEEP. Crediting overnight hours at
//    that average over-reads, because sleeping metabolism sits below it. For a 1,681 kcal BMR at ×1.2, a
//    linear figure at 08:00 after a 7h40m night claims ~676 kcal where the sleep-aware answer is ~567.
//
// THE CONSTRAINT THAT MAKES THE RATES DERIVABLE RATHER THAN GUESSED: at the end of the day this must equal
// the whole-day figure exactly. Otherwise the Calories card and the diet budget describe the same day with
// two different numbers, which is the failure the repo's rules name outright. So the waking rate is not
// chosen — it is whatever makes the day sum correctly:
//
//     sleepRate = BMR / 24
//     wakeRate  = (BMR × multiplier − sleepRate × nightHours) / (24 − nightHours)
//
// DISPLAY ONLY. Nothing here is banked, and the budget is not prorated — a budget that shrank through the
// day would read as nearly blown by a normal breakfast. The budget answers "what may I eat today"; this
// answers "what have I spent so far". Both are true and they are not the same question.
//
// Pure arithmetic over hours and kcal. No Calendar, no store.

public enum ProgressiveBurn {

    /// Which method produced a figure, so a caller can caption it without re-deriving why.
    public enum Basis: String, Equatable, Sendable {
        /// Overnight hours priced at resting metabolism and waking hours at the rate that balances the day.
        case sleepAware
        /// No sleep recorded for the day, so the baseline accrues at a flat daily rate. Cruder, and the
        /// caller should say so — it over-reads in the morning for exactly the reason above.
        case linear
        /// The day has fully elapsed. The figure is the whole-day one and no proration happened at all.
        case complete
    }

    public struct Result: Equatable, Sendable {
        /// Baseline accrued so far, before activity.
        public let baselineSoFarKcal: Double
        /// Baseline plus the activity already measured. What a card shows.
        public let totalSoFarKcal: Double
        public let basis: Basis

        public init(baselineSoFarKcal: Double, totalSoFarKcal: Double, basis: Basis) {
            self.baselineSoFarKcal = baselineSoFarKcal
            self.totalSoFarKcal = totalSoFarKcal
            self.basis = basis
        }
    }

    public static let hoursPerDay = 24.0

    /// Energy spent so far today.
    ///
    /// - Parameters:
    ///   - bmrKcal: whole-day resting energy.
    ///   - activityMultiplier: the baseline multiplier (`ActivityLevel.multiplier`), a DAILY average.
    ///   - nightSleepHours: hours of sleep belonging to this day. 0 when none is recorded, which selects
    ///     the linear path.
    ///   - sleepHoursToday: hours of that sleep which have already elapsed. Equal to `nightSleepHours` once
    ///     the user is up; smaller while they are still asleep.
    ///   - elapsedHours: hours of the day gone. 24 for any day that is not today.
    ///   - activityKcal: step NEAT plus workout energy ALREADY measured. Added whole, never prorated.
    public static func burnedSoFar(bmrKcal: Double,
                                   activityMultiplier: Double,
                                   nightSleepHours: Double,
                                   sleepHoursToday: Double,
                                   elapsedHours: Double,
                                   activityKcal: Double) -> Result {
        let activity = (activityKcal.isFinite && activityKcal > 0) ? activityKcal : 0
        guard bmrKcal.isFinite, bmrKcal > 0, activityMultiplier.isFinite, activityMultiplier > 0 else {
            return Result(baselineSoFarKcal: 0, totalSoFarKcal: activity, basis: .linear)
        }
        let dayBaseline = bmrKcal * activityMultiplier
        let elapsed = min(max(elapsedHours.isFinite ? elapsedHours : 0, 0), hoursPerDay)

        // A fully elapsed day is not prorated at all. This is the branch every PAST day takes, and it is
        // what keeps history identical to the banked whole-day figure rather than approximately equal to it.
        if elapsed >= hoursPerDay {
            return Result(baselineSoFarKcal: dayBaseline,
                          totalSoFarKcal: dayBaseline + activity,
                          basis: .complete)
        }

        let night = min(max(nightSleepHours.isFinite ? nightSleepHours : 0, 0), hoursPerDay)
        let sleptSoFar = min(max(sleepHoursToday.isFinite ? sleepHoursToday : 0, 0), elapsed)

        // No sleep to reason from, or a "night" so long there are no waking hours to balance against. Both
        // fall back to the flat daily rate rather than dividing by zero or inventing a sleep duration.
        guard night > 0, night < hoursPerDay else {
            return Result(baselineSoFarKcal: dayBaseline * (elapsed / hoursPerDay),
                          totalSoFarKcal: dayBaseline * (elapsed / hoursPerDay) + activity,
                          basis: .linear)
        }

        let sleepRate = bmrKcal / hoursPerDay
        // Not chosen — solved for, so that sleepRate × night + wakeRate × (24 − night) == dayBaseline.
        let wakeRate = (dayBaseline - sleepRate * night) / (hoursPerDay - night)
        let awakeSoFar = max(0, elapsed - sleptSoFar)
        let baseline = sleepRate * sleptSoFar + wakeRate * awakeSoFar

        // Clamped to the day's own baseline. A nap after the night was measured makes the real night longer
        // than assumed, which would otherwise let the running total drift past the figure it must converge
        // on — and a "so far" that exceeds the whole day is self-evidently wrong on screen.
        let capped = min(baseline, dayBaseline)
        return Result(baselineSoFarKcal: capped,
                      totalSoFarKcal: capped + activity,
                      basis: .sleepAware)
    }

    /// Elapsed hours of a local day, from minutes since midnight.
    ///
    /// Taken as minutes rather than a Date so this module stays free of Calendar — the caller already
    /// resolves local midnight everywhere else in the diet path.
    public static func elapsedHours(minuteOfDay: Int) -> Double {
        min(max(Double(minuteOfDay), 0), hoursPerDay * 60) / 60
    }
}
