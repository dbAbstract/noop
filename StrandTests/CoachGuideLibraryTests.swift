import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Replies to each Coach request in turn from `replies`, recording every request body.
private final class CoachGuideURLProtocol: URLProtocol {
    nonisolated(unsafe) static var replies: [String] = []
    nonisolated(unsafe) static var bodies: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.bodies.append(String(decoding: body, as: UTF8.self))
        let text = Self.replies.isEmpty ? "" : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk: [String: Any] = ["choices": [["delta": ["content": text]]]]
        let encoded = try! JSONSerialization.data(withJSONObject: chunk)
        client?.urlProtocol(self, didLoad: Data(("data: " + String(decoding: encoded, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

/// The coach guides as shipped: every file is bundled and well-formed, every file it describes exists, and
/// every constant it quotes is still the one the code uses.
///
/// THE PINS ARE THE POINT. A guide quoting "HRV 55%" after the weight moved to 0.5 would have Coach explain
/// a formula the app no longer runs. When a pin fails, the code changed under a guide: update the guide's
/// text (and the pin) in the same commit.
final class CoachGuideLibraryTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let guideDir = repoRoot.appendingPathComponent("Strand/Resources/CoachGuide")

    private func guide(_ topic: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let g = CoachGuideLibrary.guide(topic) else {
            XCTFail("no bundled guide \(topic)", file: file, line: line); return ""
        }
        return g.body
    }

    /// Percent text for a weight or share: 0.55 → "55%".
    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    func testEveryGuideFileIsBundledAndWellFormed() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.guideDir.path).filter { $0.hasSuffix(".md") }
        XCTAssertFalse(files.isEmpty)
        let bundled = CoachGuideLibrary.guides
        XCTAssertEqual(Set(bundled.map { $0.topic + ".md" }), Set(files),
                       "each guide file ships in the app and is named after its topic")
        XCTAssertEqual(Set(bundled.map(\.topic)).count, bundled.count, "topics are unique")
        for g in bundled {
            XCTAssertFalse(g.keywords.isEmpty, g.topic)
            XCTAssertFalse(g.sources.isEmpty, g.topic)
            XCTAssertLessThan(g.body.count, 4_000, "\(g.topic) stays short enough to send whole")
            for source in g.sources {
                XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repoRoot.appendingPathComponent(source).path),
                              "\(g.topic) names \(source), which no longer exists")
            }
        }
    }

    func testTheRecoveryGuidesQuoteTheLiveConstants() {
        let charge = guide("charge")
        for s in ["HRV higher than normal \(pct(RecoveryScorer.wHRV))",
                  "resting HR lower than normal \(pct(RecoveryScorer.wRHR))",
                  "last night's Rest score \(pct(RecoveryScorer.wSleep))",
                  "respiratory rate lower than normal \(pct(RecoveryScorer.wResp))",
                  "skin-temperature deviation from baseline \(pct(RecoveryScorer.wSkinTemp))",
                  "Two optional \(pct(RecoveryScorer.wRecoveryIndex))",
                  "about \(Int(RecoveryScorer.populationMean)), the published",
                  "0–\(Int(RecoveryScorer.bandRedMax) - 1) red", "\(Int(RecoveryScorer.bandRedMax))–\(Int(RecoveryScorer.bandYellowMax) - 1) yellow",
                  "\(Int(RecoveryScorer.bandYellowMax))–100 green",
                  "at least \(Baselines.minNightsSeed) valid nights", "after \(Baselines.minNightsTrust)",
                  "last \(ChargeBaselines.windowDays) days"] {
            XCTAssertTrue(charge.contains(s), "charge guide: \(s)")
        }
        XCTAssertEqual(RecoveryScorer.wActivityBalance, RecoveryScorer.wRecoveryIndex, "the guide quotes both as one figure")

        let effort = guide("effort")
        XCTAssertTrue(effort.contains("ln(\(Int(StrainScorer.strainDenominator)))"))
        XCTAssertTrue(effort.contains("208 − 0.7 × age"))
        XCTAssertEqual(ProfileStore.resolveHRMax(override: 0, age: 40), 180)
        XCTAssertTrue(effort.contains("100/\(Int(StrainScorer.whoopMaxStrain))"))

        let rest = guide("rest-and-sleep")
        for s in ["Duration \(pct(AnalyticsEngine.Rest.wDuration))", "Efficiency \(pct(AnalyticsEngine.Rest.wEfficiency))",
                  "Restorative \(pct(AnalyticsEngine.Rest.wRestorative))", "Consistency \(pct(AnalyticsEngine.Rest.wConsistency))",
                  "against a \(pct(AnalyticsEngine.Rest.restorativeTarget)) target", "under \(pct(AnalyticsEngine.Rest.deepShareTarget))",
                  "neutral \(AnalyticsEngine.Rest.neutralConsistency)",
                  "at \(Int(AnalyticsEngine.Rest.defaultNeedHours)) h", "After \(AnalyticsEngine.Rest.minNeedNights) scorable",
                  "above \(AnalyticsEngine.Rest.maxNeedHours) h",
                  "last \(SleepDebt.defaultWindowNights) nights", "\(pct(SleepDebt.debtCarryFactor)) of whatever",
                  "under \(Int(SleepDebt.minimumDebtMin)) minutes"] {
            XCTAssertTrue(rest.contains(s), "rest guide: \(s)")
        }
        XCTAssertEqual(AnalyticsEngine.Rest.deepFloorFactor, 0.5, "the guide says 'never below half'")

        let baselines = guide("baselines")
        let hrv = Baselines.metricCfg["hrv"]
        for s in ["half-life about \(Int(hrv?.halfLifeB ?? 0)) nights", "more than \(Int(Baselines.hardOutlierK))",
                  "clamped to \(Int(Baselines.winsorK)) spreads", "after \(Baselines.minNightsSeed) valid nights",
                  "trusted after \(Baselines.minNightsTrust)", "\(Baselines.staleDays) nights with no data",
                  "last \(ChargeBaselines.windowDays) days"] {
            XCTAssertTrue(baselines.contains(s), "baselines guide: \(s)")
        }
    }

