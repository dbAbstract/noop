import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Diet expenditure: assembling the day's real burn, and the budget from it
//
// The pure model lives in `CalorieTarget` / `StepNeat`. This is the part that needs the store: deciding
// WHICH steps count, which is the whole difficulty.
//
//     daily steps − steps taken inside workouts − sedentary baseline  =  NEAT steps
//
// The middle term is the one that matters and the one that needs real data. A workout's steps are already
// counted by heart rate, at their true intensity — 2,000 incline-treadmill steps cost far more than 2,000
// walking to the shop, and a flat per-step rate cannot tell them apart. Leaving them in would both
// double-count them AND price them wrongly.
//
// NOTHING HERE TOUCHES `DailyMetric.activeKcalEst`. NOOP's own heart-rate figure stays exactly as it is
// and is shown beside this one, so the two can be compared rather than one silently replacing the other.
// A model must not overwrite a measurement.

enum DietStore {
    /// Source id for everything this feature writes — its own, never confused with a strap or an import.
    static let sourceId = "diet"

    /// `metricSeries` keys. Written per day so history survives a goal change and rides `.noopbak`.
    enum Keys {
        /// What the user was allowed to eat that day (expenditure − deficit).
        static let target = "calorie_target"
        /// What this model reckons they actually spent. Deliberately NOT `energy_kcal`, which is NOOP's
        /// own heart-rate figure — two different answers to one question must not share a key.
        static let expenditure = "diet_expenditure"
        /// The ACTIVITY half of that expenditure: step NEAT plus workout energy, excluding the baseline.
        ///
        /// Banked so a measured baseline can be derived without re-deriving every past day's steps. The
        /// adaptive engine reports an average TDEE over three to six weeks, which already contains that
        /// window's average activity — so turning it into a BASELINE means subtracting the window's mean
        /// activity, and this is the series that makes that a cheap read rather than a replay.
        ///
        /// Banked rather than computed on demand for a second reason: a past day's step count can no
        /// longer be reconstructed once the strap's window has rolled off, so the figure has to be kept
        /// when it is known.
        static let activity = "diet_activity_kcal"

        static let all = [target, expenditure, activity]
    }
}

/// One day's expenditure with the step accounting that produced it, so a screen can show its working.
struct DietDayEnergy: Equatable {
    let expenditure: DayExpenditure
    /// Steps the strap recorded for the whole day, or nil when it has not answered — a 4.0 has no
    /// counter, and a 5.0 has nothing until the day's window offloads. Distinct from 0, which means the
    /// strap DID answer and the answer was "you did not move".
    let dailySteps: Int?
    /// Steps attributed to workouts and therefore excluded from NEAT.
    let workoutSteps: Int
    /// Steps that actually earned NEAT calories, after workouts and the sedentary baseline.
    let neatSteps: Int
    /// nil when no goal is set — there is a burn figure, but nothing to eat toward.
    let deficitKcal: Double?
    /// True when the baseline came from the user's own measured expenditure rather than Mifflin-St Jeor.
    /// Drives the label on the Today card's working — two readouts of one fact must not be able to
    /// disagree about which number is in play.
    var usesMeasuredBaseline: Bool = false

    /// What may still be eaten today. nil without a goal.
    func budgetKcal() -> Double? {
        guard let deficitKcal else { return nil }
        return expenditure.budgetKcal(deficitKcal: deficitKcal)
    }
}

extension Repository {

    // MARK: - The goal

    /// The goal governing `day`, or nil if none was in force then.
    func dietGoal(on day: String? = nil) async -> DietGoalRow? {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle() else { return nil }
        return try? await store.dietGoal(deviceId: DietStore.sourceId, onDay: dayKey)
    }

    func currentDietGoal() async -> DietGoalRow? {
        guard let store = await storeHandle() else { return nil }
        return try? await store.currentDietGoal(deviceId: DietStore.sourceId)
    }

