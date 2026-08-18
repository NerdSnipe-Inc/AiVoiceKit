// Sources/AiVoiceKit/macOS/AI/AppleIntelligenceProvider.swift
// Adapted from FluidVoice — no changes needed besides os(macOS) guard.
#if os(macOS)
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence Availability

enum AppleIntelligenceService {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var isAvailable: Bool {
        guard isSupported else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static var unavailabilityReason: String? {
        if !isSupported { return "Requires macOS 26 (Tahoe) or later" }
        if !isAvailable { return "Enable in System Settings → Apple Intelligence & Siri" }
        return nil
    }
}

// MARK: - Provider

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class AppleIntelligenceProvider {
    func process(systemPrompt: String, userText: String) async throws -> String {
        let session = LanguageModelSession()
        let prompt = systemPrompt.isEmpty ? userText : "\(systemPrompt)\n\n\(userText)"
        let response = try await session.respond(to: prompt)
        return response.content
    }

    func processRewrite(messages: [(role: String, content: String)], systemPrompt: String) async throws -> String {
        let session = LanguageModelSession()
        var fullPrompt = systemPrompt.isEmpty ? "" : "\(systemPrompt)\n\n"
        for message in messages {
            switch message.role {
            case "user":      fullPrompt += "User: \(message.content)\n\n"
            case "assistant": fullPrompt += "Assistant: \(message.content)\n\n"
            default:          break
            }
        }
        fullPrompt += "Assistant:"
        let response = try await session.respond(to: fullPrompt)
        return response.content
    }
}
#endif
#endif
