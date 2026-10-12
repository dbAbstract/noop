import Foundation
import WhoopStore
import StrandAnalytics

/// A transient proposal. Confirmation opens the regular goal editor; no model output writes a goal.
struct CoachDietProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: CoachDietGoalRequest
    let previousGoal: DietGoalRow?
    var state: FoodProposal.State = .pending
    var appliedPlan: DietGoalPlan?
    var appliedProteinGPerKg: Double?

    init(id: UUID = UUID(), request: CoachDietGoalRequest, previousGoal: DietGoalRow?) {
        self.id = id
        self.request = request
        self.previousGoal = previousGoal
    }
}

/// A local review snapshot shared by Coach context and the Diet check-in card.
struct CoachDietSnapshot {
    let goal: DietGoalRow?
    let reading: DietTrendReading
    let fit: WeightTrendFit?
    let trendWeightKg: Double?
    let latestWeightKg: Double?
    let goalAgeDays: Int
    let daysSinceWeighIn: Int?
    let intakeDays: Int
    let roughDays: Int
    let reviewWindowDays: Int
    let signal: CoachDietReviewSignal

    var context: String {
        var lines = ["DIET REVIEW (computed locally; do not invent a diagnosis):"]
        if let goal {
            lines.append("Goal: start \(goal.startWeightKg) kg on \(goal.startedOn), target \(goal.targetWeightKg) kg, timeline \(goal.months) months, planned deficit \(goal.dailyDeficitKcal) kcal/day. Days since plan started: \(goalAgeDays).")
            lines.append("Protein goal: \(goal.proteinGPerKg.map { String($0) } ?? "not set") g/kg. Baseline: \(goal.measuredBaselineKcal.map { "adopted calibration \($0) kcal/day" } ?? "formula estimate").")
            lines.append("Expected loss from this plan: \(goal.dailyDeficitKcal * 7 / DietGoal.kcalPerKg) kg/week.")
        } else { lines.append("No active goal. Discuss destination and timeline before proposing a plan.") }
        lines.append("Review signal: \(signal.rawValue). Latest weight: \(latestWeightKg.map { String($0) } ?? "unknown") kg; days since weigh-in: \(daysSinceWeighIn.map { String($0) } ?? "unknown").")
        if let fit {
            lines.append("Weight trend since this plan started (up to 42 days): \(fit.slopeKgPerWeek) ± \(fit.weeklyMarginKg) kg/week, negative means loss; \(fit.dayCount) weigh-in days over \(fit.spanDays) days. Distinguishable from no change: \(fit.isDistinguishableFromZero).")
        } else { lines.append("Not enough weigh-ins for a trend within this plan.") }
        lines.append("Logged intake on \(intakeDays)/\(reviewWindowDays) completed calendar days; \(roughDays) rough days. A logged day may still contain missing meals; coverage does NOT prove completeness.")
        if let adaptive = reading.adaptive {
            lines.append("Intake-derived expenditure over a separate \(adaptive.windowDays)-day window: \(adaptive.estimatedDailyKcal) kcal/day, range \(adaptive.lowerKcal)...\(adaptive.upperKcal), confidence \(adaptive.confidence.rawValue). This incorporates logging bias; it does not establish true TDEE or diagnose metabolism.")
        } else { lines.append("Intake-derived expenditure unavailable: insufficient intake/weight coverage.") }
        lines.append("Last successful Coach diet review for this goal: \(CoachDietReviewHistory.lastReviewed(goalId: goal?.id).map { ISO8601DateFormatter().string(from: $0) } ?? "never"). Do not repeatedly raise a concern already discussed; ask about consistency, missing meals, changed activity and manageability before suggesting a change.")
        return lines.joined(separator: "\n")
    }
}

/// Review cadence is local UI state. No timer sends personal data or asks a provider automatically.
enum CoachDietReviewHistory {
    static let dateKey = "coachDiet.lastReviewEpoch"
    static let goalKey = "coachDiet.lastReviewGoalId"
    static let prompt = "Review my diet progress with me. Compare my current goal with the measured weight trend, explain data quality and uncertainty, and ask about logging consistency and how manageable the plan feels before suggesting any changes. If there is not enough evidence, tell me what to collect next."

    static func lastReviewed(goalId: String?, defaults: UserDefaults = .standard) -> Date? {
        guard defaults.string(forKey: goalKey) == (goalId ?? "no-goal"),
              defaults.double(forKey: dateKey) > 0 else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: dateKey))
    }

    static func isDue(goalId: String?, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let last = lastReviewed(goalId: goalId, defaults: defaults) else { return true }
        return now.timeIntervalSince(last) >= 7 * 86_400
    }

    static func record(goalId: String?, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(goalId ?? "no-goal", forKey: goalKey)
        defaults.set(now.timeIntervalSince1970, forKey: dateKey)
    }
}

