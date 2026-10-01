import XCTest
@testable import StrandAnalytics

/// The trend maths, and specifically the thing it exists to prevent: calling a change real when it is
/// water. A slope without its uncertainty cannot be told apart from noise, and at a small deficit the
/// expected weekly change is SMALLER than ordinary daily fluctuation — so these pin that the model knows
/// when it cannot answer, not just what it answers.
final class WeightTrendTests: XCTestCase {

    /// A clean linear series: `start` kg losing `kgPerDay`, one reading a day.
    private func series(days: Int, start: Double, kgPerDay: Double,
                        noise: [Double] = []) -> [WeightReading] {
        (0..<days).map { i in
            let n = noise.isEmpty ? 0 : noise[i % noise.count]
            return WeightReading(dayIndex: i, kg: start + kgPerDay * Double(i) + n)
        }
    }

    // MARK: - Regression

    func testSlopeRecoversAKnownRate() throws {
        let fit = try XCTUnwrap(WeightTrend.fit(series(days: 30, start: 73, kgPerDay: -0.02)))
        XCTAssertEqual(fit.slopeKgPerDay, -0.02, accuracy: 1e-9)
        XCTAssertEqual(fit.slopeKgPerWeek, -0.14, accuracy: 1e-9)
        XCTAssertEqual(fit.dayCount, 30)
        XCTAssertEqual(fit.spanDays, 30)
    }

    /// A perfect line has no residual, so the slope is certain and trivially distinguishable from zero.
    func testNoiselessSeriesHasZeroScatter() throws {
        let fit = try XCTUnwrap(WeightTrend.fit(series(days: 30, start: 73, kgPerDay: -0.02)))
        XCTAssertEqual(fit.scatterKg, 0, accuracy: 1e-9)
        XCTAssertEqual(fit.standardError, 0, accuracy: 1e-9)
    }

    /// Two points fit a line EXACTLY, leaving no residual — the standard error would come out zero and
    /// claim a certainty it has not earned. Three is the minimum that can disagree with itself.
    func testFewerThanThreeDistinctDaysRefusesToFit() {
        XCTAssertNil(WeightTrend.fit([]))
        XCTAssertNil(WeightTrend.fit([WeightReading(dayIndex: 0, kg: 73)]))
        XCTAssertNil(WeightTrend.fit([WeightReading(dayIndex: 0, kg: 73),
                                      WeightReading(dayIndex: 1, kg: 72.9)]))
    }

    /// Several readings on one morning are ONE day of evidence about a trend. Counting both would shrink
    /// the standard error as though the scale had bought real information.
    func testSameDayReadingsAreAveragedNotCounted() throws {
        let doubled = [
            WeightReading(dayIndex: 0, kg: 73.0), WeightReading(dayIndex: 0, kg: 73.4),
            WeightReading(dayIndex: 1, kg: 72.8), WeightReading(dayIndex: 1, kg: 73.0),
            WeightReading(dayIndex: 2, kg: 72.6), WeightReading(dayIndex: 2, kg: 73.0),
        ]
        let fit = try XCTUnwrap(WeightTrend.fit(doubled))
        XCTAssertEqual(fit.dayCount, 3, "six readings over three days is three days of evidence")
        // The averages are 73.2, 72.9, 72.8 → slope ≈ -0.2 kg/day.
        XCTAssertEqual(fit.slopeKgPerDay, -0.2, accuracy: 0.01)
    }

    func testAllReadingsOnOneDayCannotFit() {
        XCTAssertNil(WeightTrend.fit([WeightReading(dayIndex: 5, kg: 73),
                                      WeightReading(dayIndex: 5, kg: 72),
                                      WeightReading(dayIndex: 5, kg: 74)]))
    }

    func testNonFiniteAndNonPositiveReadingsAreDropped() throws {
        var s = series(days: 10, start: 73, kgPerDay: -0.02)
        s.append(WeightReading(dayIndex: 20, kg: .nan))
        s.append(WeightReading(dayIndex: 21, kg: 0))
        s.append(WeightReading(dayIndex: 22, kg: -5))
        let fit = try XCTUnwrap(WeightTrend.fit(s))
        XCTAssertEqual(fit.dayCount, 10, "garbage readings must not become days of evidence")
    }

    // MARK: - Distinguishable from zero — the point of the file

