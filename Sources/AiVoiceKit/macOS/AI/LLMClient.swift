// Sources/AiVoiceKit/macOS/AI/LLMClient.swift
// Adapted from FluidVoice — SettingsStore replaced with inline helpers;
// added testable init(baseURL:apiKey:) and buildRequestBody(model:messages:stream:).
#if os(macOS)
import Foundation

// MARK: - Errors

public enum LLMError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)
    case encodingError
    case timeout(TimeInterval)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:              return "Invalid URL"
        case .invalidResponse:         return "Invalid response from LLM"
        case let .httpError(c, m):     return "HTTP \(c): \(m.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .networkError(e):     return Self.userFacingNetworkMessage(from: e)
        case .encodingError:           return "Failed to encode request"
        case let .timeout(s):          return "Request timed out after \(Int(s)) seconds"
        case let .invalidRequest(m):   return m
        }
    }

    private static func userFacingNetworkMessage(from error: Error) -> String {
        guard let e = error as? URLError else { return "Network error: \(error.localizedDescription)" }
        switch e.code {
        case .notConnectedToInternet:  return "Network error: no internet connection."
        case .timedOut:                return "Network error: request timed out."
        case .cannotFindHost:          return "Network error: could not find API host."
        case .cannotConnectToHost:     return "Network error: could not connect to API host."
        case .networkConnectionLost:   return "Network error: connection dropped during the request."
        default:                       return "Network error: \(e.localizedDescription)"
        }
    }
}

// MARK: - LLMClient

/// Unified LLM communication layer for all AiVoiceKit modes.
/// Not actor-isolated so that `buildRequestBody` is accessible from synchronous test code.
public final class LLMClient: @unchecked Sendable {
    public static let shared = LLMClient(baseURL: "", apiKey: "")

    static let defaultTimeoutSeconds: TimeInterval = 30

    // Stored for testable-init path; call() uses config values instead.
    private let defaultBaseURL: String
    private let defaultAPIKey: String

    private let urlSession: URLSession

    /// Convenience init for testing or single-provider usage.
    public init(baseURL: String, apiKey: String) {
        self.defaultBaseURL = baseURL
        self.defaultAPIKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.defaultTimeoutSeconds
        config.timeoutIntervalForResource = Self.defaultTimeoutSeconds * 2
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public Message Type (test surface)

    public struct ChatMessage {
        public let role: String
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        var asDictionary: [String: Any] { ["role": role, "content": content] }
    }

    // MARK: - Response

    public struct Response {
        public let thinking: String?
        public let content: String
        public let toolCalls: [ToolCall]
    }

    public struct ToolCall {
        public let id: String
        public let name: String
        public let arguments: [String: Any]

        public func getString(_ key: String) -> String? { arguments[key] as? String }
        public func getOptionalString(_ key: String) -> String? {
            guard let v = arguments[key] as? String, !v.isEmpty else { return nil }
            return v
        }
    }

    private struct ResponsesToolCallAccumulator {
        var id: String?
        var callID: String?
        var name: String?
        var arguments: String = ""
    }

    // MARK: - Config

    public struct Config {
        public let messages: [[String: Any]]
        public let model: String
        public let baseURL: String
        public let apiKey: String
        public let streaming: Bool
        public let tools: [[String: Any]]
        public let temperature: Double?
        public var maxTokens: Int?
        public var extraParameters: [String: Any]
        public var maxRetries: Int = 3
        public var retryDelayMs: Int = 200
        public var timeoutSeconds: TimeInterval?

        public var onThinkingStart: (() -> Void)?
        public var onThinkingChunk: ((String) -> Void)?
        public var onThinkingEnd: (() -> Void)?
        public var onContentChunk: ((String) -> Void)?
        public var onToolCallStart: ((String) -> Void)?

        public init(
            messages: [[String: Any]],
            model: String,
            baseURL: String,
            apiKey: String,
            streaming: Bool = true,
            tools: [[String: Any]] = [],
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            extraParameters: [String: Any] = [:]
        ) {
            self.messages = messages
            self.model = model
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.streaming = streaming
            self.tools = tools
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.extraParameters = extraParameters
        }
    }

    // MARK: - Public Test Surface

    /// Build a chat-completions request body. Exposed `public` for unit-testing.
    public func buildRequestBody(model: String, messages: [ChatMessage], stream: Bool) throws -> Data {
        let config = Config(
            messages: messages.map { $0.asDictionary },
            model: model,
            baseURL: defaultBaseURL,
            apiKey: defaultAPIKey,
            streaming: stream
        )
        let body = buildChatCompletionsBody(config)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMError.encodingError
        }
        return data
    }

