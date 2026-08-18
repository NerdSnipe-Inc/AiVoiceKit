// Sources/AiVoiceKit/Public/ASRModel.swift
import Foundation

public enum ASRModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleSpeech
    case whisperTiny, whisperBase, whisperSmall, whisperMedium, whisperLarge
    case parakeetFlash, parakeetV2, parakeetV3
    case nemotronFast, nemotronMultilingual
    case cohereTranscribe

    public var id: String { rawValue }

    public var requiresAppleSilicon: Bool {
        switch self {
        case .parakeetFlash, .parakeetV2, .parakeetV3, .nemotronFast, .nemotronMultilingual, .cohereTranscribe:
            return true
        default:
            return false
        }
    }
}

public struct ASRModelDescriptor: Sendable, Identifiable {
    public let model: ASRModel
    public let displayName: String
    /// Short marketing-style name shown in the stats panel header.
    public let tagline: String
    /// One-sentence description of the model's strengths and ideal use case.
    public let description: String
    public let downloadSizeMB: Int
    public let supportsStreaming: Bool
    /// ISO 639-1 codes; empty means all system languages.
    public let languages: [String]
    public let requiresAppleSilicon: Bool
    /// Relative speed (0–1). Used for speed indicator bar.
    public let speedPercent: Double
    /// Relative accuracy (0–1). Used for accuracy indicator bar.
    public let accuracyPercent: Double
    /// Optional short badge, e.g. "Alric Pick", "Beta", "Best Accuracy".
    public let badge: String?
    /// Warning shown for models with high RAM requirements.
    public let memoryWarning: String?
    /// Minimum recommended RAM in GB for stable operation.
    public let recommendedRAM_GB: Double

    public var id: String { model.rawValue }

