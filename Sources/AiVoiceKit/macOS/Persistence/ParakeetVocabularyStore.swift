// Sources/AiVoiceKit/macOS/Persistence/ParakeetVocabularyStore.swift
#if os(macOS)
import Foundation
#if arch(arm64)
import FluidAudio
#endif

/// JSON-backed store for Parakeet vocabulary boosting terms.
/// Persists to Application Support so it survives app updates and can be user-edited.
public final class ParakeetVocabularyStore: @unchecked Sendable {
    public nonisolated(unsafe) static let shared = ParakeetVocabularyStore()

    public struct VocabularyConfig: Codable, Sendable {
        public struct Term: Codable, Hashable, Sendable {
            public let text: String
            public let weight: Float?
            public let aliases: [String]

            public init(text: String, weight: Float?, aliases: [String] = []) {
                self.text = text
                self.weight = weight
                self.aliases = aliases
            }

            private enum CodingKeys: String, CodingKey {
                case text
                case weight
                case aliases
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.text = try container.decode(String.self, forKey: .text)
                self.weight = try container.decodeIfPresent(Float.self, forKey: .weight)
                self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(self.text, forKey: .text)
                try container.encodeIfPresent(self.weight, forKey: .weight)
                if !self.aliases.isEmpty {
                    try container.encode(self.aliases, forKey: .aliases)
                }
            }
        }

        public let alpha: Float?
        public let minCtcScore: Float?
        public let minSimilarity: Float?
        public let minCombinedConfidence: Float?
        public let minTermLength: Int?
        public let terms: [Term]
    }

    public struct ResolvedConfig: Sendable {
        public let alpha: Float
        public let minCtcScore: Float
        public let minSimilarity: Float
        public let minCombinedConfidence: Float
        public let minTermLength: Int
        public let terms: [VocabularyConfig.Term]
    }

    public enum StoreError: LocalizedError {
        case invalidJSON(String)
        case applicationSupportUnavailable

        public var errorDescription: String? {
            switch self {
            case let .invalidJSON(details):
                return "Invalid vocabulary JSON: \(details)"
            case .applicationSupportUnavailable:
                return "Could not access Application Support directory."
            }
        }
    }

    private enum Defaults {
        static let alpha: Float = 2.8
        static let minCtcScore: Float = -2.2
        static let minSimilarity: Float = 0.72
        static let minCombinedConfidence: Float = 0.64
        static let minTermLength: Int = 3
        static let maxTerms: Int = 256
    }

    private let fileName = "alric_custom_vocabulary.json"
    private let appSupportFolder = "AlricVoice"

    private init() {}

