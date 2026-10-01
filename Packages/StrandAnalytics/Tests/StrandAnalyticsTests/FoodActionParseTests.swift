import XCTest
@testable import StrandAnalytics

/// Reading a food-log action out of a coach reply.
///
/// The tests that matter most are the REFUSALS, and specifically the false positives: a coach reply
/// containing braces must never be read as a proposal to log food. A missed action is visible (no card
/// appears, the user rephrases); a spurious one writes to the series the whole diet is judged on.
final class FoodActionParseTests: XCTestCase {

    private func parse(_ s: String) -> Result<FoodAction, FoodActionParse.Failure> {
        FoodActionParse.action(fromReply: s)
    }

    private func succeeded(_ s: String) -> FoodAction? {
        if case .success(let a) = parse(s) { return a }
        return nil
    }

    private func failed(_ s: String) -> FoodActionParse.Failure? {
        if case .failure(let f) = parse(s) { return f }
        return nil
    }

    /// 15P + 20C + 0F = 60 + 80 = 140 kcal, stated as 150 (6.7% off — inside tolerance).
    private let createBlock = """
    {"noop_food_action": {"action": "create", "name": "Oikos 180 g tub", "servingLabel": "1 tub", \
    "kcal": 150, "protein": 15, "carbs": 20, "fat": 0, "fiber": 0, "portion": 1}}
    """

    // MARK: - The conversational path must stay untouched

    /// By far the most common reply, and the one that makes the feature work: the clarifying question.
    /// It carries no action, and that is not an error.
    func testAClarifyingQuestionCarriesNoAction() {
        XCTAssertEqual(failed("I see two Oikos foods saved — the yogurt and the Pro Vanilla. Which was it?"),
                       .noAction)
    }

    func testOrdinaryCoachingProseCarriesNoAction() {
        XCTAssertEqual(failed("Charge is **71** today — green light to build."), .noAction)
    }

    /// THE FALSE-POSITIVE GUARD. A coach reply can contain a JSON object for entirely innocent reasons.
    /// Without the sentinel requirement this would propose logging something the user never mentioned.
    func testJSONInProseIsNotAnAction() {
        XCTAssertEqual(failed("""
            Here's what a macro split looks like: {"protein": 150, "carbs": 200, "fat": 60} — aim for that.
            """), .noAction)
        XCTAssertEqual(failed("""
            ```json
            {"action": "log", "itemId": "abc", "portion": 1}
            ```
            """), .noAction, "an action-shaped object WITHOUT the sentinel must be ignored")
    }

    /// Braces in ordinary text must not trip the scanner either.
    func testBracesInProseAreHarmless() {
        XCTAssertEqual(failed("Your {macros} look fine, keep protein above 88 g."), .noAction)
    }

    // MARK: - Log

    func testLogResolvesItemAndPortion() throws {
        let reply = """
        Logging that for you.
        {"noop_food_action": {"action": "log", "itemId": "A1B2", "portion": 2}}
        """
        guard case .log(let id, let portion) = try XCTUnwrap(succeeded(reply)) else {
            return XCTFail("expected a log action")
        }
        XCTAssertEqual(id, "A1B2")
        XCTAssertEqual(portion, 2)
    }

    /// An absent portion is one serving, which is what "I had a yogurt" means.
    func testPortionDefaultsToOne() throws {
        let reply = #"{"noop_food_action": {"action": "log", "itemId": "A1"}}"#
        guard case .log(_, let portion) = try XCTUnwrap(succeeded(reply)) else {
            return XCTFail("expected a log action")
        }
        XCTAssertEqual(portion, 1)
    }

