import XCTest
@testable import StrandAnalytics

final class ChatTimeSeparatorTests: XCTestCase {

    // MARK: - The gap decision

    func testFirstMessageAlwaysGetsASeparator() {
        XCTAssertTrue(ChatTimeSeparator.needsSeparator(previousSentAt: nil, sentAt: 1_700_000_000))
    }

    func testGapBelowThresholdGetsNoSeparator() {
        let base = 1_700_000_000
        // A slow reasoning reply plus a slow read is still one exchange.
        XCTAssertFalse(ChatTimeSeparator.needsSeparator(previousSentAt: base,
                                                        sentAt: base + 14 * 60 + 59))
    }

    func testGapAtThresholdGetsASeparator() {
        let base = 1_700_000_000
        XCTAssertTrue(ChatTimeSeparator.needsSeparator(previousSentAt: base,
                                                       sentAt: base + ChatTimeSeparator.minimumGapSeconds))
    }

    func testMealSizedGapGetsASeparator() {
        let base = 1_700_000_000
        XCTAssertTrue(ChatTimeSeparator.needsSeparator(previousSentAt: base, sentAt: base + 5 * 3600))
    }

    /// Two streamed turns can land in the same second. A divider there would split an exchange that never
    /// paused, so an equal stamp is not a gap.
    func testEqualTimestampsGetNoSeparator() {
        XCTAssertFalse(ChatTimeSeparator.needsSeparator(previousSentAt: 1_700_000_000,
                                                        sentAt: 1_700_000_000))
    }

    /// Out of order is not a gap either, however large. The sign carries the meaning: a negative delta is
    /// a transcript problem, and dividing on its magnitude would scatter dividers through the history.
    func testMessagesOutOfOrderGetNoSeparator() {
        let base = 1_700_000_000
        XCTAssertFalse(ChatTimeSeparator.needsSeparator(previousSentAt: base + 5 * 3600, sentAt: base))
    }

    /// The property the renderer depends on: walking a sorted transcript never yields two dividers in a
    /// row, because a message that follows a divider becomes the `previous` of the next decision.
    func testNoTwoConsecutiveSeparatorsAcrossATranscript() {
        let base = 1_700_000_000
        let stamps = [base, base, base + 60, base + 6 * 3600, base + 6 * 3600 + 30,
                      base + 12 * 3600]
        var previous: Int?
        var lastWasSeparator = false
        for stamp in stamps {
            let separated = ChatTimeSeparator.needsSeparator(previousSentAt: previous, sentAt: stamp)
            XCTAssertFalse(separated && lastWasSeparator,
                           "two dividers in a row at \(stamp - base)s")
            lastWasSeparator = separated
            previous = stamp
        }
    }

    // MARK: - Day bucketing

    func testSameDayIsToday() {
        XCTAssertEqual(ChatTimeSeparator.dayBucket(messageEpochDay: 20_000, todayEpochDay: 20_000),
                       .today)
    }

    func testPreviousDayIsYesterday() {
        XCTAssertEqual(ChatTimeSeparator.dayBucket(messageEpochDay: 19_999, todayEpochDay: 20_000),
                       .yesterday)
    }

    func testTwoDaysBackIsEarlier() {
        XCTAssertEqual(ChatTimeSeparator.dayBucket(messageEpochDay: 19_998, todayEpochDay: 20_000),
                       .earlier)
    }

    /// A clock that moved backwards — a flight west, a manual change — must not produce "tomorrow".
    func testFutureDayBucketsAsToday() {
        XCTAssertEqual(ChatTimeSeparator.dayBucket(messageEpochDay: 20_001, todayEpochDay: 20_000),
                       .today)
    }
}
