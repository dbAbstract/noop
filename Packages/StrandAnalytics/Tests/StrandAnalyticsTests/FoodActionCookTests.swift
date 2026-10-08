import XCTest
@testable import StrandAnalytics

/// The v54 cook verbs: `cook`, `log_batch`, `close_batch`.
final class FoodActionCookTests: XCTestCase {

    private func reply(_ json: String) -> String {
        "Sure, here it is.\n```json\n{\"noop_food_action\": \(json)}\n```"
    }

    private func parseOne(_ json: String) -> FoodAction? {
        guard case .success(let requests) = FoodActionParse.actions(fromReply: reply(json)),
              let first = requests.first else { return nil }
        return first.action
    }

    private func failure(_ json: String) -> FoodActionParse.Failure? {
        guard case .failure(let f) = FoodActionParse.actions(fromReply: reply(json)) else { return nil }
        return f
    }

    // MARK: - cook

    func testCookWithAPortionEatenStraightAway() {
        let action = parseOne("""
            {"action": "cook", "name": "Karahi", "kcal": 2100, "protein": 145, "carbs": 120,
             "fat": 95, "note": "400g chicken", "portion": 0.6}
            """)
        guard case .cook(let name, let recipeId, let macros, let note, let portion) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(name, "Karahi")
        XCTAssertNil(recipeId)
        XCTAssertEqual(macros.kcal, 2_100)
        XCTAssertEqual(macros.protein, 145)
        XCTAssertEqual(note, "400g chicken")
        XCTAssertEqual(portion, 0.6)
    }

    /// A pot made but not yet touched. Zero is legal for THIS verb only — every other action with a zero
    /// portion would be a card promising to log something and then not.
    func testCookWithNothingEatenYetIsAllowed() {
        let action = parseOne("""
            {"action": "cook", "name": "Dal", "kcal": 900, "protein": 40, "carbs": 120, "fat": 20,
             "portion": 0}
            """)
        guard case .cook(_, _, _, _, let portion) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(portion, 0)
    }

    /// Figures are Atwater-consistent on purpose: 162P + 120C + 95F IS 1,983 kcal. The first version of
    /// this test claimed 2,340 for those macros, which `macros(body)` correctly rejected as
    /// contradictory — the parser was right and the test was wrong.
    func testCookCarriesTheRecipeItIsAMakingOf() {
        let action = parseOne("""
            {"action": "cook", "name": "Karahi", "recipeId": "abc12345", "kcal": 1983,
             "protein": 162, "carbs": 120, "fat": 95, "note": "extra chicken", "portion": 0.5}
            """)
        guard case .cook(_, let recipeId, _, let note, _) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(recipeId, "abc12345")
        // The deviation must survive parsing or the cook's figures look like an unexplained disagreement
        // with the recipe.
        XCTAssertEqual(note, "extra chicken")
    }

    func testCookAcceptsSnakeCaseRecipeId() {
        let action = parseOne("""
            {"action": "cook", "name": "Karahi", "recipe_id": "abc12345", "kcal": 2100,
             "protein": 145, "carbs": 120, "fat": 95, "portion": 1}
            """)
        guard case .cook(_, let recipeId, _, _, _) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(recipeId, "abc12345")
    }

    func testCookWithoutANameIsRejected() {
        XCTAssertEqual(failure("""
            {"action": "cook", "kcal": 2100, "protein": 145, "carbs": 120, "fat": 95, "portion": 1}
            """), .missingName)
    }

    func testCookWithANegativePortionIsRejected() {
        XCTAssertEqual(failure("""
            {"action": "cook", "name": "Karahi", "kcal": 2100, "protein": 145, "carbs": 120,
             "fat": 95, "portion": -0.5}
            """), .badPortion)
    }

    // MARK: - log_batch

    func testLogBatchWithAnExplicitFraction() {
        let action = parseOne("{\"action\": \"log_batch\", \"batchId\": \"b3000000\", \"portion\": 0.25}")
        guard case .logBatch(let id, let portion) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(id, "b3000000")
        XCTAssertEqual(portion, 0.25)
    }

    /// "The rest" must arrive as nil so the CALLER resolves it from the remainder at confirm time. A
    /// fraction fixed at parse time would overdraw the pot by anything logged in between.
    func testTheRestParsesToNilRatherThanAGuessedFraction() {
        let viaNull = parseOne("{\"action\": \"log_batch\", \"batchId\": \"b3\", \"portion\": null}")
        guard case .logBatch(_, let a) = viaNull else { return XCTFail("got \(String(describing: viaNull))") }
        XCTAssertNil(a)

        let viaWord = parseOne("{\"action\": \"log_batch\", \"batchId\": \"b3\", \"portion\": \"the rest\"}")
        guard case .logBatch(_, let b) = viaWord else { return XCTFail("got \(String(describing: viaWord))") }
        XCTAssertNil(b)
    }

    func testLogBatchWithoutABatchIdIsRejected() {
        XCTAssertEqual(failure("{\"action\": \"log_batch\", \"portion\": 0.5}"), .missingItemId)
    }

    func testLogBatchWithAZeroPortionIsRejected() {
        // Unlike `cook`, logging nothing from a pot is a card that does nothing.
        XCTAssertEqual(failure("{\"action\": \"log_batch\", \"batchId\": \"b3\", \"portion\": 0}"),
                       .badPortion)
    }

    func testLogBatchAcceptsSnakeCaseBatchId() {
        let action = parseOne("{\"action\": \"log_batch\", \"batch_id\": \"b3\", \"portion\": 0.5}")
        guard case .logBatch(let id, _) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(id, "b3")
    }

    // MARK: - close_batch

    func testCloseBatch() {
        let action = parseOne("{\"action\": \"close_batch\", \"batchId\": \"b3000000\"}")
        guard case .closeBatch(let id) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(id, "b3000000")
    }

    func testCloseBatchWithoutAnIdIsRejected() {
        XCTAssertEqual(failure("{\"action\": \"close_batch\"}"), .missingItemId)
    }

    // MARK: - The old verbs still work

    /// The cook verbs are handled before the shared portion guard, so this checks that detour did not
    /// change the behaviour of everything after it.
    func testOrdinaryLogIsUnaffected() {
        let action = parseOne("{\"action\": \"log\", \"itemId\": \"7c01aaaa\", \"portion\": 2}")
        guard case .log(let id, let portion) = action else {
            return XCTFail("got \(String(describing: action))")
        }
        XCTAssertEqual(id, "7c01aaaa")
        XCTAssertEqual(portion, 2)
    }

    func testOrdinaryLogStillRejectsAZeroPortion() {
        XCTAssertEqual(failure("{\"action\": \"log\", \"itemId\": \"7c01aaaa\", \"portion\": 0}"),
                       .badPortion)
    }
}