    public func vocabularyFileURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.applicationSupportUnavailable
        }
        let directory = base.appendingPathComponent(self.appSupportFolder, isDirectory: true)
        DebugLogger.shared.debug(
            "ParakeetVocabularyStore: app support directory=\(directory.path)",
            source: "ParakeetVocabularyStore"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(self.fileName)
    }

    @discardableResult
    public func ensureVocabularyFileExists() throws -> URL {
        let url = try self.vocabularyFileURL()
        DebugLogger.shared.debug("ParakeetVocabularyStore: checking vocabulary file \(url.path)", source: "ParakeetVocabularyStore")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }

        if let bundled = Bundle.main.url(forResource: "alric_custom_vocabulary.default", withExtension: "json"),
           let bundledText = try? String(contentsOf: bundled, encoding: .utf8)
        {
            try bundledText.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try Self.defaultTemplateJSON().write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    public func loadRawJSON() throws -> String {
        let url = try self.ensureVocabularyFileExists()
        DebugLogger.shared.debug("ParakeetVocabularyStore: loading raw JSON from \(url.path)", source: "ParakeetVocabularyStore")
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func validateJSON(_ json: String) throws -> VocabularyConfig {
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode(VocabularyConfig.self, from: data)
        } catch {
            throw StoreError.invalidJSON(error.localizedDescription)
        }
    }

    public func saveRawJSON(_ json: String) throws {
        _ = try self.validateJSON(json)
        let url = try self.ensureVocabularyFileExists()
        try json.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
    }

    public func loadUserBoostTerms() throws -> [VocabularyConfig.Term] {
        let rawJSON = try self.loadRawJSON()
        let parsed = try self.validateJSON(rawJSON)
        return Self.normalizeUserTerms(parsed.terms, maxTerms: Defaults.maxTerms)
    }

    public func saveUserBoostTerms(_ terms: [VocabularyConfig.Term]) throws {
        let normalizedTerms = Self.normalizeUserTerms(terms, maxTerms: Defaults.maxTerms)
        let config = VocabularyConfig(
            alpha: Defaults.alpha,
            minCtcScore: Defaults.minCtcScore,
            minSimilarity: Defaults.minSimilarity,
            minCombinedConfidence: Defaults.minCombinedConfidence,
            minTermLength: Defaults.minTermLength,
            terms: normalizedTerms
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidJSON("Failed to encode boost terms.")
        }

        let url = try self.ensureVocabularyFileExists()
        try text.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
    }

    public func hasAnyBoostTerms() -> Bool {
        (try? self.loadResolvedConfig())?.terms.isEmpty == false
    }

    public func loadResolvedConfig() throws -> ResolvedConfig {
        let rawJSON = try self.loadRawJSON()
        let parsed = (try? self.validateJSON(rawJSON)) ?? VocabularyConfig(
            alpha: nil,
            minCtcScore: nil,
            minSimilarity: nil,
            minCombinedConfidence: nil,
            minTermLength: nil,
            terms: []
        )
        DebugLogger.shared.debug(
            "ParakeetVocabularyStore: loaded base config terms=\(parsed.terms.count)",
            source: "ParakeetVocabularyStore"
        )

        let mergedTerms = self.mergeAndNormalizeTerms(
            jsonTerms: parsed.terms,
            dictionaryEntries: VoiceSettingsStore.shared.customDictionaryEntries
        )
        DebugLogger.shared.debug(
            "ParakeetVocabularyStore: merged terms=\(mergedTerms.count), dictionaryEntries=\(VoiceSettingsStore.shared.customDictionaryEntries.count)",
            source: "ParakeetVocabularyStore"
        )

        return ResolvedConfig(
            alpha: Defaults.alpha,
            minCtcScore: Defaults.minCtcScore,
            minSimilarity: Defaults.minSimilarity,
            minCombinedConfidence: Defaults.minCombinedConfidence,
            minTermLength: Defaults.minTermLength,
            terms: mergedTerms
        )
    }

    private func mergeAndNormalizeTerms(
        jsonTerms: [VocabularyConfig.Term],
        dictionaryEntries: [VoiceSettingsStore.CustomDictionaryEntry]
    ) -> [VocabularyConfig.Term] {
        DebugLogger.shared.debug(
            "ParakeetVocabularyStore: merge input jsonTerms=\(jsonTerms.count), dictionaryEntries=\(dictionaryEntries.count)",
            source: "ParakeetVocabularyStore"
        )
        var mergedByText: [String: VocabularyConfig.Term] = [:]

        func normalizeAliases(_ aliases: [String], excluding text: String) -> [String] {
            let normalized = aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { $0.caseInsensitiveCompare(text) != .orderedSame }
            let deduped = Array(Set(normalized.map { $0.lowercased() })).sorted()
            return deduped
        }

        func upsert(_ term: VocabularyConfig.Term) {
            let normalizedText = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else { return }
            let key = normalizedText.lowercased()

            if let existing = mergedByText[key] {
                let combinedAliases = Array(Set(existing.aliases + term.aliases)).sorted()
                let combinedWeight = max(existing.weight ?? 0, term.weight ?? 0)
                mergedByText[key] = VocabularyConfig.Term(
                    text: existing.text,
                    weight: combinedWeight > 0 ? combinedWeight : nil,
                    aliases: combinedAliases
                )
                return
            }

            mergedByText[key] = VocabularyConfig.Term(
                text: normalizedText,
                weight: term.weight,
                aliases: normalizeAliases(term.aliases, excluding: normalizedText)
            )
        }

        for term in jsonTerms {
            upsert(term)
        }

        for entry in dictionaryEntries {
            let replacement = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else { continue }
            let aliases = entry.triggers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            upsert(VocabularyConfig.Term(text: replacement, weight: 8.0, aliases: aliases))
        }

        let merged = mergedByText.values.sorted { lhs, rhs in
            lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
        }
        DebugLogger.shared.debug(
            "ParakeetVocabularyStore: merge output count=\(merged.count)",
            source: "ParakeetVocabularyStore"
        )
        return merged
    }

    private static func normalizeUserTerms(_ terms: [VocabularyConfig.Term], maxTerms: Int) -> [VocabularyConfig.Term] {
        var seen: Set<String> = []
        var normalized: [VocabularyConfig.Term] = []
        normalized.reserveCapacity(min(terms.count, maxTerms))

        for term in terms {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let aliases = term.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { $0.caseInsensitiveCompare(text) != .orderedSame }

            let dedupedAliases = Array(Set(aliases.map { $0.lowercased() })).sorted()
            normalized.append(
                VocabularyConfig.Term(
                    text: text,
                    weight: term.weight,
                    aliases: dedupedAliases
                )
            )

            if normalized.count >= maxTerms {
                break
            }
        }

        return normalized
    }

    public static func defaultTemplateJSON() -> String {
        """
        {
          "alpha": 2.8,
          "minCtcScore": -2.2,
          "minSimilarity": 0.72,
          "minCombinedConfidence": 0.64,
          "minTermLength": 3,
          "terms": []
        }
        """
    }
}