    /// Adopt (or clear) a measured baseline on the CURRENT goal.
    ///
    /// Edits the open goal in place rather than starting a new one, deliberately: this changes how the
    /// same plan is costed, not what the plan is. Superseding the goal would restart `startedOn` and so
    /// rewrite the history every adherence figure is measured against — a calibration must not look like
    /// a new diet.
    ///
    /// Pass nil to revert to the model.
    @discardableResult
    func setMeasuredBaseline(_ kcal: Double?) async -> Bool {
        guard let store = await storeHandle(),
              var goal = try? await store.currentDietGoal(deviceId: DietStore.sourceId) else {
            return false
        }
        goal.measuredBaselineKcal = kcal
        _ = try? await store.upsertDietGoals([goal])
        noteFoodChanged()
        return true
    }

    /// Replace the current goal with a new one, effective today.
    ///
    /// Ends the open goal rather than deleting it, so a day logged under the old target still resolves
    /// against that target — adherence for last week must not change because today's plan did.
    @discardableResult
    func setDietGoal(startWeightKg: Double, targetWeightKg: Double, months: Int,
                     activity: ActivityLevel, dailyDeficitKcal: Double,
                     targetOverrideKcal: Double? = nil, proteinGPerKg: Double? = nil,
                     on day: String? = nil) async -> Bool {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle() else { return false }
        _ = try? await store.endOpenDietGoals(deviceId: DietStore.sourceId, on: dayKey)
        let row = DietGoalRow(id: UUID().uuidString,
                              deviceId: DietStore.sourceId,
                              startedOn: dayKey,
                              startWeightKg: startWeightKg,
                              targetWeightKg: targetWeightKg,
                              months: months,
                              activityLevel: activity.rawValue,
                              dailyDeficitKcal: dailyDeficitKcal,
                              targetOverrideKcal: targetOverrideKcal,
                              createdAt: Int(Date().timeIntervalSince1970),
                              proteinGPerKg: proteinGPerKg)
        guard (try? await store.upsertDietGoals([row])) != nil else { return false }
        noteFoodChanged()
        return true
    }

    /// Stop dieting: close the open goal without starting another.
    func clearDietGoal(on day: String? = nil) async {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle() else { return }
        _ = try? await store.endOpenDietGoals(deviceId: DietStore.sourceId, on: dayKey)
        noteFoodChanged()
    }

    // MARK: - Steps attributed to workouts

    /// Steps taken inside the day's workouts, counted once even where workouts overlap.
    ///
    /// `workoutRows` is already cross-source deduped (a strap bout and its Apple twin collapse to one);
    /// `TimeWindows.merged` handles what survives that — two genuinely distinct sessions whose times
    /// intersect. Without the merge, a shared minute is subtracted twice and the budget silently shrinks.
    ///
    /// Returns 0 rather than nil when the strap cannot answer (a 4.0 has no step counter, and a 5.0 has
    /// nothing until the window has offloaded). That is the conservative direction: no steps excluded
    /// means they stay in NEAT and are priced at the flat walking rate — an under-credit of a hard
    /// session, not an invented one.
    func workoutStepsForDay(_ dayKey: String, stepTicksPerStep: Double) async -> Int {
        let all = await workoutRows(days: 3)
        guard let bounds = Self.dayBounds(dayKey) else { return 0 }
        let windows = all
            .filter { $0.startTs < bounds.end && $0.endTs > bounds.start }
            .map { (start: max($0.startTs, bounds.start), end: min($0.endTs, bounds.end)) }
        var total = 0
        for w in TimeWindows.merged(windows) {
            // `strapStepTicks` reads only [from, to], so the delta landing on the first sample is not
            // attributed. That under-counts a workout's steps slightly, which leaves them in NEAT at the
            // flat rate — the same conservative direction as returning 0 above, and it keeps this
            // consistent with the shipped WorkoutDetailView reading.
            if let ticks = await strapStepTicks(from: w.start, to: w.end) {
                total += Int((Double(ticks) / max(stepTicksPerStep, 0.5)).rounded())
            }
        }
        return total
    }

