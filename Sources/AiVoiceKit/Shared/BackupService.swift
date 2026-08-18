// Sources/AiVoiceKit/Shared/BackupService.swift
#if os(macOS)
import Foundation

// MARK: - BackupError

public enum BackupError: LocalizedError, Sendable {
    case applicationSupportUnavailable
    case encodingFailed
    case zipFailed(String)
    case exportDirectoryUnavailable
    case importEmpty

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Could not access Application Support."
        case .encodingFailed:
            return "Failed to encode history for export."
        case let .zipFailed(detail):
            return "ZIP creation failed: \(detail)"
        case .exportDirectoryUnavailable:
            return "Export directory is unavailable."
        case .importEmpty:
            return "The backup file contains no entries."
        }
    }
}

// MARK: - BackupService

/// Exports AiVoiceKit history to a ZIP archive (entries JSON + audio files).
public final class BackupService: Sendable {

    public static let shared = BackupService()
    private init() {}

    // MARK: - Export

    /// Creates a ZIP containing `history.json` and any .m4a audio files.
    /// - Parameter destinationURL: where to write the .zip file
    @discardableResult
    public func exportHistory(to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
            .appendingPathComponent("AiVoiceKitExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tmp) }

        // Write history JSON
        let entries = TranscriptionHistoryStore.shared.entries
        let historyData = try JSONEncoder().encode(entries)
        let historyURL = tmp.appendingPathComponent("history.json")
        try historyData.write(to: historyURL, options: .atomic)

        // Copy audio files if present
        let audioDir = try audioDirectory()
        let audioFiles = (try? fileManager.contentsOfDirectory(
            at: audioDir,
            includingPropertiesForKeys: nil
        )) ?? []
        let audioExportDir = tmp.appendingPathComponent("audio", isDirectory: true)
        if !audioFiles.isEmpty {
            try fileManager.createDirectory(at: audioExportDir, withIntermediateDirectories: true)
            for file in audioFiles where file.pathExtension == "m4a" {
                let dest = audioExportDir.appendingPathComponent(file.lastPathComponent)
                try fileManager.copyItem(at: file, to: dest)
            }
        }

        // Run /usr/bin/zip
        let zipResult = runZip(sourceDirectory: tmp, destinationURL: destinationURL)
        if !zipResult.success {
            throw BackupError.zipFailed(zipResult.output)
        }

        return destinationURL
    }

    // MARK: - Import / Restore

    /// Restores history from a previously exported `history.json`.
    public func importHistory(from jsonURL: URL) throws {
        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
        guard !decoded.isEmpty else { throw BackupError.importEmpty }
        TranscriptionHistoryStore.shared.deleteAll()
        for entry in decoded.reversed() {
            TranscriptionHistoryStore.shared.append(entry)
        }
    }

    // MARK: - Private helpers

    private func audioDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("AiVoiceKit", isDirectory: true)
            .appendingPathComponent("DictationAudio", isDirectory: true)
    }

    private func runZip(sourceDirectory: URL, destinationURL: URL) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = [
            "-r",
            destinationURL.path,
            ".",
        ]
        process.currentDirectoryURL = sourceDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output)
    }
}
#endif
