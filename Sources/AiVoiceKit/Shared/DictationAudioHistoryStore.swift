// Sources/AiVoiceKit/Shared/DictationAudioHistoryStore.swift
#if os(macOS)
import AVFoundation
import Foundation

// MARK: - DictationAudioRecord

public struct DictationAudioRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let entryID: UUID
    public let fileName: String
    public let durationSeconds: Double
    public let createdAt: Date

    public init(id: UUID = UUID(), entryID: UUID, fileName: String, durationSeconds: Double, createdAt: Date = Date()) {
        self.id = id
        self.entryID = entryID
        self.fileName = fileName
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

// MARK: - DictationAudioHistoryStore

/// Stores .m4a audio recordings alongside transcription entries.
/// Recording is opt-in via `VoiceSettingsStore.saveAudioWithHistory`.
public final class DictationAudioHistoryStore: @unchecked Sendable {

    public static let shared = DictationAudioHistoryStore()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private var recorder: AVAudioRecorder?
    private var activeEntryID: UUID?

    private init() {}

    // MARK: - Directory

    private func audioDirectory() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("AiVoiceKit", isDirectory: true)
            .appendingPathComponent("DictationAudio", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Recording

    public func startRecording(entryID: UUID) throws {
        guard VoiceSettingsStore.shared.saveAudioWithHistory else { return }

        let dir = try audioDirectory()
        let fileName = "\(entryID.uuidString)-\(Int(Date().timeIntervalSince1970)).m4a"
        let url = dir.appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.record()
        lock.withLock {
            self.recorder = rec
            self.activeEntryID = entryID
        }
    }

    /// Stops recording and returns metadata if recording was active.
    @discardableResult
    public func stopRecording() -> DictationAudioRecord? {
        lock.withLock {
            guard let rec = recorder, let entryID = activeEntryID else { return nil }
            rec.stop()
            let duration = rec.currentTime
            let fileName = rec.url.lastPathComponent
            self.recorder = nil
            self.activeEntryID = nil
            return DictationAudioRecord(
                entryID: entryID,
                fileName: fileName,
                durationSeconds: duration
            )
        }
    }

    // MARK: - File access

    public func audioFileURL(fileName: String) -> URL? {
        guard let dir = try? audioDirectory() else { return nil }
        let url = dir.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func deleteAudio(fileName: String) {
        guard let dir = try? audioDirectory() else { return }
        let url = dir.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: url)
    }

    public func deleteAllAudioFiles() {
        guard let dir = try? audioDirectory() else { return }
        let urls = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "m4a" {
            try? fileManager.removeItem(at: url)
        }
    }

    public func audioUsageBytes() -> Int64 {
        guard let dir = try? audioDirectory() else { return 0 }
        let urls = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}
#endif