extension Repository {
    func coachDietSnapshot(now: Date = Date()) async -> CoachDietSnapshot {
        let goal = await currentDietGoal()
        let today = Self.localDayKey(now)
        let todayIndex = Self.dayIndex(today) ?? 0
        let goalAge = goal.flatMap { Self.dayIndex($0.startedOn) }.map { max(0, todayIndex - $0) } ?? 0
        let windowStart = max(todayIndex - 41, goal.flatMap { Self.dayIndex($0.startedOn) } ?? todayIndex - 41)
        let weights = await weightHistory(days: 42, now: now)
        let readings = weights.compactMap { row -> WeightReading? in
            guard let index = Self.dayIndex(row.day), index >= windowStart else { return nil }
            return WeightReading(dayIndex: index, kg: row.kg)
        }.sorted { $0.dayIndex < $1.dayIndex }
        let fit = WeightTrend.fit(readings)
        let smoothed = WeightTrend.smoothed(readings).last?.kg
        let age = readings.last.map { max(0, todayIndex - $0.dayIndex) }
        // Today is unfinished, so it is not a missing-food day in the review.
        let intake = await foodHistory(days: 42, now: now)
        let completedIntake = intake.filter {
            guard let index = Self.dayIndex($0.day) else { return false }
            return index >= windowStart && index < todayIndex && $0.kcal > 0
        }
        let rough = await roughIntakeDays(days: 42, now: now)
        let signal = CoachDietReviewSignal.evaluate(hasGoal: goal != nil, goalAgeDays: goalAge,
            fit: fit, expectedLossKgPerWeek: (goal?.dailyDeficitKcal ?? 0) * 7 / DietGoal.kcalPerKg,
            trendWeightKg: smoothed, targetWeightKg: goal?.targetWeightKg, daysSinceWeighIn: age)
        return CoachDietSnapshot(goal: goal, reading: await dietTrend(now: now), fit: fit,
            trendWeightKg: smoothed, latestWeightKg: readings.last?.kg, goalAgeDays: goalAge,
            daysSinceWeighIn: age, intakeDays: completedIntake.count,
            roughDays: completedIntake.filter { rough.contains($0.day) }.count,
            reviewWindowDays: max(0, todayIndex - windowStart), signal: signal)
    }
}

extension AICoachEngine {
    static let dietProtocol = """
    DIET PLANNING AND REVIEW. Use DIET REVIEW's locally computed signal, interval, goal and coverage.
    Do not call a few similar weigh-ins a plateau or equate logging coverage with complete meals.
    Underreported intake and overestimated expenditure are indistinguishable from these data alone.
    Describe intake-derived expenditure as an effective estimate incorporating logging habits, never
    proven true TDEE. Ask about missing meals, weekends, changed logging habits, activity and whether
    the plan is manageable before recommending an adjustment. Do not blame metabolism or dishonesty.
    A building/staleWeight signal calls for evidence, not a calorie cut. When onTrack, support the plan.
    Explain slower/faster signals with their uncertainty; do not recommend faster loss by default.
    When a weekly review is due and the local signal is slower, faster, goalReached or staleWeight,
    briefly raise that concern when relevant to the user's diet question. Acknowledge a recent review
    or an agreed decision already in this conversation instead of repeating it. Do not interrupt an
    unrelated conversation with diet advice. Avoid suggesting a change solely because of one meal.
    On goalReached, discuss what the user wants next; maintenance/gain plans are not supported by this
    loss-goal editor. Do not propose one by inventing a loss goal. Never silently change any setting.

    You may propose an EDITABLE goal only when the user wants to set or revise their plan and you have
    their target weight and timeline. Preserve an existing protein goal unless a change was discussed.
    The app calculates calories and validates the plan. Never claim a proposal has been applied.
    End a goal proposal with this separate block (no food-action block in the same turn):
    {"noop_diet_goal":{"targetWeightKg":69.0,"months":6,"reason":"Explain why this plan fits the discussion","proteinGPerKg":1.2}}
    Use kilograms and whole months 1–12; proteinGPerKg is optional. The review editor shows current and
    proposed goals and allows changes before a separate save. Direct changes to deficits, burn estimates
    and calibrated baselines are unsupported: explain this instead of claiming to have changed them.
    """

    func updateDietProposal(messageId: UUID, state: FoodProposal.State,
                            appliedPlan: DietGoalPlan? = nil, proteinGPerKg: Double? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].dietProposal?.state = state
        messages[index].dietProposal?.appliedPlan = appliedPlan
        messages[index].dietProposal?.appliedProteinGPerKg = proteinGPerKg
    }
}
