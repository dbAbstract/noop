import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

final class CoachHistoricalFoodTests: XCTestCase {
    private let eggs = MacroTotals(kcal: 126, protein: 12, carbs: 0, fat: 9, fiber: 0)
    private let butter = MacroTotals(kcal: 74, protein: 0, carbs: 0, fat: 8, fiber: 0)

    @MainActor
    func testExportedEggsAndButterHistoryKeysProduceConfirmableFoods() throws {
        let history = [
            WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Butter (10g)",
                portion: 1, macros: butter),
            WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Eggs (large, 2)",
                portion: 1, macros: eggs)
        ]
        let references = FoodWeekDigest.foodReferences(entries: history)
        let reply = #"{"noop_food_action":{"actions":[{"action":"log","itemId":"o1","portion":1,"day":"yesterday"},{"action":"log","itemId":"o2","portion":1,"day":"yesterday"}]}}"#
        let requests = try FoodActionParse.actions(fromReply: reply).get()
        for (request, expected) in zip(requests, [butter, eggs]) {
            let proposal = try XCTUnwrap(FoodProposal.resolve(request, library: [], recipeIds: [],
                defaultServingLabel: "1 serving", lastKnownWeightKg: nil, recentFoods: references))
            guard case .create(_, _, let macros, let portion) = proposal.kind else {
                return XCTFail("History must resolve to a confirmable food, not Unrecognised food")
            }
            XCTAssertEqual(macros, expected)
            XCTAssertEqual(portion, 1)
            XCTAssertEqual(proposal.state, .pending)
        }
    }

    @MainActor
    func testContextHistoryCanBeConfirmedWithoutSavingToLibrary() async throws {
        let oldEnabled = UserDefaults.standard.object(forKey: FoodLogStore.enabledKey)
        UserDefaults.standard.set(true, forKey: FoodLogStore.enabledKey)
        defer {
            if let oldEnabled { UserDefaults.standard.set(oldEnabled, forKey: FoodLogStore.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: FoodLogStore.enabledKey) }
        }
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let coach = AICoachEngine(repo: repo)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let key = Repository.localDayKey(yesterday)
        let at = Int(yesterday.timeIntervalSince1970)
        _ = try await store.upsertFoodEntries([
            FoodEntryRow(id: UUID().uuidString, deviceId: FoodLogStore.sourceId, day: key,
                itemId: nil, nameSnapshot: "Butter (10g)", portion: 1, kcal: 74, protein: 0,
                carbs: 0, fat: 8, fiber: 0, loggedAt: at),
            FoodEntryRow(id: UUID().uuidString, deviceId: FoodLogStore.sourceId, day: key,
                itemId: nil, nameSnapshot: "Eggs (large, 2)", portion: 1, kcal: 126, protein: 12,
                carbs: 0, fat: 9, fiber: 0, loggedAt: at)
        ])
        let context = await coach.foodContextBlock()
        XCTAssertTrue(context.text.contains("o1 | Butter (10g)"))
        XCTAssertTrue(context.text.contains("o2 | Eggs (large, 2)"))
        let proposals = await coach.resolveProposals(in:
            #"{"noop_food_action":{"action":"log","itemId":"o2","portion":0.5,"day":"yesterday","meal":"breakfast"}}"#, recentFoods: context.references)
        let proposal = try XCTUnwrap(proposals.first)
        XCTAssertEqual(proposal.dayKey, key)
        XCTAssertEqual(proposal.loggedMacros?.kcal, 63)
        let before = await repo.foodEntries(day: key)
        XCTAssertEqual(before.count, 2, "Resolving a proposal does not log it")
        let applied = await repo.applyFoodProposal(proposal)
        XCTAssertTrue(applied)
        let entries = await repo.foodEntries(day: key)
        XCTAssertEqual(entries.count, 3)
        let repeated = try XCTUnwrap(entries.first { $0.portion == 0.5 })
        XCTAssertEqual(repeated.nameSnapshot, "Eggs (large, 2)")
        XCTAssertEqual(repeated.effectiveMacros.kcal, 63)
        XCTAssertEqual(repeated.mealType, .breakfast)
        let library = await repo.foodLibrary()
        XCTAssertTrue(library.isEmpty)
        let updatedContext = await coach.foodContextBlock()
        XCTAssertTrue(updatedContext.text.contains("-1d 263 kcal/18P"), updatedContext.text)
        XCTAssertFalse(updatedContext.text.contains("today: o2"),
            "Confirming yesterday's food today must not move it into today's context")
    }

    @MainActor
    func testUnknownHistoryKeyAndHistoricalEditRemainUnresolved() throws {
        let history = ["o1": FoodDigestEntry(id: "o1", name: "Butter", servingLabel: "10g", macros: butter)]
        for action in [FoodAction.log(itemId: "o12", portion: 1), .edit(itemId: "o1", name: nil, macros: eggs)] {
            let proposal = try XCTUnwrap(FoodProposal.resolve(FoodActionRequest(action: action),
                library: [], recipeIds: [], defaultServingLabel: "1 serving", lastKnownWeightKg: nil,
                recentFoods: history))
            guard case .unresolved = proposal.kind else { return XCTFail("Must refuse unknown or editable history") }
        }
    }
}
