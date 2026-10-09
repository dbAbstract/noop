import XCTest
@testable import StrandAnalytics

final class CoachConversationBoundaryTests: XCTestCase {
    private let hour = 3_600

    func testAfterMidnightChatRetiresAfterTheNight() {
        XCTAssertTrue(CoachConversationBoundary.shouldRetire(lastMessage: hour, now: 12 * hour,
            sleepWindows: [(start: 2 * hour, end: 10 * hour)]))
    }

    func testCrossingMidnightWhileAwakeKeepsChat() {
        XCTAssertFalse(CoachConversationBoundary.shouldRetire(lastMessage: 23 * hour, now: 25 * hour,
            sleepWindows: []))
    }

    func testMorningConversationIsNotRetiredAgain() {
        XCTAssertFalse(CoachConversationBoundary.shouldRetire(lastMessage: 11 * hour, now: 12 * hour,
            sleepWindows: [(start: 2 * hour, end: 10 * hour)]))
    }

    func testNapAndFutureWakeDoNotRetireChat() {
        XCTAssertFalse(CoachConversationBoundary.shouldRetire(lastMessage: hour, now: 12 * hour,
            sleepWindows: [(start: 2 * hour, end: 3 * hour), (start: 8 * hour, end: 16 * hour)]))
    }

    func testFutureSessionCannotHideACompletedNightFromAnotherSource() {
        XCTAssertTrue(CoachConversationBoundary.shouldRetire(lastMessage: hour, now: 12 * hour,
            sleepWindows: [(start: 2 * hour, end: 10 * hour), (start: 8 * hour, end: 16 * hour)]))
    }

    func testDuplicateSleepSourcesCannotTurnANapIntoANight() {
        XCTAssertFalse(CoachConversationBoundary.shouldRetire(lastMessage: hour, now: 12 * hour,
            sleepWindows: [(start: 2 * hour, end: 4 * hour), (start: 2 * hour, end: 4 * hour)]))
    }

    func testMissingSleepUsesLongInactivityRatherThanMidnight() {
        XCTAssertFalse(CoachConversationBoundary.shouldRetire(lastMessage: hour, now: 12 * hour,
            sleepWindows: []))
        XCTAssertTrue(CoachConversationBoundary.shouldRetire(lastMessage: hour, now: 37 * hour,
            sleepWindows: []))
    }

    func testEmptyChatAndBackwardsClockDoNotRetire() {
        XCTAssertFalse(CoachConversationBoundary.shouldRetire(lastMessage: nil, now: 12 * hour,
            sleepWindows: []))
        XCTAssertFalse(CoachConversationBoundary.shouldRetire(lastMessage: 12 * hour, now: hour,
            sleepWindows: [(start: 2 * hour, end: 10 * hour)]))
    }
}
