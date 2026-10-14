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
    @MainActor
    func testStartupPublishesOnlyResolvedTranscriptAndConcurrentLoadsJoin() async throws {
        let (store, coach) = try await fixture()
        let row = CoachMessageRow(id: UUID().uuidString, role: "user", text: "Yesterday",
            provider: "openAI", createdAt: midnight + hour, orderIndex: 0)
        try await store.replaceCoachMessages([row])
        _ = try await store.upsertSleepSessions([night()], deviceId: "my-whoop-noop")
        var published: [[String]] = []
        let observation = coach.$messages.sink { published.append($0.map(\.text)) }
        defer { observation.cancel() }
        XCTAssertFalse(coach.conversationReady)
        let now = Date(timeIntervalSince1970: Double(midnight + 12 * hour))
        async let first: Void = coach.resolveConversation(now: now)
        async let second: Void = coach.resolveConversation(now: now)
        _ = await (first, second)
        XCTAssertTrue(coach.conversationReady)
        XCTAssertFalse(coach.conversationLoadFailed)
        XCTAssertFalse(published.contains { $0.contains("Yesterday") }, "Never publish the retired candidate, even momentarily")
    }

    @MainActor
    func testClearBeforeStartupCannotRestoreOldRowsOrRestartEntry() async throws {
        let (store, coach) = try await fixture()
        try await store.replaceCoachMessages([CoachMessageRow(id: UUID().uuidString, role: "user",
            text: "Old", provider: "openAI", createdAt: midnight + hour, orderIndex: 0)])
        coach.clearConversation()
        await coach.resolveConversation(now: Date(timeIntervalSince1970: Double(midnight + 2 * hour)))
        XCTAssertTrue(coach.messages.isEmpty)
        XCTAssertTrue(coach.initialEntryResolved)
        await coach.resolveConversation(now: Date(timeIntervalSince1970: Double(midnight + 3 * hour)), reconsider: true, holdDisplay: false)
        XCTAssertTrue(coach.initialEntryResolved, "A data refresh must not create an unsolicited fresh brief after Clear")
    }

    @MainActor
    func testStartupReadsActiveRegistryNightBeforeReadSpineAdoption() async throws {
        let (store, coach) = try await fixture()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "whoop-repaired", brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [], status: .active, addedAt: midnight, lastSeenAt: midnight))
        try await store.replaceCoachMessages([CoachMessageRow(id: UUID().uuidString, role: "user",
            text: "Previous night", provider: "openAI", createdAt: midnight + hour, orderIndex: 0)])
        _ = try await store.upsertSleepSessions([night()], deviceId: "whoop-repaired-noop")
        await coach.resolveConversation(now: Date(timeIntervalSince1970: Double(midnight + 12 * hour)))
        XCTAssertTrue(coach.conversationReady)
        XCTAssertTrue(coach.messages.isEmpty, "The startup seed id must not hide the actual active strap's night")
    }

    @MainActor
    func testForegroundCheckKeepsResolvedTranscriptVisible() async throws {
        let (_, coach) = try await fixture()
        coach.messages = [ChatMessage(role: .user, text: "Still here", sentAt: midnight + hour)]
        let now = Date(timeIntervalSince1970: Double(midnight + 2 * hour))
        await coach.resolveConversation(now: now)
        var readiness: [Bool] = []
        let observation = coach.$conversationReady.sink { readiness.append($0) }
        defer { observation.cancel() }
        coach.reconcileConversationFromApp(now: now)
        await coach.resolveConversation(now: now, reconsider: true, holdDisplay: false)
        XCTAssertFalse(readiness.contains(false), "Foreground checks must not unmount the chat")
        XCTAssertEqual(coach.messages.first?.text, "Still here")
    }

}
