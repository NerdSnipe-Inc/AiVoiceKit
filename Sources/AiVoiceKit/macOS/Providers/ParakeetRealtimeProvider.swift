// Sources/AiVoiceKit/macOS/Providers/ParakeetRealtimeProvider.swift
// Ported from FluidVoice — adapted to AiVoiceKit's streaming TranscriptionProvider protocol.
// Parakeet Flash: true streaming via StreamingEouAsrManager.
// Parakeet v2/v3: delegates to FluidAudioProvider (batch).
// Requires Apple Silicon; Intel stub provided below.
#if os(macOS)
@preconcurrency import AVFoundation
import Combine
import Foundation

#if arch(arm64)
@preconcurrency import CoreML
import FluidAudio

/// `TranscriptionProvider` that routes to the appropriate Parakeet pipeline:
///
/// - `parakeetFlash` → `StreamingEouAsrManager` with live partial transcripts.
/// - `parakeetV2` / `parakeetV3` → `FluidAudioProvider` (batch transcription).
final class ParakeetRealtimeProvider: TranscriptionProvider, @unchecked Sendable {

    // MARK: - TranscriptionProvider

    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    // MARK: - Private

    private let model: ASRModel

    // Flash (streaming) path
    private var streamingEngine: StreamingEouAsrManager?
    private var audioEngine: AVAudioEngine?
    private let sampleBuffer = ThreadSafeAudioBuffer()
    private var streamedSampleCount: Int = 0
    private var streamingTask: Task<Void, Never>?

    // v2/v3 (batch) path — delegate
    private var batchProvider: FluidAudioProvider?

    private static let targetSampleRate: Double = 16_000

    // @unchecked Sendable wrapper so the resampler can be captured in the @Sendable tap closure.
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

    // MARK: - Init

    init(model: ASRModel) {
        self.model = model
    }

    // MARK: - TranscriptionProvider conformance

    func start(inputDeviceUID: String?) async throws {
        // Microphone authorization must precede any AVAudioEngine.inputNode use (see
        // MicrophonePermission.swift): without it, installTap crashes instead of throwing.
        try await MicrophonePermission.ensureAuthorized()

        _partial.send("")
        sampleBuffer.clear(keepingCapacity: true)
        streamedSampleCount = 0

        switch model {
        case .parakeetFlash:
            try await startFlash(inputDeviceUID: inputDeviceUID)
        case .parakeetV2, .parakeetV3:
            let delegate = FluidAudioProvider(model: model)
            self.batchProvider = delegate
            delegate.partialTranscript
                .sink { [weak self] text in self?._partial.send(text) }
                .cancel() // no-op subscription; partials not supported in batch mode
            try await delegate.start(inputDeviceUID: inputDeviceUID)
            isStreaming = true
        default:
            break
        }
    }

    func stop() async throws -> String {
        isStreaming = false
        streamingTask?.cancel()
        streamingTask = nil

        if let delegate = batchProvider {
            batchProvider = nil
            return try await delegate.stop()
        }

        return try await stopFlash()
    }

    func cancelAndStop() async {
        isStreaming = false
        streamingTask?.cancel()
        streamingTask = nil

        if let delegate = batchProvider {
            batchProvider = nil
            await delegate.cancelAndStop()
            return
        }

        await cancelFlash()
    }

    // MARK: - Flash streaming implementation

    private func startFlash(inputDeviceUID: String?) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.allowLowPrecisionAccumulationOnGPU = true

        let engine = StreamingEouAsrManager(
            configuration: configuration,
            chunkSize: .ms160
        )
        try await engine.loadModelsFromHuggingFace { _ in }
        self.streamingEngine = engine

        let audioEngine = AVAudioEngine()
        if let uid = inputDeviceUID, !uid.isEmpty {
            DebugLogger.shared.debug(
                "ParakeetRealtimeProvider: input device UID=\(uid)",
                source: "ParakeetRealtimeProvider"
            )
        }

        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
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

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let samples = resampler.extractSamples(from: buffer)
            if !samples.isEmpty { sampleBuf.append(samples) }
        }

        self.audioEngine = audioEngine
        isStreaming = true
        try audioEngine.start()

        // Streaming loop: feed new audio chunks to the engine every 160 ms.
        let streamingEngine = engine
        let targetFmt = targetFormat
        streamingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard let self, self.isStreaming else { break }

                let allSamples = sampleBuf.getAll()
                let delta = Array(allSamples.dropFirst(self.streamedSampleCount))
                self.streamedSampleCount = allSamples.count

                guard !delta.isEmpty,
                      let buffer = Self.makePCMBuffer(delta, format: targetFmt)
                else { continue }

                do {
                    try await streamingEngine.appendAudio(buffer)
                    try await streamingEngine.processBufferedAudio()
                    let partial = await streamingEngine.getPartialTranscript()
                    self._partial.send(partial)
                } catch {
                    DebugLogger.shared.warning(
                        "ParakeetRealtimeProvider: streaming chunk error: \(error.localizedDescription)",
                        source: "ParakeetRealtimeProvider"
                    )
                }
            }
        }

        DebugLogger.shared.info("ParakeetRealtimeProvider (Flash) started", source: "ParakeetRealtimeProvider")
    }

    private func stopFlash() async throws -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        defer {
            streamingEngine = nil
            streamedSampleCount = 0
            sampleBuffer.clear()
        }

        guard let engine = streamingEngine else { return "" }

        // Feed remaining samples
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return "" }

        let remaining = Array(sampleBuffer.getAll().dropFirst(streamedSampleCount))
        if !remaining.isEmpty, let buf = Self.makePCMBuffer(remaining, format: targetFormat) {
            try? await engine.appendAudio(buf)
            try? await engine.processBufferedAudio()
        }

        let text = (try? await engine.finish()) ?? ""
        await engine.reset()
        _partial.send("")
        DebugLogger.shared.info(
            "ParakeetRealtimeProvider (Flash) stopped [\(text.count) chars]",
            source: "ParakeetRealtimeProvider"
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelFlash() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        await streamingEngine?.reset()
        streamingEngine = nil
        streamedSampleCount = 0
        sampleBuffer.clear()
        _partial.send("")
        DebugLogger.shared.info("ParakeetRealtimeProvider cancelled", source: "ParakeetRealtimeProvider")
    }

    // MARK: - Helpers

    private static func makePCMBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(samples.count, 1))
            ),
            let ch = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            ch[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "ParakeetRealtimeProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

#else

/// Intel stub — FluidAudio is not available on x86_64.
final class ParakeetRealtimeProvider: TranscriptionProvider, @unchecked Sendable {
    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    init(model: ASRModel) {}

    func start(inputDeviceUID: String?) async throws {
        // Microphone authorization must precede any AVAudioEngine.inputNode use (see
        // MicrophonePermission.swift): without it, installTap crashes instead of throwing.
        try await MicrophonePermission.ensureAuthorized()

        throw NSError(
            domain: "ParakeetRealtimeProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Parakeet requires Apple Silicon."]
        )
    }

    func stop() async throws -> String {
        throw NSError(
            domain: "ParakeetRealtimeProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Parakeet requires Apple Silicon."]
        )
    }

    func cancelAndStop() async {}
}

#endif
#endif