    /// Workout energy for the day, from the same deduped rows the step exclusion used — so the calories
    /// added and the steps removed always describe the same set of sessions.
    func workoutKcalForDay(_ dayKey: String) async -> Double {
        guard let bounds = Self.dayBounds(dayKey) else { return 0 }
        return await workoutRows(days: 3)
            .filter { $0.startTs < bounds.end && $0.endTs > bounds.start }
            .reduce(0.0) { $0 + max(0, $1.energyKcal ?? 0) }
    }

    // MARK: - Which diet day it is

    /// The day key the DIET path should use for an instant.
    ///
    /// Differs from `Repository.localDayKey` only in the small hours, and only when sleep says the wearer is
    /// still up — see `DietDayBoundary`. Food eaten at 00:15 before bed belongs to the day being lived, not
    /// to a budget that reset fifteen minutes ago.
    ///
    /// DELIBERATELY NOT A CHANGE TO `localDayKey`. That key is how recovery, strain, sleep and steps are
    /// stored; moving it would re-key every series in the app and make existing history disagree with
    /// itself. Only the diet path asks this, because only the diet path is about a budget being spent while
    /// awake.
    ///
    /// Falls back to the calendar day whenever sleep is unknown, which is the conservative direction: the
    /// alternative assumes the user is awake and silently backdates every entry on a night the strap missed.
    func dietDayKey(now: Date = Date()) async -> String {
        guard DietDayBoundary.isInRolloverWindow(minuteOfDay: FoodEntries.minuteOfDay(now)) else {
            // The overwhelmingly common path, and it costs nothing — no sleep read at all outside the
            // window, so the normal case does not pay for the edge case.
            return Repository.localDayKey(now)
        }
        let calendarDay = Repository.localDayKey(now)
        let sleep = await sleepHoursForDay(calendarDay, now: now)
        let back = DietDayBoundary.daysBack(minuteOfDay: FoodEntries.minuteOfDay(now),
                                            hoursSleptSinceMidnight: sleep.elapsed,
                                            // `sleepHoursForDay` returns (0, 0) both when nothing is
                                            // recorded and when a worn strap recorded no sleep. Only the
                                            // first is "unknown", and `hasAnySleepRecord` tells them apart —
                                            // treating them alike would backdate on every missed night.
                                            sleepIsKnown: await hasAnySleepRecord(near: now))
        guard back > 0 else { return calendarDay }
        return Repository.localDayKey(now.addingTimeInterval(-Double(back) * 86_400))
    }

    /// An instant INSIDE the current diet day, for callers that do day arithmetic from it.
    ///
    /// Returned as a Date rather than a key so a caller can step backwards from it — the food log's day
    /// stepper subtracts whole days, and doing that from a key would mean parsing it back first.
    func dietDayAnchor(now: Date = Date()) async -> Date {
        let key = await dietDayKey(now: now)
        guard key != Repository.localDayKey(now) else { return now }
        // One day back is the only shift `DietDayBoundary` produces, so this needs no search.
        return now.addingTimeInterval(-86_400)
    }

    /// Whether the strap has recorded ANY sleep recently enough to make "have you slept yet" answerable.
    ///
    /// Separate from the hours read because absent and zero are different claims: a worn strap reporting no
    /// sleep since midnight means the wearer is up, while no record at all means nobody knows. Acting on the
    /// second as though it were the first is what would backdate entries on a night the strap missed.
    func hasAnySleepRecord(near now: Date = Date()) async -> Bool {
        let to = Int(now.timeIntervalSince1970)
        let from = to - 48 * 3_600
        if !(await sleepSessions(from: from, to: to)).isEmpty { return true }
        return !(await computedSleepSessions(from: from, to: to)).isEmpty
    }

    // MARK: - Sleep belonging to a day

