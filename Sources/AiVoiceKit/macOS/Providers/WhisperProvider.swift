// Sources/AiVoiceKit/macOS/Providers/WhisperProvider.swift
// Ported from FluidVoice — adapted to AiVoiceKit's streaming TranscriptionProvider protocol.
// Records audio with AVAudioEngine; batch-transcribes with whisper.cpp in stop().
// Works on both Intel (x86_64) and Apple Silicon.
#if os(macOS)
@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftWhisper

/// `TranscriptionProvider` backed by whisper.cpp via SwiftWhisper.
///
/// Audio is captured at the hardware's native rate, resampled to 16 kHz in the
/// tap callback, and accumulated in a `ThreadSafeAudioBuffer`. On `stop()` the
/// full sample array is passed to `Whisper.transcribe(audioFrames:)`.
///
/// Partial transcript is not supported (non-streaming); the subject always
/// publishes an empty string until `stop()` completes.
final class WhisperProvider: TranscriptionProvider, @unchecked Sendable {

    // MARK: - TranscriptionProvider

    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    // MARK: - Private

    private let model: ASRModel
    private var audioEngine: AVAudioEngine?
    private let sampleBuffer = ThreadSafeAudioBuffer()

    /// Resampler box — @unchecked Sendable so it can be captured in the @Sendable tap closure.
    private final class ResamplerBox: @unchecked Sendable {
        let converter: AVAudioConverter?
        let targetFormat: AVAudioFormat

        init(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
            self.targetFormat = targetFormat
            if inputFormat.sampleRate == targetFormat.sampleRate,
               inputFormat.channelCount == 1,
               inputFormat.commonFormat == .pcmFormatFloat32
            {
                self.converter = nil
            } else {
                self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            }
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
            // Synchronous, single-invocation-per-call AVAudioConverterInputBlock: the converter
            // calls this closure once, on the calling thread, before `convert(to:error:...)`
            // returns. It is not concurrent in practice, so the mutable flag is safe.
            nonisolated(unsafe) var consumed = false
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, let ch = out.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        }
    }

    private static let targetSampleRate: Double = 16_000

    // MARK: - Init

    init(model: ASRModel) {
        self.model = model
    }

    // MARK: - TranscriptionProvider conformance

    func start(inputDeviceUID: String?) async throws {
        // Microphone authorization must precede any AVAudioEngine.inputNode use (see
        // MicrophonePermission.swift): without it, installTap crashes instead of throwing.
        try await MicrophonePermission.ensureAuthorized()

        sampleBuffer.clear(keepingCapacity: true)
        _partial.send("")

        let engine = AVAudioEngine()

        if let uid = inputDeviceUID, !uid.isEmpty {
            DebugLogger.shared.debug(
                "WhisperProvider: input device UID=\(uid)",
                source: "WhisperProvider"
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
        DebugLogger.shared.info(
            "WhisperProvider started [\(model.rawValue)]",
            source: "WhisperProvider"
        )
    }

    func stop() async throws -> String {
        isStreaming = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        let samples = sampleBuffer.getAll()
        sampleBuffer.clear()

        guard samples.count >= 16_000 else {
            DebugLogger.shared.info(
                "WhisperProvider: audio too short (\(samples.count) samples) — returning empty",
                source: "WhisperProvider"
            )
            return ""
        }

        let modelURL = ModelRepository.shared.downloadedModelURL(for: model)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Self.makeError(
                "Whisper model file not found at \(modelURL.path). Please download it first."
            )
        }

        DebugLogger.shared.info(
            "WhisperProvider: transcribing \(samples.count) samples (\(model.rawValue))…",
            source: "WhisperProvider"
        )
        let whisper = Whisper(fromFileURL: modelURL)
        let segments = try await whisper.transcribe(audioFrames: samples)
        let text = segments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLogger.shared.info(
            "WhisperProvider: transcription done [\(text.count) chars]",
            source: "WhisperProvider"
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
        DebugLogger.shared.info("WhisperProvider cancelled", source: "WhisperProvider")
    }

    // MARK: - Private helpers

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "WhisperProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
#endif