    /// A real, steady loss with modest noise is detectable over a month.
    func testClearLossIsDistinguishable() throws {
        let fit = try XCTUnwrap(WeightTrend.fit(
            series(days: 30, start: 73, kgPerDay: -0.05, noise: [0.3, -0.2, 0.1, -0.3, 0.2])))
        XCTAssertTrue(fit.isDistinguishableFromZero)
        XCTAssertLessThan(fit.slopeKgPerWeek, 0)
    }

    /// Pure noise around a flat weight must NOT read as a trend, in either direction. This is the false
    /// positive the whole approach exists to prevent.
    func testFlatWeightWithNoiseIsNotATrend() throws {
        let fit = try XCTUnwrap(WeightTrend.fit(
            series(days: 21, start: 73, kgPerDay: 0, noise: [0.4, -0.5, 0.2, -0.3, 0.5, -0.4, 0.1])))
        XCTAssertFalse(fit.isDistinguishableFromZero,
                       "water fluctuation around a flat weight is not weight loss")
    }

    /// THE CASE THIS MODEL WAS BUILT FOR. A 150 kcal deficit predicts ~0.0195 kg/day. Over two weeks,
    /// with everyday scatter, that is NOT separable from noise — which is exactly why a weekly verdict
    /// fails at a small deficit and works at a large one.
    func testSmallDeficitIsNotDetectableInATwoWeekWindow() throws {
        let fit = try XCTUnwrap(WeightTrend.fit(
            series(days: 14, start: 73, kgPerDay: -0.0195, noise: [0.5, -0.4, 0.3, -0.5, 0.4, -0.3, 0.2])))
        XCTAssertFalse(fit.isDistinguishableFromZero)
    }

    /// The same deficit over a long enough window IS separable — the window, not the deficit, was the
    /// limiting factor.
    func testSameSmallDeficitBecomesDetectableOverALongWindow() throws {
        let fit = try XCTUnwrap(WeightTrend.fit(
            series(days: 70, start: 73, kgPerDay: -0.0195, noise: [0.5, -0.4, 0.3, -0.5, 0.4, -0.3, 0.2])))
        XCTAssertTrue(fit.isDistinguishableFromZero)
    }

    // MARK: - Detectability

    func testExpectedRateIsNegativeForADeficit() {
        XCTAssertEqual(WeightTrend.expectedRateKgPerDay(deficitKcal: 7700), -1.0, accuracy: 1e-9)
        XCTAssertEqual(WeightTrend.expectedRateKgPerDay(deficitKcal: 169), -0.02195, accuracy: 1e-5)
    }

    /// A bigger deficit needs fewer readings — the relationship the adaptive window is built on.
    func testABiggerDeficitNeedsAShorterWindow() throws {
        let scatter = 0.6
        let big = try XCTUnwrap(WeightTrend.requiredDailyReadings(deficitKcal: 500, scatterKg: scatter))
        let small = try XCTUnwrap(WeightTrend.requiredDailyReadings(deficitKcal: 150, scatterKg: scatter))
        XCTAssertLessThan(big, small)
        // Sanity: the orders of magnitude the design assumed — a fortnight-ish vs over a month.
        XCTAssertLessThan(big, 25)
        XCTAssertGreaterThan(small, 28)
    }

    /// A steadier scale shortens the wait — the window is sized from the PERSON's scatter, not a
    /// textbook figure, which is what makes the answer theirs.
    func testLessScatterNeedsFewerReadings() throws {
        let noisy = try XCTUnwrap(WeightTrend.requiredDailyReadings(deficitKcal: 250, scatterKg: 0.9))
        let steady = try XCTUnwrap(WeightTrend.requiredDailyReadings(deficitKcal: 250, scatterKg: 0.3))
        XCTAssertLessThan(steady, noisy)
    }

    /// Unanswerable rather than a guess: no deficit to detect, or no scatter to clear.
    func testRequiredReadingsIsNilWhenTheQuestionCannotBeAsked() {
        XCTAssertNil(WeightTrend.requiredDailyReadings(deficitKcal: 0, scatterKg: 0.5))
        XCTAssertNil(WeightTrend.requiredDailyReadings(deficitKcal: 200, scatterKg: 0))
    }

