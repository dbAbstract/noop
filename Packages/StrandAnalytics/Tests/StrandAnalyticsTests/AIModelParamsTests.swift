import XCTest
@testable import StrandAnalytics

/// Which parameter shape a chat model wants.
///
/// The bug this came from: `gpt-5` rejects `max_tokens` and names `max_completion_tokens` in a 400. The
/// retry for that existed on the non-streaming path only, and streaming is the path the Coach uses — so the
/// user saw the provider's raw error and no reply.
final class AIModelParamsTests: XCTestCase {

    // MARK: - Modern families

    func testGpt5WantsTheModernShape() {
        XCTAssertTrue(AIModelParams.needsModernParams(model: "gpt-5"))
        XCTAssertTrue(AIModelParams.needsModernParams(model: "gpt-5-mini"))
        XCTAssertTrue(AIModelParams.needsModernParams(model: "gpt-5-2026-01-01"))
    }

    func testTheReasoningSeriesWantsTheModernShape() {
        for id in ["o1", "o1-mini", "o1-preview", "o3", "o3-mini", "o4-mini"] {
            XCTAssertTrue(AIModelParams.needsModernParams(model: id), "\(id) should be modern")
        }
    }

    // MARK: - The gpt-4 family must not change

    func testTheOlderFamilyKeepsTheStandardShape() {
        for id in ["gpt-4", "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"] {
            XCTAssertFalse(AIModelParams.needsModernParams(model: id), "\(id) should be standard")
        }
    }

    /// `chatgpt-4o` ends in something that looks like a reasoning id. A sloppier rule would catch it and
    /// send the wrong body to a model that works today.
    func testAnIdThatMerelyLooksLikeAReasoningModelIsNotOne() {
        XCTAssertFalse(AIModelParams.needsModernParams(model: "chatgpt-4o-latest"))
        XCTAssertFalse(AIModelParams.needsModernParams(model: "gpt-4o-audio"))
    }

    // MARK: - Unknown ids

    /// THE IMPORTANT DEFAULT. An unknown id answers STANDARD, because that is what llama.cpp, Ollama and
    /// LM Studio accept. Guessing modern would break the Custom provider for every local server.
    func testUnknownModelsGetTheStandardShape() {
        XCTAssertFalse(AIModelParams.needsModernParams(model: "llama-3.3-70b"))
        XCTAssertFalse(AIModelParams.needsModernParams(model: "qwen2.5-coder"))
        XCTAssertFalse(AIModelParams.needsModernParams(model: ""))
        XCTAssertFalse(AIModelParams.needsModernParams(model: "   "))
    }

    /// A gateway addresses models by route. The shape is a property of the MODEL, not of how it was reached.
    func testAVendorPrefixIsStripped() {
        XCTAssertTrue(AIModelParams.needsModernParams(model: "openai/gpt-5"))
        XCTAssertTrue(AIModelParams.needsModernParams(model: "azure/o3-mini"))
        XCTAssertFalse(AIModelParams.needsModernParams(model: "openai/gpt-4o"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(AIModelParams.needsModernParams(model: "GPT-5"))
        XCTAssertTrue(AIModelParams.needsModernParams(model: " gpt-5 "))
    }

    // MARK: - The retry trigger

    /// The exact message the user hit.
    func testTheRealErrorIsRecognised() {
        XCTAssertTrue(AIModelParams.isParameterShapeError(
            "Unsupported parameter 'max_tokens' is not supported with this model (gpt-5), use 'max_completion_tokens' instead"))
    }

    func testTheOppositeDirectionIsAlsoRecognised() {
        XCTAssertTrue(AIModelParams.isParameterShapeError(
            "Unrecognized request argument supplied: max_completion_tokens"))
        XCTAssertTrue(AIModelParams.isParameterShapeError(
            "Unsupported value: 'temperature' does not support 0.6 with this model"))
    }

    /// An unrelated 400 must NOT trigger a retry — resending the same request in a different shape would
    /// waste a call and bury the real reason.
    func testUnrelatedErrorsDoNotTriggerARetry() {
        XCTAssertFalse(AIModelParams.isParameterShapeError("Incorrect API key provided"))
        XCTAssertFalse(AIModelParams.isParameterShapeError("You exceeded your current quota"))
        XCTAssertFalse(AIModelParams.isParameterShapeError("context_length_exceeded"))
    }
}
