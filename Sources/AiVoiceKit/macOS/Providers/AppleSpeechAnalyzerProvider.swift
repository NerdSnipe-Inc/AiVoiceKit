// Sources/AiVoiceKit/macOS/Providers/AppleSpeechAnalyzerProvider.swift
// Ported from FluidVoice/Sources/Fluid/Services/AppleSpeechAnalyzerProvider.swift
// Changes: adapted to the streaming TranscriptionProvider protocol, replaced SettingsStore
//          with Locale.current, removed FluidVoice-specific types.
#if os(macOS)
@preconcurrency import AVFoundation
import Combine
import Foundation
import Speech

/// A `TranscriptionProvider` backed by Apple's `SpeechAnalyzer` API (macOS 26+).
///
/// Uses `AVAudioEngine` for live audio capture, feeds samples into `SpeechAnalyzer`
/// via an `AsyncStream`, and publishes partial results through Combine.
@available(macOS 26.0, *)
final class AppleSpeechAnalyzerProvider: TranscriptionProvider, @unchecked Sendable {

    // MARK: - TranscriptionProvider

    private let _partialTranscriptSubject = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partialTranscriptSubject.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    // MARK: - Private state

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: SABufferConverter?
    private var accumulatedText: String = ""
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?

    /// Resumed by the results task when iteration ends, delivering the final text to `stop()`.
    private let contLock = NSLock()
    private var stopContinuation: CheckedContinuation<String, Error>?

    // MARK: - Init

    init() {}

    // MARK: - TranscriptionProvider conformance

    func start(inputDeviceUID: String?) async throws {
        let locale = Locale.current

        // 1. Create transcriber
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // 2. Verify locale is supported
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let localeID = normalizedIdentifier(for: locale)
        let isSupported = supportedLocales.map { normalizedIdentifier(for: $0) }.contains(localeID)
        guard isSupported else {
            throw Self.makeError(code: 1, description: "Current locale (\(localeID)) is not supported by SpeechAnalyzer.")
        }

        // 3. Ensure model is installed
        let installedLocales = await SpeechTranscriber.installedLocales
        let isInstalled = installedLocales.map { normalizedIdentifier(for: $0) }.contains(localeID)
        if !isInstalled {
            DebugLogger.shared.info("Downloading speech model for locale: \(localeID)", source: "AppleSpeechAnalyzerProvider")
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await downloader.downloadAndInstall()
            }
        }