    /// A deficit so small it would not settle within the cap gets "not on any timescale worth planning
    /// around", not a number pretending otherwise.
    func testAnUndetectablyTinyDeficitReturnsNil() {
        XCTAssertNil(WeightTrend.requiredDailyReadings(deficitKcal: 5, scatterKg: 0.8, maxDays: 120))
    }

    // MARK: - Calendar wait

    /// Already enough evidence → nothing to wait for.
    func testDaysToDetectIsZeroOnceTheTrendIsClear() throws {
        let fit = try XCTUnwrap(WeightTrend.fit(
            series(days: 45, start: 73, kgPerDay: -0.05, noise: [0.2, -0.1, 0.15])))
        XCTAssertEqual(WeightTrend.daysToDetect(fit: fit, deficitKcal: 385), 0)
    }

    /// Weighing less often stretches the CALENDAR wait, because the regression is fed by readings and
    /// not by dates. Someone weighing every other day waits roughly twice as long.
    func testSparseWeighInsStretchTheWait() throws {
        let daily = (0..<14).map { WeightReading(dayIndex: $0, kg: 73 - 0.0195 * Double($0) + (($0 % 2 == 0) ? 0.4 : -0.4)) }
        let everyOther = (0..<7).map { WeightReading(dayIndex: $0 * 2, kg: 73 - 0.039 * Double($0) + (($0 % 2 == 0) ? 0.4 : -0.4)) }
        let dailyWait = try XCTUnwrap(WeightTrend.daysToDetect(fit: WeightTrend.fit(daily), deficitKcal: 150))
        let sparseWait = try XCTUnwrap(WeightTrend.daysToDetect(fit: WeightTrend.fit(everyOther), deficitKcal: 150))
        XCTAssertGreaterThan(sparseWait, dailyWait)
    }

    func testDaysToDetectIsNilWithoutAFit() {
        XCTAssertNil(WeightTrend.daysToDetect(fit: nil, deficitKcal: 169))
    }

    // MARK: - Smoothing

    func testSmoothedStartsAtTheFirstReadingAndFollowsTheSeries() {
        let raw = series(days: 20, start: 73, kgPerDay: -0.05)
        let smooth = WeightTrend.smoothed(raw)
        XCTAssertEqual(smooth.count, raw.count)
        XCTAssertEqual(smooth.first?.kg ?? .nan, 73, accuracy: 1e-9)
        // Lags a falling series, but tracks it down.
        XCTAssertLessThan(smooth.last!.kg, 73)
        XCTAssertGreaterThan(smooth.last!.kg, raw.last!.kg)
    }

    /// The smoothing's job: a single salty day must barely move the line.
    func testOneSpikeBarelyMovesTheTrend() {
        var raw = series(days: 20, start: 73, kgPerDay: 0)
        raw[10] = WeightReading(dayIndex: 10, kg: 75)   // +2 kg of water for a day
        let smooth = WeightTrend.smoothed(raw)
        XCTAssertLessThan(smooth[10].kg, 73.3, "a one-day spike must not drag the trend with it")
    }

    /// Time-aware, not index-aware: after a gap the next reading carries proportionally more weight. An
    /// index-based EWMA would let someone weighing twice a week drift far behind reality while looking
    /// perfectly smooth.
    func testGapsCarryMoreWeightThanConsecutiveDays() {
        let consecutive = WeightTrend.smoothed([
            WeightReading(dayIndex: 0, kg: 73), WeightReading(dayIndex: 1, kg: 70),
        ])
        let afterGap = WeightTrend.smoothed([
            WeightReading(dayIndex: 0, kg: 73), WeightReading(dayIndex: 30, kg: 70),
        ])
        XCTAssertLessThan(afterGap[1].kg, consecutive[1].kg,
                          "a month's gap should move the trend further than one day's")
    }

    func testSmoothedHandlesEmptyAndSingleInputs() {
        XCTAssertTrue(WeightTrend.smoothed([]).isEmpty)
        XCTAssertEqual(WeightTrend.smoothed([WeightReading(dayIndex: 3, kg: 73)]).count, 1)
    }

    // MARK: - Shared constant

    func testKcalPerKgMatchesTheExpenditureEngine() {
        XCTAssertEqual(WeightTrend.kcalPerKg, AdaptiveExpenditureEngine.kcalPerKg)
    }
}