    func testTheDietGuidesQuoteTheLiveConstants() {
        let budget = guide("diet-budget")
        XCTAssertTrue(budget.contains("BMR × \(ActivityLevel.sedentary.multiplier)"))
        XCTAssertEqual(CalorieTarget.mifflinBMR(sex: "male", weightKg: 70, heightCm: 175, age: 30), 1_648.75)
        XCTAssertEqual(CalorieTarget.mifflinBMR(sex: "nonbinary", weightKg: 70, heightCm: 175, age: 30), 1_565.75)
        XCTAssertTrue(budget.contains("4,000-step") && StepNeat.sedentaryBaselineSteps == 4_000)
        XCTAssertTrue(budget.contains("\(StepNeat.netKcalPerStepPerKg) kcal per step per kg"))
        XCTAssertTrue(budget.contains("Before 0\(DietDayBoundary.latestRolloverMinute / 60):00"))
        XCTAssertTrue(budget.contains("at least \(Int(DietDayBoundary.minimumNightHours)) hours"))

        let credit = guide("workout-credit")
        let flex = SportEnergy.flexHRRFraction
        XCTAssertTrue(credit.contains("(%HRR − \(flex)) / \(1 - flex)"))
        XCTAssertTrue(credit.contains("recovery pace of \(Int(SportEnergy.offMET)) MET"))
        XCTAssertEqual(WorkoutBudgetCredit.recoveryMET, SportEnergy.offMET)
        XCTAssertTrue(credit.contains("at least \(pct(PlayedTimeEstimate.minCoverage))"))

        let macros = guide("macro-targets")
        XCTAssertTrue(macros.contains("\(MacroTargets.minProteinGPerKg)–\(MacroTargets.maxProteinGPerKg) g/kg, default \(MacroTargets.defaultProteinGPerKg)"))
        XCTAssertTrue(macros.contains("Fat floor = \(MacroTargets.fatFloorGPerKg) g/kg"))

        let goal = guide("diet-goal")
        XCTAssertEqual(DietGoal.kcalPerKg, 7_700)
        for s in ["× 7,700 kcal/kg", "months of \(DietGoal.daysPerMonth) days", "up to \(DietGoal.gradualPercentPerWeek)%/week",
                  "up to \(Int(DietGoal.maxPercentPerWeek))%/week", "over \(Int(DietGoal.maxPercentPerWeek))%/week",
                  "BMI \(DietGoal.minHealthyBMI)"] {
            XCTAssertTrue(goal.contains(s), "goal guide: \(s)")
        }

        let trend = guide("weight-trend")
        XCTAssertTrue(trend.contains("\(Int(WeightTrend.trendHalfLifeDays))-day half-life"))
        XCTAssertTrue(trend.contains("\(WeightTrend.confidenceK) standard errors"))

        let burn = guide("measured-burn")
        let A = AdaptiveExpenditureEngine.self
        for s in ["\(A.minWindowDays)–\(A.maxWindowDays) days", "at least \(A.minIntakeDays) days",
                  "at least \(pct(A.minIntakeCoverage))", "at least \(A.minWeightReadings) weigh-ins",
                  "±\(pct(A.baseReportingError)) reporting", "assumed \(pct(A.unloggedDayExcess)) bigger",
                  "carries \(A.roughGuessDiscount) of that", "× \(CalorieTarget.correctionDamping)",
                  "\(Int(CalorieTarget.minAdjustedDeficitKcal))–\(Int(CalorieTarget.maxAdjustedDeficitKcal)) kcal/day"] {
            XCTAssertTrue(burn.contains(s), "measured-burn guide: \(s)")
        }
        XCTAssertTrue(guide("rough-estimates").contains("\(A.roughGuessDiscount) of the allowance"))
    }