    /// Hours of sleep that fall inside a local day, and how many of those have already elapsed.
    ///
    /// CLIPPED TO THE DAY'S BOUNDS, not "last night's session". A night running 23:30 → 07:00 belongs 30
    /// minutes to one day and 7 hours to the next, and charging either day for the whole session would
    /// misprice both. Merged first, for the same reason `workoutStepsForDay` merges: two overlapping
    /// sessions would otherwise count their shared minutes twice.
    ///
    /// Returns (0, 0) when nothing is recorded, which selects `ProgressiveBurn`'s linear fallback rather
    /// than inventing a night.
    ///
    /// `elapsed` differs from `total` only while the user is still asleep — there is no sleep in the FUTURE
    /// part of today, so after they are up the two are equal. Both are returned because the progressive
    /// figure needs the night's length to solve its waking rate AND the part already slept to price what has
    /// happened; deriving one from the other at the call site is how those two drift apart.
    func sleepHoursForDay(_ dayKey: String, now: Date = Date()) async -> (total: Double, elapsed: Double) {
        guard let bounds = Self.dayBounds(dayKey) else { return (0, 0) }
        // A generous read window: a session that STARTED the previous evening still contributes to this day,
        // so querying only within the day's bounds would miss its overlap.
        var sessions = await sleepSessions(from: bounds.start - 24 * 3_600, to: bounds.end)
        if sessions.isEmpty {
            // A Bluetooth-only strap banks nights under the COMPUTED source, so the imported-only read above
            // returns nothing for a 4.0 user whose every night is computed (#1150's reasoning). Without this
            // the progressive figure would silently take the linear path for them, forever.
            sessions = await computedSleepSessions(from: bounds.start - 24 * 3_600, to: bounds.end)
        }
        let clipped = sessions
            .filter { $0.startTs < bounds.end && $0.endTs > bounds.start }
            .map { (start: max($0.startTs, bounds.start), end: min($0.endTs, bounds.end)) }
        guard !clipped.isEmpty else { return (0, 0) }

        let nowTs = Int(now.timeIntervalSince1970)
        var total = 0.0
        var elapsed = 0.0
        for window in TimeWindows.merged(clipped) {
            total += Double(max(0, window.end - window.start)) / 3_600
            // The part that has actually happened. For a past day `nowTs` is beyond the window and this
            // equals `total`, which is what makes a past day read its full figure.
            elapsed += Double(max(0, min(window.end, nowTs) - window.start)) / 3_600
        }
        return (min(total, 24), min(elapsed, total))
    }

    // MARK: - Which step count the budget may use

    /// The day's total step count, from the freshest instrument that can answer.
    ///
    /// THIS EXISTS BECAUSE THE BUDGET WAS NOT MOVING. `days` is the merged daily cache, and its `steps`
    /// column for TODAY only gains a value once the strap has offloaded the window. Between offloads the
    /// column is nil, `stepsAboveBaseline` was handed 0, and the budget sat at BMR x 1.2 - deficit all
    /// day while the Today screen — which reads its own fresher series — showed thousands of steps. The
    /// arithmetic was right; it was being fed a step count from hours ago.
    ///
    /// PRECEDENCE, not a sum, and not a maximum across instruments. These are alternative measurements of
    /// the same legs, so adding them would double-count and taking whichever is highest would hand the
    /// budget to whichever device over-reports. The order mirrors `MetricCatalog.todayStepsMetric`, which
    /// already decided this question for the Today tile: the measured strap count, else Apple Health's.
    ///
    /// The ONE exception is the live phone pedometer, and only for today, and only upward. `CMPedometer`
    /// is the only source that knows about the last ten minutes; the strap column and the Health series
    /// both lag it. So for today it may RAISE a resolved figure, never lower one — if the strap has
    /// already offloaded more steps than the phone saw, the phone was in a bag and the strap is right.
    /// Taking the larger of two counts that both lag for different reasons is the least-wrong way to
    /// track a day still in progress, and it cannot invent movement: both are measurements.
    ///
    /// Returns nil when nothing can answer, which the caller treats as no NEAT credit rather than a
    /// guess — the conservative direction every other gap here errs in.
    func dailyStepsForDiet(_ dayKey: String) async -> Int? {
        var resolved: Int? = days.first(where: { $0.day == dayKey })?.steps
        // Apple Health only when the strap has nothing. A zero column is "no answer", not "no steps":
        // the daily cache writes 0 for a day it has not seen stepped, and treating that as measured
        // would pin the budget at baseline for anyone whose steps come from their phone.
        if (resolved ?? 0) <= 0 {
            let series = await series(key: "steps", source: "apple-health", days: 2)
            if let v = series.first(where: { $0.day == dayKey })?.value, v > 0 {
                resolved = Int(v.rounded())
            }
        }
        guard dayKey == Repository.localDayKey(Date()) else { return resolved }
        // Today only: let the live pedometer raise the figure. iOS-only — on macOS this is nil and the
        // resolved value stands unchanged.
        guard let bounds = Self.dayBounds(dayKey),
              let live = await WorkoutPedometer.steps(fromSec: bounds.start,
                                                      toSec: min(bounds.end, Int(Date().timeIntervalSince1970))),
              live > 0 else { return resolved }
        return max(resolved ?? 0, live)
    }

