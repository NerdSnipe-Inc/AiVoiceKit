// Sources/AiVoiceKit/Shared/ModelRepository.swift
import Foundation

public final class ModelRepository: @unchecked Sendable {
    public static let shared = ModelRepository()
    private init() {}

    public func descriptor(for model: ASRModel) -> ASRModelDescriptor? {
        ASRModelDescriptor.catalog.first { $0.model == model }
    }

    public func isAvailableWithoutDownload(_ model: ASRModel) -> Bool {
        model == .appleSpeech
    }

    public func isDownloaded(_ model: ASRModel) -> Bool {
        guard model != .appleSpeech else { return true }
        let url = downloadedModelURL(for: model)
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func downloadedModelURL(for model: ASRModel) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AiVoiceKit/Models", isDirectory: true)
        return base.appendingPathComponent(model.rawValue, isDirectory: true)
    }
}
