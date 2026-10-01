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

        static let all = [target, expenditure]
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

    // MARK: - The day

    /// Assemble the day's expenditure and budget.
    ///
    /// `profile` is passed in rather than read from an ambient store, so this stays a plain function of
    /// its inputs and can be reasoned about without knowing what else is on screen.
    func dietDayEnergy(day: String? = nil, profile: ProfileStore) async -> DietDayEnergy {
        let dayKey = day ?? Repository.localDayKey(Date())
        let goal = await dietGoal(on: dayKey)
        let activity = ActivityLevel(rawValue: goal?.activityLevel ?? "") ?? .sedentary

        let dailySteps = days.first(where: { $0.day == dayKey })?.steps
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
                                                       workoutKcal: workoutKcal)
        return DietDayEnergy(expenditure: expenditure,
                             dailySteps: dailySteps,
                             workoutSteps: workoutSteps,
                             neatSteps: neatSteps,
                             deficitKcal: goal?.dailyDeficitKcal)
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
            ], deviceId: DietStore.sourceId)
        }
        return energy
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
