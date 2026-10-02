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

// MARK: - Several actions, days, and the non-logging verbs

/// "I had eggs, toast and a coffee" should be one turn, not three. And "I forgot to log yesterday" should
/// land on yesterday rather than today.
extension FoodActionParseTests {

    private func parseAll(_ s: String) -> Result<[FoodActionRequest], FoodActionParse.Failure> {
        FoodActionParse.actions(fromReply: s)
    }

    private func all(_ s: String) -> [FoodActionRequest]? {
        if case .success(let r) = parseAll(s) { return r }
        return nil
    }

    private func allFailed(_ s: String) -> FoodActionParse.Failure? {
        if case .failure(let f) = parseAll(s) { return f }
        return nil
    }

    /// Three items, one reply.
    func testSeveralActionsInOneReply() throws {
        let reply = """
        {"noop_food_action": {"actions": [
          {"action": "log", "itemId": "A1", "portion": 2},
          {"action": "create", "name": "Sourdough", "kcal": 160, "protein": 6, "carbs": 30, "fat": 1},
          {"action": "log", "itemId": "B2"}
        ]}}
        """
        let items = try XCTUnwrap(all(reply))
        XCTAssertEqual(items.count, 3)
        guard case .log(let id, let portion) = items[0].action else { return XCTFail("expected a log") }
        XCTAssertEqual(id, "A1")
        XCTAssertEqual(portion, 2)
        guard case .create(let name, _, _, _) = items[1].action else { return XCTFail("expected a create") }
        XCTAssertEqual(name, "Sourdough")
    }

    /// ONE BAD ITEM MUST NOT DISCARD THE GOOD ONES. Throwing all three away over one nonsense figure would
    /// make a described meal less reliable than logging each item separately, which defeats the point.
    func testABadActionDoesNotDiscardTheOthers() throws {
        let reply = """
        {"noop_food_action": {"actions": [
          {"action": "log", "itemId": "A1"},
          {"action": "create", "name": "Mystery", "kcal": 0},
          {"action": "log", "itemId": "B2"}
        ]}}
        """
        let items = try XCTUnwrap(all(reply))
        XCTAssertEqual(items.count, 2, "the two valid logs must survive the invalid create")
    }

    /// But when nothing survives, the reason is reported rather than an empty success.
    func testAllActionsFailingReportsWhy() {
        let reply = #"{"noop_food_action": {"actions": [{"action": "create", "name": "X", "kcal": 0}]}}"#
        XCTAssertEqual(allFailed(reply), .noCalories)
    }

