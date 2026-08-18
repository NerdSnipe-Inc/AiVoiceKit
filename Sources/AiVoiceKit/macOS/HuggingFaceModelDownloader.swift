// Sources/AiVoiceKit/macOS/HuggingFaceModelDownloader.swift
// Ported from FluidVoice — downloads multi-file Hugging Face model repositories.
// Used by ModelDownloader for Nemotron and Cohere models.
// Foundation-only; no FluidAudio dependency.
#if os(macOS)
import Foundation

final class HuggingFaceModelDownloader: @unchecked Sendable {
    struct ModelItem {
        let path: String
        let isDirectory: Bool
    }

    private struct HFEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private let owner: String
    private let repo: String
    private let revision: String
    private let requiredItemsList: [ModelItem]

    private var baseApiURL: URL
    private var baseResolveURL: URL

    init(owner: String, repo: String, revision: String = "main", requiredItems: [ModelItem]) {
        self.owner = owner
        self.repo = repo
        self.revision = revision
        self.requiredItemsList = requiredItems

        var apiBase = URL(string: "https://huggingface.co/api/models/")!
        apiBase.appendPathComponent(owner)
        apiBase.appendPathComponent(repo)
        apiBase.appendPathComponent("tree")
        apiBase.appendPathComponent(revision)
        self.baseApiURL = apiBase

        var resolveBase = URL(string: "https://huggingface.co/")!
        resolveBase.appendPathComponent(owner)
        resolveBase.appendPathComponent(repo)
        resolveBase.appendPathComponent("resolve")
        resolveBase.appendPathComponent(revision)
        self.baseResolveURL = resolveBase
    }

    func ensureModelsPresent(at targetRoot: URL, onProgress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        onProgress?(0.0, "")

        var pendingFiles: [String] = []
        var listedSizeByPath: [String: Int64] = [:]

        for item in requiredItemsList {
            try Task.checkCancellation()
            if item.isDirectory {
                let files = try await listFilesRecursively(relativePath: item.path)
                for entry in files {
                    let rel = entry.path
                    if let size = entry.size, size >= 0 { listedSizeByPath[rel] = size }
                    let dest = targetRoot.appendingPathComponent(rel)
                    if needsDownload(relativePath: rel, at: dest, expectedBytes: entry.size) {
                        pendingFiles.append(rel)
                    }
                }
            } else {
                let dest = targetRoot.appendingPathComponent(item.path)
                let expectedBytes = try await headExpectedLength(relativePath: item.path)
                if expectedBytes > 0 { listedSizeByPath[item.path] = expectedBytes }
                if needsDownload(relativePath: item.path, at: dest, expectedBytes: expectedBytes > 0 ? expectedBytes : nil) {
                    pendingFiles.append(item.path)
                }
            }
        }

        if pendingFiles.isEmpty {
            guard Self.artifactsAreComplete(root: targetRoot, items: requiredItemsList) else {
                throw NSError(domain: "HF", code: -4, userInfo: [NSLocalizedDescriptionKey: "Cached model artifacts are incomplete. Please try again."])
            }
            onProgress?(1.0, "")
            return
        }

        var sizeByPath: [String: Int64] = [:]
        var totalBytes: Int64 = 0
        for rel in pendingFiles {
            try Task.checkCancellation()
            let expected: Int64
            if let listed = listedSizeByPath[rel] { expected = listed }
            else { expected = try await headExpectedLength(relativePath: rel) }
            sizeByPath[rel] = expected
            if expected > 0 { totalBytes += expected }
        }

        DebugLogger.shared.info("[HFDownloader] Files to download: \(pendingFiles.count), total: \(Self.formatBytes(totalBytes))", source: "HFDownloader")

        var downloadedBytes: Int64 = 0
        let maxIncomplete = 0.999

        for (idx, rel) in pendingFiles.enumerated() {
            try Task.checkCancellation()
            DebugLogger.shared.info("[HFDownloader] (\(idx + 1)/\(pendingFiles.count)) Downloading: \(rel)", source: "HFDownloader")
            let completedBefore = downloadedBytes
            try await downloadFile(relativePath: rel, to: targetRoot.appendingPathComponent(rel)) { perFilePct in
                let expected = sizeByPath[rel] ?? 0
                if expected > 0, totalBytes > 0 {
                    let base = Double(completedBefore) / Double(totalBytes)
                    let combined = min(maxIncomplete, base + (perFilePct * Double(expected)) / Double(totalBytes))
                    onProgress?(combined, rel)
                }
            }
            try Task.checkCancellation()
            let expectedFileBytes = sizeByPath[rel] ?? 0
            if expectedFileBytes > 0 {
                let dest = targetRoot.appendingPathComponent(rel)
                let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                let actualBytes = (attrs?[.size] as? NSNumber)?.int64Value
                guard actualBytes == expectedFileBytes else {
                    try? FileManager.default.removeItem(at: dest)
                    throw NSError(domain: "HF", code: -5, userInfo: [NSLocalizedDescriptionKey: "Downloaded file size mismatch for \(rel). Please try again."])
                }
                downloadedBytes += expectedFileBytes
                onProgress?(min(maxIncomplete, Double(downloadedBytes) / Double(totalBytes)), rel)
            }
        }

        guard Self.artifactsAreComplete(root: targetRoot, items: requiredItemsList) else {
            throw NSError(domain: "HF", code: -4, userInfo: [NSLocalizedDescriptionKey: "Downloaded model artifacts are incomplete. Please try again."])
        }
        try Task.checkCancellation()
        onProgress?(1.0, "")
    }

