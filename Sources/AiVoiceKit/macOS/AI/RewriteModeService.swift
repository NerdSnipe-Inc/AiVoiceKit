// Sources/AiVoiceKit/macOS/AI/RewriteModeService.swift
// Adapted from FluidVoice — rewritten for AiVoiceKit.
// The FluidVoice original depends on ~15 FluidVoice-specific types (SettingsStore,
// AnalyticsService, FileLogger, TextSelectionService, feature not ported, etc.) that
// don't exist here. This version follows the DictationPostProcessingService pattern:
// VoiceSettingsStore + KeychainService + LLMClient + DebugLogger.
#if os(macOS)
import Foundation

// MARK: - RewriteModeService

/// Applies an AI edit instruction to a piece of selected text.
///
/// Usage:
/// ```swift
/// let result = try await RewriteModeService.shared.rewrite(
///     selectedText: "Hello wrold",
///     instruction: "Fix typos"
/// )
/// ```
@MainActor
public final class RewriteModeService: ObservableObject {
    public static let shared = RewriteModeService()

    @Published public private(set) var isProcessing = false
    @Published public private(set) var lastError: String = ""

    private init() {}

    // MARK: - Default system prompt

    private static let defaultSystemPrompt = """
    You are an expert text editor. Apply the user's instruction to the provided text. \
    Output ONLY the rewritten text — no preamble, no explanation, no markdown fences.
    """

    // MARK: - Public API

    /// Rewrites `selectedText` according to `instruction`.
    /// - Parameters:
    ///   - selectedText: The text the user highlighted before speaking.
    ///   - instruction:  The spoken edit instruction (e.g. "make it more formal").
    /// - Returns: The rewritten text, or the original if the LLM call fails.
    public func rewrite(selectedText: String, instruction: String) async -> String {
        let trimmedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty, !trimmedInstruction.isEmpty else { return selectedText }

        isProcessing = true
        lastError = ""
        defer { isProcessing = false }

        do {
            let result = try await callLLM(selectedText: trimmedText, instruction: trimmedInstruction)
            DebugLogger.shared.info(
                "RewriteModeService: rewrite complete (\(result.count) chars)",
                source: "RewriteModeService"
            )
            return result
        } catch {
            lastError = error.localizedDescription
            DebugLogger.shared.error(
                "RewriteModeService: \(error.localizedDescription)",
                source: "RewriteModeService"
            )
            return selectedText
        }
    }

    // MARK: - LLM call

    private func callLLM(selectedText: String, instruction: String) async throws -> String {
        let settings = VoiceSettingsStore.shared
        let provider = settings.selectedAIProvider

        // Apple Intelligence path
        if provider == .appleintelligence {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                guard AppleIntelligenceService.isAvailable else {
                    throw AIProcessingError.appleIntelligenceUnavailable
                }
                let appleProvider = AppleIntelligenceProvider()
                let userMessage = buildUserMessage(selectedText: selectedText, instruction: instruction)
                let output = try await appleProvider.process(
                    systemPrompt: Self.defaultSystemPrompt,
                    userText: userMessage
                )
                guard !output.isEmpty else { throw AIProcessingError.emptyResponse }
                return output
            }
            #endif
            throw AIProcessingError.appleIntelligenceUnavailable
        }

        // Cloud provider path
        guard provider != .off else { throw AIProcessingError.noProviderConfigured }

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

        let userMessage = buildUserMessage(selectedText: selectedText, instruction: instruction)
        let messages: [[String: Any]] = [
            ["role": "system", "content": Self.defaultSystemPrompt],
            ["role": "user",   "content": userMessage],
        ]

        var config = LLMClient.Config(
            messages: messages,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            streaming: false,
            temperature: LLMClient.isReasoningModel(model) ? nil : 0.7
        )
        config.timeoutSeconds = 120

        let response = try await LLMClient.shared.call(config)
        guard !response.content.isEmpty else { throw AIProcessingError.emptyResponse }
        return response.content
    }

    // MARK: - Prompt construction

    private func buildUserMessage(selectedText: String, instruction: String) -> String {
        """
        Instruction: \(instruction)

        Text to edit:
        \(selectedText)
        """
    }
}
#endif
