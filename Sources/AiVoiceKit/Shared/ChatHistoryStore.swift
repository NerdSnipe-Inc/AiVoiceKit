// Sources/AiVoiceKit/Shared/ChatHistoryStore.swift
import Foundation

// MARK: - VoiceChatSession

public struct VoiceChatSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var messages: [VoiceChatMessage]

    public init(id: UUID = UUID(), startedAt: Date = Date(), messages: [VoiceChatMessage] = []) {
        self.id = id
        self.startedAt = startedAt
        self.messages = messages
    }
}

public struct VoiceChatMessage: Codable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public let text: String
    public let timestamp: Date

    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - ChatHistoryStore

/// Persists voice chat sessions to disk as JSON.
public final class ChatHistoryStore: @unchecked Sendable {

    public static let shared: ChatHistoryStore = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AiVoiceKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let url = appSupport.appendingPathComponent("chat-history.json")
        return ChatHistoryStore(storageURL: url)
    }()

    private let lock = NSLock()
    private var _sessions: [VoiceChatSession]
    private let storageURL: URL

    public var maxSessions: Int = 200

    public init(storageURL: URL) {
        self.storageURL = storageURL
        self._sessions = Self.load(from: storageURL)
    }

    // MARK: - Public API

    public var sessions: [VoiceChatSession] {
        lock.withLock { _sessions }
    }

    public func append(_ session: VoiceChatSession) {
        lock.withLock {
            _sessions.insert(session, at: 0)
            if maxSessions > 0, _sessions.count > maxSessions {
                _sessions = Array(_sessions.prefix(maxSessions))
            }
        }
        persist()
    }

    public func update(_ session: VoiceChatSession) {
        lock.withLock {
            if let idx = _sessions.firstIndex(where: { $0.id == session.id }) {
                _sessions[idx] = session
            }
        }
        persist()
    }

    public func delete(id: UUID) {
        lock.withLock { _sessions.removeAll { $0.id == id } }
        persist()
    }

    public func deleteAll() {
        lock.withLock { _sessions.removeAll() }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = lock.withLock { _sessions }
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func load(from url: URL) -> [VoiceChatSession] {
        guard let data = try? Data(contentsOf: url),
              let sessions = try? JSONDecoder().decode([VoiceChatSession].self, from: data)
        else { return [] }
        return sessions
    }
}
