// Sources/AiVoiceKit/Public/VoiceSettings.swift
import Foundation

public enum AIProviderID: String, Codable, Sendable, CaseIterable {
    case off, appleintelligence, openai, groq, custom
}

public enum DictationPromptMode: String, Codable, Sendable {
    case off, `default`, custom
}

public enum HotkeyActivationMode: String, Codable, CaseIterable, Sendable {
    case holdToRecord, toggle, doubleTap

    public var displayName: String {
        switch self {
        case .holdToRecord: return "Hold to Record"
        case .toggle:       return "Toggle"
        case .doubleTap:    return "Double Tap"
        }
    }
}

public enum OverlayPosition: String, Codable, CaseIterable, Sendable {
    case notch, bottom
}

public enum OverlaySize: String, Codable, CaseIterable, Sendable {
    case compact, standard, large
}

public struct VoiceSettings: Codable, Equatable, Sendable {
    public var selectedASRModel: ASRModel           = .appleSpeech
    public var selectedAIProvider: AIProviderID     = .appleintelligence
    public var selectedAIModel: String              = ""
    public var dictationPromptMode: DictationPromptMode = .default
    public var customDictationPrompt: String        = ""
    public var hotkeyActivationMode: HotkeyActivationMode = .holdToRecord
    /// The key combination that triggers dictation. Defaults to Right Option (modifier-only).
    #if os(macOS)
    public var hotkeyShortcut: HotkeyShortcut       = HotkeyShortcut(keyCode: 61, modifierFlags: .option)
    #endif
    public var overlayPosition: OverlayPosition     = .notch
    public var overlaySize: OverlaySize             = .compact
    public var enableStreamingPreview: Bool         = true
    public var copyToClipboard: Bool                = false
    public var autoConvertPunctuation: Bool         = true
    public var smartCapitalization: Bool            = true
    public var continuousDictationSpacing: Bool     = true
    public var lowercaseFirstLetter: Bool           = false
    public var removeTrailingPeriod: Bool           = false
    public var pauseMediaDuringDictation: Bool      = false
    public var notifyAIFailures: Bool               = false
    public var saveTranscriptionHistory: Bool       = true
    public var saveAudioWithHistory: Bool           = false
    public var audioHistoryBudgetGB: Double         = 2.0
    public var visualizerNoiseThreshold: Double     = 0.4
    public var transcriptionPreviewCharLimit: Int   = 120
    public var overlayBottomOffset: Double          = 80
    public var weekendsDontBreakStreak: Bool        = false
    public var launchAtStartup: Bool                = false
    public var hideFromDockAndAppSwitcher: Bool     = false
    public var showMainWindowAtLogin: Bool          = true
    public var enableDebugLogs: Bool                = false
    public var shareAnonymousAnalytics: Bool        = false

    // MARK: - Audio Device Selection

    /// CoreAudio UID of the preferred input device (empty string = system default).
    public var selectedInputDeviceUID: String       = ""
    /// CoreAudio UID of the preferred output device (empty string = system default).
    public var selectedOutputDeviceUID: String      = ""

    public init() {}
}
