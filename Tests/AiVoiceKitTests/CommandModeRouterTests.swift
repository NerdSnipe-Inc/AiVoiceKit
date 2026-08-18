// Tests/AiVoiceKitTests/CommandModeRouterTests.swift
import XCTest
@testable import AiVoiceKit

final class CommandModeRouterTests: XCTestCase {
    func testAlricPrefixWithCommaIsDetected() async {
        var received: String? = nil
        await CommandModeRouter.route(text: "Alric, set a timer for 5 minutes") { text in
            received = text
        }
        XCTAssertEqual(received, "set a timer for 5 minutes")
    }

    func testAlricPrefixCaseInsensitive() async {
        var received: String? = nil
        await CommandModeRouter.route(text: "alric, do something") { received = $0 }
        XCTAssertEqual(received, "do something")
    }

    func testHeyAlricPrefix() async {
        var received: String? = nil
        await CommandModeRouter.route(text: "Hey Alric, open Safari") { received = $0 }
        XCTAssertEqual(received, "open Safari")
    }

    func testNonAlricTextIsNotRouted() async {
        var received: String? = nil
        await CommandModeRouter.route(text: "This is just regular dictation") { received = $0 }
        XCTAssertNil(received)
    }

    func testAlricPrefixWithPeriod() async {
        var received: String? = nil
        await CommandModeRouter.route(text: "Alric. Open my calendar") { received = $0 }
        XCTAssertEqual(received, "Open my calendar")
    }

    func testExtractCommandReturnsNilForEmptyRemainder() {
        // "Alric," alone should not produce an empty command
        let result = CommandModeRouter.extractCommand(from: "Alric,")
        XCTAssertNil(result)
    }

    func testExtractCommandHeyAlricSpace() {
        let result = CommandModeRouter.extractCommand(from: "Hey Alric turn on dark mode")
        XCTAssertEqual(result, "turn on dark mode")
    }

    func testRouteReturnsTrueWhenCommandMatched() async {
        let routed = await CommandModeRouter.route(text: "Alric, do the thing") { _ in }
        XCTAssertTrue(routed)
    }

    func testRouteReturnsFalseForPlainDictation() async {
        let routed = await CommandModeRouter.route(text: "Hello world") { _ in }
        XCTAssertFalse(routed)
    }
}
