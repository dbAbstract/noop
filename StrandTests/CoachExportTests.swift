import XCTest
@testable import Strand

final class CoachExportTests: XCTestCase {
    func testMarkdownCacheReusesUnchangedRepliesAndSeparatesRevisions() {
        let cache = CoachMarkdownCache()
        let id = UUID()
        let first = cache.entry(for: "**Original** reply", messageId: id)
        XCTAssertTrue(first === cache.entry(for: "**Original** reply", messageId: id))
        let revised = cache.entry(for: "**Revised** reply", messageId: id)
        XCTAssertFalse(first === revised)
        XCTAssertNotEqual(first.content, revised.content)
        XCTAssertTrue(revised === cache.entry(for: "**Revised** reply", messageId: id))
        let otherId = UUID()
        let other = cache.entry(for: "Another reply", messageId: otherId)
        for revision in 0..<100 {
            _ = cache.entry(for: "Streaming revision \(revision)", messageId: id)
        }
        XCTAssertTrue(other === cache.entry(for: "Another reply", messageId: otherId),
            "Streaming revisions must not fill the cache with obsolete versions")
    }

    @MainActor
    private func engine() async throws -> AICoachEngine {
        let coach = AICoachEngine(repo: Repository(deviceId: "test-export"))
        let proposal = FoodProposal(kind: .unresolved(handle: "o12"),
            dayKey: "2026-10-08", dayLabel: "Yesterday")
        coach.messages = [ChatMessage(role: .assistant, text: "Here is the food", proposals: [proposal])]
        return coach
    }

    @MainActor
    func testExportUsesLatestProposalStateAndKeepsEarlierSnapshotIntact() async throws {
        let coach = try await engine()
        let before = coach.conversationExport()
        let message = try XCTUnwrap(coach.messages.first)
        let proposal = try XCTUnwrap(message.proposals.first)
        coach.updateProposalState(messageId: message.id, proposalId: proposal.id, to: .dismissed)
        let after = coach.conversationExport()
        let beforeURL = try await before.file()
        let afterURL = try await after.file()
        let beforeJSON = try String(contentsOf: beforeURL, encoding: .utf8)
        let afterJSON = try String(contentsOf: afterURL, encoding: .utf8)
        XCTAssertTrue(beforeJSON.contains("\"state\" : \"pending\""))
        XCTAssertTrue(afterJSON.contains("\"state\" : \"dismissed\""))
        XCTAssertNotEqual(beforeURL, afterURL)
        XCTAssertEqual(try String(contentsOf: beforeURL, encoding: .utf8), beforeJSON)
        XCTAssertEqual(beforeURL.pathExtension, "json")
    }

    @MainActor
    func testConcurrentExportsHaveSeparateFilesAndValidPayloads() async throws {
        let coach = try await engine()
        let snapshot = coach.conversationExport()
        async let first = snapshot.file()
        async let second = snapshot.file()
        let (a, b) = try await (first, second)
        XCTAssertNotEqual(a, b)
        for url in [a, b] {
            let data = try Data(contentsOf: url)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["messageCount"] as? Int, 1)
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["text"] as? String, "Here is the food")
        }
    }
}