    // swiftlint:disable function_body_length
    public static let catalog: [ASRModelDescriptor] = [
        .init(
            model: .appleSpeech,
            displayName: "Apple Speech",
            tagline: "Built-in & Instant",
            description: "macOS built-in speech recognition. No download, no setup — works immediately on any Mac. Best for quick dictation when you don't need high accuracy.",
            downloadSizeMB: 0,
            supportsStreaming: true,
            languages: [],
            requiresAppleSilicon: false,
            speedPercent: 0.60,
            accuracyPercent: 0.60,
            badge: nil,
            memoryWarning: nil,
            recommendedRAM_GB: 2
        ),
        .init(
            model: .whisperTiny,
            displayName: "Whisper Tiny",
            tagline: "Fast & Lightweight",
            description: "Minimal resource usage. Best for older Macs or when battery life matters. Accuracy is limited — expect more corrections needed.",
            downloadSizeMB: 75,
            supportsStreaming: false,
            languages: [],
            requiresAppleSilicon: false,
            speedPercent: 0.90,
            accuracyPercent: 0.40,
            badge: nil,
            memoryWarning: nil,
            recommendedRAM_GB: 2
        ),
        .init(
            model: .whisperBase,
            displayName: "Whisper Base",
            tagline: "Solid All-Rounder",
            description: "Good balance of speed and accuracy. Works on any Mac. A practical first choice for English dictation without needing Apple Silicon.",
            downloadSizeMB: 142,
            supportsStreaming: false,
            languages: [],
            requiresAppleSilicon: false,
            speedPercent: 0.80,
            accuracyPercent: 0.60,
            badge: nil,
            memoryWarning: nil,
            recommendedRAM_GB: 3
        ),
        .init(
            model: .whisperSmall,
            displayName: "Whisper Small",
            tagline: "Better Accuracy, Still Fast",
            description: "Noticeably better transcription quality than Base with moderate resource usage. A solid upgrade if you type long documents or work in multiple languages.",
            downloadSizeMB: 466,
            supportsStreaming: false,
            languages: [],
            requiresAppleSilicon: false,
            speedPercent: 0.60,
            accuracyPercent: 0.70,
            badge: nil,
            memoryWarning: nil,
            recommendedRAM_GB: 4
        ),
        .init(
            model: .whisperMedium,
            displayName: "Whisper Medium",
            tagline: "High Accuracy",
            description: "Strong transcription quality for demanding tasks. Slower than Small — expect a noticeable pause after you stop speaking. Requires adequate RAM.",
            downloadSizeMB: 1500,
            supportsStreaming: false,
            languages: [],
            requiresAppleSilicon: false,
            speedPercent: 0.40,
            accuracyPercent: 0.80,
            badge: nil,
            memoryWarning: "Requires 6 GB+ RAM for stable operation.",
            recommendedRAM_GB: 6
        ),
        .init(
            model: .whisperLarge,
            displayName: "Whisper Large",
            tagline: "Maximum Accuracy",
            description: "Best possible Whisper accuracy across all 99 languages. Slowest of the family and heaviest on memory — best suited to M-series Macs with 16 GB+.",
            downloadSizeMB: 2900,
            supportsStreaming: false,
            languages: [],
            requiresAppleSilicon: false,
            speedPercent: 0.20,
            accuracyPercent: 1.00,
            badge: nil,
            memoryWarning: "Requires 10 GB+ RAM. May crash on Macs with 8 GB or less.",
            recommendedRAM_GB: 10
        ),
        .init(
            model: .parakeetFlash,
            displayName: "Parakeet Flash",
            tagline: "Lowest Latency Streaming",
            description: "Real-time English streaming with end-of-utterance detection and partial text as you speak. Words appear as you talk. English only — best for fast live dictation.",
            downloadSizeMB: 430,
            supportsStreaming: true,
            languages: ["en"],
            requiresAppleSilicon: true,
            speedPercent: 1.0,
            accuracyPercent: 0.75,
            badge: "Beta",
            memoryWarning: nil,
            recommendedRAM_GB: 4
        ),
        .init(
            model: .parakeetV2,
            displayName: "Parakeet TDT v2",
            tagline: "Blazing Fast — English",
            description: "Optimised for English accuracy at maximum speed. Ideal for anyone who dictates in English and wants the fastest turnaround. Streams partial results live.",
            downloadSizeMB: 463,
            supportsStreaming: true,
            languages: ["en"],
            requiresAppleSilicon: true,
            speedPercent: 1.0,
            accuracyPercent: 0.96,
            badge: "Alric Pick",
            memoryWarning: nil,
            recommendedRAM_GB: 4
        ),
        .init(
            model: .parakeetV3,
            displayName: "Parakeet TDT v3",
            tagline: "Blazing Fast — 25 Languages",
            description: "Same speed as v2 but adds 24 European languages (Bulgarian, Croatian, Czech, Danish, Dutch, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, Ukrainian). The go-to choice for multilingual users on Apple Silicon.",
            downloadSizeMB: 483,
            supportsStreaming: true,
            languages: ["bg","hr","cs","da","nl","en","et","fi","fr","de","el","hu","it","lv","lt","mt","pl","pt","ro","ru","sk","sl","es","sv","uk"],
            requiresAppleSilicon: true,
            speedPercent: 1.0,
            accuracyPercent: 0.92,
            badge: "Alric Pick",
            memoryWarning: nil,
            recommendedRAM_GB: 4
        ),
        .init(
            model: .nemotronFast,
            displayName: "Nemotron Speech 3.5 Fast",
            tagline: "Ultra-Fast Streaming — 40 Languages",
            description: "NVIDIA Nemotron 3.5 streaming variant. Near-instant response across ~40 language locales with automatic language detection. Choose this over the multilingual variant when speed is the priority.",
            downloadSizeMB: 670,
            supportsStreaming: true,
            languages: [],
            requiresAppleSilicon: true,
            speedPercent: 1.0,
            accuracyPercent: 0.85,
            badge: "New",
            memoryWarning: nil,
            recommendedRAM_GB: 8
        ),
        .init(
            model: .nemotronMultilingual,
            displayName: "Nemotron 3.5 Multilingual",
            tagline: "High Accuracy — 40 Languages",
            description: "NVIDIA Nemotron 3.5 offline variant. More accurate than the Fast model at the cost of speed. Best when transcription quality matters more than response time. Supports ~40 language locales with manual or automatic language selection.",
            downloadSizeMB: 530,
            supportsStreaming: false,
            languages: [],
            requiresAppleSilicon: true,
            speedPercent: 0.85,
            accuracyPercent: 0.90,
            badge: "New",
            memoryWarning: nil,
            recommendedRAM_GB: 8
        ),
        .init(
            model: .cohereTranscribe,
            displayName: "Cohere Transcribe",
            tagline: "Highest Accuracy — 14 Languages",
            description: "State-of-the-art transcription accuracy across 14 languages (English, French, German, Italian, Spanish, Portuguese, Greek, Dutch, Polish, Chinese, Japanese, Korean, Vietnamese, Arabic). Select your language manually before dictating for best results. Largest download in the catalog.",
            downloadSizeMB: 1540,
            supportsStreaming: false,
            languages: ["en","fr","de","it","es","pt","el","nl","pl","zh","ja","ko","vi","ar"],
            requiresAppleSilicon: true,
            speedPercent: 0.85,
            accuracyPercent: 0.98,
            badge: "Best Accuracy",
            memoryWarning: nil,
            recommendedRAM_GB: 8
        ),
    ]
    // swiftlint:enable function_body_length
}
