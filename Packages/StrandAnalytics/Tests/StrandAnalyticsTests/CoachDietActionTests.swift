import XCTest
@testable import StrandAnalytics

final class CoachDietActionTests: XCTestCase {
    func testGoalParserRejectsCoercionsAndBounds() {
        let good = #"{"noop_diet_goal":{"targetWeightKg":69,"months":6,"reason":"A manageable timeline","proteinGPerKg":1.2}}"#
        let parsed = CoachDietAction.parse("Discuss this first.\n" + good)
        XCTAssertEqual(parsed?.targetWeightKg, 69)
        XCTAssertEqual(parsed?.months, 6)
        XCTAssertEqual(parsed?.proteinGPerKg, 1.2)
        for invalid in [good.replacingOccurrences(of: "69", with: "true"),
                        good.replacingOccurrences(of: "69", with: "\"69\""),
                        good.replacingOccurrences(of: "69", with: "-1"),
                        good.replacingOccurrences(of: "\"months\":6", with: "\"months\":6.5"),
                        good.replacingOccurrences(of: "\"months\":6", with: "\"months\":13"),
                        good.replacingOccurrences(of: "1.2", with: "4"),
                        good.replacingOccurrences(of: "A manageable timeline", with: " "),
                        #"{"targetWeightKg":69,"months":6,"reason":"not an action"}"#] {
            XCTAssertNil(CoachDietAction.parse(invalid), invalid)
        }
    }

    func testStreamingAndFencedBlocksDoNotExposeGoalJSONOrEatProse() {
        let action = #"{"noop_diet_goal":{"targetWeightKg":69,"months":6,"reason":"Contains {braces}"}}"#
        let reply = "A proposal, not a save.\n```json\n" + action + "\n```"
        XCTAssertNotNil(CoachDietAction.parse(reply))
        XCTAssertEqual(CoachDietAction.strippingAction(from: reply), "A proposal, not a save.")
        XCTAssertEqual(CoachDietAction.displayText("A proposal.\n{\"noop_diet_goal\": {"), "A proposal.")
        XCTAssertEqual(CoachDietAction.displayText("A plain answer with {examples}."), "A plain answer with {examples}.")
        let food = #"{"noop_food_action":{"action":"weight","kg":72.4}}"#
        XCTAssertEqual(CoachDietAction.strippingAction(from: food), food)
        XCTAssertEqual(FoodActionParse.strippingAction(from: action), action)
    }

    private func signal(slope: Double, error: Double = 0.005, age: Int = 42,
                        span: Int = 42, readings: Int = 12, weighInAge: Int? = 0,
                        trendWeight: Double = 72) -> CoachDietReviewSignal {
        CoachDietReviewSignal.evaluate(hasGoal: true, goalAgeDays: age,
            fit: WeightTrendFit(slopeKgPerDay: slope / 7, standardError: error,
                                scatterKg: 0.3, dayCount: readings, spanDays: span),
            expectedLossKgPerWeek: 0.4, trendWeightKg: trendWeight,
            targetWeightKg: 69, daysSinceWeighIn: weighInAge)
    }

    func testReviewRequiresCurrentPlanEvidenceAndFreshWeight() {
        XCTAssertEqual(signal(slope: -0.1, age: 7), .building)
        XCTAssertEqual(signal(slope: -0.1, span: 7), .building)
        XCTAssertEqual(signal(slope: -0.1, readings: 3), .building)
        XCTAssertEqual(signal(slope: -0.1, weighInAge: 8), .staleWeight)
        XCTAssertEqual(signal(slope: -0.1, weighInAge: nil), .staleWeight)
        XCTAssertEqual(signal(slope: 0, error: 0.1), .building)
    }

    func testReviewComparesIntervalsWithExpectedPace() {
        XCTAssertEqual(signal(slope: -0.4), .onTrack)
        XCTAssertEqual(signal(slope: -0.1), .slower)
        XCTAssertEqual(signal(slope: -0.8), .faster)
        XCTAssertEqual(signal(slope: 0, error: 0.005), .slower,
                       "A narrow flat interval can rule out the planned pace without claiming a loss")
        XCTAssertEqual(signal(slope: -0.4, trendWeight: 68.8), .goalReached)
        XCTAssertEqual(signal(slope: -0.4, readings: 3, trendWeight: 68.8), .building)
    }
}
