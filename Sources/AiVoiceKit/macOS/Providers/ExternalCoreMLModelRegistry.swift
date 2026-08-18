// Sources/AiVoiceKit/macOS/Providers/ExternalCoreMLModelRegistry.swift
// Ported from FluidVoice — adapted to use AiVoiceKit's ASRModel enum.
// Provides model specs for ASR models backed by external CoreML artifacts.
#if os(macOS)
import Foundation

#if arch(arm64)
import FluidAudio

// MARK: - Backend

enum ExternalCoreMLASRBackend {
    case cohereTranscribe
}

// MARK: - Manifest identity (decoded from coreml_manifest.json)

struct ExternalCoreMLManifestIdentity: Decodable {
    let modelID: String
    let sampleRate: Int
    let maxAudioSamples: Int
    let maxAudioSeconds: Double
    let overlapSamples: Int?

    private enum CodingKeys: String, CodingKey {
        case modelID         = "model_id"
        case sampleRate      = "sample_rate"
        case maxAudioSamples = "max_audio_samples"
        case maxAudioSeconds = "max_audio_seconds"
        case overlapSamples  = "overlap_samples"
    }
}

// MARK: - Validation errors

enum ExternalCoreMLArtifactsValidationError: LocalizedError {
    case missingEntries([String])
    case manifestMissing(URL)
    case manifestUnreadable(URL, Error)
    case unexpectedModelID(expected: String, actual: String)
    case unexpectedSampleRate(expected: Int, actual: Int)
    case invalidMaxAudioSeconds(Double)
    case invalidMaxAudioSamples(Int)
    case inconsistentAudioWindow(samples: Int, seconds: Double, sampleRate: Int)
    case invalidOverlapSamples(Int, maxAudioSamples: Int)

    var errorDescription: String? {
        switch self {
        case let .missingEntries(entries):
            return "Missing required files: \(entries.joined(separator: ", "))"
        case let .manifestMissing(url):
            return "Manifest file not found at \(url.path)"
        case let .manifestUnreadable(url, error):
            return "Failed to read manifest at \(url.path): \(error.localizedDescription)"
        case let .unexpectedModelID(expected, actual):
            return "Unexpected model_id '\(actual)'. Expected '\(expected)'."
        case let .unexpectedSampleRate(expected, actual):
            return "Unexpected sample rate \(actual). Expected \(expected)."
        case let .invalidMaxAudioSeconds(s):
            return "Invalid max_audio_seconds \(s)."
        case let .invalidMaxAudioSamples(n):
            return "Invalid max_audio_samples \(n)."
        case let .inconsistentAudioWindow(samples, seconds, sampleRate):
            return "Manifest audio window inconsistent: \(samples) samples vs \(seconds)s at \(sampleRate) Hz."
        case let .invalidOverlapSamples(overlap, max):
            return "Invalid overlap_samples \(overlap) for max_audio_samples \(max)."
        }
    }
}

// MARK: - Model spec

struct ExternalCoreMLASRModelSpec {
    private static let bundleStampFileName = ".fluid_artifact_bundle_version"
    private let maximumAudioWindowSeconds: Double = 60

    let backend: ExternalCoreMLASRBackend
    let artifactFolderHint: String
    let manifestFileName: String
    let frontendFileName: String
    let encoderFileName: String
    let crossKVProjectorFileName: String?
    let decoderFileName: String
    let cachedDecoderFileName: String
    let expectedModelID: String
    let expectedSampleRate: Int
    let computeConfiguration: CohereTranscribeComputeConfiguration
    let repositoryOwner: String?
    let repositoryName: String?
    let repositoryRevision: String
    let artifactBundleVersion: String

    var requiredEntries: [String] {
        [
            manifestFileName,
            frontendFileName,
            encoderFileName,
            crossKVProjectorFileName,
            decoderFileName,
            cachedDecoderFileName,
        ].compactMap { $0 }
    }