extension Notification.Name {
    public static let parakeetVocabularyDidChange = Notification.Name("AlricParakeetVocabularyDidChange")
}

#if arch(arm64)
extension ParakeetVocabularyStore {
    /// Creates tokenized vocabulary + CTC models for FluidAudio vocabulary boosting.
    public func loadTokenizedVocabularyBundle(
        maxTerms: Int = 256
    ) async throws -> (vocabulary: CustomVocabularyContext, ctcModels: CtcModels)? {
        let resolved = try self.loadResolvedConfig()
        DebugLogger.shared.debug("ParakeetVocabularyStore: resolved vocabulary term count=\(resolved.terms.count)", source: "ParakeetVocabularyStore")
        guard !resolved.terms.isEmpty else {
            DebugLogger.shared.debug("ParakeetVocabularyStore: no resolved terms; returning nil bundle", source: "ParakeetVocabularyStore")
            return nil
        }

        let cappedLimit = min(maxTerms, 256)
        let prioritizedTerms = resolved.terms.sorted { lhs, rhs in
            let lhsWeight = lhs.weight ?? 0
            let rhsWeight = rhs.weight ?? 0
            if lhsWeight == rhsWeight {
                return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
            }
            return lhsWeight > rhsWeight
        }
        let cappedTerms = Array(prioritizedTerms.prefix(cappedLimit))
        DebugLogger.shared.debug(
            "ParakeetVocabularyStore: capped terms count=\(cappedTerms.count)",
            source: "ParakeetVocabularyStore"
        )
        let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let ctcTokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: ctcModels.variant))

        let tokenizedTerms: [CustomVocabularyTerm] = cappedTerms.compactMap { term in
            let tokens = ctcTokenizer.encode(term.text)
            guard !tokens.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                weight: term.weight,
                aliases: term.aliases,
                tokenIds: nil,
                ctcTokenIds: tokens
            )
        }

        DebugLogger.shared.debug("ParakeetVocabularyStore: tokenized term count=\(tokenizedTerms.count)", source: "ParakeetVocabularyStore")
        guard !tokenizedTerms.isEmpty else {
            DebugLogger.shared.debug("ParakeetVocabularyStore: tokenization produced empty list; returning nil bundle", source: "ParakeetVocabularyStore")
            return nil
        }

        let vocabulary = CustomVocabularyContext(
            terms: tokenizedTerms,
            alpha: resolved.alpha,
            minCtcScore: resolved.minCtcScore,
            minSimilarity: resolved.minSimilarity,
            minCombinedConfidence: resolved.minCombinedConfidence,
            minTermLength: resolved.minTermLength
        )
        return (vocabulary, ctcModels)
    }
}
#endif
#endif