    // MARK: - The day

    /// Assemble the day's expenditure and budget.
    ///
    /// `profile` is passed in rather than read from an ambient store, so this stays a plain function of
    /// its inputs and can be reasoned about without knowing what else is on screen.
    func dietDayEnergy(day: String? = nil, profile: ProfileStore) async -> DietDayEnergy {
        let dayKey = day ?? Repository.localDayKey(Date())
        let goal = await dietGoal(on: dayKey)
        let activity = ActivityLevel(rawValue: goal?.activityLevel ?? "") ?? .sedentary

        let dailySteps = await dailyStepsForDiet(dayKey)
        let workoutSteps = await workoutStepsForDay(dayKey, stepTicksPerStep: profile.stepTicksPerStep)
        // No step answer means no NEAT credit, not a guess. The budget is then baseline + workouts, which
        // under-credits rather than inventing movement — the same direction every other gap here errs in.
        let neatSteps = StepNeat.stepsAboveBaseline(dailySteps: dailySteps ?? 0, workoutSteps: workoutSteps)
        let workoutKcal = await workoutKcalForDay(dayKey)

        // Weight comes from the profile rather than the goal's stored start weight: expenditure scales
        // with the body doing the spending, and a goal set eight kilos ago would otherwise keep pricing
        // today at the old mass.
        let expenditure = CalorieTarget.dayExpenditure(sex: profile.sex,
                                                       weightKg: profile.weightKg,
                                                       heightCm: profile.heightCm,
                                                       age: Double(profile.age),
                                                       activity: activity,
                                                       neatSteps: neatSteps,
                                                       workoutKcal: workoutKcal,
                                                       // Replaces ONLY the baseline, so the step and
                                                       // workout terms above still move the budget with
                                                       // the day. nil on every goal until the user opts
                                                       // in at the review card.
                                                       baselineOverrideKcal: goal?.measuredBaselineKcal)
        return DietDayEnergy(expenditure: expenditure,
                             dailySteps: dailySteps,
                             workoutSteps: workoutSteps,
                             neatSteps: neatSteps,
                             deficitKcal: goal?.dailyDeficitKcal,
                             // Reported so a screen can label the baseline honestly. Taken from the
                             // EXPENDITURE rather than from the goal, so it reflects what the sanity
                             // floor actually allowed rather than merely what was stored: a sub-BMR
                             // figure is refused inside `dayExpenditure`, and a card that read the goal
                             // would then claim a measured baseline was in use when it was not.
                             usesMeasuredBaseline: CalorieTarget.sanitisedBaselineOverride(
                                 goal?.measuredBaselineKcal,
                                 bmrKcal: expenditure.bmrKcal) != nil)
    }

    /// Compute the day and bank the two derived figures, so history survives and the charts have a series.
    ///
    /// Only writes when a goal exists: a target with nothing to target is not a fact worth storing, and a
    /// zero would read on a chart as "you were allowed nothing that day".
    @discardableResult
    func refreshDietDay(day: String? = nil, profile: ProfileStore) async -> DietDayEnergy {
        let dayKey = day ?? Repository.localDayKey(Date())
        let energy = await dietDayEnergy(day: dayKey, profile: profile)
        if let budget = energy.budgetKcal(), let store = await storeHandle() {
            _ = try? await store.upsertMetricSeries([
                MetricPoint(day: dayKey, key: DietStore.Keys.target, value: budget),
                MetricPoint(day: dayKey, key: DietStore.Keys.expenditure, value: energy.expenditure.totalKcal),
                // Written from the SAME assembly as the total above, so the two can never describe
                // different days' activity.
                MetricPoint(day: dayKey, key: DietStore.Keys.activity, value: energy.expenditure.activityKcal),
            ], deviceId: DietStore.sourceId)
        }
        return energy
    }

