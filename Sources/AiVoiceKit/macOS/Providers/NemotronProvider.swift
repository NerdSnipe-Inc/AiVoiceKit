// Sources/AiVoiceKit/macOS/Providers/NemotronProvider.swift
// Ported from FluidVoice — adapted to AiVoiceKit's streaming TranscriptionProvider protocol.
// nemotronFast  → NemotronStreamingAsrManager in streaming mode.
// nemotronMultilingual → NemotronStreamingAsrManager in offline (batch) mode.
// Requires Apple Silicon; Intel stub provided below.
#if os(macOS)
@preconcurrency import AVFoundation
import Combine
import Foundation

#if arch(arm64)
@preconcurrency import CoreML
import FluidAudio

/// `TranscriptionProvider` backed by FluidAudio's `NemotronStreamingAsrManager`.
///
/// - `nemotronFast`: streaming mode — feeds audio chunks during recording and
///   publishes partial transcripts every 160 ms.
/// - `nemotronMultilingual`: offline (batch) mode — accumulates all audio,
///   batch-transcribes in `stop()`.
@available(macOS 14.0, *)
final class NemotronProvider: TranscriptionProvider, @unchecked Sendable {

    // MARK: - TranscriptionProvider

    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    // MARK: - Mode

    enum Mode {
        case offline    // nemotronMultilingual
        case streaming  // nemotronFast

        var folderHint: String {
            switch self {
            case .offline:   return "nemotron-3.5-asr-offline-6bit-CoreML"
            case .streaming: return "nemotron-3.5-asr-streaming320-int8-CoreML"
            }
        }

        var repositoryOwner: String { "BarathwajAnandan" }
        var repositoryName: String { folderHint }
    }

    // MARK: - Private

    private let mode: Mode
    private var manager: NemotronStreamingAsrManager?
    private var audioEngine: AVAudioEngine?
    private let sampleBuffer = ThreadSafeAudioBuffer()
    private var streamedSampleCount: Int = 0
    private var streamingTask: Task<Void, Never>?

    // Target language defaults to English; no language selection in VoiceSettingsStore yet.
    private let defaultLanguageCode = "en"

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

    init(model: ASRModel) {
        self.mode = (model == .nemotronFast) ? .streaming : .offline
    }

    // MARK: - TranscriptionProvider conformance

    func start(inputDeviceUID: String?) async throws {
        sampleBuffer.clear(keepingCapacity: true)
        streamedSampleCount = 0
        _partial.send("")

        guard let modelDir = cacheDirectory else {
            throw Self.makeError("Unable to resolve Nemotron model cache directory.")
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.allowLowPrecisionAccumulationOnGPU = true

        let mgr = NemotronStreamingAsrManager(configuration: configuration)
        try await mgr.loadModels(modelDir: modelDir)
        try await mgr.setTargetLanguage(defaultLanguageCode)
        self.manager = mgr

        let audioEngine = AVAudioEngine()
        if let uid = inputDeviceUID, !uid.isEmpty {
            DebugLogger.shared.debug(
                "NemotronProvider: input device UID=\(uid)",
                source: "NemotronProvider"
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

        if mode == .streaming {
            let streamMgr = mgr
            let targetFmt = targetFormat
            streamingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    guard let self, self.isStreaming else { break }

                    let all = sampleBuf.getAll()
                    let delta = Array(all.dropFirst(self.streamedSampleCount))
                    self.streamedSampleCount = all.count

                    guard !delta.isEmpty,
                          let buffer = Self.makePCMBuffer(delta, format: targetFmt)
                    else { continue }

                    do {
                        try await streamMgr.appendAudio(buffer)
                        try await streamMgr.processBufferedAudio()
                        let partial = await streamMgr.getPartialTranscript()
                        self._partial.send(partial)
                    } catch {
                        DebugLogger.shared.warning(
                            "NemotronProvider: streaming chunk error: \(error.localizedDescription)",
                            source: "NemotronProvider"
                        )
                    }
                }
            }
        }

        DebugLogger.shared.info(
            "NemotronProvider started [mode=\(mode.folderHint)]",
            source: "NemotronProvider"
        )
    }

    func stop() async throws -> String {
        isStreaming = false
        streamingTask?.cancel()
        streamingTask = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        defer {
            manager = nil
            streamedSampleCount = 0
            sampleBuffer.clear()
        }

        guard let mgr = manager else { return "" }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return "" }

        let text: String

        if mode == .streaming {
            let remaining = Array(sampleBuffer.getAll().dropFirst(streamedSampleCount))
            if !remaining.isEmpty, let buf = Self.makePCMBuffer(remaining, format: targetFormat) {
                try? await mgr.appendAudio(buf)
                try? await mgr.processBufferedAudio()
            }
            text = (try? await mgr.finish()) ?? ""
            await mgr.reset()
        } else {
            // Offline/batch: transcribe full buffer
            let samples = sampleBuffer.getAll()
            if samples.isEmpty {
                text = ""
            } else if let buf = Self.makePCMBuffer(samples, format: targetFormat) {
                text = (try? await mgr.transcribe(audioBuffer: buf)) ?? ""
                await mgr.reset()
            } else {
                text = ""
            }
        }

        _partial.send("")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLogger.shared.info(
            "NemotronProvider stopped [\(trimmed.count) chars]",
            source: "NemotronProvider"
        )
        return trimmed
    }

    func cancelAndStop() async {
        isStreaming = false
        streamingTask?.cancel()
        streamingTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        await manager?.reset()
        manager = nil
        streamedSampleCount = 0
        sampleBuffer.clear()
        _partial.send("")
        DebugLogger.shared.info("NemotronProvider cancelled", source: "NemotronProvider")
    }

    // MARK: - Helpers

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(mode.folderHint, isDirectory: true)
    }

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
            domain: "NemotronProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

#else

/// Intel stub — Nemotron requires Apple Silicon.
final class NemotronProvider: TranscriptionProvider, @unchecked Sendable {
    private let _partial = CurrentValueSubject<String, Never>("")
    var partialTranscript: AnyPublisher<String, Never> { _partial.eraseToAnyPublisher() }
    private(set) var isStreaming: Bool = false

    init(model: ASRModel) {}

    func start(inputDeviceUID: String?) async throws {
        throw NSError(
            domain: "NemotronProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Nemotron requires Apple Silicon."]
        )
    }

    func stop() async throws -> String {
        throw NSError(
            domain: "NemotronProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Nemotron requires Apple Silicon."]
        )
    }

    func cancelAndStop() async {}
}

#endif
#endif
