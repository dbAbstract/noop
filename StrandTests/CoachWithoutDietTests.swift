import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Coach for someone who never turns food logging on: no food or diet instructions in the prompt, and no
/// food card even if a model emits a food action anyway.
final class CoachWithoutDietTests: XCTestCase {

    private func withFoodLogging(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let keys = [FoodLogStore.enabledKey, AICoachEngine.systemPromptKey]
        let previous = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set(on, forKey: FoodLogStore.enabledKey)
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        try await body()
    }

    @MainActor
    func testFoodAndDietInstructionsRideOnlyWithFoodLogging() async {
        let engine = AICoachEngine(repo: Repository(deviceId: "coach-without-diet"))
        await withFoodLogging(false) {
            let prompt = engine.interactiveSystemPrompt
            XCTAssertTrue(prompt.hasPrefix(AICoachEngine.defaultSystemPrompt))
            XCTAssertFalse(prompt.contains("LOGGING FOOD AND WEIGHT"))
            XCTAssertFalse(prompt.contains("\"action\": \"create\""))
            XCTAssertFalse(prompt.contains(CoachDietAction.sentinel))
            XCTAssertTrue(prompt.contains("GUIDE TOPICS:"))
            XCTAssertLessThan(prompt.count, 6_000, "the persona and guide index, not the diet protocol")
        }
        await withFoodLogging(true) {
            let prompt = engine.interactiveSystemPrompt
            XCTAssertEqual(prompt.components(separatedBy: "LOGGING FOOD AND WEIGHT").count, 2)
            XCTAssertTrue(prompt.contains(CoachDietAction.sentinel))
            // A custom prompt copied from the old default already carries the protocol: not given it twice.
            engine.customSystemPrompt = AICoachEngine.defaultSystemPrompt + "\n\n" + AICoachEngine.foodProtocol
            XCTAssertEqual(engine.interactiveSystemPrompt.components(separatedBy: "LOGGING FOOD AND WEIGHT").count, 2)
            XCTAssertFalse(engine.customPromptMissesFoodProtocol)
        }
    }

    @MainActor
    func testAFoodActionMakesNoCardWithFoodLoggingOff() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "coach-without-diet-cards")
        repo.setStoreForTesting(store)
        let engine = AICoachEngine(repo: repo)
        let reply = """
        Noted. {"noop_food_action": {"actions": [{"action": "create", "name": "Two eggs", "servingLabel": "2 eggs", \
        "kcal": 140, "protein": 12, "carbs": 1, "fat": 10, "portion": 1}, {"action": "weight", "kg": 72.4}]}}
        """
        await withFoodLogging(false) {
            let cards = await engine.resolveProposals(in: reply, recentFoods: [:])
            XCTAssertEqual(cards.count, 1, "only the weigh-in survives")
            guard case .weight = cards.first?.kind else { return XCTFail("expected the weigh-in card") }
        }
        await withFoodLogging(true) {
            let cards = await engine.resolveProposals(in: reply, recentFoods: [:])
            XCTAssertEqual(cards.count, 2)
        }
    }
}
