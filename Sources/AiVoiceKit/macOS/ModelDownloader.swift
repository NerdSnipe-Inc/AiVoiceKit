// Sources/AiVoiceKit/macOS/ModelDownloader.swift
#if os(macOS)
import Foundation

public enum ModelDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)
}

/// Downloads ASR models from remote URLs to the local Application Support directory.
/// Uses URLSession with background-style progress reporting.
@MainActor
public final class ModelDownloader: NSObject, ObservableObject {
    public static let shared = ModelDownloader()

    @Published public private(set) var states: [ASRModel: ModelDownloadState] = [:]

    private var tasks: [ASRModel: URLSessionDownloadTask] = [:]
    private var observations: [ASRModel: NSKeyValueObservation] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    private override init() {
        super.init()
        for model in ASRModel.allCases {
            states[model] = Self.checkDownloaded(model) ? .downloaded : .notDownloaded
        }
    }

    // MARK: - Public API

    public func state(for model: ASRModel) -> ModelDownloadState {
        states[model] ?? .notDownloaded
    }

    /// Begin downloading a model using the known download spec for that model.
    /// No-op for built-in or FluidAudio-managed models.
    public func download(_ model: ASRModel) {
        guard let current = states[model] else { return }
        switch current {
        case .downloaded, .downloading: return
        default: break
        }

        switch model {
        // Whisper: single GGUF file from ggerganov/whisper.cpp
        case .whisperTiny:
            download(model, from: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!)
        case .whisperBase:
            download(model, from: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!)
        case .whisperSmall:
            download(model, from: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!)
        case .whisperMedium:
            download(model, from: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!)
        case .whisperLarge:
            download(model, from: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!)

        // Nemotron: multi-file HF repo — providers read from Caches/<folderHint>
        case .nemotronFast:
            downloadHuggingFaceRepo(
                model: model,
                owner: "BarathwajAnandan",
                repo: "nemotron-3.5-asr-streaming320-int8-CoreML",
                cacheDir: Self.nemotronCacheDir(fast: true),
                items: Self.nemotronRequiredItems
            )
        case .nemotronMultilingual:
            downloadHuggingFaceRepo(
                model: model,
                owner: "BarathwajAnandan",
                repo: "nemotron-3.5-asr-offline-6bit-CoreML",
                cacheDir: Self.nemotronCacheDir(fast: false),
                items: Self.nemotronRequiredItems
            )

        // Cohere: multi-file HF repo — ExternalCoreMLTranscriptionProvider reads from Caches/<folderHint>
        case .cohereTranscribe:
            downloadHuggingFaceRepo(
                model: model,
                owner: "BarathwajAnandan",
                repo: "cohere-transcribe-03-2026-CoreML-6bit",
                cacheDir: Self.cohereCacheDir,
                items: Self.cohereRequiredItems
            )

        // Parakeet: managed by FluidAudio SDK — downloads automatically on first recording
        case .appleSpeech, .parakeetFlash, .parakeetV2, .parakeetV3:
            break
        }
    }

    /// Begin downloading a model. No-op if already downloaded or download is in progress.
    public func download(_ model: ASRModel, from remoteURL: URL) {
        guard let current = states[model] else { return }
        switch current {
        case .downloaded, .downloading:
            return
        default:
            break
        }

        let destination = ModelRepository.shared.downloadedModelURL(for: model)
        do {
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            states[model] = .failed("Could not create directory: \(error.localizedDescription)")
            return
        }

        states[model] = .downloading(progress: 0)

        let task = session.downloadTask(with: remoteURL) { [weak self] tempURL, _, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleCompletion(model: model, destination: destination, tempURL: tempURL, error: error)
            }
        }

