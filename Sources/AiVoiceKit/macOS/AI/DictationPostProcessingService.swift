// Sources/AiVoiceKit/macOS/AI/DictationPostProcessingService.swift
// Adapted from FluidVoice — cloud provider paths removed; simplified to VoiceSettingsStore + KeychainService.
#if os(macOS)
import Combine
import Foundation

// MARK: - Errors

public enum AIProcessingError: Error, LocalizedError {
    case noProviderConfigured
    case missingModel(provider: String)
    case missingAPIKey(provider: String)
    case emptyResponse
    case appleIntelligenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .noProviderConfigured:          return "No AI provider is configured."
        case let .missingModel(p):           return "No model selected for provider '\(p)'."
        case let .missingAPIKey(p):          return "API key missing for provider '\(p)'."
        case .emptyResponse:                 return "The AI returned an empty response."
        case .appleIntelligenceUnavailable:  return "Apple Intelligence is not available on this device."
        }
    }
}

// MARK: - Service

/// Applies AI post-processing to a raw ASR transcript.
///
/// Call `process(transcript:)` — it always returns a `String`.
/// On any error the original transcript is returned unchanged and `lastError` is set.
@MainActor
public final class DictationPostProcessingService: ObservableObject {
    public static let shared = DictationPostProcessingService()

    @Published public private(set) var isProcessing: Bool = false
    @Published public private(set) var lastError: String = ""

    private init() {}

    // MARK: - Default System Prompt

    private static let defaultSystemPrompt = """
    You are a transcription editor. Clean up the following dictated text: \
    fix punctuation, capitalisation, and obvious speech-recognition errors. \
    Preserve the speaker's words and intent exactly. Return only the corrected text.
    """

    // MARK: - Process

    /// Process a raw transcript. Returns the enhanced text, or the original if AI is disabled or fails.
    public func process(transcript: String) async -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        let settings = VoiceSettingsStore.shared
        guard settings.selectedAIProvider != .off,
              settings.dictationPromptMode != .off else { return transcript }

        isProcessing = true
        lastError = ""
        defer { isProcessing = false }

        do {
            return try await performAIProcessing(transcript: trimmed, settings: settings)
        } catch {
            lastError = error.localizedDescription
            DebugLogger.shared.error(
                "DictationPostProcessingService: \(error.localizedDescription)",
                source: "DictationPostProcessingService"
            )
            return trimmed
        }
    }

    // MARK: - Internal

    private func performAIProcessing(transcript: String, settings: VoiceSettingsStore) async throws -> String {
        let provider = settings.selectedAIProvider

        // Apple Intelligence path
        if provider == .appleintelligence {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                guard AppleIntelligenceService.isAvailable else { throw AIProcessingError.appleIntelligenceUnavailable }
                let appleProvider = AppleIntelligenceProvider()
                let systemPrompt = effectiveSystemPrompt(settings: settings)
                let userMessage = buildUserMessage(systemPrompt: systemPrompt, transcript: transcript)
                let output = try await appleProvider.process(systemPrompt: "", userText: userMessage)
                guard !output.isEmpty else { throw AIProcessingError.emptyResponse }
                return output
            }
            #endif
            throw AIProcessingError.appleIntelligenceUnavailable
        }

        // Cloud provider path
        let model = settings.selectedAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIProcessingError.missingModel(provider: provider.rawValue) }

        let baseURL = AIProviderURLs.baseURL(for: provider)
        let apiKey: String
        if LLMClient.isLocalEndpoint(baseURL) {
            apiKey = ""
        } else {
            let stored = (try? KeychainService.shared.fetchKey(for: provider.rawValue)) ?? ""
            let trimmedKey = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { throw AIProcessingError.missingAPIKey(provider: provider.rawValue) }
            apiKey = trimmedKey
        }

        let systemPrompt = effectiveSystemPrompt(settings: settings)
        let userMessage = buildUserMessage(systemPrompt: systemPrompt, transcript: transcript)

        var messages: [[String: Any]] = []
        messages.append(["role": "user", "content": userMessage])

        var config = LLMClient.Config(
            messages: messages,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            streaming: false,
            temperature: LLMClient.isReasoningModel(model) ? nil : 0.2
        )
        config.timeoutSeconds = 120

        let response = try await LLMClient.shared.call(config)
        guard !response.content.isEmpty else { throw AIProcessingError.emptyResponse }
        return response.content
    }

    private func effectiveSystemPrompt(settings: VoiceSettingsStore) -> String {
        switch settings.dictationPromptMode {
        case .custom:
            let custom = settings.customDictationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? Self.defaultSystemPrompt : custom
        case .default, .off:
            return Self.defaultSystemPrompt
        }
    }

    private func buildUserMessage(systemPrompt: String, transcript: String) -> String {
        "\(systemPrompt)\n\nTranscript:\n\(transcript)"
    }
}
#endif
