import XCTest
@testable import StrandAnalytics

/// Which meal an entry belongs to, and how a day groups.
///
/// The two that matter are the skipped-breakfast case — which is why the boundary is 11:00 rather than the
/// conventional 10:00 — and the refusal to infer a meal from a timestamp that is only a sentinel.
final class MealGroupingTests: XCTestCase {

    private func meal(_ hour: Int, _ minute: Int = 0,
                      explicit: Meal? = nil, unknown: Bool = false) -> Meal {
        MealGrouping.meal(explicit: explicit, minuteOfDay: hour * 60 + minute, isUnknownTime: unknown)
    }

    // MARK: - The skipped-breakfast case

    /// THE REASON THE BOUNDARY IS 11:00. Waking at 09:30–10:30 and taking a first meal at 11:30 is lunch,
    /// not a late breakfast — a 10:00 boundary would show a breakfast that was not eaten and no lunch that
    /// was.
    func testALateFirstMealIsLunchNotBreakfast() {
        XCTAssertEqual(meal(11, 30), .lunch)
        XCTAssertEqual(meal(12, 15), .lunch)
    }

    /// And an early riser's breakfast still reads as breakfast — the generous boundary costs them nothing.
    func testAnEarlyBreakfastIsStillBreakfast() {
        XCTAssertEqual(meal(7), .breakfast)
        XCTAssertEqual(meal(10, 30), .breakfast)
    }

    func testTheBoundaryIsExclusiveAtEleven() {
        XCTAssertEqual(meal(10, 59), .breakfast)
        XCTAssertEqual(meal(11, 0), .lunch)
    }

    // MARK: - The rest of the day

    func testAfternoonAndEveningBoundaries() {
        XCTAssertEqual(meal(15, 59), .lunch)
        XCTAssertEqual(meal(16, 0), .dinner)
        XCTAssertEqual(meal(20, 59), .dinner)
        XCTAssertEqual(meal(21, 0), .snack)
    }

    /// 02:00 is the end of a long night, not the start of a day.
    func testTheSmallHoursAreASnackNotBreakfast() {
        XCTAssertEqual(meal(2), .snack)
        XCTAssertEqual(meal(4, 59), .snack)
        XCTAssertEqual(meal(5, 0), .breakfast)
    }

    // MARK: - Explicit wins

    /// Someone eating lunch at 23:00 after a long shift has had lunch. A stated meal is a fact and the
    /// clock does not get to overrule it.
    func testAnExplicitMealBeatsTheClock() {
        XCTAssertEqual(meal(23, explicit: .lunch), .lunch)
        XCTAssertEqual(meal(8, explicit: .dinner), .dinner)
    }

    /// Explicit beats an unknown time too, which is the Coach path for a backfilled day: "yesterday's
    /// dinner" has no timestamp but a perfectly clear meal.
    func testAnExplicitMealSurvivesAnUnknownTime() {
        XCTAssertEqual(meal(12, explicit: .dinner, unknown: true), .dinner)
    }

    // MARK: - An unknown time is not a meal

    /// THE OTHER IMPORTANT ONE. A backfilled entry is stamped midday as an admission that its time is
    /// unknown. Calling it lunch would be exactly the guess-dressed-as-a-fact that stamp exists to avoid.
    func testAnUnknownTimeIsUnassignedNotLunch() {
        XCTAssertEqual(meal(12, unknown: true), .unassigned)
        XCTAssertEqual(meal(19, unknown: true), .unassigned)
    }

    func testNonsenseMinutesAreUnassigned() {
        XCTAssertEqual(MealGrouping.meal(explicit: nil, minuteOfDay: -1, isUnknownTime: false), .unassigned)
        XCTAssertEqual(MealGrouping.meal(explicit: nil, minuteOfDay: 24 * 60, isUnknownTime: false),
                       .unassigned)
    }

    // MARK: - Grouping

    private struct Item: Sendable {
        let meal: Meal
        let kcal: Double
    }

    private func grouped(_ items: [Item]) -> [MealGrouping.Group<Item>] {
        MealGrouping.grouped(items,
                            meal: { $0.meal },
                            macros: { MacroTotals(kcal: $0.kcal, protein: 0, carbs: 0, fat: 0, fiber: 0) })
    }

    /// The user's actual day: no breakfast. Two groups, and no empty breakfast heading implying they got
    /// something wrong.
    func testASkippedBreakfastProducesNoBreakfastGroup() {
        let groups = grouped([Item(meal: .lunch, kcal: 610), Item(meal: .dinner, kcal: 680)])
        XCTAssertEqual(groups.map(\.meal), [.lunch, .dinner])
        XCTAssertFalse(groups.contains { $0.meal == .breakfast })
    }

    func testGroupsComeBackInMealOrderRegardlessOfInputOrder() {
        let groups = grouped([Item(meal: .snack, kcal: 100),
                              Item(meal: .breakfast, kcal: 400),
                              Item(meal: .dinner, kcal: 700),
                              Item(meal: .lunch, kcal: 600)])
        XCTAssertEqual(groups.map(\.meal), [.breakfast, .lunch, .dinner, .snack])
    }

    func testUnassignedSortsLast() {
        let groups = grouped([Item(meal: .unassigned, kcal: 500), Item(meal: .breakfast, kcal: 400)])
        XCTAssertEqual(groups.map(\.meal), [.breakfast, .unassigned])
    }

    /// Subtotals must account for every entry exactly once — an entry dropped or double-counted here would
    /// make the groups disagree with the day total the budget is measured against.
    func testSubtotalsSumToTheDayTotal() {
        let items = [Item(meal: .lunch, kcal: 610), Item(meal: .lunch, kcal: 90),
                     Item(meal: .dinner, kcal: 680), Item(meal: .snack, kcal: 137)]
        let groups = grouped(items)
        XCTAssertEqual(groups.first { $0.meal == .lunch }?.total.kcal ?? .nan, 700, accuracy: 0.001)
        let groupSum = groups.reduce(0) { $0 + $1.total.kcal }
        XCTAssertEqual(groupSum, items.reduce(0) { $0 + $1.kcal }, accuracy: 0.001)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.items.count }, items.count)
    }

    func testAnEmptyDayGroupsToNothing() {
        XCTAssertTrue(grouped([]).isEmpty)
    }

    /// The sort index is asserted rather than left to declaration order, because a screen depends on it and
    /// inserting a case would silently reorder somebody's day.
    func testSortOrderIsPinned() {
        XCTAssertEqual(Meal.allCases.sorted { $0.sortIndex < $1.sortIndex },
                       [.breakfast, .lunch, .dinner, .snack, .unassigned])
    }

    /// The raw values are stored in `foodEntry.mealType`, so they are a wire format — a rename would
    /// orphan every logged entry.
    func testRawValuesAreTheStoredContract() {
        XCTAssertEqual(Meal.breakfast.rawValue, "breakfast")
        XCTAssertEqual(Meal.lunch.rawValue, "lunch")
        XCTAssertEqual(Meal.dinner.rawValue, "dinner")
        XCTAssertEqual(Meal.snack.rawValue, "snack")
    }
}
