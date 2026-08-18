// Sources/AiVoiceKit/macOS/AI/DictationAIPostProcessingGate.swift
// Simplified from FluidVoice — cloud provider paths removed;
// fingerprint verification replaced with simple presence check.
#if os(macOS)
import Foundation

/// Shared gating logic for whether dictation AI post-processing is usable.
public enum DictationAIPostProcessingGate {
    /// Returns `true` when AI post-processing can run:
    /// - Dictation prompt mode is not `.off`
    /// - A non-`.off` provider is selected
    /// - An API key exists for cloud providers (or the endpoint is local)
    public static func isConfigured() -> Bool {
        let settings = VoiceSettingsStore.shared
        guard settings.dictationPromptMode != .off else { return false }
        guard settings.selectedAIProvider != .off else { return false }

        // Apple Intelligence needs no API key
        if settings.selectedAIProvider == .appleintelligence {
            return AppleIntelligenceService.isAvailable
        }

        // Cloud providers require a key unless the endpoint is local
        let baseURL = AIProviderURLs.baseURL(for: settings.selectedAIProvider)
        if LLMClient.isLocalEndpoint(baseURL) { return true }

        let providerID = settings.selectedAIProvider.rawValue
        let apiKey = (try? KeychainService.shared.fetchKey(for: providerID)) ?? ""
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns `true` when a model name has been configured (non-empty).
    public static func hasSelectedModel() -> Bool {
        !VoiceSettingsStore.shared.selectedAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
#endif
