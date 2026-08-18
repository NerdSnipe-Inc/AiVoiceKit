// Tests/AiVoiceKitTests/LLMClientTests.swift
import XCTest
@testable import AiVoiceKit

#if os(macOS)
final class LLMClientTests: XCTestCase {
    func testBuildRequestBodyIncludesModel() throws {
        let client = LLMClient(baseURL: "https://api.openai.com/v1", apiKey: "test")
        let body = try client.buildRequestBody(
            model: "gpt-4o-mini",
            messages: [.init(role: "user", content: "hello")],
            stream: false
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertFalse(json["stream"] as! Bool)
    }

    func testThinkingParserStripsThinkingTags() {
        let input = "<thinking>reasoning here</thinking>Clean response."
        let result = ThinkingParsers.stripThinking(from: input)
        XCTAssertEqual(result, "Clean response.")
    }

    func testBuildRequestBodyIncludesMessages() throws {
        let client = LLMClient(baseURL: "https://api.openai.com/v1", apiKey: "test")
        let body = try client.buildRequestBody(
            model: "gpt-4o-mini",
            messages: [
                .init(role: "system", content: "You are a helper."),
                .init(role: "user", content: "Hello"),
            ],
            stream: false
        )
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "Hello")
    }

    func testStripThinkingHandlesThinkShortTag() {
        let input = "<think>internal monologue</think>Final answer."
        XCTAssertEqual(ThinkingParsers.stripThinking(from: input), "Final answer.")
    }

    func testStripThinkingReturnsUnchangedWhenNoTags() {
        let input = "Plain text with no tags."
        XCTAssertEqual(ThinkingParsers.stripThinking(from: input), input)
    }
}
#endif