    // MARK: - Main Entry Point

    public func call(_ config: Config) async throws -> Response {
        var request = try buildRequest(config)
        request.timeoutInterval = config.timeoutSeconds ?? Self.defaultTimeoutSeconds
        return try await executeWithRetry(request: request, config: config)
    }

    private func executeWithRetry(request: URLRequest, config: Config) async throws -> Response {
        var lastError: Error?
        for attempt in 1...config.maxRetries {
            do {
                if config.streaming {
                    if isResponsesRequest(request) {
                        return try await processResponsesStreaming(request: request, config: config)
                    }
                    return try await processStreaming(request: request, config: config)
                } else {
                    return try await processNonStreaming(request: request)
                }
            } catch let error as URLError where isRetryableError(error) {
                lastError = LLMError.networkError(error)
                if attempt < config.maxRetries {
                    let delayNs = UInt64(config.retryDelayMs * 1_000_000 * attempt)
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            } catch let error as URLError {
                throw LLMError.networkError(error)
            } catch {
                throw error
            }
        }
        throw lastError ?? LLMError.networkError(
            NSError(domain: "LLMClient", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Request failed after retries"])
        )
    }

    // MARK: - Request Building

    private func buildRequest(_ config: Config) throws -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw LLMError.invalidURL }

        let useResponses = shouldUseResponsesAPI(for: config, baseURL: base)
        let endpointString = endpoint(for: base, useResponsesAPI: useResponses)
        guard let url = URL(string: endpointString) else { throw LLMError.invalidURL }

        let body = useResponses ? buildResponsesBody(config) : buildChatCompletionsBody(config)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMError.encodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = jsonData
        return request
    }

    private func appendingPath(_ path: String, to base: String) -> String {
        base.hasSuffix("/") ? "\(base)\(path)" : "\(base)/\(path)"
    }

    private func endpoint(for base: String, useResponsesAPI: Bool) -> String {
        if useResponsesAPI {
            if base.contains("/responses") { return base }
            if base.contains("/chat/completions") {
                return base.replacingOccurrences(of: "/chat/completions", with: "/responses")
            }
            return appendingPath("responses", to: base)
        }
        if base.contains("/chat/completions") ||
           base.contains("/api/chat") ||
           base.contains("/api/generate") { return base }
        return appendingPath("chat/completions", to: base)
    }

    private func shouldUseResponsesAPI(for config: Config, baseURL: String) -> Bool {
        if baseURL.contains("/responses") { return true }
        guard let url = URL(string: baseURL),
              url.host?.lowercased() == "api.openai.com" else { return false }
        let m = config.model.lowercased()
        return m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    private func isResponsesRequest(_ request: URLRequest) -> Bool {
        request.url?.path.contains("/responses") == true
    }

    // MARK: - Body Builders (internal for testability)

    func buildChatCompletionsBody(_ config: Config) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model,
            "messages": config.messages,
            "stream": config.streaming,
        ]
        if let temp = config.temperature { body["temperature"] = temp }
        if !config.tools.isEmpty { body["tools"] = config.tools; body["tool_choice"] = "auto" }

        let modelExtras = ThinkingParserFactory.getExtraParameters(for: config.model)
        for (k, v) in modelExtras { body[k] = v }
        for (k, v) in config.extraParameters { body[k] = v }

