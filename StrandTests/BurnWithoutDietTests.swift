import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The burn model (resting + steps + training) works, and is banked, for someone with no diet goal and food
/// logging off — the Calories tile reads it for everyone.
final class BurnWithoutDietTests: XCTestCase {

    @MainActor
    func testTheBurnIsComputedAndBankedWithNoGoal() async throws {
        let previous = UserDefaults.standard.object(forKey: FoodLogStore.enabledKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: FoodLogStore.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: FoodLogStore.enabledKey) }
        }
        UserDefaults.standard.set(false, forKey: FoodLogStore.enabledKey)
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "burn-without-diet")
        repo.setStoreForTesting(store)
        let profile = ProfileStore()
        let day = Repository.localDayKey(Date())

        let goal = await repo.currentDietGoal()
        XCTAssertNil(goal)
        let energy = await repo.refreshDietDay(day: day, profile: profile)
        XCTAssertGreaterThan(energy.expenditure.totalKcal, energy.expenditure.bmrKcal,
                             "baseline living is priced above BMR without any goal")
        XCTAssertNil(energy.budgetKcal(), "no goal, no budget")

        let banked = await repo.bankedDietExpenditure(day: day)
        XCTAssertEqual(try XCTUnwrap(banked).kcal, energy.expenditure.totalKcal, accuracy: 0.001)
        let target = await repo.bankedBudgetKcal(day: day)
        XCTAssertNil(target, "a target is banked only with a goal")

        let soFar = await repo.burnedSoFar(day: day, profile: profile)
        XCTAssertNotNil(soFar)
    }
}
