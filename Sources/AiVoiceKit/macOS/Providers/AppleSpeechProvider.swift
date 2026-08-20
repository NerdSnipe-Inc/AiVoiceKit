// Sources/AiVoiceKit/macOS/Providers/AppleSpeechProvider.swift
// Ported from FluidVoice/Sources/Fluid/Services/AppleSpeechProvider.swift
// Changes: adapted to the new streaming TranscriptionProvider protocol (start/stop/partialTranscript),
//          replaced SettingsStore with Locale.current, removed FluidVoice-specific types.
#if os(macOS)
import AVFoundation
import Combine
import Foundation
import Speech
import os

/// A `TranscriptionProvider` backed by Apple's `SFSpeechRecognizer`.
///
/// Uses `AVAudioEngine` to capture live microphone audio and feeds it into
/// `SFSpeechAudioBufferRecognitionRequest` for streaming partial results.
/// Available on macOS 10.15+.
final class AppleSpeechProvider: TranscriptionProvider, @unchecked Sendable {

    /// Routes to the unified system log (visible in Console.app / `log stream`), unlike
    /// `DebugLogger` which is in-memory-only and off by default — needed to actually diagnose
    /// "recording shows active but nothing transcribes" from outside the running process.
    private static let logger = Logger(subsystem: "com.nerdsnipe.aivoicekit", category: "AppleSpeechProvider")

    // MARK: - TranscriptionProvider

    private let _partialTranscriptSubject = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partialTranscriptSubject.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    // MARK: - Private state

    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var accumulatedText: String = ""

    /// Guards `stopContinuation`. Called from main actor (start/stop) and the recognition callback
    /// (an unstructured DispatchQueue). NSLock is the lightest option here.
    private let contLock = NSLock()
    private var stopContinuation: CheckedContinuation<String, Error>?

    // MARK: - Init

    init() {}

    // MARK: - TranscriptionProvider conformance

    func start(inputDeviceUID: String?) async throws {
        // 0. Microphone authorization — must precede any AVAudioEngine.inputNode use (see
        // MicrophonePermission.swift): without it, installTap crashes instead of throwing.
        try await MicrophonePermission.ensureAuthorized()

        // 1. Authorization
        let status = await requestAuthorization()
        guard status == .authorized else {
            throw Self.makeError(code: 1, description: "Speech recognition not authorized. Grant access in System Settings > Privacy > Speech Recognition.")
        }

        // 2. Recognizer — prefer current locale, fall back to en-US
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw Self.makeError(code: 2, description: "SFSpeechRecognizer is not available right now.")
        }
        self.recognizer = recognizer
        Self.logger.notice("recognizer ready: locale=\(recognizer.locale.identifier, privacy: .public) onDeviceSupported=\(recognizer.supportsOnDeviceRecognition, privacy: .public)")

        // 3. Audio engine
        let engine = AVAudioEngine()

        // Device selection: if a UID is given, try to steer the input node.
        // Task 5 expands this with full AudioUnit device routing.
        if let uid = inputDeviceUID, !uid.isEmpty {
            DebugLogger.shared.debug("AppleSpeechProvider: requesting input device UID=\(uid) (full routing in Task 5)", source: "AppleSpeechProvider")
        }

        self.audioEngine = engine

        // 4. Recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device when available, not server-based: matches this app's own on-device-only
        // positioning, and avoids a real production bug — network-based recognition returned "No
        // speech detected" for genuine, correctly-captured microphone audio (confirmed via live
        // buffer counts). Only forced when the recognizer actually supports it for this locale —
        // requiring it unconditionally would make recognition fail outright on locales where
        // on-device isn't available at all.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.recognitionRequest = request

        accumulatedText = ""
        _partialTranscriptSubject.send("")
        isStreaming = true

        // 5. Microphone tap → recognition request
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        Self.logger.notice("inputFormat: channels=\(inputFormat.channelCount, privacy: .public) sampleRate=\(inputFormat.sampleRate, privacy: .public)")
        var bufferCount = 0
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            bufferCount += 1
            // Peak amplitude per buffer — distinguishes "real audio, recognizer just isn't
            // matching it" from "silence is being captured" (wrong/muted input device), which
            // frame count and channel count alone can't tell apart.
            var peak: Float = 0
            if let channelData = buffer.floatChannelData {
                let samples = channelData[0]
                for i in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(samples[i]))
                }
            }
            if bufferCount <= 5 || bufferCount % 20 == 0 {
                Self.logger.notice("tap buffer #\(bufferCount, privacy: .public) frameLength=\(buffer.frameLength, privacy: .public) peak=\(peak, privacy: .public)")
            }
            self?.recognitionRequest?.append(buffer)
        }

        // 6. Recognition task — publishes partials and resumes stop() via continuation
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                Self.logger.notice("result: len=\(text.count, privacy: .public) isFinal=\(result.isFinal, privacy: .public)")
                self._partialTranscriptSubject.send(text)
                self.accumulatedText = text
                if result.isFinal {
                    self.resumeStopContinuation(with: text)
                }
            }

            if let error {
                let nsError = error as NSError
                // Domain "kAFAssistantErrorDomain" code 216 = "No speech detected"
                // Domain "kAFAssistantErrorDomain" code 1110 = recognition task was cancelled — both are expected.
                let isExpected = (nsError.code == 216 || nsError.code == 1110 || nsError.code == 203)
                Self.logger.notice("callback error: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) expected=\(isExpected, privacy: .public) desc=\(error.localizedDescription, privacy: .public)")
                if !isExpected {
                    DebugLogger.shared.warning("AppleSpeechProvider recognition error: \(error.localizedDescription)", source: "AppleSpeechProvider")
                }
                self.resumeStopContinuation(with: self.accumulatedText)
            }
        }

        try engine.start()
        Self.logger.notice("engine.start() succeeded, isRunning=\(engine.isRunning, privacy: .public)")
        DebugLogger.shared.info("AppleSpeechProvider started", source: "AppleSpeechProvider")
    }

    /// Signals end of speech, waits for `SFSpeechRecognizer` to deliver its final result,
    /// and returns the accumulated transcript.
    func stop() async throws -> String {
        isStreaming = false
        DebugLogger.shared.info("AppleSpeechProvider stopping", source: "AppleSpeechProvider")

        return try await withCheckedThrowingContinuation { [self] cont in
            // Protect against a race where the recognition task already finished.
            contLock.lock()
            let alreadyDone = stopContinuation != nil
            if !alreadyDone {
                stopContinuation = cont
            }
            contLock.unlock()

            if alreadyDone {
                // The continuation was already set — caller is racing stop() against itself.
                cont.resume(returning: accumulatedText)
                return
            }

            // Signal end of audio; the recognizer will fire its final result callback.
            recognitionRequest?.endAudio()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
        }
    }

    func cancelAndStop() async {
        isStreaming = false
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        resumeStopContinuation(with: accumulatedText)
        _partialTranscriptSubject.send("")
        DebugLogger.shared.info("AppleSpeechProvider cancelled", source: "AppleSpeechProvider")
    }

    // MARK: - Private helpers

    private func resumeStopContinuation(with text: String) {
        contLock.lock()
        let cont = stopContinuation
        stopContinuation = nil
        contLock.unlock()
        cont?.resume(returning: text)
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private static func makeError(code: Int, description: String) -> NSError {
        NSError(domain: "AppleSpeechProvider", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#endif
