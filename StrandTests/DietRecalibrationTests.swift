import XCTest
import StrandAnalytics
@testable import Strand

/// The recalibration loop, driven by synthetic histories.
///
/// These matter more than usual because the proposal CANNOT render for roughly three weeks after a goal
/// is set — the gates see to that — so there is no way to eyeball it before it reaches a real user. Until
/// then these tests are the only thing standing between a correct proposal and a confidently wrong one.
///
/// Built on `DietTrendReading` directly rather than through the store: the arithmetic under test is the
/// decision, not the plumbing that fetches rows.
final class DietRecalibrationTests: XCTestCase {

    /// A reading that satisfies `hasVerdict` — a fitted trend whose slope clears its own standard error.
    private func reading(expectedKgPerWeek: Double, actualKgPerWeek: Double,
                         deficit: Double, certain: Bool = true) -> DietTrendReading {
        let slopePerDay = actualKgPerWeek / 7
        // Low scatter makes the slope distinguishable; high scatter makes it indistinguishable, which is
        // how the "no verdict" cases below are built without hand-faking the flag.
        let noise = certain ? 0.02 : 0.9
        let readings = (0..<40).map { i in
            WeightReading(dayIndex: i,
                          kg: 73 + slopePerDay * Double(i) + (i % 2 == 0 ? noise : -noise))
        }
        let fit = WeightTrend.fit(readings)
        return DietTrendReading(fit: fit,
                                targetDeficitKcal: deficit,
                                expectedKgPerWeek: expectedKgPerWeek,
                                daysToDetect: nil,
                                adaptive: nil,
                                intakeDays: 30,
                                windowDays: 42)
    }

    @MainActor private var repo: Repository { Repository(deviceId: "test") }

    // MARK: - When a proposal is earned

    /// Losing slower than planned means real expenditure is BELOW the estimate, so the deficit must grow
    /// to hold the same pace. Getting this sign backwards is the classic error in this algorithm.
    @MainActor func testLosingSlowerProposesABiggerDeficit() throws {
        let r = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.05, deficit: 169)
        XCTAssertTrue(r.hasVerdict)
        let p = try XCTUnwrap(repo.proposedDeficit(from: r))
        XCTAssertGreaterThan(p, 169)
        // shortfall 0.10 kg/wk × 7700 / 7 × 0.5 damping ≈ +55
        XCTAssertEqual(p, 224, accuracy: 3)
    }

    func testLosingFasterProposesASmallerDeficit() throws {
        let r = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.45, deficit: 400)
        let p = try XCTUnwrap(MainActor.assumeIsolated { repo.proposedDeficit(from: r) })
        XCTAssertLessThan(p, 400)
    }

    /// Damping is what stops the target oscillating on noisy weight data: the proposal moves half the way
    /// the gap suggests, so an unlucky fortnight cannot swing it.
    @MainActor func testProposalIsDampedNotFullyCorrected() throws {
        // A near-stall rather than an exact stall: a slope of precisely zero is BY DEFINITION
        // indistinguishable from zero, so the model would correctly refuse to propose and the damping
        // would never be exercised. The first draft of this test asked for exactly that and failed —
        // the model was right and the premise was not.
        let r = reading(expectedKgPerWeek: -0.20, actualKgPerWeek: -0.02, deficit: 200)
        XCTAssertTrue(r.hasVerdict)
        let p = try XCTUnwrap(repo.proposedDeficit(from: r))
        let gap = 0.18                                   // expected 0.20 lost, actual 0.02
        let fullCorrection = 200 + (gap * 7700 / 7)
        XCTAssertLessThan(p, fullCorrection)
        XCTAssertEqual(p - 200, (fullCorrection - 200) / 2, accuracy: 3)
    }

    // MARK: - When it is NOT earned — the half that matters most

    /// No proposal without a measurable trend. A proposal made from noise is worse than none, because
    /// once it is on screen the user cannot tell which kind it is.
    @MainActor func testNoProposalWithoutAVerdict() {
        let r = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.05, deficit: 169, certain: false)
        XCTAssertFalse(r.hasVerdict, "high scatter must not produce a verdict")
        XCTAssertNil(repo.proposedDeficit(from: r))
    }

    @MainActor func testNoProposalWithoutAGoal() {
        var r = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.05, deficit: 169)
        r = DietTrendReading(fit: r.fit, targetDeficitKcal: nil, expectedKgPerWeek: nil,
                             daysToDetect: nil, adaptive: nil, intakeDays: 30, windowDays: 42)
        XCTAssertNil(repo.proposedDeficit(from: r))
    }

    @MainActor func testNoProposalWithoutAFit() {
        let r = DietTrendReading(fit: nil, targetDeficitKcal: 169, expectedKgPerWeek: -0.15,
                                 daysToDetect: nil, adaptive: nil, intakeDays: 2, windowDays: 42)
        XCTAssertFalse(r.hasVerdict)
        XCTAssertNil(repo.proposedDeficit(from: r))
    }

    /// On plan is not an occasion to propose anything. Nudging a target that is working would be change
    /// for its own sake, and it trains the user to ignore the card.
    @MainActor func testNoProposalWhenOnPlan() {
        let r = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.15, deficit: 169)
        XCTAssertTrue(r.hasVerdict)
        XCTAssertNil(repo.proposedDeficit(from: r))
    }

    /// A change smaller than the noise that produced it is theatre. The floor keeps the card quiet rather
    /// than shuffling the target by a few kcal every time the window advances.
    @MainActor func testTinyAdjustmentsAreSuppressed() {
        let r = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.14, deficit: 169)
        XCTAssertTrue(r.hasVerdict)
        XCTAssertNil(repo.proposedDeficit(from: r), "a sub-25 kcal move is inside the noise")
    }

    // MARK: - Shortfall sign

    /// `shortfallKgPerWeek` is positive when BEHIND plan. Both rates are negative while losing, which is
    /// exactly where a sign error hides.
    @MainActor func testShortfallIsPositiveWhenBehind() throws {
        let behind = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.05, deficit: 169)
        XCTAssertEqual(try XCTUnwrap(behind.shortfallKgPerWeek), 0.10, accuracy: 0.01)

        let ahead = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.30, deficit: 169)
        XCTAssertLessThan(try XCTUnwrap(ahead.shortfallKgPerWeek), 0)
    }

    /// Unavailable rather than wrong when the measurement cannot support it.
    @MainActor func testShortfallIsNilWithoutAVerdict() {
        let r = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: -0.05, deficit: 169, certain: false)
        XCTAssertNil(r.shortfallKgPerWeek)
    }

    // MARK: - Clamps

    /// No single window may walk the target somewhere absurd, however extreme the measured gap.
    @MainActor func testProposalStaysInsideTheDeficitClamps() throws {
        let wayBehind = reading(expectedKgPerWeek: -0.15, actualKgPerWeek: 2.0, deficit: 700)
        let high = try XCTUnwrap(repo.proposedDeficit(from: wayBehind))
        XCTAssertLessThanOrEqual(high, CalorieTarget.maxAdjustedDeficitKcal)

        let wayAhead = reading(expectedKgPerWeek: -0.10, actualKgPerWeek: -2.0, deficit: 200)
        let low = try XCTUnwrap(repo.proposedDeficit(from: wayAhead))
        XCTAssertGreaterThanOrEqual(low, CalorieTarget.minAdjustedDeficitKcal)
    }
}
