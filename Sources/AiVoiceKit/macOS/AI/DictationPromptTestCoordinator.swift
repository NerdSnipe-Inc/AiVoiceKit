// Sources/AiVoiceKit/macOS/AI/DictationPromptTestCoordinator.swift
// Adapted from FluidVoice — no SettingsStore dependencies; minimal changes.
#if os(macOS)
import Combine
import Foundation

/// Coordinates "Prompt Test Mode" for the dictation prompt editor.
/// When active, the dictation flow populates test output in the modal
/// instead of typing into the frontmost app.
@MainActor
public final class DictationPromptTestCoordinator: ObservableObject {
    public static let shared = DictationPromptTestCoordinator()

    @Published public private(set) var isActive: Bool = false
    @Published public private(set) var draftPromptText: String = ""
    @Published public var isProcessing: Bool = false

    @Published public var lastTranscriptionText: String = ""
    @Published public var lastOutputText: String = ""
    @Published public var lastError: String = ""

    private init() {}

    public func activate(draftPromptText: String) {
        self.isActive = true
        self.draftPromptText = draftPromptText
        self.isProcessing = false
        self.lastTranscriptionText = ""
        self.lastOutputText = ""
        self.lastError = ""
    }

    public func deactivate() {
        self.isActive = false
        self.draftPromptText = ""
        self.isProcessing = false
    }

    public func updateDraftPromptText(_ text: String) {
        guard self.isActive else { return }
        self.draftPromptText = text
    }
}
#endif
