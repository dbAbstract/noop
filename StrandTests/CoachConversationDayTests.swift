import XCTest
import WhoopStore
@testable import Strand

final class CoachConversationDayTests: XCTestCase {
    private let hour = 3_600
    private let midnight = 1_791_504_000

    @MainActor
    private func fixture() async throws -> (WhoopStore, AICoachEngine) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        return (store, AICoachEngine(repo: repo))
    }

    private func night(dayOffset: Int = 0) -> CachedSleepSession {
        let base = midnight + dayOffset * 24 * hour
        return CachedSleepSession(startTs: base + 2 * hour, endTs: base + 10 * hour,
            efficiency: 0.9, restingHr: 52, avgHrv: 70, stagesJSON: nil, stagingSparse: true)
    }

    @MainActor
    func testRestoredAfterMidnightTranscriptIsRetiredAfterWaking() async throws {
        let (store, coach) = try await fixture()
        let row = CoachMessageRow(id: UUID().uuidString, role: "user", text: "Late dinner",
            provider: "openAI", createdAt: midnight + hour, orderIndex: 0)
        try await store.replaceCoachMessages([row])
        _ = try await store.upsertSleepSessions([night()], deviceId: "my-whoop-noop")
        await coach.loadPersistedMessagesIfNeeded(now: Date(timeIntervalSince1970: Double(midnight + 12 * hour)))
        XCTAssertTrue(coach.messages.isEmpty)
        let persisted = try await store.coachMessages()
        XCTAssertEqual(persisted, [row], "Opening Coach does not delete stored history")
    }

    @MainActor
    func testLateSyncRetiresLiveChatDespiteOlderImportedNight() async throws {
        let (store, coach) = try await fixture()
        coach.messages = [ChatMessage(role: .user, text: "Late dinner", sentAt: midnight + hour)]
        _ = try await store.upsertSleepSessions([night(dayOffset: -1)], deviceId: "my-whoop")
        let now = Date(timeIntervalSince1970: Double(midnight + 12 * hour))
        await coach.retireStaleConversationIfNeeded(now: now)
        XCTAssertEqual(coach.messages.count, 1, "Yesterday's wake does not end today's chat")
        _ = try await store.upsertSleepSessions([night()], deviceId: "my-whoop-noop")
        await coach.retireStaleConversationIfNeeded(now: now)
        XCTAssertTrue(coach.messages.isEmpty)
        coach.messages = [ChatMessage(role: .user, text: "Breakfast", sentAt: midnight + 11 * hour)]
        await coach.retireStaleConversationIfNeeded(now: now)
        XCTAssertEqual(coach.messages.count, 1, "A new morning chat survives further refreshes")
    }

    @MainActor
    func testRefreshCannotRetireAnInFlightReply() async throws {
        let (store, coach) = try await fixture()
        coach.messages = [ChatMessage(role: .user, text: "Late dinner", sentAt: midnight + hour)]
        _ = try await store.upsertSleepSessions([night()], deviceId: "my-whoop-noop")
        coach.sending = true
        await coach.retireStaleConversationIfNeeded(now: Date(timeIntervalSince1970: Double(midnight + 12 * hour)))
        XCTAssertEqual(coach.messages.count, 1)
    }
}
