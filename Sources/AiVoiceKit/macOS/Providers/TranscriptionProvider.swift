// Sources/AiVoiceKit/macOS/Providers/TranscriptionProvider.swift
#if os(macOS)
import Combine
import Foundation

/// Internal streaming transcription contract.
/// `VoiceEngineMacOS` holds one concrete provider at a time.
/// All methods are called exclusively from `@MainActor` context.
protocol TranscriptionProvider: AnyObject, Sendable {
    /// Streams partial transcripts while recording is active.
    var partialTranscript: AnyPublisher<String, Never> { get }

    /// `true` while audio capture and recognition are running.
    var isStreaming: Bool { get }

    /// Starts audio capture from the specified device (or system default when nil/empty)
    /// and begins streaming recognition.
    func start(inputDeviceUID: String?) async throws

    /// Signals end of speech, finalizes recognition, and returns the complete transcript.
    func stop() async throws -> String

    /// Aborts without returning a result. Safe to call at any point.
    func cancelAndStop() async
}
#endif
