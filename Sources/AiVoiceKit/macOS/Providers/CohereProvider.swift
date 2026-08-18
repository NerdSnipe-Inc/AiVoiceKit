// Sources/AiVoiceKit/macOS/Providers/CohereProvider.swift
// Backed by ExternalCoreMLTranscriptionProvider (Cohere Transcribe CoreML).
// Batch transcription: accumulates audio in start(), processes in stop().
// Requires Apple Silicon (macOS 15+); stub provided for other platforms.
#if os(macOS)
@preconcurrency import AVFoundation
import Combine
import Foundation

#if arch(arm64)

/// `TranscriptionProvider` backed by Cohere Transcribe (via CoreML / FluidAudio).
///
/// Audio is accumulated during `start()` and batch-transcribed in `stop()`.
/// No partial-transcript streaming is published.
@available(macOS 15.0, *)
final class CohereProvider: TranscriptionProvider, @unchecked Sendable {

    // MARK: - TranscriptionProvider

    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private let sampleBuffer = ThreadSafeAudioBuffer()
    private let backend = ExternalCoreMLTranscriptionProvider()
    private var isPrepared: Bool = false

    private static let targetSampleRate: Double = 16_000

    private final class ResamplerBox: @unchecked Sendable {
        let converter: AVAudioConverter?
        let targetFormat: AVAudioFormat

        init(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
            self.targetFormat = targetFormat
            self.converter = (inputFormat.sampleRate == targetFormat.sampleRate
                && inputFormat.channelCount == 1
                && inputFormat.commonFormat == .pcmFormatFloat32)
                ? nil
                : AVAudioConverter(from: inputFormat, to: targetFormat)
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

    init() {}

    // MARK: - TranscriptionProvider conformance

    func start(inputDeviceUID: String?) async throws {
        sampleBuffer.clear(keepingCapacity: true)
        _partial.send("")

        // Prepare backend (downloads model if needed; no-op if already ready).
        if !isPrepared {
            DebugLogger.shared.info("CohereProvider: preparing backend…", source: "CohereProvider")
            try await backend.prepare(for: .cohereTranscribe)
            isPrepared = true
        }

        let engine = AVAudioEngine()
        if let uid = inputDeviceUID, !uid.isEmpty {
            DebugLogger.shared.debug(
                "CohereProvider: input device UID=\(uid)",
                source: "CohereProvider"
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
        DebugLogger.shared.info("CohereProvider started", source: "CohereProvider")
    }

    func stop() async throws -> String {
        isStreaming = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        let samples = sampleBuffer.getAll()
        sampleBuffer.clear()

        guard !samples.isEmpty else { return "" }

        DebugLogger.shared.info(
            "CohereProvider: transcribing \(samples.count) samples…",
            source: "CohereProvider"
        )
        let text = try await backend.transcribe(audioSamples: samples)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLogger.shared.info(
            "CohereProvider: done [\(trimmed.count) chars]",
            source: "CohereProvider"
        )
        return trimmed
    }

    func cancelAndStop() async {
        isStreaming = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        sampleBuffer.clear()
        _partial.send("")
        DebugLogger.shared.info("CohereProvider cancelled", source: "CohereProvider")
    }

    // MARK: - Helpers

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "CohereProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

#else

/// Intel stub — Cohere Transcribe requires Apple Silicon.
final class CohereProvider: TranscriptionProvider, @unchecked Sendable {
    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    init() {}

    func start(inputDeviceUID: String?) async throws {
        throw NSError(
            domain: "CohereProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Cohere Transcribe requires Apple Silicon (macOS 15+)."]
        )
    }

    func stop() async throws -> String {
        throw NSError(
            domain: "CohereProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Cohere Transcribe requires Apple Silicon (macOS 15+)."]
        )
    }

    func cancelAndStop() async {}
}

#endif
#endif