    @MainActor
    func testOnlyAQuestionAboutATopicPutsItsGuideInTheContext() {
        let asked = CoachGuideLibrary.contextBlock(for: "how is my charge calculated?", includingDiet: true)
        XCTAssertTrue(asked.hasPrefix("HOW NOOP WORKS"))
        XCTAssertTrue(asked.contains("## charge:"))
        XCTAssertEqual(CoachGuideLibrary.contextBlock(for: "had 2 eggs, 10g butter", includingDiet: true), "")
        XCTAssertEqual(CoachGuideLibrary.contextBlock(for: "what's up?", includingDiet: true), "",
                       "a question about no topic adds nothing")
        let prompt = CoachGuideLibrary.promptSection(includingDiet: true)
        XCTAssertTrue(prompt.contains("GUIDE TOPICS:\n- baselines: "))
        XCTAssertTrue(prompt.contains("\"action\": \"read_guide\""))
        XCTAssertTrue(AICoachEngine(repo: Repository(deviceId: "guide-prompt")).interactiveSystemPrompt.contains("GUIDE TOPICS:"))
    }

    /// With food logging off, Coach is not offered the diet guides: neither in the index nor for a question.
    func testDietGuidesAreOfferedOnlyWithFoodLogging() {
        let diet = Set(CoachGuideLibrary.guides.filter(\.diet).map(\.topic))
        XCTAssertEqual(diet, ["diet-budget", "workout-credit", "macro-targets", "diet-goal", "measured-burn",
                              "weekly-reports", "rough-estimates", "nutrition-pdfs"])
        let off = CoachGuideLibrary.promptSection(includingDiet: false)
        XCTAssertTrue(off.contains("- charge: "))
        XCTAssertFalse(off.contains("- diet-budget: "))
        XCTAssertEqual(CoachGuideLibrary.contextBlock(for: "why is my budget so low?", includingDiet: false), "")
        XCTAssertTrue(CoachGuideLibrary.contextBlock(for: "why is my budget so low?", includingDiet: true)
            .contains("## diet-budget:"))
    }

    /// The round trip: Coach asks for a guide instead of answering from general knowledge, the app sends the
    /// text, and the second reply is what the user sees. Works without data consent: a guide is not user data.
    @MainActor
    func testCoachReadsAGuideBeforeAnswering() async throws {
        let keys = ["ai.provider", "ai.model", "ai.dataConsent", "ai.customConnected", "ai.customBaseURL",
                    "noop.coachEnabled", AICoachEngine.systemPromptKey]
        let previous = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set(true, forKey: "noop.coachEnabled")
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "coach-guide-test")
        repo.setStoreForTesting(store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachGuideURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = AICoachEngine(repo: repo, session: session)
        engine.provider = .custom
        engine.model = "test-model"
        engine.customBaseURL = "https://coach.invalid/v1"
        engine.customConnected = true
        engine.dataConsent = false

        CoachGuideURLProtocol.bodies = []
        CoachGuideURLProtocol.replies = [
            #"{"noop_food_action": {"action": "read_guide", "topics": ["weekly-reports", "no-such-topic"]}}"#,
            "Your weeks read uncertain because every day was tagged rough.",
        ]
        await engine.send("my weekly reports always say uncertain, is that bad")
        XCTAssertNil(engine.errorText)
        XCTAssertEqual(CoachGuideURLProtocol.bodies.count, 2)
        XCTAssertTrue(CoachGuideURLProtocol.bodies[1].contains("## weekly-reports:"))
        XCTAssertTrue(CoachGuideURLProtocol.bodies[1].contains("No guide for: no-such-topic"))
        XCTAssertEqual(engine.messages.last?.text, "Your weeks read uncertain because every day was tagged rough.")
        XCTAssertEqual(engine.messages.count, 2)
    }
}
