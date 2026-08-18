// Sources/AiVoiceKit/macOS/AI/ThinkingParsers.swift
// Adapted from FluidVoice — SettingsStore references replaced with inline helpers.
#if os(macOS)
import Foundation

// MARK: - Parser State

enum ThinkingParserState {
    case initial     // Haven't yet entered thinking or content
    case inThinking  // Inside a thinking section
    case inContent   // Inside the main response content
}

// MARK: - Protocol

protocol ThinkingParser {
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String)

    func finalize(
        thinkingBuffer: [String],
        contentBuffer: [String],
        finalState: ThinkingParserState
    ) -> (thinking: String, content: String)
}

// MARK: - Factory

enum ThinkingParserFactory {
    static func createParser(for model: String) -> ThinkingParser {
        let m = model.lowercased()
        if m.contains("nemotron") || m.contains("nemo") {
            return NemoThinkingParser()
        }
        if m.contains("deepseek") || isKnownReasoningModel(m) {
            return SeparateFieldThinkingParser()
        }
        return StandardThinkingParser()
    }

    static func getExtraParameters(for model: String) -> [String: Any] {
        let m = model.lowercased()
        if m.contains("nemotron") || m.contains("nemo") {
            return ["enable_thinking": true]
        }
        if m.contains("deepseek") && m.contains("r1") {
            return ["enable_reasoning": true]
        }
        return [:]
    }

    static func isKnownReasoningModel(_ modelLower: String) -> Bool {
        modelLower.hasPrefix("o1") ||
        modelLower.hasPrefix("o3") ||
        modelLower.hasPrefix("o4") ||
        modelLower.hasPrefix("gpt-5") ||
        modelLower.hasPrefix("gpt-oss")
    }
}

// MARK: - Standard Parser (<think>…</think>)

struct StandardThinkingParser: ThinkingParser {
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String) {
        tagBuffer += chunk
        var thinkingChunk = ""
        var contentChunk = ""
        var newState = currentState

        if newState != .inThinking {
            if let openRange = tagBuffer.range(of: "<think>") ?? tagBuffer.range(of: "<thinking>") {
                let before = String(tagBuffer[..<openRange.lowerBound])
                if !before.isEmpty { contentChunk += before }
                tagBuffer = String(tagBuffer[openRange.upperBound...])
                newState = .inThinking
            }
        }

        if newState == .inThinking {
            if let closeRange = tagBuffer.range(of: "</think>") ?? tagBuffer.range(of: "</thinking>") {
                let before = String(tagBuffer[..<closeRange.lowerBound])
                if !before.isEmpty { thinkingChunk += before }
                tagBuffer = String(tagBuffer[closeRange.upperBound...])
                newState = .inContent
                if !tagBuffer.isEmpty { contentChunk += tagBuffer; tagBuffer = "" }
            } else {
                let safeLength = max(0, tagBuffer.count - 15)
                if safeLength > 0 {
                    let idx = tagBuffer.index(tagBuffer.startIndex, offsetBy: safeLength)
                    thinkingChunk = String(tagBuffer[..<idx])
                    tagBuffer = String(tagBuffer[idx...])
                }
            }
        } else {
            let safeLength = max(0, tagBuffer.count - 15)
            if safeLength > 0 {
                let idx = tagBuffer.index(tagBuffer.startIndex, offsetBy: safeLength)
                contentChunk += String(tagBuffer[..<idx])
                tagBuffer = String(tagBuffer[idx...])
            }
        }

        return (newState, thinkingChunk, contentChunk)
    }

    func finalize(
        thinkingBuffer: [String],
        contentBuffer: [String],
        finalState: ThinkingParserState
    ) -> (thinking: String, content: String) {
        let thinking = thinkingBuffer.joined()
        var content = contentBuffer.joined()
        content = content
            .replacingOccurrences(of: "</think>", with: "")
            .replacingOccurrences(of: "</thinking>", with: "")
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "<thinking>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (thinking, content)
    }
}

// MARK: - Nemo Parser (no opening tag; everything before </think> is thinking)

struct NemoThinkingParser: ThinkingParser {
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String) {
        tagBuffer += chunk
        var thinkingChunk = ""
        var contentChunk = ""
        var newState = currentState == .initial ? .inThinking : currentState

        if newState == .inThinking {
            if let closeRange = tagBuffer.range(of: "</think>") ?? tagBuffer.range(of: "</thinking>") {
                thinkingChunk = String(tagBuffer[..<closeRange.lowerBound])
                tagBuffer = String(tagBuffer[closeRange.upperBound...])
                newState = .inContent
                if !tagBuffer.isEmpty { contentChunk = tagBuffer; tagBuffer = "" }
            } else {
                let safeLength = max(0, tagBuffer.count - 15)
                if safeLength > 0 {
                    let idx = tagBuffer.index(tagBuffer.startIndex, offsetBy: safeLength)
                    thinkingChunk = String(tagBuffer[..<idx])
                    tagBuffer = String(tagBuffer[idx...])
                }
            }
        } else {
            contentChunk = tagBuffer
            tagBuffer = ""
        }

        return (newState, thinkingChunk, contentChunk)
    }

    func finalize(
        thinkingBuffer: [String],
        contentBuffer: [String],
        finalState: ThinkingParserState
    ) -> (thinking: String, content: String) {
        var thinking = thinkingBuffer.joined()
        var content = contentBuffer.joined()
        if finalState == .inThinking {
            content = thinking + content
            thinking = ""
        }
        content = content
            .replacingOccurrences(of: "</think>", with: "")
            .replacingOccurrences(of: "</thinking>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (thinking, content)
    }
}

// MARK: - Separate Field Parser (OpenAI o-series, DeepSeek via API)

struct SeparateFieldThinkingParser: ThinkingParser {
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String) {
        (.inContent, "", chunk)
    }

    func finalize(
        thinkingBuffer: [String],
        contentBuffer: [String],
        finalState: ThinkingParserState
    ) -> (thinking: String, content: String) {
        (thinkingBuffer.joined(), contentBuffer.joined().trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - No Thinking Parser

struct NoThinkingParser: ThinkingParser {
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String) {
        (.inContent, "", chunk)
    }

    func finalize(
        thinkingBuffer: [String],
        contentBuffer: [String],
        finalState: ThinkingParserState
    ) -> (thinking: String, content: String) {
        ("", contentBuffer.joined())
    }
}

// MARK: - Public ThinkingParsers Façade (test surface)

/// Namespace for public utility methods on thinking-token parsing.
public enum ThinkingParsers {
    /// Strip `<think>…</think>` and `<thinking>…</thinking>` blocks from text,
    /// returning only the clean response content.
    public static func stripThinking(from text: String) -> String {
        var working = text

        // Remove properly paired tags and their content
        let pairedPattern = #"<think(?:ing)?>([\s\S]*?)</think(?:ing)?>"#
        if let regex = try? NSRegularExpression(pattern: pairedPattern) {
            let range = NSRange(working.startIndex..., in: working)
            working = regex.stringByReplacingMatches(in: working, range: range, withTemplate: "")
        }

        // Remove orphan closing tags with any leading content (e.g. content before </think>)
        let orphanPattern = #"^([\s\S]*?)</think(?:ing)?>"#
        if let regex = try? NSRegularExpression(pattern: orphanPattern) {
            let range = NSRange(working.startIndex..., in: working)
            working = regex.stringByReplacingMatches(in: working, range: range, withTemplate: "")
        }

        // Strip any stray open/close tags
        working = working
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .replacingOccurrences(of: "<thinking>", with: "")
            .replacingOccurrences(of: "</thinking>", with: "")

        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
