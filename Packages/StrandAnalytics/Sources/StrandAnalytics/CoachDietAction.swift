import Foundation
import CoreFoundation

/// An editable destination and timeline. Calories remain derived by `DietGoal`, never supplied by AI.
public struct CoachDietGoalRequest: Equatable, Sendable {
    public let targetWeightKg: Double
    public let months: Int
    public let proteinGPerKg: Double?
    public let reason: String

    public init(targetWeightKg: Double, months: Int, proteinGPerKg: Double? = nil, reason: String) {
        self.targetWeightKg = targetWeightKg
        self.months = months
        self.proteinGPerKg = proteinGPerKg
        self.reason = reason
    }
}

/// A separate action boundary for diet planning, with strict numeric types and bounded editor inputs.
public enum CoachDietAction {
    public static let sentinel = "noop_diet_goal"

    public static func parse(_ reply: String) -> CoachDietGoalRequest? {
        guard let range = FoodActionParse.sentinelObjectRange(in: reply, sentinel: sentinel),
              let data = String(reply[range]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root[sentinel] as? [String: Any],
              let target = number(body["targetWeightKg"]), target > 0,
              let months = number(body["months"]), (1...12).contains(months), months.rounded() == months,
              let reason = body["reason"] as? String,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 1_000
        else { return nil }
        var protein: Double?
        if let raw = body["proteinGPerKg"] {
            guard let value = number(raw),
                  (MacroTargets.minProteinGPerKg...MacroTargets.maxProteinGPerKg).contains(value)
            else { return nil }
            protein = value
        }
        return CoachDietGoalRequest(targetWeightKg: target, months: Int(months),
                                    proteinGPerKg: protein, reason: reason)
    }

    public static func displayText(_ reply: String) -> String {
        FoodActionParse.displayText(reply, sentinel: sentinel)
    }

    public static func strippingAction(from reply: String) -> String {
        FoodActionParse.strippingAction(from: reply, sentinel: sentinel)
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}

/// Review signals determined from data, independent of model prose or a network request.
public enum CoachDietReviewSignal: String, Equatable, Sendable {
    case noGoal, building, onTrack, slower, faster, goalReached, staleWeight

    public static func evaluate(hasGoal: Bool, goalAgeDays: Int, fit: WeightTrendFit?,
                                expectedLossKgPerWeek: Double, trendWeightKg: Double?,
                                targetWeightKg: Double?, daysSinceWeighIn: Int?) -> Self {
        guard hasGoal else { return .noGoal }
        guard let age = daysSinceWeighIn, age <= 7 else { return .staleWeight }
        if let trendWeightKg, let targetWeightKg, trendWeightKg <= targetWeightKg,
           let fit, fit.dayCount >= 6, fit.spanDays >= 21 { return .goalReached }
        guard goalAgeDays >= 21, let fit, fit.dayCount >= 6, fit.spanDays >= 21 else { return .building }
        // Compare the planned loss with the entire observed interval, not just its central slope.
        let expectedSlope = -expectedLossKgPerWeek
        if fit.slopeKgPerWeek - fit.weeklyMarginKg > expectedSlope { return .slower }
        if fit.slopeKgPerWeek + fit.weeklyMarginKg < expectedSlope { return .faster }
        return fit.isDistinguishableFromZero || (fit.standardError == 0 && fit.slopeKgPerWeek != 0) ? .onTrack : .building
    }
}