    /// The budget LAST BANKED for a day, without recomputing it.
    ///
    /// Exists for readers that need the figure but hold no `ProfileStore` — the coach context being the
    /// first. Reading the banked value rather than re-deriving is the point, not a shortcut: a second
    /// derivation is a second answer to one question, and the repo's hard rules say two readouts of one
    /// fact must not be able to disagree. `refreshDietDay` is what keeps this current, and the budget
    /// card calls it on every appear and on every foreground.
    ///
    /// nil when no goal has ever banked a figure for that day, which a caller must render as "no budget"
    /// rather than as zero.
    func bankedBudgetKcal(day: String? = nil) async -> Double? {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle(),
              let points = try? await store.metricSeries(deviceId: DietStore.sourceId,
                                                         key: DietStore.Keys.target,
                                                         from: dayKey, to: dayKey)
        else { return nil }
        return points.first(where: { $0.day == dayKey })?.value
    }

    /// The whole-day expenditure last banked for a day, and whether a measured baseline produced it.
    ///
    /// Read back rather than recomputed for the same reason `bankedBudgetKcal` is: a second derivation is a
    /// second answer to one question. Callers that hold no `ProfileStore` — the Today calorie tile — could
    /// not derive it honestly anyway.
    ///
    /// The `measured` flag comes from the CURRENT goal, which is the truth about today. It is used only to
    /// caption the figure, so a stale flag on a backdated day would mislabel rather than miscount; reading
    /// the open goal keeps today's caption right, which is the day the tile shows.
    ///
    /// nil when nothing is banked — no goal, or food logging never used — and the caller then falls back to
    /// whatever it showed before.
    func bankedDietExpenditure(day: String? = nil) async -> (kcal: Double, measured: Bool)? {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard let store = await storeHandle(),
              let points = try? await store.metricSeries(deviceId: DietStore.sourceId,
                                                         key: DietStore.Keys.expenditure,
                                                         from: dayKey, to: dayKey),
              let value = points.first(where: { $0.day == dayKey })?.value,
              value > 0 else { return nil }
        let measured = (try? await store.currentDietGoal(deviceId: DietStore.sourceId))?
            .measuredBaselineKcal != nil
        return (value, measured)
    }

    /// What has been spent SO FAR on a day, for display.
    ///
    /// Live-computed rather than banked, deliberately: it changes every minute, and a stored running total
    /// would be stale the moment it was written. The banked `diet_expenditure` stays the whole-day figure —
    /// it is what history charts and what the measured-baseline derivation subtracts against, and both of
    /// those need a day total rather than a snapshot.
    ///
    /// For a day that is not today the result is the whole-day figure, because the day has fully elapsed.
    /// So this is safe to call for any day and needs no "is it today" check at the call site.
    ///
    /// nil when there is no expenditure to describe.
    func burnedSoFar(day: String? = nil, profile: ProfileStore,
                     now: Date = Date()) async -> ProgressiveBurn.Result? {
        let dayKey = day ?? Repository.localDayKey(now)
        let energy = await dietDayEnergy(day: dayKey, profile: profile)
        guard energy.expenditure.totalKcal > 0 else { return nil }

        let isToday = dayKey == Repository.localDayKey(now)
        let elapsed = isToday
            ? ProgressiveBurn.elapsedHours(minuteOfDay: FoodEntries.minuteOfDay(now))
            : ProgressiveBurn.hoursPerDay
        let sleep = await sleepHoursForDay(dayKey, now: now)

        // The multiplier is re-derived from the baseline rather than read from the goal's activity level,
        // so an adopted MEASURED baseline flows through correctly: its effective multiplier is whatever the
        // measurement implies, not the ×1.2 the model would have used.
        let multiplier = energy.expenditure.bmrKcal > 0
            ? energy.expenditure.baselineKcal / energy.expenditure.bmrKcal
            : 1.2
        return ProgressiveBurn.burnedSoFar(bmrKcal: energy.expenditure.bmrKcal,
                                           activityMultiplier: multiplier,
                                           nightSleepHours: sleep.total,
                                           sleepHoursToday: sleep.elapsed,
                                           elapsedHours: elapsed,
                                           activityKcal: energy.expenditure.activityKcal)
    }

