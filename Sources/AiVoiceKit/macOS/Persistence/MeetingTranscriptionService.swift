// Sources/AiVoiceKit/macOS/Persistence/MeetingTranscriptionService.swift
#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

// MARK: - FileTranscriptionProvider protocol

/// A provider that can transcribe audio samples or full files.
/// Adopted by batch-capable providers (Parakeet, Whisper) and injected into
/// `MeetingTranscriptionService` to avoid hardcoding a specific model.
public protocol FileTranscriptionProvider: Sendable {
    /// Human-readable provider name (for logging).
    var name: String { get }

    /// Whether the provider's models are loaded and ready to transcribe.
    var isReady: Bool { get }

    /// When `true` the provider handles entire file URLs natively (preferred path).
    /// When `false` the service reads and resamples audio chunks itself.
    var prefersNativeFileTranscription: Bool { get }

    /// Transcribe a complete audio file at `url`. Only called when
    /// `prefersNativeFileTranscription == true` and the file is not a video container.
    func transcribeFile(at url: URL) async throws -> FileTranscriptionResult

    /// Transcribe a pre-resampled 16 kHz mono Float32 audio chunk.
    func transcribe(_ samples: [Float]) async throws -> FileTranscriptionResult
}

/// Result returned by a `FileTranscriptionProvider`.
public struct FileTranscriptionResult: Sendable {
    public let text: String
    public let confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

// MARK: - TranscriptionResult

/// Full result of a meeting/file transcription operation.
public struct TranscriptionResult: Identifiable, Sendable, Codable {
    public let id: UUID
    public let text: String
    public let confidence: Float
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let fileName: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        duration: TimeInterval,
        processingTime: TimeInterval,
        fileName: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.duration = duration
        self.processingTime = processingTime
        self.fileName = fileName
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, duration, processingTime, fileName, timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.confidence = try c.decode(Float.self, forKey: .confidence)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.processingTime = try c.decode(TimeInterval.self, forKey: .processingTime)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.text, forKey: .text)
        try c.encode(self.confidence, forKey: .confidence)
        try c.encode(self.duration, forKey: .duration)
        try c.encode(self.processingTime, forKey: .processingTime)
        try c.encode(self.fileName, forKey: .fileName)
        try c.encode(self.timestamp, forKey: .timestamp)
    }
}

// MARK: - MeetingTranscriptionService

/// Transcribes complete audio/video files using an injected `FileTranscriptionProvider`.
/// Long files are processed in 20-minute chunks to avoid memory overflow.
@MainActor
public final class MeetingTranscriptionService: ObservableObject {
    @Published public var isTranscribing: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var currentStatus: String = ""
    @Published public var error: String?
    @Published public var result: TranscriptionResult?

    // MARK: - Supported Formats

