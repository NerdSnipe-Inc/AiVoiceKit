// Sources/AiVoiceKit/Shared/VoiceSettingsStore.swift
import Combine
import Foundation

/// Observable settings store for AiVoiceKit.
/// Each VoiceSettings field is a separate @Published property for fine-grained SwiftUI observation.
/// Persists to UserDefaults suite "com.nerdsnipe.alric.voice".
public final class VoiceSettingsStore: ObservableObject {
    public nonisolated(unsafe) static let shared = VoiceSettingsStore()
    private let defaults = UserDefaults(suiteName: "com.nerdsnipe.alric.voice")!

    // MARK: - ASR / AI

    @Published public var selectedASRModel: ASRModel {
        didSet { defaults.set(selectedASRModel.rawValue, forKey: Keys.selectedASRModel) }
    }

    @Published public var selectedAIProvider: AIProviderID {
        didSet { defaults.set(selectedAIProvider.rawValue, forKey: Keys.selectedAIProvider) }
    }

    @Published public var selectedAIModel: String {
        didSet { defaults.set(selectedAIModel, forKey: Keys.selectedAIModel) }
    }

    // MARK: - Dictation prompt

    @Published public var dictationPromptMode: DictationPromptMode {
        didSet { defaults.set(dictationPromptMode.rawValue, forKey: Keys.dictationPromptMode) }
    }

    @Published public var customDictationPrompt: String {
        didSet { defaults.set(customDictationPrompt, forKey: Keys.customDictationPrompt) }
    }

    // MARK: - Hotkey / Activation

    @Published public var hotkeyActivationMode: HotkeyActivationMode {
        didSet { defaults.set(hotkeyActivationMode.rawValue, forKey: Keys.hotkeyActivationMode) }
    }

