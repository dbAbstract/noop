import XCTest
@testable import Strand

/// `MetricCatalog.todayCaloriesMetric` — which source the Calories tile reads, and which detail it taps to.
///
/// The two branches return DIFFERENT QUANTITIES: Apple's `active_kcal` is active energy only, while NOOP's
/// `energy_kcal` resolves from `activeKcalEst`, which is resting + active. So these pin not just a
/// preference but the point at which the number on screen changes meaning — which is why the caller
/// captions it.
final class CaloriePrecedenceTests: XCTestCase {

    // MARK: - Default (preferStrap off) — imported-first, unchanged from #616

    func testImportedWinsByDefault() {
        let m = MetricCatalog.todayCaloriesMetric(hasImportedKcal: true, hasOnDeviceKcal: true)
        XCTAssertEqual(m?.key, "active_kcal")
        XCTAssertEqual(m?.source, "apple-health")
    }

    func testFallsBackToOnDeviceWhenNoImport() {
        let m = MetricCatalog.todayCaloriesMetric(hasImportedKcal: false, hasOnDeviceKcal: true)
        XCTAssertEqual(m?.key, "energy_kcal")
        XCTAssertEqual(m?.source, "my-whoop")
    }

    /// With neither source the descriptor must still resolve, so the tile always has somewhere to tap
    /// through to rather than dead-ending.
    func testResolvesWithNeitherSource() {
        let m = MetricCatalog.todayCaloriesMetric(hasImportedKcal: false, hasOnDeviceKcal: false)
        XCTAssertEqual(m?.key, "energy_kcal")
        XCTAssertEqual(m?.source, "my-whoop")
    }

    // MARK: - preferStrap on

    /// The whole point of the flag: the strap outranks the phone even when an import exists.
    func testStrapWinsOverImportWhenPreferred() {
        let m = MetricCatalog.todayCaloriesMetric(hasImportedKcal: true, hasOnDeviceKcal: true,
                                                  preferStrap: true)
        XCTAssertEqual(m?.key, "energy_kcal")
        XCTAssertEqual(m?.source, "my-whoop")
    }

    /// The preference must not invent a strap figure that does not exist — with no on-device value the
    /// imported one is still the only real number, and showing "—" instead would be worse.
    func testPreferStrapFallsBackToImportWhenNoOnDeviceValue() {
        let m = MetricCatalog.todayCaloriesMetric(hasImportedKcal: true, hasOnDeviceKcal: false,
                                                  preferStrap: true)
        XCTAssertEqual(m?.key, "active_kcal")
        XCTAssertEqual(m?.source, "apple-health")
    }

    func testPreferStrapWithNoImportStillResolvesOnDevice() {
        let m = MetricCatalog.todayCaloriesMetric(hasImportedKcal: false, hasOnDeviceKcal: true,
                                                  preferStrap: true)
        XCTAssertEqual(m?.key, "energy_kcal")
        XCTAssertEqual(m?.source, "my-whoop")
    }

    // MARK: - The descriptors the above resolve to must actually exist in the catalog

    /// A descriptor that resolves to nil would make the tile untappable. Both sources must be registered.
    func testBothCalorieDescriptorsAreRegistered() {
        XCTAssertNotNil(MetricCatalog.metric(key: "active_kcal", source: "apple-health"))
        XCTAssertNotNil(MetricCatalog.metric(key: "energy_kcal", source: "my-whoop"))
    }

    /// Steps already preferred the measured strap count before this change; calories were the odd one out.
    /// Pinned so the two cannot drift apart again.
    func testStepsStillPreferMeasuredStrapCount() {
        let m = MetricCatalog.todayStepsMetric(hasMeasuredSteps: true, hasImportedSteps: true)
        XCTAssertEqual(m?.source, "my-whoop")
    }

    // MARK: - Food log metric registration

    /// Every CHARTABLE food-log key needs a catalog descriptor or it charts nowhere.
    ///
    /// Narrowed from `Keys.all` to `Keys.charted` when `intake_rough` arrived: that key is a 0/1 flag
    /// about how a figure was obtained, not an amount, and registering it would put a square wave in the
    /// metric explorer for someone to read as calories. The two guards below are what stop that narrowing
    /// becoming a hole.
    func testFoodLogMetricsAreRegistered() {
        for key in FoodLogStore.Keys.charted {
            XCTAssertNotNil(MetricCatalog.metric(key: key, source: FoodLogStore.sourceId),
                            "\(key) is written by the food log but not registered in the catalog")
        }
    }

    /// A chartable key must also be in the CLEAR list, or deleting a day's last entry leaves its figure
    /// behind on the chart — the exact bug `Keys.all` exists to prevent.
    func testEveryChartedFoodKeyIsAlsoCleared() {
        for key in FoodLogStore.Keys.charted {
            XCTAssertTrue(FoodLogStore.Keys.all.contains(key),
                          "\(key) is charted but would survive a re-bank")
        }
    }

    /// And the un-charted remainder is pinned by NAME, so adding a new written key forces a deliberate
    /// decision about whether it is a quantity rather than letting it default to invisible.
    func testTheUnchartedFoodKeysAreExactlyTheKnownFlags() {
        let uncharted = Set(FoodLogStore.Keys.all).subtracting(FoodLogStore.Keys.charted)
        XCTAssertEqual(uncharted, [FoodLogStore.Keys.roughDay])
    }

    /// Hand-logged weigh-ins must be their own source, never colliding with Apple Health's weight series.
    func testWeightLogIsItsOwnSource() {
        XCTAssertNotEqual(WeightLogStore.sourceId, "apple-health")
        XCTAssertNotNil(MetricCatalog.metric(key: WeightLogStore.key, source: WeightLogStore.sourceId))
        XCTAssertNotNil(MetricCatalog.metric(key: "weight", source: "apple-health"),
                        "the Apple Health weight series must still resolve independently")
    }
}
