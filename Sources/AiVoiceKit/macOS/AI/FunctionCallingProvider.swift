// Sources/AiVoiceKit/macOS/AI/FunctionCallingProvider.swift
// Adapted from FluidVoice — ModelRepository.defaultBaseURL replaced with inline fallback.
#if os(macOS)
import Foundation

/// Extends the OpenAI-compatible chat completions API to support function/tool calling.
final class FunctionCallingProvider {
    struct FunctionCall: Codable {
        let name: String
        let arguments: String
    }

    struct ToolCall: Codable {
        let id: String
        let type: String
        let function: FunctionCall
    }

    struct ChatMessage: Codable {
        let role: String
        let content: String?
        let tool_calls: [ToolCall]
        let tool_call_id: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case role, content, tool_calls, tool_call_id, name
        }

        init(role: String, content: String?, tool_calls: [ToolCall] = [], tool_call_id: String? = nil, name: String? = nil) {
            self.role = role; self.content = content
            self.tool_calls = tool_calls; self.tool_call_id = tool_call_id; self.name = name
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try c.decode(String.self, forKey: .role)
            self.content = try c.decodeIfPresent(String.self, forKey: .content)
            self.tool_calls = try c.decodeIfPresent([ToolCall].self, forKey: .tool_calls) ?? []
            self.tool_call_id = try c.decodeIfPresent(String.self, forKey: .tool_call_id)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(self.role, forKey: .role)
            try c.encodeIfPresent(self.content, forKey: .content)
            if !self.tool_calls.isEmpty { try c.encode(self.tool_calls, forKey: .tool_calls) }
            try c.encodeIfPresent(self.tool_call_id, forKey: .tool_call_id)
            try c.encodeIfPresent(self.name, forKey: .name)
        }
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let tools: [[String: Any]]
        let tool_choice: String?

        enum CodingKeys: String, CodingKey { case model, messages, temperature, tools, tool_choice }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(messages, forKey: .messages)
            try c.encodeIfPresent(temperature, forKey: .temperature)
            try c.encodeIfPresent(tool_choice, forKey: .tool_choice)
            if !tools.isEmpty {
                let toolsData = try JSONSerialization.data(withJSONObject: tools)
                let toolsArray = try JSONDecoder().decode([AnyCodable].self, from: toolsData)
                try c.encode(toolsArray, forKey: .tools)
            }
        }
    }

    struct ChatChoice: Codable { let index: Int?; let message: ChatMessage; let finish_reason: String? }
    struct ChatResponse: Codable { let choices: [ChatChoice] }

    struct AnyCodable: Codable {
        let value: Any
        init(_ value: Any) { self.value = value }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let dict = try? c.decode([String: AnyCodable].self) { self.value = dict.mapValues { $0.value } }
            else if let arr = try? c.decode([AnyCodable].self) { self.value = arr.map { $0.value } }
            else if let s = try? c.decode(String.self) { self.value = s }
            else if let i = try? c.decode(Int.self) { self.value = i }
            else if let d = try? c.decode(Double.self) { self.value = d }
            else if let b = try? c.decode(Bool.self) { self.value = b }
            else { self.value = NSNull() }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            if let dict = value as? [String: Any] { try c.encode(dict.mapValues { AnyCodable($0) }) }
            else if let arr = value as? [Any] { try c.encode(arr.map { AnyCodable($0) }) }
            else if let s = value as? String { try c.encode(s) }
            else if let i = value as? Int { try c.encode(i) }
            else if let d = value as? Double { try c.encode(d) }
            else if let b = value as? Bool { try c.encode(b) }
            else { try c.encodeNil() }
        }
    }

    enum LLMResult {
        case textResponse(String)
        case toolCalls([(name: String, arguments: [String: Any], callId: String)])
        case error(String)
    }

    // MARK: - Process With Tools

    func processWithTools(
        userText: String,
        conversationHistory: [ChatMessage],
        tools: [[String: Any]],
        model: String,
        apiKey: String,
        baseURL: String
    ) async -> LLMResult {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://api.openai.com/v1"
            : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        let fullEndpoint = endpoint.contains("/chat/completions") ||
                           endpoint.contains("/api/chat") ||
                           endpoint.contains("/api/generate")
            ? endpoint : endpoint + "/chat/completions"

        guard let url = URL(string: fullEndpoint) else { return .error("Invalid Base URL") }

        let isLocal = LLMClient.isLocalEndpoint(endpoint)
        var messages = conversationHistory
        messages.append(ChatMessage(role: "user", content: userText))

        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: LLMClient.isReasoningModel(model) ? nil : 0.2,
            tools: tools,
            tool_choice: tools.isEmpty ? nil : "auto"
        )

        guard let jsonData = try? JSONEncoder().encode(body) else { return .error("Failed to encode request") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !isLocal { request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                return .error("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let choice = decoded.choices.first else { return .error("No response from LLM") }
            let toolCalls = choice.message.tool_calls
            if !toolCalls.isEmpty {
                let parsed = toolCalls.compactMap { tc -> (name: String, arguments: [String: Any], callId: String)? in
                    guard let argsData = tc.function.arguments.data(using: .utf8),
                          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                    else { return nil }
                    return (tc.function.name, args, tc.id)
                }
                return .toolCalls(parsed)
            }
            return .textResponse(choice.message.content ?? "<no content>")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Continue With Tool Results

    func continueWithToolResults(
        conversationHistory: [ChatMessage],
        toolResults: [(callId: String, toolName: String, result: String)],
        model: String,
        apiKey: String,
        baseURL: String
    ) async -> LLMResult {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://api.openai.com/v1"
            : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        let fullEndpoint = endpoint.contains("/chat/completions") ||
                           endpoint.contains("/api/chat") ||
                           endpoint.contains("/api/generate")
            ? endpoint : endpoint + "/chat/completions"

        guard let url = URL(string: fullEndpoint) else { return .error("Invalid Base URL") }

        let isLocal = LLMClient.isLocalEndpoint(endpoint)

        // Append each tool result as a "tool" role message so the model sees
        // what each tool call returned before generating its follow-up response.
        var messages = conversationHistory
        for result in toolResults {
            messages.append(ChatMessage(
                role: "tool",
                content: result.result,
                tool_call_id: result.callId,
                name: result.toolName
            ))
        }

        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: LLMClient.isReasoningModel(model) ? nil : 0.2,
            tools: [],
            tool_choice: nil
        )
        guard let jsonData = try? JSONEncoder().encode(body) else { return .error("Failed to encode request") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !isLocal { request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                return .error("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let choice = decoded.choices.first else { return .error("No response from LLM") }
            if !choice.message.tool_calls.isEmpty {
                if let content = choice.message.content, !content.isEmpty { return .textResponse(content) }
                return .textResponse("Task completed successfully.")
            }
            return .textResponse(choice.message.content ?? "<no content>")
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
#endif
