import XCTest
@testable import StrandAnalytics

/// Reading coach guide files, deciding when a message asks about one, and the `read_guide` action.
final class CoachGuideTests: XCTestCase {

    private let charge = """
    ---
    topic: charge
    title: Charge — the daily recovery score
    keywords: charge, recovery, readiness
    sources: Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift
    ---
    Charge is how recovered you look.
    """

    private var guides: [CoachGuide] {
        [CoachGuide.parse(charge)!,
         CoachGuide(topic: "rest-and-sleep", title: "Rest", keywords: ["rest score", "sleep"], sources: [], body: "b"),
         CoachGuide(topic: "diet-budget", title: "Budget", keywords: ["budget", "calories left", "steps"],
                    sources: [], body: "b")]
    }

    func testAGuideFileParsesItsHeaderAndBody() throws {
        let g = try XCTUnwrap(CoachGuide.parse(charge))
        XCTAssertEqual(g.topic, "charge")
        XCTAssertEqual(g.title, "Charge — the daily recovery score")
        XCTAssertEqual(g.keywords, ["charge", "recovery", "readiness"])
        XCTAssertEqual(g.sources, ["Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift"])
        XCTAssertEqual(g.body, "Charge is how recovered you look.")
        XCTAssertEqual(g.indexLine, "- charge: Charge — the daily recovery score")
        XCTAssertTrue(g.contextText.hasPrefix("## charge: "))
    }

    func testFilesWithoutAHeaderTopicOrBodyAreRefused() {
        XCTAssertNil(CoachGuide.parse("# A README\nNo header here."))
        XCTAssertNil(CoachGuide.parse(charge.replacingOccurrences(of: "topic: charge\n", with: "")))
        XCTAssertNil(CoachGuide.parse("---\ntopic: x\ntitle: X\n---\n   "))
    }

    func testOnlyQuestionsAskForAnExplanation() {
        for q in ["how is charge calculated", "why is my budget so low?", "what does effort mean",
                  "explain my sleep score", "チャージはどうやって計算される"] {
            XCTAssertTrue(CoachGuide.asksForExplanation(q), q)
        }
        for m in ["had 2 eggs and toast", "log my weight 73.1", "finished eating"] {
            XCTAssertFalse(CoachGuide.asksForExplanation(m), m)
        }
    }

    func testKeywordsMatchWholeWordsAndPhrases() {
        XCTAssertEqual(CoachGuide.matching("how is my charge worked out?", in: guides).map(\.topic), ["charge"])
        XCTAssertTrue(CoachGuide.matching("which restaurant was it?", in: guides).isEmpty,
                      "a keyword inside another word is not a match")
        XCTAssertEqual(CoachGuide.matching("why is my rest score low?", in: guides).map(\.topic), ["rest-and-sleep"])
        XCTAssertEqual(CoachGuide.matching("how many calories left, and do steps count in the budget?", in: guides)
            .map(\.topic), ["diet-budget"])
        let both = CoachGuide.matching("does sleep affect charge and recovery?", in: guides)
        XCTAssertEqual(both.map(\.topic), ["charge", "rest-and-sleep"], "the guide with more keyword hits first")
        XCTAssertEqual(CoachGuide.matching("charge sleep budget?", in: guides, limit: 2).count, 2)
    }

    func testReadGuideTopicsAreReadLowercasedAndCapped() {
        let reply = #"{"noop_food_action": {"actions": [{"action": "read_guide", "topics": ["Charge", "charge", "effort", "baselines", "diet-budget"]}]}}"#
        XCTAssertEqual(FoodActionParse.guideTopics(fromReply: reply), ["charge", "effort", "baselines"])
        XCTAssertEqual(FoodActionParse.guideTopics(fromReply: #"{"noop_food_action": {"action": "read_guide", "topic": "weight-trend"}}"#),
                       ["weight-trend"])
        XCTAssertTrue(FoodActionParse.documentSearchQueries(fromReply: reply).isEmpty, "a guide read is not a search")
        XCTAssertTrue(FoodActionParse.guideTopics(fromReply: "Charge is fine.").isEmpty)
    }
}