    #if os(macOS)
    /// The key combination that triggers dictation globally. Persisted as JSON Data.
    @Published public var hotkeyShortcut: HotkeyShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(hotkeyShortcut) {
                defaults.set(data, forKey: Keys.hotkeyShortcut)
            }
        }
    }
    #endif

    // MARK: - Overlay

    @Published public var overlayPosition: OverlayPosition {
        didSet { defaults.set(overlayPosition.rawValue, forKey: Keys.overlayPosition) }
    }

    @Published public var overlaySize: OverlaySize {
        didSet { defaults.set(overlaySize.rawValue, forKey: Keys.overlaySize) }
    }

    @Published public var overlayBottomOffset: Double {
        didSet { defaults.set(overlayBottomOffset, forKey: Keys.overlayBottomOffset) }
    }

    // MARK: - Streaming / Preview

    @Published public var enableStreamingPreview: Bool {
        didSet { defaults.set(enableStreamingPreview, forKey: Keys.enableStreamingPreview) }
    }

    @Published public var transcriptionPreviewCharLimit: Int {
        didSet { defaults.set(transcriptionPreviewCharLimit, forKey: Keys.transcriptionPreviewCharLimit) }
    }

    // MARK: - Post-processing

    @Published public var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    @Published public var autoConvertPunctuation: Bool {
        didSet { defaults.set(autoConvertPunctuation, forKey: Keys.autoConvertPunctuation) }
    }

    @Published public var smartCapitalization: Bool {
        didSet { defaults.set(smartCapitalization, forKey: Keys.smartCapitalization) }
    }

    @Published public var continuousDictationSpacing: Bool {
        didSet { defaults.set(continuousDictationSpacing, forKey: Keys.continuousDictationSpacing) }
    }

    @Published public var lowercaseFirstLetter: Bool {
        didSet { defaults.set(lowercaseFirstLetter, forKey: Keys.lowercaseFirstLetter) }
    }

    @Published public var removeTrailingPeriod: Bool {
        didSet { defaults.set(removeTrailingPeriod, forKey: Keys.removeTrailingPeriod) }
    }

    // MARK: - Behaviour flags

    @Published public var pauseMediaDuringDictation: Bool {
        didSet { defaults.set(pauseMediaDuringDictation, forKey: Keys.pauseMediaDuringDictation) }
    }

    @Published public var notifyAIFailures: Bool {
        didSet { defaults.set(notifyAIFailures, forKey: Keys.notifyAIFailures) }
    }

    @Published public var visualizerNoiseThreshold: Double {
        didSet { defaults.set(visualizerNoiseThreshold, forKey: Keys.visualizerNoiseThreshold) }
    }

    // MARK: - History

    @Published public var saveTranscriptionHistory: Bool {
        didSet { defaults.set(saveTranscriptionHistory, forKey: Keys.saveTranscriptionHistory) }
    }

    @Published public var saveAudioWithHistory: Bool {
        didSet { defaults.set(saveAudioWithHistory, forKey: Keys.saveAudioWithHistory) }
    }

    @Published public var audioHistoryBudgetGB: Double {
        didSet { defaults.set(audioHistoryBudgetGB, forKey: Keys.audioHistoryBudgetGB) }
    }

    // MARK: - App lifecycle

    @Published public var weekendsDontBreakStreak: Bool {
        didSet { defaults.set(weekendsDontBreakStreak, forKey: Keys.weekendsDontBreakStreak) }
    }

    @Published public var launchAtStartup: Bool {
        didSet { defaults.set(launchAtStartup, forKey: Keys.launchAtStartup) }
    }

    @Published public var hideFromDockAndAppSwitcher: Bool {
        didSet { defaults.set(hideFromDockAndAppSwitcher, forKey: Keys.hideFromDockAndAppSwitcher) }
    }

    @Published public var showMainWindowAtLogin: Bool {
        didSet { defaults.set(showMainWindowAtLogin, forKey: Keys.showMainWindowAtLogin) }
    }

    // MARK: - Diagnostics / Analytics

    @Published public var enableDebugLogs: Bool {
        didSet { defaults.set(enableDebugLogs, forKey: Keys.enableDebugLogs) }
    }

    @Published public var shareAnonymousAnalytics: Bool {
        didSet { defaults.set(shareAnonymousAnalytics, forKey: Keys.shareAnonymousAnalytics) }
    }

    // MARK: - Audio Device Selection

    @Published public var selectedInputDeviceUID: String {
        didSet { defaults.set(selectedInputDeviceUID, forKey: Keys.selectedInputDeviceUID) }
    }

    @Published public var selectedOutputDeviceUID: String {
        didSet { defaults.set(selectedOutputDeviceUID, forKey: Keys.selectedOutputDeviceUID) }
    }

    // MARK: - Custom Dictionary

    @Published public var customDictionaryEntries: [CustomDictionaryEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(customDictionaryEntries) {
                defaults.set(data, forKey: Keys.customDictionaryEntries)
            }
        }
    }

    // MARK: - Transcription sounds

    @Published public var enableTranscriptionSounds: Bool {
        didSet { defaults.set(enableTranscriptionSounds, forKey: Keys.enableTranscriptionSounds) }
    }

    @Published public var transcriptionSoundVolume: Float {
        didSet { defaults.set(transcriptionSoundVolume, forKey: Keys.transcriptionSoundVolume) }
    }

    @Published public var transcriptionSoundIndependentVolume: Bool {
        didSet { defaults.set(transcriptionSoundIndependentVolume, forKey: Keys.transcriptionSoundIndependentVolume) }
    }

    // MARK: - Computed aggregate

    /// Assembles a snapshot of the current state as a value-type VoiceSettings struct.
    public var settings: VoiceSettings {
        var s = VoiceSettings()
        s.selectedASRModel = selectedASRModel
        s.selectedAIProvider = selectedAIProvider
        s.selectedAIModel = selectedAIModel
        s.dictationPromptMode = dictationPromptMode
        s.customDictationPrompt = customDictationPrompt
        s.hotkeyActivationMode = hotkeyActivationMode
        s.overlayPosition = overlayPosition
        s.overlaySize = overlaySize
        s.overlayBottomOffset = overlayBottomOffset
        s.enableStreamingPreview = enableStreamingPreview
        s.transcriptionPreviewCharLimit = transcriptionPreviewCharLimit
        s.copyToClipboard = copyToClipboard
        s.autoConvertPunctuation = autoConvertPunctuation
        s.smartCapitalization = smartCapitalization
        s.continuousDictationSpacing = continuousDictationSpacing
        s.lowercaseFirstLetter = lowercaseFirstLetter
        s.removeTrailingPeriod = removeTrailingPeriod
        s.pauseMediaDuringDictation = pauseMediaDuringDictation
        s.notifyAIFailures = notifyAIFailures
        s.visualizerNoiseThreshold = visualizerNoiseThreshold
        s.saveTranscriptionHistory = saveTranscriptionHistory
        s.saveAudioWithHistory = saveAudioWithHistory
        s.audioHistoryBudgetGB = audioHistoryBudgetGB
        s.weekendsDontBreakStreak = weekendsDontBreakStreak
        s.launchAtStartup = launchAtStartup
        s.hideFromDockAndAppSwitcher = hideFromDockAndAppSwitcher
        s.showMainWindowAtLogin = showMainWindowAtLogin
        s.enableDebugLogs = enableDebugLogs
        s.shareAnonymousAnalytics = shareAnonymousAnalytics
        s.selectedInputDeviceUID = selectedInputDeviceUID
        s.selectedOutputDeviceUID = selectedOutputDeviceUID
        return s
    }

    // MARK: - CustomDictionaryEntry

    /// A user-defined spoken trigger → replacement pair used by the ASR post-processor
    /// and Parakeet vocabulary boosting.
    public struct CustomDictionaryEntry: Codable, Identifiable, Sendable, Equatable {
        public var id: UUID
        public var triggers: [String]
        public var replacement: String

        public init(id: UUID = UUID(), triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers
            self.replacement = replacement
        }
    }

    // MARK: - Init

    private init() {
        let d = UserDefaults(suiteName: "com.nerdsnipe.alric.voice")!

        self.selectedASRModel = ASRModel(rawValue: d.string(forKey: Keys.selectedASRModel) ?? "") ?? .appleSpeech
        self.selectedAIProvider = AIProviderID(rawValue: d.string(forKey: Keys.selectedAIProvider) ?? "") ?? .off
        self.selectedAIModel = d.string(forKey: Keys.selectedAIModel) ?? ""

        self.dictationPromptMode = DictationPromptMode(rawValue: d.string(forKey: Keys.dictationPromptMode) ?? "") ?? .default
        self.customDictationPrompt = d.string(forKey: Keys.customDictationPrompt) ?? ""

        self.hotkeyActivationMode = HotkeyActivationMode(rawValue: d.string(forKey: Keys.hotkeyActivationMode) ?? "") ?? .holdToRecord
        #if os(macOS)
        let defaultShortcut = HotkeyShortcut(keyCode: 61, modifierFlags: .option) // Right Option
        if let data = d.data(forKey: Keys.hotkeyShortcut),
           let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            self.hotkeyShortcut = shortcut
        } else {
            self.hotkeyShortcut = defaultShortcut
        }
        #endif

        self.overlayPosition = OverlayPosition(rawValue: d.string(forKey: Keys.overlayPosition) ?? "") ?? .notch
        self.overlaySize = OverlaySize(rawValue: d.string(forKey: Keys.overlaySize) ?? "") ?? .compact
        self.overlayBottomOffset = d.object(forKey: Keys.overlayBottomOffset) as? Double ?? 80.0

        self.enableStreamingPreview = d.object(forKey: Keys.enableStreamingPreview) as? Bool ?? true
        self.transcriptionPreviewCharLimit = d.object(forKey: Keys.transcriptionPreviewCharLimit) as? Int ?? 120

        self.copyToClipboard = d.bool(forKey: Keys.copyToClipboard)
        self.autoConvertPunctuation = d.object(forKey: Keys.autoConvertPunctuation) as? Bool ?? true
        self.smartCapitalization = d.object(forKey: Keys.smartCapitalization) as? Bool ?? true
        self.continuousDictationSpacing = d.object(forKey: Keys.continuousDictationSpacing) as? Bool ?? true
        self.lowercaseFirstLetter = d.bool(forKey: Keys.lowercaseFirstLetter)
        self.removeTrailingPeriod = d.bool(forKey: Keys.removeTrailingPeriod)

        self.pauseMediaDuringDictation = d.bool(forKey: Keys.pauseMediaDuringDictation)
        self.notifyAIFailures = d.bool(forKey: Keys.notifyAIFailures)
        self.visualizerNoiseThreshold = d.object(forKey: Keys.visualizerNoiseThreshold) as? Double ?? 0.4

        self.saveTranscriptionHistory = d.object(forKey: Keys.saveTranscriptionHistory) as? Bool ?? true
        self.saveAudioWithHistory = d.bool(forKey: Keys.saveAudioWithHistory)
        self.audioHistoryBudgetGB = d.object(forKey: Keys.audioHistoryBudgetGB) as? Double ?? 2.0

        self.weekendsDontBreakStreak = d.bool(forKey: Keys.weekendsDontBreakStreak)
        self.launchAtStartup = d.bool(forKey: Keys.launchAtStartup)
        self.hideFromDockAndAppSwitcher = d.bool(forKey: Keys.hideFromDockAndAppSwitcher)
        self.showMainWindowAtLogin = d.object(forKey: Keys.showMainWindowAtLogin) as? Bool ?? true

        self.enableDebugLogs = d.bool(forKey: Keys.enableDebugLogs)
        self.shareAnonymousAnalytics = d.bool(forKey: Keys.shareAnonymousAnalytics)

        self.selectedInputDeviceUID = d.string(forKey: Keys.selectedInputDeviceUID) ?? ""
        self.selectedOutputDeviceUID = d.string(forKey: Keys.selectedOutputDeviceUID) ?? ""

        if let data = d.data(forKey: Keys.customDictionaryEntries),
           let entries = try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data) {
            self.customDictionaryEntries = entries
        } else {
            self.customDictionaryEntries = []
        }

        self.enableTranscriptionSounds = d.object(forKey: Keys.enableTranscriptionSounds) as? Bool ?? false
        self.transcriptionSoundVolume = d.object(forKey: Keys.transcriptionSoundVolume) as? Float ?? 0.5
        self.transcriptionSoundIndependentVolume = d.bool(forKey: Keys.transcriptionSoundIndependentVolume)
    }

    // MARK: - Keys

    private enum Keys {
        static let selectedASRModel = "selectedASRModel"
        static let selectedAIProvider = "selectedAIProvider"
        static let selectedAIModel = "selectedAIModel"
        static let dictationPromptMode = "dictationPromptMode"
        static let customDictationPrompt = "customDictationPrompt"
        static let hotkeyActivationMode = "hotkeyActivationMode"
        static let hotkeyShortcut = "hotkeyShortcut"
        static let overlayPosition = "overlayPosition"
        static let overlaySize = "overlaySize"
        static let overlayBottomOffset = "overlayBottomOffset"
        static let enableStreamingPreview = "enableStreamingPreview"
        static let transcriptionPreviewCharLimit = "transcriptionPreviewCharLimit"
        static let copyToClipboard = "copyToClipboard"
        static let autoConvertPunctuation = "autoConvertPunctuation"
        static let smartCapitalization = "smartCapitalization"
        static let continuousDictationSpacing = "continuousDictationSpacing"
        static let lowercaseFirstLetter = "lowercaseFirstLetter"
        static let removeTrailingPeriod = "removeTrailingPeriod"
        static let pauseMediaDuringDictation = "pauseMediaDuringDictation"
        static let notifyAIFailures = "notifyAIFailures"
        static let visualizerNoiseThreshold = "visualizerNoiseThreshold"
        static let saveTranscriptionHistory = "saveTranscriptionHistory"
        static let saveAudioWithHistory = "saveAudioWithHistory"
        static let audioHistoryBudgetGB = "audioHistoryBudgetGB"
        static let weekendsDontBreakStreak = "weekendsDontBreakStreak"
        static let launchAtStartup = "launchAtStartup"
        static let hideFromDockAndAppSwitcher = "hideFromDockAndAppSwitcher"
        static let showMainWindowAtLogin = "showMainWindowAtLogin"
        static let enableDebugLogs = "enableDebugLogs"
        static let shareAnonymousAnalytics = "shareAnonymousAnalytics"
        static let selectedInputDeviceUID = "selectedInputDeviceUID"
        static let selectedOutputDeviceUID = "selectedOutputDeviceUID"
        static let customDictionaryEntries = "customDictionaryEntries"
        static let enableTranscriptionSounds = "enableTranscriptionSounds"
        static let transcriptionSoundVolume = "transcriptionSoundVolume"
        static let transcriptionSoundIndependentVolume = "transcriptionSoundIndependentVolume"
    }
}