    /// File extensions the OS can decode, queried dynamically from AVFoundation.
    public static let supportedFileExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.compactMap { fileType -> String? in
            guard let utType = UTType(fileType.rawValue) else { return nil }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return nil }
            return utType.preferredFilenameExtension
        }
        return Set(extensions)
    }()

    public static let allowedContentTypes: [UTType] = [.audio, .movie]
    public static let supportedFormatsDescription = "Supported: WAV, MP3, M4A, OGG, MP4, MOV, and more"
    public static let dropErrorCopy = "Accepted file types: WAV, MP3, M4A, OGG, MP4, MOV, and more."

    // MARK: - Private

    private let provider: any FileTranscriptionProvider

    // MARK: - Init

    /// - Parameter provider: The batch-capable ASR provider to use for transcription.
    public init(provider: any FileTranscriptionProvider) {
        self.provider = provider
    }

    // MARK: - Errors

    public enum TranscriptionError: LocalizedError {
        case providerNotReady
        case audioConversionFailed(String)
        case transcriptionFailed(String)
        case fileNotSupported(String)

        public var errorDescription: String? {
            switch self {
            case .providerNotReady:
                return "Transcription provider is not ready. Please wait for the model to load."
            case let .audioConversionFailed(msg):
                return "Failed to convert audio: \(msg)"
            case let .transcriptionFailed(msg):
                return "Transcription failed: \(msg)"
            case let .fileNotSupported(msg):
                return "File format not supported: \(msg)"
            }
        }
    }

    // MARK: - Transcription

    /// Transcribe an audio or video file at `fileURL`.
    public func transcribeFile(_ fileURL: URL) async throws -> TranscriptionResult {
        self.isTranscribing = true
        self.error = nil
        self.progress = 0.0
        let startTime = Date()

        defer {
            self.isTranscribing = false
            self.progress = 0.0
        }

        do {
            guard self.provider.isReady else {
                throw TranscriptionError.providerNotReady
            }

            let fileExtension = fileURL.pathExtension.lowercased()
            guard Self.supportedFileExtensions.contains(fileExtension) else {
                throw TranscriptionError.fileNotSupported(
                    "Format .\(fileExtension) not supported. \(Self.supportedFormatsDescription)"
                )
            }

            self.currentStatus = "Analyzing audio file..."
            self.progress = 0.2

            let asset = AVAsset(url: fileURL)
            let duration: Double
            do {
                let cmDuration = try await asset.load(.duration)
                duration = CMTimeGetSeconds(cmDuration)
            } catch {
                duration = 0
                DebugLogger.shared.warning(
                    "Could not determine audio duration: \(error.localizedDescription)",
                    source: "MeetingTranscriptionService"
                )
            }

            let isVideoContainer = UTType(filenameExtension: fileExtension)
                .map { $0.conforms(to: .movie) } ?? false

            // Native file path — provider handles the file directly (avoids chunking overhead).
            if self.provider.prefersNativeFileTranscription && !isVideoContainer {
                self.currentStatus = duration > 0
                    ? "Transcribing audio (\(Int(duration))s)..."
                    : "Transcribing audio..."
                self.progress = 0.3

                DebugLogger.shared.info(
                    "MeetingTranscriptionService: native file transcription [provider=\(self.provider.name)]",
                    source: "MeetingTranscriptionService"
                )

                let nativeResult = try await self.provider.transcribeFile(at: fileURL)
                let processingTime = Date().timeIntervalSince(startTime)
                let result = TranscriptionResult(
                    text: nativeResult.text,
                    confidence: nativeResult.confidence,
                    duration: duration,
                    processingTime: processingTime,
                    fileName: fileURL.lastPathComponent
                )
                self.currentStatus = "Complete!"
                self.progress = 1.0
                self.result = result
                return result
            }

            // Chunked path — read and resample audio in ~20-minute segments.
            if self.provider.prefersNativeFileTranscription && isVideoContainer {
                DebugLogger.shared.info(
                    "MeetingTranscriptionService: video container → buffered path [provider=\(self.provider.name), ext=\(fileExtension)]",
                    source: "MeetingTranscriptionService"
                )
            }

            let chunkDurationSeconds: Double = 20 * 60
            let sampleRate: Double = 16_000
            let samplesPerChunk = Int(chunkDurationSeconds * sampleRate)

            var allTranscriptions: [String] = []
            var totalConfidence: Float = 0
            var chunkCount = 0

            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: fileURL)
            } catch {
                throw TranscriptionError.audioConversionFailed(
                    "Could not open audio file: \(error.localizedDescription)"
                )
            }

            let fileFormat = audioFile.processingFormat
            let fileSampleRate = fileFormat.sampleRate
            guard fileSampleRate > 0 else {
                throw TranscriptionError.audioConversionFailed("Invalid audio file: sample rate is 0")
            }
            let resampleRatio = sampleRate / fileSampleRate
            let sourceFramesPerChunk = AVAudioFrameCount(Double(samplesPerChunk) / resampleRatio)
            var currentFrame: AVAudioFramePosition = 0

            self.currentStatus = duration > 0
                ? "Transcribing audio (\(Int(duration))s)..."
                : "Transcribing audio..."

            while currentFrame < audioFile.length {
                let remainingFrames = AVAudioFrameCount(audioFile.length - currentFrame)
                let framesToRead = min(sourceFramesPerChunk, remainingFrames)

                guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                    throw TranscriptionError.audioConversionFailed("Could not create audio buffer")
                }

                audioFile.framePosition = currentFrame
                do {
                    try audioFile.read(into: buffer, frameCount: framesToRead)
                } catch {
                    throw TranscriptionError.audioConversionFailed(
                        "Could not read audio chunk: \(error.localizedDescription)"
                    )
                }

                let samples: [Float]
                do {
                    samples = try self.resampleBuffer(buffer, targetSampleRate: sampleRate)
                } catch {
                    throw TranscriptionError.audioConversionFailed(
                        "Could not resample audio: \(error.localizedDescription)"
                    )
                }

                // Skip chunks shorter than 1 second.
                guard samples.count >= Int(sampleRate) else {
                    currentFrame += AVAudioFramePosition(framesToRead)
                    continue
                }

                let chunkResult = try await self.provider.transcribe(samples)
                if !chunkResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allTranscriptions.append(chunkResult.text)
                    totalConfidence += chunkResult.confidence
                    chunkCount += 1
                }

                currentFrame += AVAudioFramePosition(framesToRead)

                let progressPercent = Double(currentFrame) / Double(audioFile.length)
                self.progress = 0.3 + progressPercent * 0.6
                self.currentStatus = "Transcribing... \(Int(progressPercent * 100))%"
            }

            if allTranscriptions.isEmpty {
                DebugLogger.shared.warning(
                    "No audio chunks long enough to transcribe (minimum 1 second required)",
                    source: "MeetingTranscriptionService"
                )
            }

            let finalText = allTranscriptions.joined(separator: " ")
            let avgConfidence = chunkCount > 0 ? totalConfidence / Float(chunkCount) : 0
            let processingTime = Date().timeIntervalSince(startTime)

            self.currentStatus = "Complete!"
            self.progress = 1.0

            let result = TranscriptionResult(
                text: finalText,
                confidence: avgConfidence,
                duration: duration,
                processingTime: processingTime,
                fileName: fileURL.lastPathComponent
            )
            self.result = result
            return result

        } catch let error as TranscriptionError {
            self.error = error.localizedDescription
            throw error
        } catch {
            let wrapped = TranscriptionError.transcriptionFailed(error.localizedDescription)
            self.error = wrapped.localizedDescription
            throw wrapped
        }
    }

    // MARK: - Export

    public nonisolated func exportToText(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let content = """
        Transcription: \(result.fileName)
        Date: \(result.timestamp.formatted())
        Duration: \(String(format: "%.1f", result.duration))s
        Processing Time: \(String(format: "%.1f", result.processingTime))s
        Confidence: \(String(format: "%.1f%%", result.confidence * 100))

        ---

        \(result.text)
        """
        try content.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    public nonisolated func exportToJSON(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: destinationURL)
    }

    // MARK: - Reset

    public func reset() {
        self.result = nil
        self.error = nil
        self.currentStatus = ""
        self.progress = 0.0
    }

    // MARK: - Audio Resampling

    private nonisolated func resampleBuffer(_ buffer: AVAudioPCMBuffer, targetSampleRate: Double = 16_000) throws -> [Float] {
        let sourceFormat = buffer.format
        let sourceSampleRate = sourceFormat.sampleRate
        let sourceChannels = sourceFormat.channelCount

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create target audio format"]
            )
        }

        if sourceSampleRate == targetSampleRate,
           sourceChannels == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32
        {
            guard let channelData = buffer.floatChannelData else {
                throw NSError(
                    domain: "MeetingTranscriptionService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not access audio channel data"]
                )
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"]
            )
        }

        let ratio = targetSampleRate / sourceSampleRate
        let estimatedFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrameCount + 1024) else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Could not create output buffer"]
            )
        }

        var conversionError: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Could not access converted audio data"]
            )
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
#endif
