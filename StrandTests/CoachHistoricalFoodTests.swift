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
        let butterKey = try XCTUnwrap(references.first { $0.value.name == "Butter (10g)" }?.key)
        let eggsKey = try XCTUnwrap(references.first { $0.value.name == "Eggs (large, 2)" }?.key)
        let reply = """
        {"noop_food_action":{"actions":[{"action":"log","itemId":"\(butterKey)","portion":1,"day":"yesterday"},{"action":"log","itemId":"\(eggsKey)","portion":1,"day":"yesterday"}]}}
        """
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
    func testEggsAndConflictingButterSnapshotsRemainLoggable() throws {
        let entries = [
            WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Butter",
                portion: 1, macros: butter),
            WeekEntryDigest(daysAgo: 2, itemId: nil, batchId: nil, name: "Butter",
                portion: 1, macros: MacroTotals(kcal: 148, protein: 0, carbs: 0, fat: 16, fiber: 0)),
            WeekEntryDigest(daysAgo: 1, itemId: nil, batchId: nil, name: "Eggs",
                portion: 1, macros: eggs)
        ]
        let references = FoodWeekDigest.foodReferences(entries: entries)
        XCTAssertEqual(references.count, 3)
        for (key, snapshot) in references {
            let proposal = try XCTUnwrap(FoodProposal.resolve(
                FoodActionRequest(action: .log(itemId: key, portion: 1)),
                library: [], recipeIds: [], defaultServingLabel: "1 serving",
                lastKnownWeightKg: nil, recentFoods: references))
            guard case .create(_, _, let macros, _) = proposal.kind else {
                return XCTFail("Each eggs/butter snapshot must resolve")
            }
            XCTAssertEqual(macros, snapshot.macros)
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
        let eggsKey = try XCTUnwrap(context.references.first { $0.value.name == "Eggs (large, 2)" }?.key)
        XCTAssertTrue(context.text.contains("\(eggsKey) | Eggs (large, 2)"))
        let reply = """
        {"noop_food_action":{"action":"log","itemId":"\(eggsKey)","portion":0.5,"day":"yesterday","meal":"breakfast"}}
        """
        let proposals = await coach.resolveProposals(in: reply, recentFoods: context.references)
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
        XCTAssertFalse(updatedContext.text.contains("today: \(eggsKey)"),
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
