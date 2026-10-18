import XCTest
@testable import Strand

private final class StreamingRetryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [[String: Any]] = []
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock(); Self.captured.append(body); let first = Self.captured.count == 1; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: first ? 400 : 200,
            httpVersion: nil, headerFields: ["Content-Type": first ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if first {
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Unsupported parameter: max_tokens"}}"#.utf8))
        } else {
            for part in ["Hello", " there"] {
                let chunk: [String: Any] = ["choices": [["delta": ["content": part]]]]
                let json = try! JSONSerialization.data(withJSONObject: chunk)
                client?.urlProtocol(self, didLoad: Data(("data: " + String(decoding: json, as: UTF8.self) + "\n\n").utf8))
            }
            client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class OpenAIStreamingRetryTests: XCTestCase {
    func testOnlyOriginalGPT5InteractiveRepliesUseMinimalReasoning() {
        for id in ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-2025-08-07", "openai/gpt-5"] {
            XCTAssertEqual(OpenAIClient.interactiveReasoningEffort(model: id), "minimal")
        }
        for id in ["gpt-5.1", "gpt-5.2", "gpt-5-pro", "gpt-5-chat-latest", "o3"] {
            XCTAssertEqual(OpenAIClient.interactiveReasoningEffort(model: id), "low")
        }
    }

    func testParameterRetryStillStreamsInsteadOfWaitingForACompleteResponse() async throws {
        StreamingRetryProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingRetryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var deltas: [String] = []
        try await OpenAIClient().stream(key: "test-key", model: "future-reasoner", systemPrompt: "Test",
            messages: [(.user, "Hello")], session: session, onDelta: { deltas.append($0) })
        XCTAssertEqual(deltas, ["Hello", " there"])
        let requests = StreamingRetryProtocol.bodies
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0["stream"] as? Bool == true })
        XCTAssertNotNil(requests.first?["max_tokens"])
        XCTAssertNotNil(requests.last?["max_completion_tokens"])
    }
}
