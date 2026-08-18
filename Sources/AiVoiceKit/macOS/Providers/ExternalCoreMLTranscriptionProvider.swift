// Sources/AiVoiceKit/macOS/Providers/ExternalCoreMLTranscriptionProvider.swift
// Ported from FluidVoice — adapted to use AiVoiceKit types.
// Wraps CohereTranscribeAsrManager with download, validation, and prompt configuration.
// Requires Apple Silicon (macOS 15+); stub provided for other platforms.
#if os(macOS)
import Foundation

#if arch(arm64)
import FluidAudio

/// Batch transcription backend for external CoreML models (currently Cohere Transcribe).
///
/// This class handles model download/validation and wraps `CohereTranscribeAsrManager`.
/// It is used by `CohereProvider` to implement the `TranscriptionProvider` protocol.
///
/// Unlike the streaming providers, this class is NOT a `TranscriptionProvider` itself —
/// it exposes a lower-level `transcribe(audioSamples:)` API used by `CohereProvider`.
@available(macOS 15.0, *)
final class ExternalCoreMLTranscriptionProvider: @unchecked Sendable {

    // MARK: - State

    private(set) var isReady: Bool = false
    private var cohereManager: CohereTranscribeAsrManager?
    private var loadedManifest: ExternalCoreMLManifestIdentity?
    private var coherePromptTemplate: [Int] = []
    private let streamingPreviewMaxSeconds: Double = 12

    // MARK: - Init

    init() {}

    // MARK: - Prepare

    /// Downloads model artifacts if needed and loads the CoreML models.
    func prepare(for model: ASRModel, progressHandler: ((Double) -> Void)? = nil) async throws {
        guard !isReady else { return }

        guard let spec = model.externalCoreMLSpec else {
            throw Self.makeError("No external CoreML spec for \(model.rawValue).")
        }
        guard let directory = spec.defaultCacheDirectory else {
            throw Self.makeError("Unable to resolve cache directory for \(model.rawValue).")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // HuggingFaceModelDownloader is not publicly exported from FluidAudio.
        // Artifacts must be placed at the default cache directory by the host app's
        // ModelDownloader before CohereProvider is activated.
        if !spec.validateArtifacts(at: directory) {
            throw Self.makeError(
                "Cohere model artifacts not found at \(directory.path). " +
                "Please download them via ModelDownloader before enabling Cohere Transcribe."
            )
        }

        loadedManifest = try spec.loadManifest(at: directory)
        try loadCoherePromptConfiguration(at: directory)

        let manager = CohereTranscribeAsrManager()
        try await manager.loadModels(from: directory, computeConfiguration: spec.computeConfiguration)
        self.cohereManager = manager
        isReady = true

        DebugLogger.shared.info(
            "ExternalCoreML: ready [\(model.rawValue)]",
            source: "ExternalCoreML"
        )
    }

    // MARK: - Transcription

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let manager = cohereManager else {
            throw Self.makeError("CoreML model is not loaded.")
        }
        let promptIDs = currentPromptIDs()
        return try await manager.transcribe(
            audioSamples: audioSamples,
            promptIDs: promptIDs.isEmpty ? nil : promptIDs
        )
    }

    // MARK: - Private helpers

    private func loadCoherePromptConfiguration(at directory: URL) throws {
        let manifestURL = directory.appendingPathComponent("coreml_manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let data = try Data(contentsOf: manifestURL)
        guard
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawPromptIDs = raw["prompt_ids"] as? [Any]
        else { return }
        let promptIDs = rawPromptIDs.compactMap { ($0 as? NSNumber)?.intValue }
        guard promptIDs.count == rawPromptIDs.count else { return }
        coherePromptTemplate = promptIDs
    }

    private func currentPromptIDs() -> [Int] {
        // Language selection not yet wired to VoiceSettingsStore; return default template.
        coherePromptTemplate
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "ExternalCoreMLTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

#endif
#endif
