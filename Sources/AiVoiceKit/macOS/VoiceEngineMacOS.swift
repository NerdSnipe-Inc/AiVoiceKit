// Sources/AiVoiceKit/macOS/VoiceEngineMacOS.swift
#if os(macOS)
import AppKit
import Combine
import Foundation

/// Main-actor–isolated voice engine for macOS.
///
/// Implements `VoiceEngine` using the Apple Speech provider (Task 3).
/// Tasks 6–9 expand `makeProvider()` with full model routing, command mode,
/// and edit mode.
@MainActor
public final class VoiceEngineMacOS: VoiceEngine {

    // MARK: - VoiceEngine

    @Published public private(set) var state: VoiceEngineState = .idle
    @Published public private(set) var transcript: String = ""
    @Published public var selectedASRModel: ASRModel {
        didSet { VoiceSettingsStore.shared.selectedASRModel = selectedASRModel }
    }
    public var settings: VoiceSettings { VoiceSettingsStore.shared.settings }

    // MARK: - Private

    /// Called when voice recognition produces an "Alric, …" command utterance.
    /// Updated by the host app after the view hierarchy is ready (see ContentView).
    public var onCommandReceived: (String) async -> Void
    /// Called in edit mode with (selectedText, instruction); returns the replacement.
    /// Updated by the host app after the view hierarchy is ready (see ContentView).
    public var onEditRequested: (String, String) async -> String
    private var currentProvider: (any TranscriptionProvider)?
    private var cancellables = Set<AnyCancellable>()
    /// Separate bag for overlay observations — not cleared between recording sessions.
    private var overlayCancellables = Set<AnyCancellable>()
    private var pendingEditSelectedText: String?
    private var hotkeyManager: VoiceHotkeyManager?

    // MARK: - Init

    public init(
        onCommandReceived: @escaping (String) async -> Void,
        onEditRequested: @escaping (String, String) async -> String = { _, _ in "" }
    ) {
        self.onCommandReceived = onCommandReceived
        self.onEditRequested = onEditRequested
        self.selectedASRModel = VoiceSettingsStore.shared.selectedASRModel
        setupOverlayObservation()
    }

    // MARK: - Overlay observation

    private func setupOverlayObservation() {
        $state
            .receive(on: RunLoop.main)
            .sink { newState in
                switch newState {
                case .recording(let mode):
                    NotchOverlayManager.shared.show(mode: mode)
                case .idle, .error:
                    NotchOverlayManager.shared.hide()
                case .processing:
                    NotchOverlayManager.shared.showProcessing()
                }
            }
            .store(in: &overlayCancellables)

        $transcript
            .receive(on: RunLoop.main)
            .sink { text in
                NotchOverlayManager.shared.updateTranscript(text)
            }
            .store(in: &overlayCancellables)
    }

    // MARK: - Hotkey setup

    /// Call once after init to enable global hotkeys.
    /// Requires accessibility permissions (AXIsProcessTrusted).
    public func setupHotkeyManager() {
        let manager = VoiceHotkeyManager()
        manager.isRecording = { [weak self] in
            if case .recording = self?.state { return true }
            return false
        }
        manager.onDictationStart = { [weak self] in
            Task { @MainActor in try? await self?.startDictation() }
        }
        manager.onDictationStop = { [weak self] in
            Task { @MainActor in _ = await self?.stopDictation() }
        }
        manager.onCommandModeStart = { [weak self] in
            Task { @MainActor in try? await self?.startCommandMode() }
        }
        manager.onCancelRecording = { [weak self] in
            Task { @MainActor in
                _ = await self?.stopDictation()
                await self?.stopCommandMode()
            }
        }

        // Load the user's configured shortcut. Activation mode is read live from VoiceSettingsStore.
        manager.primaryShortcuts = [VoiceSettingsStore.shared.hotkeyShortcut]

        self.hotkeyManager = manager
    }

    /// Call after the user changes their hotkey in Settings to apply it immediately.
    public func updateHotkeyShortcut(_ shortcut: HotkeyShortcut) {
        hotkeyManager?.primaryShortcuts = [shortcut]
    }

    // MARK: - Provider factory

