import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

private final class CoachDietURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var text = ""
    nonisolated(unsafe) static var lastBody = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = request.httpBody {
            Self.lastBody = String(decoding: body, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            Self.lastBody = String(decoding: body, as: UTF8.self)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk: [String: Any] = ["choices": [["delta": ["content": Self.text]]]]
        let encoded = try! JSONSerialization.data(withJSONObject: chunk)
        let body = "data: " + String(data: encoded, encoding: .utf8)! + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class CoachDietTests: XCTestCase {
    @MainActor
    private func withEngine(_ body: (AICoachEngine, Repository) async throws -> Void) async throws {
        let keys = ["ai.provider", "ai.model", "ai.dataConsent", "ai.customConnected", "ai.customBaseURL",
                    "noop.coachEnabled", FoodLogStore.enabledKey, CoachDietReviewHistory.dateKey,
                    CoachDietReviewHistory.goalKey, CoachDietReviewHistory.weeksKey, AICoachEngine.systemPromptKey]
        let previous = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set(true, forKey: "noop.coachEnabled")
        UserDefaults.standard.set(true, forKey: FoodLogStore.enabledKey)
        UserDefaults.standard.removeObject(forKey: CoachDietReviewHistory.dateKey)
        UserDefaults.standard.removeObject(forKey: CoachDietReviewHistory.goalKey)
        UserDefaults.standard.removeObject(forKey: CoachDietReviewHistory.weeksKey)
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "coach-diet-wire-test")
        repo.setStoreForTesting(store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachDietURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = AICoachEngine(repo: repo, session: session)
        engine.provider = .custom
        engine.model = "test-model"
        engine.customBaseURL = "https://coach.invalid/v1"
        engine.customConnected = true
        engine.dataConsent = true
        try await body(engine, repo)
    }

    @MainActor
    func testInteractiveReplyCreatesOnlyAReviewableCardAndRespectsConsent() async throws {
        try await withEngine { engine, repo in
            CoachDietURLProtocol.status = 200
            CoachDietURLProtocol.text = "Review this first.\n" +
                #"{"noop_diet_goal":{"targetWeightKg":69,"months":6,"reason":"Our agreed timeline"}}"#
            await engine.send("Help me plan a goal of 69 kg over six months.")
            XCTAssertNil(engine.errorText)
            XCTAssertEqual(engine.messages.last?.dietProposal?.request.targetWeightKg, 69)
            XCTAssertFalse(engine.messages.last?.text.contains("noop_diet_goal") ?? true)
            let goal = await repo.currentDietGoal()
            XCTAssertNil(goal, "A provider response must not write a goal")
            engine.dataConsent = false
            await engine.send("Try again")
            XCTAssertNil(engine.messages.last?.dietProposal)
            let after = await repo.currentDietGoal()
            XCTAssertNil(after)
        }
    }

    @MainActor
    func testOnlySuccessfulRequestedReviewsAcknowledgeWeeklyCadence() async throws {
        try await withEngine { engine, _ in
            CoachDietURLProtocol.status = 500
            CoachDietURLProtocol.text = ""
            await engine.send(CoachDietReviewHistory.prompt)
            XCTAssertNotNil(engine.errorText)
            XCTAssertNil(CoachDietReviewHistory.lastReviewed(goalId: nil))
            CoachDietURLProtocol.status = 200
            CoachDietURLProtocol.text = "There is no active goal. What destination and timeline would you like?"
            await engine.send(CoachDietReviewHistory.prompt)
            XCTAssertNil(engine.errorText)
            XCTAssertNotNil(CoachDietReviewHistory.lastReviewed(goalId: nil))
        }
    }

    @MainActor
    func testHistoricalWeekUsesSelectedEvidenceAndAcknowledgesOnlySuccessfulReply() async throws {
        try await withEngine { engine, repo in
            let today = WeeklyDietReview.dayIndex(Repository.localDayKey(Date()))!
            let latest = WeeklyDietReview.monday(containing: today) - 7
            let old = latest - 7
            let store = await repo.storeHandle()!
            _ = try await store.upsertMetricSeries([
                MetricPoint(day: WeeklyDietReview.dayKey(old), key: FoodLogStore.Keys.caloriesIn, value: 1234),
                MetricPoint(day: WeeklyDietReview.dayKey(latest), key: FoodLogStore.Keys.caloriesIn, value: 2345),
            ], deviceId: FoodLogStore.sourceId)
            let oldKey = WeeklyDietReview.dayKey(old)
            let latestKey = WeeklyDietReview.dayKey(latest)
            let prompt = CoachDietReviewHistory.weeklyPrompt(startKey: oldKey)
            CoachDietURLProtocol.status = 500
            CoachDietURLProtocol.text = ""
            await engine.send(prompt)
            XCTAssertFalse(CoachDietReviewHistory.hasReviewed(week: oldKey))
            CoachDietURLProtocol.status = 200
            CoachDietURLProtocol.text = "The selected week has only one logged day. We cannot infer a full-week deficit."
            await engine.send(prompt)
            XCTAssertNil(engine.errorText)
            XCTAssertTrue(CoachDietURLProtocol.lastBody.contains("SELECTED WEEK AND PRECEDING WEEKS"))
            XCTAssertTrue(CoachDietURLProtocol.lastBody.contains("Week \(oldKey)"))
            XCTAssertTrue(CoachDietReviewHistory.hasReviewed(week: oldKey))
            XCTAssertFalse(CoachDietReviewHistory.hasReviewed(week: latestKey))
            engine.dataConsent = false
            await engine.send(CoachDietReviewHistory.weeklyPrompt(startKey: latestKey))
            XCTAssertFalse(CoachDietReviewHistory.hasReviewed(week: latestKey))
            XCTAssertFalse(CoachDietURLProtocol.lastBody.contains("WEEKLY DIET REPORTS (newest first):"))
        }
    }

    @MainActor
    func testConcurrentSendsCannotInterleaveProposalTurns() async throws {
        try await withEngine { engine, _ in
            CoachDietURLProtocol.status = 200
            CoachDietURLProtocol.text = "One review."
            async let first: Void = engine.send("Review my goal")
            async let second: Void = engine.send("Review my goal again")
            _ = await (first, second)
            XCTAssertEqual(engine.messages.filter { $0.role == .user }.count, 1)
            XCTAssertEqual(engine.messages.filter { $0.role == .assistant }.count, 1)
        }
    }

    @MainActor
    func testCustomPromptIsPreservedWhileTheRequestIncludesTheDietProtocolOnce() async throws {
        try await withEngine { engine, _ in
            engine.customSystemPrompt = "Be concise."
            XCTAssertEqual(engine.systemPrompt, "Be concise.")
            XCTAssertTrue(engine.interactiveSystemPrompt.contains(CoachDietAction.sentinel))
            engine.customSystemPrompt = engine.interactiveSystemPrompt
            XCTAssertEqual(engine.interactiveSystemPrompt.components(separatedBy: "DIET PLANNING AND REVIEW").count, 2)
        }
    }

    func testReviewHistoryIsWeeklyAndResetsForANewGoal() throws {
        let suite = "CoachDietTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(CoachDietReviewHistory.isDue(goalId: "a", now: now, defaults: defaults))
        CoachDietReviewHistory.record(goalId: "a", now: now, defaults: defaults)
        XCTAssertFalse(CoachDietReviewHistory.isDue(goalId: "a", now: now.addingTimeInterval(6 * 86_400), defaults: defaults))
        XCTAssertTrue(CoachDietReviewHistory.isDue(goalId: "a", now: now.addingTimeInterval(7 * 86_400), defaults: defaults))
        XCTAssertTrue(CoachDietReviewHistory.isDue(goalId: "b", now: now, defaults: defaults))
        XCTAssertNil(CoachDietReviewHistory.lastReviewed(goalId: nil, defaults: defaults))
    }

    @MainActor
    func testReviewedGoalRetainsCalibrationAndRejectsASecondSave() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "coach-diet-test")
        repo.setStoreForTesting(store)
        let original = DietGoalRow(id: "a", deviceId: DietStore.sourceId, startedOn: "2026-09-01",
            startWeightKg: 73, targetWeightKg: 69, months: 6, activityLevel: "sedentary",
            dailyDeficitKcal: 170, createdAt: 1, proteinGPerKg: 1.2, measuredBaselineKcal: 1900)
        _ = try await store.upsertDietGoals([original])
        guard case .success(let plan) = DietGoal.plan(startWeightKg: 72, targetWeightKg: 68,
                                                      heightCm: 175, months: 6) else {
            return XCTFail("Expected valid plan")
        }
        let saved = await repo.saveReviewedDietGoal(plan: plan, proteinGPerKg: 1.4, expecting: original)
        XCTAssertTrue(saved)
        let current = await repo.currentDietGoal()
        XCTAssertEqual(current?.measuredBaselineKcal, 1900)
        XCTAssertEqual(current?.targetWeightKg, 68)
        XCTAssertEqual(current?.proteinGPerKg, 1.4)
        XCTAssertEqual(current?.dailyDeficitKcal, plan.dailyDeficitKcal)
        let staleSave = await repo.saveReviewedDietGoal(plan: plan, proteinGPerKg: 1.4, expecting: original)
        XCTAssertFalse(staleSave)
    }

    @MainActor
    func testDietContextUsesOnlyWeightEvidenceWithinTheCurrentPlan() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "coach-diet-context")
        repo.setStoreForTesting(store)
        let now = Date()
        let today = Repository.localDayKey(now)
        let goal = DietGoalRow(id: "today", deviceId: DietStore.sourceId, startedOn: today,
            startWeightKg: 73, targetWeightKg: 69, months: 6, activityLevel: "sedentary",
            dailyDeficitKcal: 170, createdAt: 1)
        _ = try await store.upsertDietGoals([goal])
        for back in 0..<30 {
            let day = Repository.localDayKey(now.addingTimeInterval(-Double(back) * 86_400))
            await repo.logWeight(kg: 73 + Double(back) * 0.05, day: day)
        }
        let snapshot = await repo.coachDietSnapshot(now: now)
        XCTAssertNil(snapshot.fit, "Earlier-plan loss cannot justify adjusting a plan started today")
        XCTAssertEqual(snapshot.signal, .building)
        XCTAssertEqual(snapshot.reviewWindowDays, 0)
        XCTAssertTrue(snapshot.context.contains("coverage does NOT prove completeness"))
    }

    @MainActor
    func testGoalProposalExportCapturesStateWithoutWritingAGoal() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "coach-diet-proposal")
        repo.setStoreForTesting(store)
        let engine = AICoachEngine(repo: repo)
        let request = CoachDietGoalRequest(targetWeightKg: 69, months: 6, reason: "Discussed timeline")
        let message = ChatMessage(role: .assistant, text: "Review this proposal.",
                                 dietProposal: CoachDietProposal(request: request, previousGoal: nil))
        engine.messages = [message]
        let original = await repo.currentDietGoal()
        XCTAssertNil(original)
        let edited = try DietGoal.plan(startWeightKg: 73, targetWeightKg: 68, heightCm: 175, months: 8).get()
        engine.updateDietProposal(messageId: message.id, state: .applied, appliedPlan: edited, proteinGPerKg: 1.4)
        let acceptedExport = try XCTUnwrap(CoachDump.json(messages: engine.messages, provider: "test", model: "test",
            dataConsent: true, onDeviceSignals: false, hasCustomPrompt: false, customPromptMissesFoodProtocol: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(acceptedExport.utf8)) as? [String: Any])
        let turns = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let accepted = try XCTUnwrap(turns.first?["dietProposal"] as? [String: Any])
        XCTAssertEqual(accepted["targetWeightKg"] as? Double, 69)
        XCTAssertEqual(accepted["appliedTargetWeightKg"] as? Double, 68)
        XCTAssertEqual(accepted["appliedMonths"] as? Int, 8)
        XCTAssertEqual(accepted["appliedProteinGPerKg"] as? Double, 1.4)
        engine.updateDietProposal(messageId: message.id, state: .dismissed)
        XCTAssertEqual(engine.messages.first?.dietProposal?.state, .dismissed)
        let export = try XCTUnwrap(CoachDump.json(messages: engine.messages, provider: "test", model: "test",
            dataConsent: true, onDeviceSignals: false, hasCustomPrompt: false, customPromptMissesFoodProtocol: false))
        XCTAssertTrue(export.contains("\"dietProposal\""))
        XCTAssertTrue(export.contains("\"dismissed\""))
        let after = await repo.currentDietGoal()
        XCTAssertNil(after)
    }
}
