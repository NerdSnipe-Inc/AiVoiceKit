// Sources/AiVoiceKit/macOS/AI/AIProvider.swift
// Adapted from FluidVoice — ModelRepository.defaultBaseURL replaced with AIProviderURLs.
#if os(macOS)
import Foundation

// MARK: - Provider URL Helpers

enum AIProviderURLs {
    static func baseURL(for providerID: AIProviderID) -> String {
        switch providerID {
        case .openai:           return "https://api.openai.com/v1"
        case .groq:             return "https://api.groq.com/openai/v1"
        case .appleintelligence: return ""
        case .off, .custom:     return ""
        }
    }

    static func isLocal(_ urlString: String) -> Bool {
        LLMClient.isLocalEndpoint(urlString)
    }
}

// MARK: - Protocol

protocol AIProvider {
    func process(systemPrompt: String, userText: String, model: String, apiKey: String, baseURL: String, stream: Bool) async -> String
}

// MARK: - OpenAI-Compatible Provider

final class OpenAICompatibleProvider: AIProvider {
    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let reasoning_effort: String?
        let stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, reasoning_effort, stream
        }
    }

    struct ChatChoiceMessage: Codable { let role: String; let content: String }
    struct ChatChoice: Codable { let index: Int?; let message: ChatChoiceMessage }
    struct ChatResponse: Codable { let choices: [ChatChoice] }

    func process(systemPrompt: String, userText: String, model: String, apiKey: String, baseURL: String, stream: Bool = false) async -> String {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://api.openai.com/v1"
            : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        let fullEndpoint: String
        if endpoint.contains("/chat/completions") || endpoint.contains("/api/chat") || endpoint.contains("/api/generate") {
            fullEndpoint = endpoint
        } else {
            fullEndpoint = endpoint + "/chat/completions"
        }

        guard let url = URL(string: fullEndpoint) else { return "Error: Invalid Base URL" }

        let isLocal = AIProviderURLs.isLocal(endpoint)
        let modelLower = model.lowercased()
        let isReasoningModel = LLMClient.isReasoningModel(model)
        let shouldAddReasoningEffort = modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/")

        let body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userText),
            ],
            temperature: isReasoningModel ? nil : 0.2,
            reasoning_effort: shouldAddReasoningEffort ? "low" : nil,
            stream: stream ? true : nil
        )

        guard let jsonData = try? JSONEncoder().encode(body) else { return "Error: Failed to encode request" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !isLocal { request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
                return "Error: HTTP \(http.statusCode): \(errText)"
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return decoded.choices.first?.message.content ?? "<no content>"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
#endif