    /// Local-day bounds as unix seconds, `[start, end)`.
    static func dayBounds(_ dayKey: String) -> (start: Int, end: Int)? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        guard let start = f.date(from: dayKey),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }
}

// MARK: - Last night's detected wake

extension Repository {

    /// When NOOP thinks the wearer woke, as minute-of-day plus the local day it fell on.
    ///
    /// Feeds the wake-triggered morning brief (`CoachBriefScheduler`). Returns nil when there is no
    /// session recent enough to be "last night" — an unworn strap, or a night not yet offloaded — and the
    /// scheduler then falls back to its fixed time rather than inventing a wake.
    ///
    /// The window is the last 36 hours rather than "today", deliberately. A night that ran 23:30 → 07:00
    /// has its ONSET on one day and its wake on the next, so a today-bounded read would miss it on the
    /// morning it matters. The caller still checks the returned DAY against today, so a wake found inside
    /// the window but belonging to yesterday cannot trigger anything.
    ///
    /// Takes the newest session by wake time, which is what "last night" means on a day containing a nap:
    /// `sleepSessions` is ordered by onset, and a long nap could start after the night's onset but end
    /// before its wake only in pathological data — ordering by `endTs` makes the choice explicit rather
    /// than relying on that.
    func detectedWakeMinuteOfDay(now: Date = Date()) async -> (minutes: Int, day: String)? {
        let to = Int(now.timeIntervalSince1970)
        let from = to - 36 * 3_600
        var sessions = await sleepSessions(from: from, to: to)
        if sessions.isEmpty {
            // A Bluetooth-only strap banks nights under the COMPUTED source, so the imported-only read
            // above returns nothing for a 4.0 user whose every night is computed — the same fallback the
            // sleep funnel makes (#1150). Without it this feature would silently never fire for them.
            sessions = await computedSleepSessions(from: from, to: to)
        }
        guard let latest = sessions.max(by: { $0.endTs < $1.endTs }) else { return nil }
        // A session whose wake is in the FUTURE is a clock or timezone artefact, not a wake. Treated as
        // no answer rather than clamped: timing a brief off it would fire at a moment that never happened.
        guard latest.endTs <= to else { return nil }
        let wake = Date(timeIntervalSince1970: TimeInterval(latest.endTs))
        let comps = Calendar.current.dateComponents([.hour, .minute], from: wake)
        return ((comps.hour ?? 0) * 60 + (comps.minute ?? 0), Repository.localDayKey(wake))
    }
}

// MARK: - Mean banked activity over a window

extension Repository {

    /// Mean per-day activity energy (step NEAT + workouts) over the last `days`, from the series
    /// `refreshDietDay` banks.
    ///
    /// Averaged over days that HAVE a figure, not over the window: a day the app never assembled has no
    /// activity reading, and counting it as zero would understate the mean and so overstate the derived
    /// baseline — which is the direction that inflates a budget.
    ///
    /// nil when no day in the window banked one, so the caller cannot derive a baseline from nothing.
    func meanDietActivityKcal(days: Int, now: Date = Date()) async -> Double? {
        let n = max(1, days)
        let fromKey = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1) * 86_400))
        let toKey = Repository.localDayKey(now)
        guard let store = await storeHandle(),
              let points = try? await store.metricSeries(deviceId: DietStore.sourceId,
                                                        key: DietStore.Keys.activity,
                                                        from: fromKey, to: toKey),
              !points.isEmpty else { return nil }
        let values = points.map(\.value).filter { $0.isFinite && $0 >= 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