        if let tokens = config.maxTokens {
            body[Self.isReasoningModel(config.model) ? "max_completion_tokens" : "max_tokens"] = tokens
        }
        return body
    }

    func buildResponsesBody(_ config: Config) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model,
            "input": responsesInput(from: config.messages),
            "store": false,
            "stream": config.streaming,
        ]
        if !config.tools.isEmpty {
            body["tools"] = responsesTools(from: config.tools)
            body["tool_choice"] = "auto"
        }
        if let tokens = config.maxTokens { body["max_output_tokens"] = tokens }
        if let temp = config.temperature { body["temperature"] = temp }

        for (k, v) in ThinkingParserFactory.getExtraParameters(for: config.model) {
            addResponsesExtraParameter(name: k, value: v, to: &body)
        }
        for (k, v) in config.extraParameters {
            addResponsesExtraParameter(name: k, value: v, to: &body)
        }
        return body
    }

    private func addResponsesExtraParameter(name: String, value: Any, to body: inout [String: Any]) {
        if name == "reasoning_effort" { body["reasoning"] = ["effort": value] } else { body[name] = value }
    }

    private func responsesTools(from chatTools: [[String: Any]]) -> [[String: Any]] {
        chatTools.compactMap { chatTool -> [String: Any]? in
            guard chatTool["type"] as? String == "function",
                  let function = chatTool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let parameters = function["parameters"] as? [String: Any] else { return nil }
            var tool: [String: Any] = ["type": "function", "name": name, "parameters": parameters, "strict": false]
            if let desc = function["description"] as? String { tool["description"] = desc }
            return tool
        }
    }

    private func responsesInput(from messages: [[String: Any]]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            if role == "tool" {
                input.append([
                    "type": "function_call_output",
                    "call_id": message["tool_call_id"] as? String ?? "call_unknown",
                    "output": message["content"] as? String ?? "",
                ])
                continue
            }
            if let content = message["content"] as? String, !content.isEmpty {
                input.append(["role": role, "content": content])
            }
            guard let toolCalls = message["tool_calls"] as? [[String: Any]] else { continue }
            for tc in toolCalls {
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                input.append([
                    "type": "function_call",
                    "call_id": tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                    "name": name,
                    "arguments": function["arguments"] as? String ?? "{}",
                ])
            }
        }
        return input
    }

    // MARK: - Non-Streaming

    private func processNonStreaming(request: URLRequest) async throws -> Response {
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LLMError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse
        }
        if isResponsesRequest(request) { return try parseResponsesResponse(json) }
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { throw LLMError.invalidResponse }
        return parseMessageResponse(message)
    }

    // MARK: - Responses API Streaming

    private func processResponsesStreaming(request: URLRequest, config: Config) async throws -> Response {
        let (bytes, response) = try await urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw LLMError.httpError(http.statusCode, String(data: errorData, encoding: .utf8) ?? "")
        }

        var contentBuffer: [String] = []
        var toolCallsByIndex: [Int: ResponsesToolCallAccumulator] = [:]

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            var jsonString = String(line.dropFirst(5))
            if jsonString.hasPrefix(" ") { jsonString = String(jsonString.dropFirst()) }
            if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" { continue }
            guard let jsonData = jsonString.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    contentBuffer.append(delta)
                    config.onContentChunk?(delta)
                }
            case "response.output_item.added", "response.output_item.done":
                guard let item = event["item"] as? [String: Any],
                      item["type"] as? String == "function_call" else { continue }
                let index = event["output_index"] as? Int ?? 0
                var call = toolCallsByIndex[index] ?? ResponsesToolCallAccumulator()
                call.id = item["id"] as? String ?? call.id
                call.callID = item["call_id"] as? String ?? call.callID
                call.name = item["name"] as? String ?? call.name
                if let args = item["arguments"] as? String, !args.isEmpty { call.arguments = args }
                toolCallsByIndex[index] = call
                if let name = call.name { config.onToolCallStart?(name) }
            case "response.function_call_arguments.delta":
                let index = event["output_index"] as? Int ?? 0
                var call = toolCallsByIndex[index] ?? ResponsesToolCallAccumulator()
                call.arguments += event["delta"] as? String ?? ""
                toolCallsByIndex[index] = call
            case "response.function_call_arguments.done":
                let index = event["output_index"] as? Int ?? 0
                var call = toolCallsByIndex[index] ?? ResponsesToolCallAccumulator()
                call.id = event["item_id"] as? String ?? call.id
                call.callID = event["call_id"] as? String ?? call.callID
                call.name = event["name"] as? String ?? call.name
                call.arguments = event["arguments"] as? String ?? call.arguments
                toolCallsByIndex[index] = call
            default: continue
            }
        }

        let toolCalls = toolCallsByIndex.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = toolCallsByIndex[index],
                  let name = call.name,
                  let argsData = call.arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
            else { return nil }
            return ToolCall(id: call.callID ?? call.id ?? "call_\(UUID().uuidString.prefix(8))", name: name, arguments: args)
        }
        return Response(thinking: nil, content: contentBuffer.joined().trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: toolCalls)
    }

    // MARK: - Chat Completions Streaming

    private func processStreaming(request: URLRequest, config: Config) async throws -> Response {
        let (bytes, response) = try await urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw LLMError.httpError(http.statusCode, String(data: errorData, encoding: .utf8) ?? "")
        }

        var parser = ThinkingParserFactory.createParser(for: config.model)
        var state = ThinkingParserState.initial
        var thinkingBuffer: [String] = []
        var contentBuffer: [String] = []
        var tagBuffer = ""
        var useSeparateFields = false
        var toolCallId: String?
        var toolCallName: String?
        var toolCallArguments = ""

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            var jsonString = String(line.dropFirst(5))
            if jsonString.hasPrefix(" ") { jsonString = String(jsonString.dropFirst()) }
            if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" { continue }
            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            let reasoningField = delta["reasoning_content"] as? String ??
                delta["reasoning"] as? String ?? delta["thought"] as? String ?? delta["thinking"] as? String
            if let reasoning = reasoningField {
                useSeparateFields = true
                if state == .initial { state = .inThinking; config.onThinkingStart?() }
                thinkingBuffer.append(reasoning)
                config.onThinkingChunk?(reasoning)
            }

            if let content = delta["content"] as? String {
                if useSeparateFields {
                    if state == .inThinking { state = .inContent; config.onThinkingEnd?() }
                    contentBuffer.append(content)
                    config.onContentChunk?(content)
                    continue
                }
                let previousState = state
                let (newState, thinkChunk, contentChunk) = parser.processChunk(content, currentState: state, tagBuffer: &tagBuffer)
                if previousState != .inThinking && newState == .inThinking { config.onThinkingStart?() }
                if previousState == .inThinking && newState == .inContent { config.onThinkingEnd?() }
                state = newState
                if !thinkChunk.isEmpty { thinkingBuffer.append(thinkChunk); config.onThinkingChunk?(thinkChunk) }
                if !contentChunk.isEmpty { contentBuffer.append(contentChunk); config.onContentChunk?(contentChunk) }
            }

            if let tcs = delta["tool_calls"] as? [[String: Any]], let tc = tcs.first {
                if let id = tc["id"] as? String { toolCallId = id }
                if let function = tc["function"] as? [String: Any] {
                    if let name = function["name"] as? String { toolCallName = name; config.onToolCallStart?(name) }
                    if let args = function["arguments"] as? String { toolCallArguments += args }
                }
            }
        }

        if !tagBuffer.isEmpty {
            if state == .inThinking { thinkingBuffer.append(tagBuffer); config.onThinkingChunk?(tagBuffer) }
            else { contentBuffer.append(tagBuffer); config.onContentChunk?(tagBuffer) }
        }

        let (thinkingText, contentText) = parser.finalize(thinkingBuffer: thinkingBuffer, contentBuffer: contentBuffer, finalState: state)

        var parsedToolCalls: [ToolCall] = []
        if let name = toolCallName,
           let argsData = toolCallArguments.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            parsedToolCalls = [ToolCall(id: toolCallId ?? "call_\(UUID().uuidString.prefix(8))", name: name, arguments: args)]
        }

        return Response(thinking: thinkingText.isEmpty ? nil : thinkingText, content: contentText, toolCalls: parsedToolCalls)
    }

    // MARK: - Response Parsing

    private func parseResponsesResponse(_ json: [String: Any]) throws -> Response {
        guard let output = json["output"] as? [[String: Any]] else { throw LLMError.invalidResponse }
        var contentParts: [String] = []
        var parsedToolCalls: [ToolCall] = []
        for item in output {
            switch item["type"] as? String {
            case "message":
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if part["type"] as? String == "output_text", let text = part["text"] as? String { contentParts.append(text) }
                }
            case "function_call":
                guard let name = item["name"] as? String,
                      let argsString = item["arguments"] as? String,
                      let argsData = argsString.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else { continue }
                parsedToolCalls.append(ToolCall(id: item["call_id"] as? String ?? "call_\(UUID().uuidString.prefix(8))", name: name, arguments: args))
            default: continue
            }
        }
        let rawContent = contentParts.joined()
        let (thinking, cleanedContent) = stripThinkingTags(rawContent)
        return Response(thinking: thinking.isEmpty ? nil : thinking, content: cleanedContent.isEmpty ? rawContent : cleanedContent, toolCalls: parsedToolCalls)
    }

    private func parseMessageResponse(_ message: [String: Any]) -> Response {
        let rawContent = message["content"] as? String ?? ""
        var parsedToolCalls: [ToolCall] = []
        if let tcs = message["tool_calls"] as? [[String: Any]] {
            parsedToolCalls = tcs.compactMap { tc -> ToolCall? in
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let argsString = function["arguments"] as? String,
                      let argsData = argsString.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else { return nil }
                return ToolCall(id: tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))", name: name, arguments: args)
            }
        }
        let (thinking, cleanedContent) = stripThinkingTags(rawContent)
        let reasoningContent = message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? message["thought"] as? String ?? message["thinking"] as? String
        let finalThinking = [thinking, reasoningContent].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return Response(thinking: finalThinking.isEmpty ? nil : finalThinking, content: cleanedContent.isEmpty ? rawContent : cleanedContent, toolCalls: parsedToolCalls)
    }

    // MARK: - Thinking Tag Stripping

    private static let thinkingTagPattern = #"<think(?:ing)?>([\s\S]*?)</think(?:ing)?>"#
    private static let orphanThinkingPattern = #"^([\s\S]*?)</think(?:ing)?>"#

    func stripThinkingTags(_ text: String) -> (thinking: String, content: String) {
        var working = text
        var thinking = ""
        if let regex = try? NSRegularExpression(pattern: Self.thinkingTagPattern) {
            let range = NSRange(working.startIndex..., in: working)
            let matches = regex.matches(in: working, range: range)
            for match in matches {
                if let r = Range(match.range(at: 1), in: working) { thinking += String(working[r]) }
            }
            working = regex.stringByReplacingMatches(in: working, range: range, withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: Self.orphanThinkingPattern) {
            let range = NSRange(working.startIndex..., in: working)
            let matches = regex.matches(in: working, range: range)
            for match in matches {
                if let r = Range(match.range(at: 1), in: working) { thinking += String(working[r]) }
            }
            working = regex.stringByReplacingMatches(in: working, range: range, withTemplate: "")
        }
        working = working
            .replacingOccurrences(of: "</think>", with: "")
            .replacingOccurrences(of: "</thinking>", with: "")
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "<thinking>", with: "")
        return (thinking, working.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Helpers

    private func isRetryableError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default: return false
        }
    }

    static func isReasoningModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") ||
               m.hasPrefix("gpt-5") || m.hasPrefix("gpt-oss") ||
               m.contains("nemotron")
    }

    static func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        let h = host.lowercased()
        if h == "localhost" || h == "127.0.0.1" { return true }
        if h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let octet = Int(parts[1]), octet >= 16 && octet <= 31 { return true }
        }
        return false
    }
}
#endif
