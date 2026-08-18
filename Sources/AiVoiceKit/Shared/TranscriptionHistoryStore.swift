// Sources/AiVoiceKit/Shared/TranscriptionHistoryStore.swift
import Foundation

// MARK: - TranscriptionEntry

public struct TranscriptionEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let model: ASRModel
    public let timestamp: Date
    public let audioDurationSeconds: Double?

    public init(
        id: UUID = UUID(),
        text: String,
        model: ASRModel,
        timestamp: Date = Date(),
        audioDurationSeconds: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.model = model
        self.timestamp = timestamp
        self.audioDurationSeconds = audioDurationSeconds
    }
}

// MARK: - TranscriptionHistoryStore

/// Thread-safe persistence store for dictation/transcription history.
/// Entries are written to a JSON file on disk.
public final class TranscriptionHistoryStore: @unchecked Sendable {

    // MARK: - Shared singleton

    public static let shared: TranscriptionHistoryStore = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AiVoiceKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let url = appSupport.appendingPathComponent("transcription-history.json")
        return TranscriptionHistoryStore(storageURL: url)
    }()

    // MARK: - State

    private let lock = NSLock()
    private var _entries: [TranscriptionEntry]
    private let storageURL: URL

    /// Maximum entries retained. 0 means unlimited.
    public var maxEntries: Int = 500

    // MARK: - Init

    public init(storageURL: URL) {
        self.storageURL = storageURL
        self._entries = Self.load(from: storageURL)
    }

    // MARK: - Public API

    public var entries: [TranscriptionEntry] {
        lock.withLock { _entries }
    }

    public func append(_ entry: TranscriptionEntry) {
        lock.withLock {
            _entries.insert(entry, at: 0)
            if maxEntries > 0, _entries.count > maxEntries {
                _entries = Array(_entries.prefix(maxEntries))
            }
        }
        persist()
    }

    public func delete(id: UUID) {
        lock.withLock {
            _entries.removeAll { $0.id == id }
        }
        persist()
    }

    public func deleteAll() {
        lock.withLock { _entries.removeAll() }
        persist()
    }

    public func search(query: String) -> [TranscriptionEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.text.lowercased().contains(q) }
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = lock.withLock { _entries }
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func load(from url: URL) -> [TranscriptionEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TranscriptionEntry].self, from: data)
        else { return [] }
        return entries
    }
}
