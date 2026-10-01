import XCTest
@testable import StrandAnalytics

/// Reading macros out of a model's reply. Tolerant about wrapping, strict about content — these pin both
/// halves, and most of them are about REFUSING something rather than accepting it.
final class MacroEstimateParseTests: XCTestCase {

    /// A self-consistent reply: 24P + 30C + 10F = 96 + 120 + 90 = 306 kcal, stated as 310 (1.3% off).
    private let good = #"{"kcal": 310, "protein": 24, "carbs": 30, "fat": 10, "fiber": 3}"#

    private func parse(_ s: String) -> Result<MacroTotals, MacroEstimateParse.Failure> {
        MacroEstimateParse.macros(fromReply: s)
    }

    private func succeeded(_ s: String) -> MacroTotals? {
        if case .success(let m) = parse(s) { return m }
        return nil
    }

    private func failed(_ s: String) -> MacroEstimateParse.Failure? {
        if case .failure(let f) = parse(s) { return f }
        return nil
    }

    // MARK: - Wrapping: be generous

    func testBareObject() throws {
        let m = try XCTUnwrap(succeeded(good))
        XCTAssertEqual(m.kcal, 310)
        XCTAssertEqual(m.protein, 24)
        XCTAssertEqual(m.fiber, 3)
    }

    func testFencedJSON() throws {
        let m = try XCTUnwrap(succeeded("```json\n\(good)\n```"))
        XCTAssertEqual(m.kcal, 310)
    }

    func testUnlabelledFence() throws {
        XCTAssertNotNil(succeeded("```\n\(good)\n```"))
    }

    /// The most common real failure: a model that cannot resist a preamble.
    func testProseAroundTheObject() throws {
        let m = try XCTUnwrap(succeeded("Sure! Here's the breakdown:\n\n\(good)\n\nHope that helps!"))
        XCTAssertEqual(m.kcal, 310)
    }

    /// A nested object must not confuse the scan. Slicing to the FIRST `}` would cut the outer object
    /// short; slicing to the LAST would swallow trailing prose.
    func testNestedObjectIsHandled() throws {
        let nested = #"{"per_serving": {"note": "approx"}, "kcal": 310, "protein": 24, "carbs": 30, "fat": 10, "fiber": 3}"#
        let m = try XCTUnwrap(succeeded("Here you go: \(nested) — let me know!"))
        XCTAssertEqual(m.kcal, 310)
    }

    /// A brace inside a string must not be counted as structure.
    func testBracesInsideStringsAreIgnored() throws {
        let tricky = #"{"name": "rice {large}", "kcal": 310, "protein": 24, "carbs": 30, "fat": 10}"#
        XCTAssertNotNil(succeeded(tricky))
    }

    /// Models disagree about field names; the prompt should not have to win that argument.
    func testAlternativeFieldNames() throws {
        let alt = #"{"calories": 310, "protein_g": 24, "carbohydrates": 30, "fat_g": 10, "fibre": 3}"#
        let m = try XCTUnwrap(succeeded(alt))
        XCTAssertEqual(m.kcal, 310)
        XCTAssertEqual(m.carbs, 30)
        XCTAssertEqual(m.fiber, 3)
    }

    /// Numbers arriving as strings — including with a unit attached — are a formatting detail, not a
    /// reason to refuse.
    func testNumericStringsAreAccepted() throws {
        let strings = #"{"kcal": "310", "protein": "24 g", "carbs": "30g", "fat": "10"}"#
        let m = try XCTUnwrap(succeeded(strings))
        XCTAssertEqual(m.kcal, 310)
        XCTAssertEqual(m.protein, 24)
        XCTAssertEqual(m.carbs, 30)
    }

    // MARK: - Content: be strict

    /// THE IMPORTANT ONE. A truncated reply must fail rather than be salvaged: its last number is as
    /// likely half-written as complete, and a plausible fragment is worse than an honest failure. This
    /// is the realistic small-local-model case, where a short context window cuts the reply off.
    func testTruncatedObjectIsRejectedNotSalvaged() {
        XCTAssertEqual(failed(#"{"kcal": 310, "protein": 24, "carbs": 3"#), .truncated)
        XCTAssertEqual(failed("```json\n{\"kcal\": 310, \"protein\": 2"), .truncated)
    }

    func testProseWithNoObjectAtAll() {
        XCTAssertEqual(failed("That looks like roughly 300 calories with 24g of protein."), .noJSON)
        XCTAssertEqual(failed(""), .noJSON)
    }

    /// The hallucination detector. These macros imply 96+120+90 = 306 kcal; the reply claims 900. The
    /// model contradicted itself, so neither figure is trustworthy and the estimate is refused rather
    /// than quietly corrected.
    func testSelfContradictingMacrosAreRejected() {
        let lying = #"{"kcal": 900, "protein": 24, "carbs": 30, "fat": 10}"#
        XCTAssertEqual(failed(lying), .inconsistent)
    }

    func testNoCaloriesIsRejected() {
        XCTAssertEqual(failed(#"{"protein": 24, "carbs": 30, "fat": 10}"#), .noCalories)
        XCTAssertEqual(failed(#"{"kcal": 0, "protein": 24}"#), .noCalories)
    }

    /// Nothing is repaired. A rejected estimate stays rejected — rewriting the kcal from the macros
    /// would hand the user a number neither they nor the model ever stated.
    func testInconsistentRepliesAreNotRecomputed() {
        let lying = #"{"kcal": 900, "protein": 24, "carbs": 30, "fat": 10}"#
        if case .success = parse(lying) { XCTFail("must not accept, and must not repair") }
    }

    // MARK: - Clamping

    func testNegativeAndNonFiniteFieldsCollapseToZero() throws {
        // kcal stays consistent with the macros; the negative fibre is the thing under test.
        let m = try XCTUnwrap(succeeded(#"{"kcal": 306, "protein": 24, "carbs": 30, "fat": 10, "fiber": -5}"#))
        XCTAssertEqual(m.fiber, 0)
    }

    /// A misplaced decimal becomes zero rather than being capped AT the ceiling: a 10,000 kcal sandwich
    /// is not a better answer than no answer.
    func testAbsurdValuesCollapseRatherThanCap() {
        XCTAssertEqual(failed(#"{"kcal": 2500000, "protein": 24, "carbs": 30, "fat": 10}"#), .noCalories)
    }

    /// A very large restaurant meal must still get through — the ceiling exists to catch 25,000, not
    /// 1,500.
    func testALargeButRealMealIsAccepted() throws {
        // 90P + 150C + 70F = 360 + 600 + 630 = 1590
        let big = #"{"kcal": 1590, "protein": 90, "carbs": 150, "fat": 70, "fiber": 12}"#
        XCTAssertNotNil(succeeded(big))
    }

    // MARK: - The object scanner directly

    func testFirstJSONObjectFindsBalancedBraces() {
        XCTAssertEqual(MacroEstimateParse.firstJSONObject(in: "a {\"x\": 1} b"), "{\"x\": 1}")
        XCTAssertEqual(MacroEstimateParse.firstJSONObject(in: "{\"a\": {\"b\": 2}}"), "{\"a\": {\"b\": 2}}")
        XCTAssertNil(MacroEstimateParse.firstJSONObject(in: "{\"a\": 1"))
        XCTAssertNil(MacroEstimateParse.firstJSONObject(in: "no braces here"))
    }

    /// A stray close brace before any open must not throw the scan off.
    func testStrayClosingBraceIsIgnored() {
        XCTAssertEqual(MacroEstimateParse.firstJSONObject(in: "} then {\"x\": 1}"), "{\"x\": 1}")
    }
}