    /// The original single-object shape still works — a model will emit either, and refusing the older one
    /// would fail on a technicality the user cannot see.
    func testTheSingleObjectShapeStillParses() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "log", "itemId": "A1"}}"#))
        XCTAssertEqual(items.count, 1)
    }

    func testTheSentinelMayPointStraightAtAnArray() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": [{"action": "log", "itemId": "A1"}]}"#))
        XCTAssertEqual(items.count, 1)
    }

    /// A looping model must not hand over a wall of cards.
    func testTooManyActionsAreCapped() throws {
        let one = #"{"action": "log", "itemId": "A1"}"#
        let many = Array(repeating: one, count: 20).joined(separator: ",")
        let items = try XCTUnwrap(all("{\"noop_food_action\": {\"actions\": [\(many)]}}"))
        XCTAssertEqual(items.count, FoodActionParse.maxActions)
    }

    func testAnEmptyActionsArrayIsRefused() {
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"actions": []}}"#), .unknownAction)
    }

    // MARK: - Days

    func testDayDefaultsToToday() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "log", "itemId": "A1"}}"#))
        XCTAssertEqual(items[0].day, .today)
    }

    func testYesterdayIsUnderstood() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "log", "itemId": "A1", "day": "yesterday"}}"#))
        XCTAssertEqual(items[0].day, .daysAgo(1))
    }

    func testAnISODayIsCarriedThrough() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "log", "itemId": "A1", "day": "2026-09-28"}}"#))
        XCTAssertEqual(items[0].day, .explicit("2026-09-28"))
    }

    func testDayIsCaseInsensitive() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "log", "itemId": "A1", "day": "Yesterday"}}"#))
        XCTAssertEqual(items[0].day, .daysAgo(1))
    }

    /// A model paraphrasing a date is a model guessing at one. Refused rather than resolved here, because
    /// this module has no calendar and "last Tuesday" stored as a day key is a silently wrong day.
    func testAVagueDayIsRefused() {
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"action": "log", "itemId": "A1", "day": "last tuesday"}}"#),
                       .badDay)
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"action": "log", "itemId": "A1", "day": "3 days ago"}}"#),
                       .badDay)
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"action": "log", "itemId": "A1", "day": "28/09/2026"}}"#),
                       .badDay)
    }

    func testMalformedISODaysAreRefused() {
        XCTAssertFalse(FoodActionParse.isPlausibleISODay("2026-13-01"))
        XCTAssertFalse(FoodActionParse.isPlausibleISODay("2026-09-32"))
        XCTAssertFalse(FoodActionParse.isPlausibleISODay("26-09-01"))
        XCTAssertFalse(FoodActionParse.isPlausibleISODay("2026-9-1"))
        XCTAssertTrue(FoodActionParse.isPlausibleISODay("2026-09-01"))
    }

    /// Each item carries its OWN day, so "I had porridge this morning and forgot yesterday's dinner" works.
    func testActionsCanTargetDifferentDays() throws {
        let reply = """
        {"noop_food_action": {"actions": [
          {"action": "log", "itemId": "A1"},
          {"action": "log", "itemId": "B2", "day": "yesterday"}
        ]}}
        """
        let items = try XCTUnwrap(all(reply))
        XCTAssertEqual(items[0].day, .today)
        XCTAssertEqual(items[1].day, .daysAgo(1))
    }

    // MARK: - Save without logging

    /// The user's own ask: save it so they can log a portion against yesterday themselves. Distinct from
    /// `create`, which logs — a card that said it would log and then did not would be worse than no card.
    func testSaveAddsToTheLibraryWithoutLogging() throws {
        let reply = #"{"noop_food_action": {"action": "save", "name": "Oikos 180 g tub", "servingLabel": "1 tub", "kcal": 150, "protein": 15, "carbs": 20, "fat": 0}}"#
        let items = try XCTUnwrap(all(reply))
        guard case .save(let name, let serving, let macros) = items[0].action else {
            return XCTFail("expected a save action")
        }
        XCTAssertEqual(name, "Oikos 180 g tub")
        XCTAssertEqual(serving, "1 tub")
        XCTAssertEqual(macros.kcal, 150)
    }

    /// A save is held to the same arithmetic as everything else — it is going into the library, where it
    /// will be logged repeatedly, so a self-contradicting figure there is worse than in one entry.
    func testSaveIsHeldToTheArithmeticCheck() {
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"action": "save", "name": "X", "kcal": 900, "protein": 15, "carbs": 20, "fat": 0}}"#),
                       .inconsistent)
    }

    // MARK: - Weight

    func testWeightIsUnderstood() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "weight", "kg": 72.4}}"#))
        guard case .weight(let kg) = items[0].action else { return XCTFail("expected a weight action") }
        XCTAssertEqual(kg, 72.4, accuracy: 0.001)
    }

    func testWeightAcceptsAlternativeKeys() throws {
        XCTAssertNotNil(all(#"{"noop_food_action": {"action": "weight", "weightKg": 72.4}}"#))
        XCTAssertNotNil(all(#"{"noop_food_action": {"action": "weight", "weight": 72.4}}"#))
    }

    /// A typo or a model confusing weight with calories would corrupt the one series the whole trend is
    /// fitted through, so a figure outside any human range is refused outright.
    func testAnImplausibleWeightIsRefused() {
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"action": "weight", "kg": 2100}}"#), .badWeight)
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"action": "weight", "kg": 0}}"#), .badWeight)
        XCTAssertEqual(allFailed(#"{"noop_food_action": {"action": "weight", "kg": 10}}"#), .badWeight)
    }

    /// 160 kg is ACCEPTED, and that is correct even though for most users it would be a pounds figure
    /// misread as kilos. People do weigh 160 kg, and a pure range check has no way to tell the two apart.
    ///
    /// Catching the pounds case needs the user's OWN recent weight, which this module deliberately does not
    /// have — so the guard lives at the app layer, where the profile does. Pinned here so nobody "fixes"
    /// this by narrowing the range and quietly locking out heavier users.
    func testALargeButRealWeightIsAccepted() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "weight", "kg": 160}}"#))
        guard case .weight(let kg) = items[0].action else { return XCTFail("expected a weight action") }
        XCTAssertEqual(kg, 160)
    }

    /// A weigh-in can be backdated like anything else.
    func testWeightCanTargetYesterday() throws {
        let items = try XCTUnwrap(all(#"{"noop_food_action": {"action": "weight", "kg": 72.4, "day": "yesterday"}}"#))
        XCTAssertEqual(items[0].day, .daysAgo(1))
    }

    /// The false-positive guard still holds across the new shapes: prose with an `actions` array in it but
    /// no sentinel must stay invisible.
    func testTheSentinelIsStillRequiredForTheArrayShape() {
        XCTAssertEqual(allFailed(#"Here's a plan: {"actions": [{"action": "log", "itemId": "A1"}]}"#),
                       .noAction)
    }
}

// MARK: - The meal a user named

/// "For lunch I had X" is the only way a BACKDATED entry ever gets grouped — a past day has no usable
/// timestamp to infer a meal from.
extension FoodActionParseTests {

    private func firstRequest(_ s: String) -> FoodActionRequest? {
        if case .success(let r) = FoodActionParse.actions(fromReply: s) { return r.first }
        return nil
    }

    func testAMealIsCarriedThrough() throws {
        let r = try XCTUnwrap(firstRequest(#"{"noop_food_action": {"action": "log", "itemId": "A1", "meal": "lunch"}}"#))
        XCTAssertEqual(r.meal, .lunch)
    }

    func testTheMealPairsWithABackdatedDay() throws {
        let r = try XCTUnwrap(firstRequest(#"{"noop_food_action": {"action": "log", "itemId": "A1", "day": "yesterday", "meal": "dinner"}}"#))
        XCTAssertEqual(r.day, .daysAgo(1))
        XCTAssertEqual(r.meal, .dinner)
    }

    func testMealIsCaseInsensitiveAndAcceptsTheAlternativeKey() throws {
        XCTAssertEqual(try XCTUnwrap(firstRequest(#"{"noop_food_action": {"action": "log", "itemId": "A1", "meal": "Dinner"}}"#)).meal, .dinner)
        XCTAssertEqual(try XCTUnwrap(firstRequest(#"{"noop_food_action": {"action": "log", "itemId": "A1", "mealType": "snack"}}"#)).meal, .snack)
    }

    func testAnAbsentMealIsNil() throws {
        XCTAssertNil(try XCTUnwrap(firstRequest(#"{"noop_food_action": {"action": "log", "itemId": "A1"}}"#)).meal)
    }

    /// An unparseable meal must not discard the log — a meal nobody can read is simply not known, and the
    /// entry is still worth having.
    func testAnUnrecognisedMealIsIgnoredNotFatal() throws {
        let r = try XCTUnwrap(firstRequest(#"{"noop_food_action": {"action": "log", "itemId": "A1", "meal": "brunch"}}"#))
        XCTAssertNil(r.meal)
    }

    /// `unassigned` is a DISPLAY state for an entry with no meal. Accepting it as input would let a model
    /// state the absence of a fact as a fact.
    func testUnassignedIsNotAnAcceptableInput() throws {
        XCTAssertNil(try XCTUnwrap(firstRequest(#"{"noop_food_action": {"action": "log", "itemId": "A1", "meal": "unassigned"}}"#)).meal)
    }
}