    // MARK: - Completion checks

    static func artifactsAreComplete(root: URL, items: [ModelItem]) -> Bool {
        items.allSatisfy { item in
            artifactIsComplete(at: root.appendingPathComponent(item.path, isDirectory: item.isDirectory), isDirectory: item.isDirectory)
        }
    }

    static func artifactIsComplete(at url: URL, isDirectory: Bool) -> Bool {
        guard isDirectory else { return fileHasContents(at: url) }
        if url.pathExtension == "mlpackage" {
            let manifestURL = url.appendingPathComponent("Manifest.json")
            guard fileHasContents(at: manifestURL),
                  let data = try? Data(contentsOf: manifestURL),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let manifest = obj as? [String: Any],
                  let entries = manifest["itemInfoEntries"] as? [String: [String: Any]],
                  !entries.isEmpty
            else { return false }
            return entries.values.allSatisfy { entry in
                guard let rel = entry["path"] as? String else { return false }
                let artifact = url.appendingPathComponent("Data", isDirectory: true).appendingPathComponent(rel)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: artifact.path, isDirectory: &isDir) else { return false }
                return artifactIsComplete(at: artifact, isDirectory: isDir.boolValue)
            }
        }
        if url.pathExtension == "mlmodelc" {
            return fileHasContents(at: url.appendingPathComponent("coremldata.bin"))
                && fileHasContents(at: url.appendingPathComponent("metadata.json"))
                && fileHasContents(at: url.appendingPathComponent("weights/weight.bin"))
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return false }
        for case let fileURL as URL in enumerator where fileHasContents(at: fileURL) { return true }
        return false
    }

    static func cachedFileIsMarkup(at fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 512)) ?? Data()
        return looksLikeHTML(prefix)
    }

    static func looksLikeHTML(_ data: Data) -> Bool {
        var bytes = [UInt8](data.prefix(512))
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0a || first == 0x0d { bytes.removeFirst() }
        guard bytes.first == 0x3c, bytes.count >= 2 else { return false }
        let second = bytes[1]
        let isLetter = (second >= 0x41 && second <= 0x5a) || (second >= 0x61 && second <= 0x7a)
        return isLetter || second == 0x21 || second == 0x3f || second == 0x2f
    }

    private static func fileHasContents(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.int64Value > 0 && !cachedFileIsMarkup(at: url)
    }

    // MARK: - Internals

    private func needsDownload(relativePath: String, at destination: URL, expectedBytes: Int64? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return true }
        if let expected = expectedBytes, expected >= 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let local = attrs[.size] as? NSNumber, local.int64Value != expected
        {
            try? FileManager.default.removeItem(at: destination)
            return true
        }
        guard !Self.artifactIsComplete(at: destination, isDirectory: false) else { return false }
        if Self.cachedFileIsMarkup(at: destination) {
            do { try FileManager.default.removeItem(at: destination) } catch {}
        }
        return true
    }

    private func downloadFile(relativePath: String, to destination: URL, perFileProgress: ((Double) -> Void)? = nil) async throws {
        let fileURL = baseResolveURL.appendingPathComponent(relativePath)
        let delegate = ProgressDelegate { written, expected in
            guard expected > 0 else { return }
            perFileProgress?(min(1.0, Double(written) / Double(expected)))
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var tempURL: URL?
        do {
            let result = try await withTaskCancellationHandler {
                try await session.download(from: fileURL)
            } onCancel: {
                session.invalidateAndCancel()
            }
            tempURL = result.0
            let response = result.1
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "HF", code: http.statusCode)
            }
            try validateDownload(at: result.0, response: response, relativePath: relativePath)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: result.0, to: destination)
            tempURL = nil
        } catch {
            if let t = tempURL { try? FileManager.default.removeItem(at: t) }
            session.invalidateAndCancel()
            if Task.isCancelled || isCancellation(error) { throw CancellationError() }
            throw error
        }
    }

    private func validateDownload(at fileURL: URL, response: URLResponse?, relativePath: String) throws {
        if let expected = response?.expectedContentLength, expected > 0 {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let actual = attrs[.size] as? NSNumber, actual.int64Value == expected else {
                throw NSError(domain: "HF", code: -5, userInfo: [NSLocalizedDescriptionKey: "Size mismatch for \(relativePath). Please try again."])
            }
        }
        if let http = response as? HTTPURLResponse, let ct = http.value(forHTTPHeaderField: "Content-Type") {
            let low = ct.lowercased()
            if low.contains("text/html") || low.contains("text/xml") || low.contains("application/xml") {
                throw NSError(domain: "HF", code: -3, userInfo: [NSLocalizedDescriptionKey: "Server returned markup instead of model data for \(relativePath). A proxy may be blocking downloads."])
            }
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 512)) ?? Data()
        if Self.looksLikeHTML(prefix) {
            throw NSError(domain: "HF", code: -3, userInfo: [NSLocalizedDescriptionKey: "Downloaded file for \(relativePath) is HTML, not model data."])
        }
    }

    private func headExpectedLength(relativePath: String) async throws -> Int64 {
        try Task.checkCancellation()
        var req = URLRequest(url: baseResolveURL.appendingPathComponent(relativePath))
        req.httpMethod = "HEAD"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            try Task.checkCancellation()
            guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else { return 0 }
            return http.expectedContentLength
        } catch {
            if Task.isCancelled || isCancellation(error) { throw CancellationError() }
            return 0
        }
    }

    private func listFilesRecursively(relativePath: String) async throws -> [HFEntry] {
        try Task.checkCancellation()
        let listURL = baseApiURL.appendingPathComponent(relativePath)
        guard var comps = URLComponents(url: listURL, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid listing URL"])
        }
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = comps.url else {
            throw NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid listing URL"])
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "HF", code: http.statusCode)
        }
        return try JSONDecoder().decode([HFEntry].self, from: data).filter { $0.type == "file" }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let b = Double(bytes)
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.2f KB", b / kb) }
        return "\(bytes) B"
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: (Int64, Int64) -> Void
        init(onProgress: @escaping (Int64, Int64) -> Void) { self.onProgress = onProgress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
}
#endif
