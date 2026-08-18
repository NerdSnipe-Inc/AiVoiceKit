// Sources/AiVoiceKit/macOS/Persistence/DictionaryTransferService.swift
#if os(macOS)
import Foundation

public struct DictionaryTransferReplacement: Codable, Equatable, Sendable {
    public let from: [String]
    public let to: String

    public init(from: [String], to: String) {
        self.from = from
        self.to = to
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.from) {
            self.from = try Self.decodeStringList(from: container, key: .from)
        } else if container.contains(.triggers) {
            self.from = try Self.decodeStringList(from: container, key: .triggers)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.from,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected from or triggers.")
            )
        }

        self.to = try container.decodeIfPresent(String.self, forKey: .to)
            ?? container.decode(String.self, forKey: .replacement)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.from, forKey: .from)
        try container.encode(self.to, forKey: .to)
    }

    private enum CodingKeys: String, CodingKey {
        case from
        case to
        case triggers
        case replacement
    }

    private static func decodeStringList(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [String] {
        if let values = try? container.decodeIfPresent([String].self, forKey: key) {
            return values
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return [value]
        }
        if try container.decodeNil(forKey: key) {
            return []
        }
        var codingPath = container.codingPath
        codingPath.append(key)
        throw DecodingError.typeMismatch(
            [String].self,
            DecodingError.Context(codingPath: codingPath, debugDescription: "Expected a string or list of strings.")
        )
    }
}

public struct DictionaryTransferCustomWord: Codable, Equatable, Sendable {
    public let text: String
    public let weight: Float?

    public init(text: String, weight: Float?) {
        self.text = text
        self.weight = weight
    }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.text = text
            self.weight = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.weight = try container.decodeIfPresent(Float.self, forKey: .weight)
    }

    public func encode(to encoder: Encoder) throws {
        if self.weight == nil {
            var container = encoder.singleValueContainer()
            try container.encode(self.text)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.text, forKey: .text)
        try container.encodeIfPresent(self.weight, forKey: .weight)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case weight
    }
}

public struct DictionaryTransferDocument: Codable, Equatable, Sendable {
    public let replacements: [DictionaryTransferReplacement]
    public let customWords: [DictionaryTransferCustomWord]

    public init(replacements: [DictionaryTransferReplacement], customWords: [String]) {
        self.init(
            replacements: replacements,
            customWordEntries: customWords.map { DictionaryTransferCustomWord(text: $0, weight: nil) }
        )
    }

    public init(replacements: [DictionaryTransferReplacement], customWordEntries: [DictionaryTransferCustomWord]) {
        self.replacements = replacements
        self.customWords = customWordEntries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let replacements = try Self.decodeReplacements(from: container)
        let customWords = try Self.decodeCustomWords(from: container)

        guard replacements.found || customWords.found else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected replacements, customWords, terms, or API items/entries."
                )
            )
        }

        self.replacements = replacements.values
        self.customWords = customWords.values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.replacements, forKey: .replacements)
        try container.encode(self.customWords, forKey: .customWords)
    }

    private enum CodingKeys: String, CodingKey {
        case replacements
        case customWords
        case terms
        case items
        case entries
    }

    private static func decodeReplacements(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> (found: Bool, values: [DictionaryTransferReplacement]) {
        if container.contains(.replacements) {
            return try (true, container.decode([DictionaryTransferReplacement].self, forKey: .replacements))
        }
        if container.contains(.items),
           let replacements = try? container.decode([DictionaryTransferReplacement].self, forKey: .items)
        {
            return (true, replacements)
        }
        if container.contains(.entries),
           let replacements = try? container.decode([DictionaryTransferReplacement].self, forKey: .entries)
        {
            return (true, replacements)
        }
        return (false, [])
    }

    private static func decodeCustomWords(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> (found: Bool, values: [DictionaryTransferCustomWord]) {
        let customWords = try Self.decodeCustomWordValues(from: container, key: .customWords)
        if customWords.found { return customWords }
        let terms = try Self.decodeCustomWordValues(from: container, key: .terms)
        if terms.found { return terms }
        if container.contains(.items),
           let items = try? Self.decodeCustomWordValues(from: container, key: .items),
           items.found
        {
            return items
        }
        if container.contains(.entries),
           let entries = try? Self.decodeCustomWordValues(from: container, key: .entries),
           entries.found
        {
            return entries
        }
        return (false, [])
    }

    private static func decodeCustomWordValues(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> (found: Bool, values: [DictionaryTransferCustomWord]) {
        guard container.contains(key) else { return (false, []) }
        return try (true, container.decode([DictionaryTransferCustomWord].self, forKey: key))
    }
}

public enum DictionaryTransferImportMode: Sendable {
    case merge
    case replace
}

public struct DictionaryTransferState: Sendable {
    public let replacements: [VoiceSettingsStore.CustomDictionaryEntry]
    public let customWords: [ParakeetVocabularyStore.VocabularyConfig.Term]
}

public struct DictionaryTransferSummary: Sendable {
    public let replacementCount: Int
    public let customWordCount: Int
}

public enum DictionaryTransferServiceError: LocalizedError, Sendable {
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The selected file is not a valid Alric dictionary file."
        }
    }
}

