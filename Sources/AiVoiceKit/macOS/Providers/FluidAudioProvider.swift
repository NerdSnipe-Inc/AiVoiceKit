// Sources/AiVoiceKit/macOS/Providers/FluidAudioProvider.swift
// Ported from FluidVoice — adapted to AiVoiceKit's streaming TranscriptionProvider protocol.
// Handles Parakeet TDT v2 and v3 (batch transcription via FluidAudio AsrManager).
// Requires Apple Silicon; an Intel stub is provided below the #if arch(arm64) guard.
#if os(macOS)
@preconcurrency import AVFoundation
import Combine
import Foundation

#if arch(arm64)
import FluidAudio

/// `TranscriptionProvider` backed by FluidAudio's `AsrManager` (Parakeet TDT v2/v3).
///
/// Records audio with `AVAudioEngine`, accumulates 16 kHz PCM float samples, and
/// performs batch transcription in `stop()`. No partial-transcript streaming.
final class FluidAudioProvider: TranscriptionProvider, @unchecked Sendable {

    // MARK: - TranscriptionProvider

    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    // MARK: - Private

    private let modelVersion: AsrModelVersion
    private var audioEngine: AVAudioEngine?
    private let sampleBuffer = ThreadSafeAudioBuffer()
    private var loadedModels: AsrModels?
    /// Persisted across recording sessions — initialized once, reset between calls.
    private var asrManager: AsrManager?

    private static let targetSampleRate: Double = 16_000

    // @unchecked Sendable so the converter can be captured in the @Sendable tap closure.
    private final class ResamplerBox: @unchecked Sendable {
        let converter: AVAudioConverter?
        let targetFormat: AVAudioFormat

        init(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
            self.targetFormat = targetFormat
            // Three-field check avoids spurious converter installation when channel layout
            // objects differ but the format is already the target (16 kHz / mono / Float32).
            let alreadyTarget = inputFormat.sampleRate == 16_000
                && inputFormat.channelCount == 1
                && inputFormat.commonFormat == .pcmFormatFloat32
            self.converter = alreadyTarget ? nil : AVAudioConverter(from: inputFormat, to: targetFormat)
        }

        func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
            guard let conv = converter else {
                guard let ch = buffer.floatChannelData else { return [] }
                return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
            }
            let ratio = conv.outputFormat.sampleRate / conv.inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
            var err: NSError?
            var consumed = false
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, let ch = out.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        }
    }

    // MARK: - Init

    /// - Parameter model: Must be `.parakeetV2` or `.parakeetV3`.
    init(model: ASRModel) {
        self.modelVersion = (model == .parakeetV2) ? .v2 : .v3
    }

    // MARK: - TranscriptionProvider conformance

    func start(inputDeviceUID: String?) async throws {
        // Microphone authorization must precede any AVAudioEngine.inputNode use (see
        // MicrophonePermission.swift): without it, installTap crashes instead of throwing.
        try await MicrophonePermission.ensureAuthorized()

        sampleBuffer.clear(keepingCapacity: true)
        _partial.send("")

        // Download/load FluidAudio models if not already cached.
        if loadedModels == nil {
            DebugLogger.shared.info(
                "FluidAudioProvider: loading Parakeet \(modelVersion == .v2 ? "v2" : "v3") models…",
                source: "FluidAudioProvider"
            )
            loadedModels = try await AsrModels.downloadAndLoad(version: modelVersion) { _ in }
        }

        let engine = AVAudioEngine()
        if let uid = inputDeviceUID, !uid.isEmpty {
            DebugLogger.shared.debug(
                "FluidAudioProvider: input device UID=\(uid)",
                source: "FluidAudioProvider"
            )
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Self.makeError("Failed to create 16 kHz mono audio format.")
        }

        let resampler = ResamplerBox(from: inputFormat, to: targetFormat)
        let sampleBuf = self.sampleBuffer

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let samples = resampler.extractSamples(from: buffer)
            if !samples.isEmpty { sampleBuf.append(samples) }
        }

        self.audioEngine = engine
        isStreaming = true
        try engine.start()
        DebugLogger.shared.info("FluidAudioProvider started", source: "FluidAudioProvider")
    }

    func stop() async throws -> String {
        isStreaming = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        let samples = sampleBuffer.getAll()
        sampleBuffer.clear()

        guard !samples.isEmpty else { return "" }
        guard let models = loadedModels else {
            throw Self.makeError("FluidAudio models are not loaded.")
        }

        if asrManager == nil {
            let manager = AsrManager(config: ASRConfig.default)
            try await manager.initialize(models: models)
            asrManager = manager
        }
        // AsrManager.transcribe(_:source:) resets decoder state after each call,
        // so no explicit reset is needed between recording sessions.
        let result = try await asrManager!.transcribe(samples, source: AudioSource.microphone)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLogger.shared.info(
            "FluidAudioProvider: transcription done [\(text.count) chars]",
            source: "FluidAudioProvider"
        )
        return text
    }

    func cancelAndStop() async {
        isStreaming = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        sampleBuffer.clear()
        _partial.send("")
        DebugLogger.shared.info("FluidAudioProvider cancelled", source: "FluidAudioProvider")
    }

    // MARK: - Helpers

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "FluidAudioProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

#else

/// Intel stub — FluidAudio is not available on x86_64.
final class FluidAudioProvider: TranscriptionProvider, @unchecked Sendable {
    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    init(model: ASRModel) {}

    func start(inputDeviceUID: String?) async throws {
        // Microphone authorization must precede any AVAudioEngine.inputNode use (see
        // MicrophonePermission.swift): without it, installTap crashes instead of throwing.
        try await MicrophonePermission.ensureAuthorized()

        throw NSError(
            domain: "FluidAudioProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FluidAudio Parakeet requires Apple Silicon."]
        )
    }

    func stop() async throws -> String {
        throw NSError(
            domain: "FluidAudioProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FluidAudio Parakeet requires Apple Silicon."]
        )
    }

    func cancelAndStop() async {}
}

#endif
#endif
