import XCTest
@testable import Strand

/// The UIKit Coach transcript shows the same rows as the SwiftUI one, redraws only what changed, and knows where
/// the end of the conversation is (`CoachTranscriptPlan`).
@MainActor
final class CoachTranscriptPlanTests: XCTestCase {

    private func msg(_ role: ChatMessage.Role, _ text: String, at sentAt: Int, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text, sentAt: sentAt)
    }

    func testTurnsInOrderThenTheTypingLineWhileAReplyIsOnItsWay() {
        let a = msg(.user, "hi", at: 100), b = msg(.assistant, "hello", at: 110)
        let rows = CoachTranscriptRow.Model.rows([a, b], streamingId: nil, sending: true)
        let update = CoachTranscriptPlan.update(previous: [:], rows: rows, typing: true)
        XCTAssertEqual(update.items, [.message(a.id), .message(b.id), .typing])
        XCTAssertEqual(update.changed, [], "rows that were not on screen are inserted, not reconfigured")
        XCTAssertEqual(CoachTranscriptPlan.update(previous: [:], rows: rows, typing: false).items.last, .message(b.id))
    }

    /// Only a turn whose content changed is redrawn: here the streamed placeholder receiving its final text.
    func testOnlyChangedTurnsAreReconfigured() {
        let user = msg(.user, "log my lunch", at: 100)
        let id = UUID()
        let placeholder = msg(.assistant, "", at: 101, id: id)
        let before = CoachTranscriptRow.Model.rows([user, placeholder], streamingId: id, sending: true)
        XCTAssertTrue(before[1].streaming, "the empty reply arriving now is drawn from the stream")

        let final = msg(.assistant, "Here's what I've got:", at: 101, id: id)
        let after = CoachTranscriptRow.Model.rows([user, final], streamingId: nil, sending: true)
        XCTAssertFalse(after[1].streaming)
        let update = CoachTranscriptPlan.update(previous: CoachTranscriptPlan.byId(before), rows: after, typing: false)
        XCTAssertEqual(update.changed, [.message(id)])
    }

    /// Each row carries the turn before it, so removing or retiming that turn redraws the divider below it.
    func testTheRowCarriesThePreviousTurnForItsTimeDivider() {
        let a = msg(.user, "a", at: 100), b = msg(.assistant, "b", at: 50_000)
        let rows = CoachTranscriptRow.Model.rows([a, b], streamingId: nil, sending: false)
        XCTAssertNil(rows[0].previousSentAt)
        XCTAssertEqual(rows[1].previousSentAt, 100)
        let without = CoachTranscriptRow.Model.rows([b], streamingId: nil, sending: false)
        let update = CoachTranscriptPlan.update(previous: CoachTranscriptPlan.byId(rows), rows: without, typing: false)
        XCTAssertEqual(update.changed, [.message(b.id)])
    }

    /// A repeated id would trap the diffable snapshot; the first occurrence wins.
    func testARepeatedTurnIdIsShownOnce() {
        let id = UUID()
        let rows = CoachTranscriptRow.Model.rows([msg(.user, "one", at: 1, id: id), msg(.user, "two", at: 2, id: id)],
                                                 streamingId: nil, sending: false)
        XCTAssertEqual(CoachTranscriptPlan.update(previous: [:], rows: rows, typing: false).items, [.message(id)])
        XCTAssertEqual(CoachTranscriptPlan.byId(rows)[id]?.message.text, "one")
    }

    func testTheEndOfTheTranscript() {
        // 1,000 pt of content in a 400 pt viewport, 24 pt below it: the end is at 624.
        XCTAssertEqual(CoachTranscriptPlan.endOffset(contentHeight: 1_000, viewportHeight: 400, topInset: 90,
                                                     bottomInset: 24), 624)
        // Shorter than the viewport: the top, under the header.
        XCTAssertEqual(CoachTranscriptPlan.endOffset(contentHeight: 200, viewportHeight: 400, topInset: 90,
                                                     bottomInset: 0), -90)
        XCTAssertTrue(CoachTranscriptPlan.isAtEnd(offsetY: 624, viewportHeight: 400, contentHeight: 1_000, bottomInset: 24))
        XCTAssertTrue(CoachTranscriptPlan.isAtEnd(offsetY: 505, viewportHeight: 400, contentHeight: 1_000, bottomInset: 24),
                      "within the 120 pt tolerance the ↓ button stays hidden")
        XCTAssertFalse(CoachTranscriptPlan.isAtEnd(offsetY: 500, viewportHeight: 400, contentHeight: 1_000, bottomInset: 24))
        XCTAssertFalse(CoachTranscriptPlan.isAtEnd(offsetY: 560, viewportHeight: 400, contentHeight: 1_000, bottomInset: 24,
                                                   tolerance: 48), "the tighter pin tolerance lets a reader scroll up")
    }
}