    private func makeProvider() -> any TranscriptionProvider {
        let model = VoiceSettingsStore.shared.selectedASRModel
        guard ModelRepository.shared.isDownloaded(model) else {
            DebugLogger.shared.warning(
                "Model \(model.rawValue) not downloaded, falling back to Apple Speech",
                source: "VoiceEngineMacOS"
            )
            return AppleSpeechProvider()
        }
        switch model {
        case .appleSpeech:
            return AppleSpeechProvider()
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return WhisperProvider(model: model)
        case .parakeetFlash, .parakeetV2, .parakeetV3:
            return ParakeetRealtimeProvider(model: model)
        case .nemotronFast, .nemotronMultilingual:
            if #available(macOS 14.0, *) {
                return NemotronProvider(model: model)
            } else {
                DebugLogger.shared.warning(
                    "Nemotron requires macOS 14+, falling back to Apple Speech",
                    source: "VoiceEngineMacOS"
                )
                return AppleSpeechProvider()
            }
        case .cohereTranscribe:
            if #available(macOS 15.0, *) {
                return CohereProvider()
            } else {
                DebugLogger.shared.warning(
                    "Cohere requires macOS 15+, falling back to Apple Speech",
                    source: "VoiceEngineMacOS"
                )
                return AppleSpeechProvider()
            }
        }
    }

    // MARK: - VoiceEngine conformance

    public func startDictation() async throws {
        guard state == .idle else { return }
        state = .recording(mode: .dictation)
        transcript = ""

        let provider = makeProvider()
        currentProvider = provider
        provider.partialTranscript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.transcript = t }
            .store(in: &cancellables)

        try await provider.start(inputDeviceUID: VoiceSettingsStore.shared.settings.selectedInputDeviceUID)
    }

    public func stopDictation() async -> String? {
        guard case .recording = state else { return nil }
        state = .processing
        do {
            let text = try await currentProvider?.stop() ?? ""
            currentProvider = nil
            cancellables.removeAll()
            transcript = ""
            state = .idle
            if !text.isEmpty {
                await CommandModeRouter.route(text: text, onCommandReceived: onCommandReceived)
            }
            return text.isEmpty ? nil : text
        } catch {
            currentProvider = nil
            cancellables.removeAll()
            transcript = ""
            state = .error(error.localizedDescription)
            return nil
        }
    }

    public func startCommandMode() async throws {
        // Implemented in Task 8
        state = .recording(mode: .command)
    }

    public func stopCommandMode() async {
        state = .idle
    }

    public func startEditMode(selectedText: String) async throws {
        guard state == .idle else { return }
        state = .recording(mode: .edit)
        transcript = ""
        pendingEditSelectedText = selectedText

        let provider = makeProvider()
        currentProvider = provider
        provider.partialTranscript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.transcript = t }
            .store(in: &cancellables)

        try await provider.start(inputDeviceUID: VoiceSettingsStore.shared.settings.selectedInputDeviceUID)
    }

    /// Transcribe a complete audio or video file using the currently selected ASR model.
    /// The model must conform to `FileTranscriptionProvider`; returns `nil` if the
    /// current provider does not support file transcription.
    public func startFileTranscription(url: URL) async throws -> TranscriptionResult? {
        let provider = makeProvider()
        guard let fileProvider = provider as? any FileTranscriptionProvider else {
            DebugLogger.shared.warning(
                "Current provider does not support file transcription",
                source: "VoiceEngineMacOS"
            )
            return nil
        }
        let service = MeetingTranscriptionService(provider: fileProvider)
        return try await service.transcribeFile(url)
    }

    public func stopEditMode() async -> String? {
        guard case .recording(mode: .edit) = state else { return nil }
        state = .processing
        defer {
            state = .idle
            transcript = ""
        }
        let instruction = (try? await currentProvider?.stop()) ?? ""
        currentProvider = nil
        cancellables.removeAll()
        guard !instruction.isEmpty, let selected = pendingEditSelectedText else {
            pendingEditSelectedText = nil
            return nil
        }
        pendingEditSelectedText = nil
        return await onEditRequested(selected, instruction)
    }
}
#endif
