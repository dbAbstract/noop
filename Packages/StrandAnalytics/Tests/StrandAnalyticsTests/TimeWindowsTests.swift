import XCTest
@testable import StrandAnalytics

/// Merging exists so a second covered by two workouts is never counted twice when subtracting their steps
/// from the NEAT total. Over-subtracting would silently deflate the eating budget.
final class TimeWindowsTests: XCTestCase {

    private func merge(_ w: [(Int, Int)]) -> [(start: Int, end: Int)] {
        TimeWindows.merged(w.map { (start: $0.0, end: $0.1) })
    }

    func testDisjointWindowsSurviveInOrder() {
        let out = merge([(300, 400), (100, 200)])
        XCTAssertEqual(out.map(\.start), [100, 300])
        XCTAssertEqual(out.map(\.end), [200, 400])
    }

    func testOverlappingWindowsBecomeOne() {
        let out = merge([(100, 300), (200, 400)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 100)
        XCTAssertEqual(out[0].end, 400)
    }

    /// A warm-up fully inside the main session must not extend or split it.
    func testFullyContainedWindowIsAbsorbed() {
        let out = merge([(100, 500), (200, 300)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 100)
        XCTAssertEqual(out[0].end, 500)
    }

    /// Touching windows merge: the boundary second belongs to one of them, and keeping them apart only
    /// creates a chance to count it twice downstream.
    func testTouchingWindowsMerge() {
        let out = merge([(100, 200), (200, 300)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].end, 300)
    }

    func testAdjacentButNotTouchingStaysSeparate() {
        XCTAssertEqual(merge([(100, 200), (201, 300)]).count, 2)
    }

    /// A zero-length or inverted window has no steps to attribute; repairing it would be inventing data.
    func testInvalidWindowsAreDropped() {
        XCTAssertTrue(merge([(100, 100)]).isEmpty)
        XCTAssertTrue(merge([(300, 100)]).isEmpty)
        XCTAssertEqual(merge([(100, 100), (200, 300)]).count, 1)
    }

    func testEmptyInput() {
        XCTAssertTrue(merge([]).isEmpty)
    }

    /// The property that matters: merged coverage never exceeds the union, however the inputs overlap.
    func testCoveredSecondsCountsEachSecondOnce() {
        // Two 200s windows overlapping by 100s cover 300s, not 400s.
        XCTAssertEqual(TimeWindows.coveredSeconds([(start: 0, end: 200), (start: 100, end: 300)]), 300)
        // Three identical windows still cover one window's worth.
        XCTAssertEqual(TimeWindows.coveredSeconds([(start: 0, end: 100), (start: 0, end: 100),
                                                   (start: 0, end: 100)]), 100)
    }

    func testChainOfOverlapsCollapsesToOne() {
        let out = merge([(0, 100), (50, 150), (140, 250), (240, 300)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[0].end, 300)
    }
}