    var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(artifactFolderHint, isDirectory: true)
    }

    func url(for entry: String, in directory: URL) -> URL {
        directory.appendingPathComponent(entry, isDirectory: entry.hasSuffix(".mlpackage"))
    }

    func missingEntries(at directory: URL) -> [String] {
        requiredEntries.filter { entry in
            !FileManager.default.fileExists(atPath: url(for: entry, in: directory).path)
        }
    }

    func validateArtifacts(at directory: URL) -> Bool {
        (try? validateArtifactsOrThrow(at: directory)) != nil
    }

    func validateArtifactsOrThrow(at directory: URL) throws {
        let missing = missingEntries(at: directory)
        guard missing.isEmpty else {
            throw ExternalCoreMLArtifactsValidationError.missingEntries(missing)
        }
        let manifest = try loadManifest(at: directory)
        guard manifest.modelID == expectedModelID else {
            throw ExternalCoreMLArtifactsValidationError.unexpectedModelID(
                expected: expectedModelID, actual: manifest.modelID
            )
        }
        guard manifest.sampleRate == expectedSampleRate else {
            throw ExternalCoreMLArtifactsValidationError.unexpectedSampleRate(
                expected: expectedSampleRate, actual: manifest.sampleRate
            )
        }
        guard manifest.maxAudioSeconds > 0,
              manifest.maxAudioSeconds <= maximumAudioWindowSeconds
        else {
            throw ExternalCoreMLArtifactsValidationError.invalidMaxAudioSeconds(manifest.maxAudioSeconds)
        }
        let maxSamples = Int((Double(expectedSampleRate) * maximumAudioWindowSeconds).rounded())
        guard manifest.maxAudioSamples > 0, manifest.maxAudioSamples <= maxSamples else {
            throw ExternalCoreMLArtifactsValidationError.invalidMaxAudioSamples(manifest.maxAudioSamples)
        }
        let expectedSamples = Int((manifest.maxAudioSeconds * Double(manifest.sampleRate)).rounded())
        guard abs(expectedSamples - manifest.maxAudioSamples) <= 1 else {
            throw ExternalCoreMLArtifactsValidationError.inconsistentAudioWindow(
                samples: manifest.maxAudioSamples,
                seconds: manifest.maxAudioSeconds,
                sampleRate: manifest.sampleRate
            )
        }
        if let overlap = manifest.overlapSamples {
            guard overlap >= 0, overlap < manifest.maxAudioSamples else {
                throw ExternalCoreMLArtifactsValidationError.invalidOverlapSamples(
                    overlap, maxAudioSamples: manifest.maxAudioSamples
                )
            }
        }
    }

    func loadManifest(at directory: URL) throws -> ExternalCoreMLManifestIdentity {
        let manifestURL = url(for: manifestFileName, in: directory)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExternalCoreMLArtifactsValidationError.manifestMissing(manifestURL)
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(ExternalCoreMLManifestIdentity.self, from: data)
        } catch {
            throw ExternalCoreMLArtifactsValidationError.manifestUnreadable(manifestURL, error)
        }
    }

    func artifactBundleStampMatches(at directory: URL) -> Bool {
        let stampURL = directory.appendingPathComponent(Self.bundleStampFileName, isDirectory: false)
        guard let stamp = try? String(contentsOf: stampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return stamp == artifactBundleVersion
    }

    func persistArtifactBundleStamp(at directory: URL) {
        let stampURL = directory.appendingPathComponent(Self.bundleStampFileName, isDirectory: false)
        try? artifactBundleVersion.write(to: stampURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Registry

enum ExternalCoreMLModelRegistry {
    /// Returns the `ExternalCoreMLASRModelSpec` for the given `ASRModel`, or `nil` if the
    /// model is not backed by external CoreML artifacts.
    static func spec(for model: ASRModel) -> ExternalCoreMLASRModelSpec? {
        switch model {
        case .cohereTranscribe:
            return ExternalCoreMLASRModelSpec(
                backend: .cohereTranscribe,
                artifactFolderHint: "cohere-transcribe-03-2026-CoreML-6bit",
                manifestFileName: "coreml_manifest.json",
                frontendFileName: "cohere_frontend.mlpackage",
                encoderFileName: "cohere_encoder.mlpackage",
                crossKVProjectorFileName: "cohere_cross_kv_projector.mlpackage",
                decoderFileName: "cohere_decoder_fullseq_masked.mlpackage",
                cachedDecoderFileName: "cohere_decoder_cached.mlpackage",
                expectedModelID: "CohereLabs/cohere-transcribe-03-2026",
                expectedSampleRate: 16_000,
                computeConfiguration: .aneSmall,
                repositoryOwner: "BarathwajAnandan",
                repositoryName: "cohere-transcribe-03-2026-CoreML-6bit",
                repositoryRevision: "main",
                artifactBundleVersion: "2026-04-02-cohere-refresh-1"
            )
        default:
            return nil
        }
    }
}

// MARK: - ASRModel extension

extension ASRModel {
    var externalCoreMLSpec: ExternalCoreMLASRModelSpec? {
        ExternalCoreMLModelRegistry.spec(for: self)
    }
}

#endif
#endif