        // KVO progress observation
        let obs = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            guard let self else { return }
            Task { @MainActor in
                self.states[model] = .downloading(progress: progress.fractionCompleted)
            }
        }

        tasks[model] = task
        observations[model] = obs
        task.resume()
    }

    /// Cancel an in-progress download.
    public func cancel(_ model: ASRModel) {
        tasks[model]?.cancel()
        cleanUpTask(model: model)
        states[model] = .notDownloaded
    }

    /// Delete a downloaded model from disk.
    public func delete(_ model: ASRModel) throws {
        let url = Self.diskURL(for: model)
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        states[model] = .notDownloaded
    }

    // MARK: - HF repo download

    private func downloadHuggingFaceRepo(
        model: ASRModel,
        owner: String,
        repo: String,
        cacheDir: URL?,
        items: [HuggingFaceModelDownloader.ModelItem]
    ) {
        guard let dest = cacheDir else {
            states[model] = .failed("Cannot resolve cache directory.")
            return
        }
        states[model] = .downloading(progress: 0)
        let downloader = HuggingFaceModelDownloader(owner: owner, repo: repo, requiredItems: items)
        Task {
            do {
                try await downloader.ensureModelsPresent(at: dest) { @Sendable progress, _ in
                    Task { @MainActor [weak self] in
                        self?.states[model] = .downloading(progress: progress)
                    }
                }
                await MainActor.run { self.states[model] = .downloaded }
            } catch is CancellationError {
                await MainActor.run { self.states[model] = .notDownloaded }
            } catch {
                await MainActor.run { self.states[model] = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Per-model disk locations

    private static func checkDownloaded(_ model: ASRModel) -> Bool {
        guard model != .appleSpeech else { return true }
        guard let url = diskURL(for: model) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func diskURL(for model: ASRModel) -> URL? {
        switch model {
        case .appleSpeech:
            return nil
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return ModelRepository.shared.downloadedModelURL(for: model)
        case .nemotronFast:
            return nemotronCacheDir(fast: true)
        case .nemotronMultilingual:
            return nemotronCacheDir(fast: false)
        case .cohereTranscribe:
            return cohereCacheDir
        case .parakeetFlash, .parakeetV2, .parakeetV3:
            return nil  // FluidAudio-managed; location opaque to us
        }
    }

    private static func nemotronCacheDir(fast: Bool) -> URL? {
        let hint = fast
            ? "nemotron-3.5-asr-streaming320-int8-CoreML"
            : "nemotron-3.5-asr-offline-6bit-CoreML"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(hint, isDirectory: true)
    }

    private static var cohereCacheDir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cohere-transcribe-03-2026-CoreML-6bit", isDirectory: true)
    }

    private static let nemotronRequiredItems: [HuggingFaceModelDownloader.ModelItem] = [
        .init(path: "metadata.json",             isDirectory: false),
        .init(path: "preprocessor.mlpackage",    isDirectory: true),
        .init(path: "encoder.mlpackage",         isDirectory: true),
        .init(path: "decoder.mlpackage",         isDirectory: true),
        .init(path: "joint.mlpackage",           isDirectory: true),
        .init(path: "joint_decision.mlpackage",  isDirectory: true),
        .init(path: "tokenizer.model",           isDirectory: false),
    ]

    private static let cohereRequiredItems: [HuggingFaceModelDownloader.ModelItem] = [
        .init(path: "coreml_manifest.json",                      isDirectory: false),
        .init(path: "cohere_frontend.mlpackage",                 isDirectory: true),
        .init(path: "cohere_encoder.mlpackage",                  isDirectory: true),
        .init(path: "cohere_cross_kv_projector.mlpackage",       isDirectory: true),
        .init(path: "cohere_decoder_fullseq_masked.mlpackage",   isDirectory: true),
        .init(path: "cohere_decoder_cached.mlpackage",           isDirectory: true),
    ]

    // MARK: - Private

    private func handleCompletion(model: ASRModel, destination: URL, tempURL: URL?, error: Error?) {
        defer { cleanUpTask(model: model) }

        if let error {
            let nsErr = error as NSError
            // Treat cancellation as reverting to notDownloaded, not as failure
            if nsErr.domain == NSURLErrorDomain, nsErr.code == NSURLErrorCancelled {
                states[model] = .notDownloaded
            } else {
                states[model] = .failed(error.localizedDescription)
            }
            return
        }

        guard let tempURL else {
            states[model] = .failed("Download completed but no file was returned.")
            return
        }

        do {
            // Remove stale destination if it exists
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            states[model] = .downloaded
        } catch {
            states[model] = .failed("Could not move downloaded file: \(error.localizedDescription)")
        }
    }

    private func cleanUpTask(model: ASRModel) {
        observations[model]?.invalidate()
        observations[model] = nil
        tasks[model] = nil
    }
}
#endif