@MainActor
public final class DictionaryTransferService {
    public static let shared = DictionaryTransferService()

    private static let importedCustomWordWeight: Float = 10.0
    private static let maxCustomWords = 256

    private init() {}

    public func makeExportDocument() throws -> DictionaryTransferDocument {
        try DictionaryTransferDocument(
            replacements: VoiceSettingsStore.shared.customDictionaryEntries.compactMap(Self.exportReplacement(from:)),
            customWordEntries: Self.exportCustomWords(from: ParakeetVocabularyStore.shared.loadUserBoostTerms())
        )
    }

    public func encode(_ document: DictionaryTransferDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Self.normalizedDocument(document))
    }

    public func decode(_ data: Data) throws -> DictionaryTransferDocument {
        do {
            let document = try JSONDecoder().decode(DictionaryTransferDocument.self, from: data)
            return Self.normalizedDocument(document)
        } catch {
            throw DictionaryTransferServiceError.invalidJSON
        }
    }

    @discardableResult
    public func restore(_ document: DictionaryTransferDocument, mode: DictionaryTransferImportMode) throws -> DictionaryTransferSummary {
        let state = try Self.importState(
            document: document,
            mode: mode,
            currentReplacements: VoiceSettingsStore.shared.customDictionaryEntries,
            currentCustomWords: ParakeetVocabularyStore.shared.loadUserBoostTerms()
        )

        try ParakeetVocabularyStore.shared.saveUserBoostTerms(state.customWords)
        VoiceSettingsStore.shared.customDictionaryEntries = state.replacements
        NotificationCenter.default.post(name: .alricDictionaryCacheDidInvalidate, object: nil)
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)

        return DictionaryTransferSummary(
            replacementCount: state.replacements.count,
            customWordCount: state.customWords.count
        )
    }

    public func suggestedFilename(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "AlricVoice_Dictionary_\(formatter.string(from: date)).json"
    }

    public static func importState(
        document: DictionaryTransferDocument,
        mode: DictionaryTransferImportMode,
        currentReplacements: [VoiceSettingsStore.CustomDictionaryEntry],
        currentCustomWords: [ParakeetVocabularyStore.VocabularyConfig.Term]
    ) throws -> DictionaryTransferState {
        let normalizedDocument = self.normalizedDocument(document)
        var replacements = mode == .replace ? [] : currentReplacements
        for replacement in normalizedDocument.replacements {
            guard let entry = self.storeReplacement(from: replacement) else { continue }
            self.upsert(entry, into: &replacements)
        }

        var customWords = mode == .replace ? [] : currentCustomWords
        for word in normalizedDocument.customWords {
            guard customWords.count < self.maxCustomWords else { break }
            if customWords.contains(where: { $0.text.caseInsensitiveCompare(word.text) == .orderedSame }) {
                continue
            }
            customWords.append(
                ParakeetVocabularyStore.VocabularyConfig.Term(
                    text: word.text,
                    weight: word.weight ?? self.importedCustomWordWeight,
                    aliases: []
                )
            )
        }

        return DictionaryTransferState(replacements: replacements, customWords: customWords)
    }

    private static func normalizedDocument(_ document: DictionaryTransferDocument) -> DictionaryTransferDocument {
        DictionaryTransferDocument(
            replacements: document.replacements.compactMap(self.exportReplacement(from:)),
            customWordEntries: self.exportCustomWords(from: document.customWords)
        )
    }

    private static func exportReplacement(from entry: VoiceSettingsStore.CustomDictionaryEntry) -> DictionaryTransferReplacement? {
        let from = self.normalizedUniqueStrings(entry.triggers, lowercased: true)
        let to = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return DictionaryTransferReplacement(from: from, to: to)
    }

    private static func exportReplacement(from replacement: DictionaryTransferReplacement) -> DictionaryTransferReplacement? {
        let from = self.normalizedUniqueStrings(replacement.from, lowercased: true)
        let to = replacement.to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return DictionaryTransferReplacement(from: from, to: to)
    }

    private static func storeReplacement(
        from replacement: DictionaryTransferReplacement
    ) -> VoiceSettingsStore.CustomDictionaryEntry? {
        let from = self.normalizedUniqueStrings(replacement.from, lowercased: true)
        let to = replacement.to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return VoiceSettingsStore.CustomDictionaryEntry(triggers: from, replacement: to)
    }

    private static func exportCustomWords(
        from terms: [ParakeetVocabularyStore.VocabularyConfig.Term]
    ) -> [DictionaryTransferCustomWord] {
        self.exportCustomWords(
            from: terms.map { DictionaryTransferCustomWord(text: $0.text, weight: $0.weight) }
        )
    }

    private static func exportCustomWords(
        from words: [DictionaryTransferCustomWord]
    ) -> [DictionaryTransferCustomWord] {
        var seen: Set<String> = []
        var result: [DictionaryTransferCustomWord] = []
        result.reserveCapacity(words.count)

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(DictionaryTransferCustomWord(text: text, weight: word.weight))
        }

        return result
    }

    private static func upsert(
        _ entry: VoiceSettingsStore.CustomDictionaryEntry,
        into entries: inout [VoiceSettingsStore.CustomDictionaryEntry]
    ) {
        let matchingIndex = entries.firstIndex {
            $0.replacement.caseInsensitiveCompare(entry.replacement) == .orderedSame
        }
        let replacementID = matchingIndex.map { entries[$0].id } ?? entry.id
        let replacementText = matchingIndex.map { entries[$0].replacement } ?? entry.replacement
        let previousTriggers = matchingIndex.map { entries[$0].triggers } ?? []
        let combinedTriggers = self.normalizedUniqueStrings(previousTriggers + entry.triggers, lowercased: true)
        let triggerKeys = Set(combinedTriggers.map { $0.lowercased() })

        entries.removeAll {
            $0.replacement.caseInsensitiveCompare(entry.replacement) == .orderedSame
        }

        entries = entries.compactMap { existing in
            let remainingTriggers = existing.triggers.filter { !triggerKeys.contains($0.lowercased()) }
            guard !remainingTriggers.isEmpty else { return nil }
            return VoiceSettingsStore.CustomDictionaryEntry(
                id: existing.id,
                triggers: remainingTriggers,
                replacement: existing.replacement
            )
        }

        entries.append(
            VoiceSettingsStore.CustomDictionaryEntry(
                id: replacementID,
                triggers: combinedTriggers,
                replacement: replacementText
            )
        )
    }

    private static func normalizedUniqueStrings(_ values: [String], lowercased: Bool) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(values.count)

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let output = lowercased ? trimmed.lowercased() : trimmed
            let key = output.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(output)
        }

        return result
    }
}

extension Notification.Name {
    /// Posted when the dictionary cache should be invalidated (e.g. after import/restore).
    public static let alricDictionaryCacheDidInvalidate = Notification.Name("AlricDictionaryCacheDidInvalidate")
}
#endif