        // 4. Resolve audio format and converter
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Self.makeError(code: 4, description: "SpeechAnalyzer could not determine a compatible audio format.")
        }
        self.analyzerFormat = analyzerFormat
        self.converter = SABufferConverter()

        // 5. Set up audio engine
        let engine = AVAudioEngine()
        if let uid = inputDeviceUID, !uid.isEmpty {
            DebugLogger.shared.debug("AppleSpeechAnalyzerProvider: input device UID=\(uid) (full routing in Task 5)", source: "AppleSpeechAnalyzerProvider")
        }
        self.audioEngine = engine

        // 6. Create the input stream
        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputCont

        // 7. Create analyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // 8. Microphone tap — converts and feeds into the analyzer stream
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let conv = self.converter
        let requiredFormat = analyzerFormat   // non-optional after guard above

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let cont = self.inputContinuation else { return }
            let converted: AVAudioPCMBuffer
            if let conv {
                converted = (try? conv.convertBuffer(buffer, to: requiredFormat)) ?? buffer
            } else {
                converted = buffer
            }
            cont.yield(AnalyzerInput(buffer: converted))
        }

        accumulatedText = ""
        _partialTranscriptSubject.send("")
        isStreaming = true

        // 9. Start the analyzer in a detached task
        self.analyzerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.analyzer?.start(inputSequence: inputStream)
            } catch {
                DebugLogger.shared.warning("SpeechAnalyzer start error: \(error.localizedDescription)", source: "AppleSpeechAnalyzerProvider")
            }
        }

        // 10. Collect results in a detached task; resumes stopContinuation when done
        self.resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if !text.isEmpty {
                        self._partialTranscriptSubject.send(text)
                        if result.isFinal {
                            if !self.accumulatedText.isEmpty { self.accumulatedText += " " }
                            self.accumulatedText += text
                        }
                    }
                }
            } catch {
                DebugLogger.shared.warning("SpeechAnalyzer results error: \(error.localizedDescription)", source: "AppleSpeechAnalyzerProvider")
            }
            // Results stream closed — deliver to stop() caller
            self.resumeStopContinuation(with: self.accumulatedText)
            DebugLogger.shared.info("AppleSpeechAnalyzerProvider results complete: '\(self.accumulatedText)'", source: "AppleSpeechAnalyzerProvider")
        }

        try engine.start()
        DebugLogger.shared.info("AppleSpeechAnalyzerProvider started for locale \(localeID)", source: "AppleSpeechAnalyzerProvider")
    }

    func stop() async throws -> String {
        isStreaming = false
        DebugLogger.shared.info("AppleSpeechAnalyzerProvider stopping", source: "AppleSpeechAnalyzerProvider")

        return try await withCheckedThrowingContinuation { [self] cont in
            contLock.lock()
            let alreadyHasCont = stopContinuation != nil
            if !alreadyHasCont { stopContinuation = cont }
            contLock.unlock()

            if alreadyHasCont {
                cont.resume(returning: accumulatedText)
                return
            }

            // Close the input stream — SpeechAnalyzer will finalize and close transcriber.results
            inputContinuation?.finish()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()

            // Finalize in a task; resumeStopContinuation is called from resultsTask when done
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.analyzer?.finalizeAndFinishThroughEndOfInput()
                } catch {
                    DebugLogger.shared.warning("SpeechAnalyzer finalize error: \(error.localizedDescription)", source: "AppleSpeechAnalyzerProvider")
                    self.resumeStopContinuation(with: self.accumulatedText)
                }
            }
        }
    }

    func cancelAndStop() async {
        isStreaming = false
        resultsTask?.cancel()
        analyzerTask?.cancel()
        inputContinuation?.finish()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        resumeStopContinuation(with: accumulatedText)
        _partialTranscriptSubject.send("")
        DebugLogger.shared.info("AppleSpeechAnalyzerProvider cancelled", source: "AppleSpeechAnalyzerProvider")
    }

    // MARK: - Private helpers

    private func resumeStopContinuation(with text: String) {
        contLock.lock()
        let cont = stopContinuation
        stopContinuation = nil
        contLock.unlock()
        cont?.resume(returning: text)
    }

    private func normalizedIdentifier(for locale: Locale) -> String {
        locale.identifier(.bcp47).replacingOccurrences(of: "_", with: "-")
    }

    private static func makeError(code: Int, description: String) -> NSError {
        NSError(domain: "AppleSpeechAnalyzerProvider", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

// MARK: - Buffer Converter (adapted from Apple's SpeechAnalyzer sample)

@available(macOS 26.0, *)
private final class SABufferConverter: @unchecked Sendable {
    enum ConverterError: Error {
        case failedToCreateConverter
        case failedToCreateBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConverterError.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw ConverterError.failedToCreateBuffer
        }

        // AVAudioConverter's inputBlock is marked @Sendable in Swift 6 even though it's called
        // synchronously. Use a reference-type flag so the mutation is Sendable-safe.
        final class Flag: @unchecked Sendable { var value = false }
        var nsError: NSError?
        let consumed = Flag()
        let status = converter.convert(to: out, error: &nsError) { _, statusPtr in
            defer { consumed.value = true }
            statusPtr.pointee = consumed.value ? .noDataNow : .haveData
            return consumed.value ? nil : buffer
        }
        guard status != .error else { throw ConverterError.conversionFailed(nsError) }
        return out
    }
}
#endif