    /// A log with no item is meaningless — it must not silently become a create.
    func testLogWithoutAnItemIdIsRefused() {
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "log", "portion": 1}}"#), .missingItemId)
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "log", "itemId": "  "}}"#), .missingItemId)
    }

    /// Snake case too — models disagree about casing and the prompt should not have to win that argument.
    func testSnakeCaseItemIdIsAccepted() {
        XCTAssertNotNil(succeeded(#"{"noop_food_action": {"action": "log", "item_id": "A1"}}"#))
    }

    // MARK: - Create

    func testCreateCarriesNameServingAndMacros() throws {
        guard case .create(let name, let serving, let macros, let portion) =
                try XCTUnwrap(succeeded(createBlock)) else { return XCTFail("expected a create action") }
        XCTAssertEqual(name, "Oikos 180 g tub")
        XCTAssertEqual(serving, "1 tub")
        XCTAssertEqual(macros.kcal, 150)
        XCTAssertEqual(macros.protein, 15)
        XCTAssertEqual(portion, 1)
    }

    func testCreateSurvivesProseAroundIt() {
        XCTAssertNotNil(succeeded("Got it, that's a new food.\n\n\(createBlock)\n\nLogged once you confirm."))
    }

    func testCreateSurvivesAFence() {
        XCTAssertNotNil(succeeded("Here you go:\n```json\n\(createBlock)\n```"))
    }

    func testCreateWithoutANameIsRefused() {
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "create", "kcal": 150, "protein": 15, "carbs": 20, "fat": 0}}"#),
                       .missingName)
    }

    func testCreateWithoutCaloriesIsRefused() {
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "create", "name": "Mystery", "protein": 15}}"#),
                       .noCalories)
    }

    /// The hallucination detector, same as the typed-estimate path: 15P + 20C + 0F implies 140 kcal, and
    /// the reply claims 900. Neither figure is trustworthy, so nothing is offered to the user.
    func testSelfContradictingMacrosAreRefusedNotRepaired() {
        let lying = #"{"noop_food_action": {"action": "create", "name": "Oikos", "kcal": 900, "protein": 15, "carbs": 20, "fat": 0}}"#
        XCTAssertEqual(failed(lying), .inconsistent)
    }

    /// A blank serving label passes through as empty — the CALLER supplies the default, because a pure
    /// module has no business inventing a localized string.
    func testBlankServingLabelIsLeftToTheCaller() throws {
        let reply = #"{"noop_food_action": {"action": "create", "name": "X", "kcal": 140, "protein": 15, "carbs": 20, "fat": 0}}"#
        guard case .create(_, let serving, _, _) = try XCTUnwrap(succeeded(reply)) else {
            return XCTFail("expected a create action")
        }
        XCTAssertEqual(serving, "")
    }

    // MARK: - Edit

    func testEditCarriesItemIdAndMacros() throws {
        let reply = #"{"noop_food_action": {"action": "edit", "itemId": "A1", "kcal": 140, "protein": 15, "carbs": 20, "fat": 0}}"#
        guard case .edit(let id, _, let macros) = try XCTUnwrap(succeeded(reply)) else {
            return XCTFail("expected an edit action")
        }
        XCTAssertEqual(id, "A1")
        XCTAssertEqual(macros.kcal, 140)
    }

    /// Edit and create are deliberately distinct verbs. A model that conflated them would fork the
    /// library into near-duplicates — so an edit without a target is refused rather than becoming one.
    func testEditWithoutAnItemIdIsRefused() {
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "edit", "kcal": 140, "protein": 15, "carbs": 20, "fat": 0}}"#),
                       .missingItemId)
    }

    // MARK: - Verb and portion validation

    func testUnknownVerbIsRefused() {
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "delete", "itemId": "A1"}}"#), .unknownAction)
        XCTAssertEqual(failed(#"{"noop_food_action": {"itemId": "A1"}}"#), .unknownAction)
    }

    func testVerbIsCaseAndWhitespaceTolerant() {
        XCTAssertNotNil(succeeded(#"{"noop_food_action": {"action": " LOG ", "itemId": "A1"}}"#))
    }

    /// An absurd portion is a model mis-parsing "120 g" as a serving count, which would log a day's
    /// calories over and over. Refused rather than clamped: clamping to 12 is still a meal nobody ate.
    func testAbsurdPortionIsRefused() {
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "log", "itemId": "A1", "portion": 120}}"#),
                       .badPortion)
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "log", "itemId": "A1", "portion": 0}}"#),
                       .badPortion)
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "log", "itemId": "A1", "portion": -1}}"#),
                       .badPortion)
    }

    func testTruncatedProposalIsMalformed() {
        XCTAssertEqual(failed(#"{"noop_food_action": {"action": "log", "itemId": "A"#), .malformed)
    }

    // MARK: - Stripping the block from what the user sees

    func testStrippingRemovesTheBlockAndKeepsTheProse() {
        let reply = "Got it, that's a new food.\n\n\(createBlock)"
        let shown = FoodActionParse.strippingAction(from: reply)
        XCTAssertEqual(shown, "Got it, that's a new food.")
        XCTAssertFalse(shown.contains("noop_food_action"))
        XCTAssertFalse(shown.contains("{"))
    }

    /// A model told to emit bare JSON will fence it anyway, and leaving an empty ``` behind looks like a
    /// rendering bug.
    func testStrippingRemovesAnEnclosingFence() {
        let shown = FoodActionParse.strippingAction(from: "Done.\n```json\n\(createBlock)\n```")
        XCTAssertEqual(shown, "Done.")
        XCTAssertFalse(shown.contains("```"))
    }

    /// The ordinary path pays nothing and cannot be damaged by this.
    func testStrippingLeavesAnOrdinaryReplyExactlyAsItWas() {
        let prose = "Charge is **71** today — green light to build.\n\n```\nsome block\n```"
        XCTAssertEqual(FoodActionParse.strippingAction(from: prose), prose)
    }

    /// Prose AFTER the block survives — a model often adds a closing line, and dropping it would make
    /// the coach look like it stopped mid-thought.
    func testStrippingKeepsProseOnBothSides() {
        let shown = FoodActionParse.strippingAction(from: "Before.\n\(createBlock)\nAfter.")
        XCTAssertTrue(shown.contains("Before."))
        XCTAssertTrue(shown.contains("After."))
        XCTAssertFalse(shown.contains("noop_food_action"))
    }

    // MARK: - Mid-stream display

    /// The reply arrives a chunk at a time. Without this the user watches the JSON type itself out
    /// across the screen, which looks like a bug at the exact moment the feature is working.
    func testAPartiallyStreamedBlockIsNotShown() {
        let partial = "Got it, that's a new food.\n" + #"{"noop_food_action": {"action": "cre"#
        let shown = FoodActionParse.displayText(partial)
        XCTAssertEqual(shown, "Got it, that's a new food.")
        XCTAssertFalse(shown.contains("noop_food_action"))
        XCTAssertFalse(shown.contains("{"))
    }

    /// Even before the opening brace has arrived, the sentinel itself must not flash up.
    func testTheSentinelAloneIsNotShown() {
        let shown = FoodActionParse.displayText("Done.\nnoop_food_action")
        XCTAssertFalse(shown.contains("noop_food_action"))
    }

    func testAPartialBlockInsideAFenceTakesTheFenceWithIt() {
        let shown = FoodActionParse.displayText("Done.\n```json\n" + #"{"noop_food_action": {"act"#)
        XCTAssertEqual(shown, "Done.")
        XCTAssertFalse(shown.contains("```"))
    }

    func testACompleteBlockIsStrippedByTheDisplayPath() {
        XCTAssertEqual(FoodActionParse.displayText("Done.\n\(createBlock)"), "Done.")
    }

    /// Streaming an ordinary reply must cost nothing and change nothing, character by character.
    func testEveryPrefixOfAnOrdinaryReplyIsShownVerbatim() {
        let reply = "Charge is **71** today — green light. Here's a split: {\"protein\": 150}"
        for end in reply.indices {
            let prefix = String(reply[reply.startIndex...end])
            XCTAssertEqual(FoodActionParse.displayText(prefix), prefix)
        }
    }

    // MARK: - The locator directly

    /// The sentinel object must be found even when an unrelated object comes FIRST — the case the
    /// first-balanced-object approach would get wrong.
    func testTheSentinelObjectWinsOverAnEarlierUnrelatedOne() {
        let text = "{\"unrelated\": 1} then \(createBlock)"
        let found = FoodActionParse.objectContainingSentinel(in: text)
        XCTAssertNotNil(found)
        XCTAssertTrue(found?.contains("Oikos") ?? false)
        XCTAssertFalse(found?.contains("unrelated") ?? true)
    }
}
