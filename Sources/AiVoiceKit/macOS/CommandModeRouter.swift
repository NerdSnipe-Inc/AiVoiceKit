// Sources/AiVoiceKit/macOS/CommandModeRouter.swift
#if os(macOS)
import Foundation

public enum CommandModeRouter {
    /// Ordered longest-first so "hey alric," matches before "alric,".
    private static let prefixPatterns: [String] = [
        "hey alric, ",
        "hey alric,",
        "hey alric. ",
        "hey alric.",
        "hey alric ",
        "alric, ",
        "alric,",
        "alric. ",
        "alric.",
        "alric ",
    ]

    /// Returns the command text if this utterance targets Alric; nil if the
    /// remainder is empty or the text does not begin with a recognised prefix.
    public static func extractCommand(from text: String) -> String? {
        let lower = text.lowercased()
        for pattern in prefixPatterns {
            if lower.hasPrefix(pattern) {
                let remainder = text.dropFirst(pattern.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return remainder.isEmpty ? nil : remainder
            }
        }
        return nil
    }

    /// Routes text to the command callback if it starts with an "Alric" prefix.
    /// Returns `true` if the text was consumed as a command, `false` if it is
    /// plain dictation and should be typed into the frontmost app.
    @discardableResult
    @MainActor
    public static func route(
        text: String,
        onCommandReceived: (String) async -> Void
    ) async -> Bool {
        guard let command = extractCommand(from: text) else { return false }
        await onCommandReceived(command)
        return true
    }
}
#endif
