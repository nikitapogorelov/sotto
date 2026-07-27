import Foundation
import SwiftUI

/// Manages the local Whisper models. Three presets (see WhisperModel);
/// the default is large-v3-turbo: near large-v3 quality on multilingual
/// audio at a fraction of the latency.
@MainActor
final class ModelManager: ObservableObject {
    private static let selectedKey = "selectedModelID"

    @Published private(set) var installed: Set<WhisperModel>
    @Published private(set) var downloadingModel: WhisperModel?
    @Published var error: String?
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64? // nil until known (or if server omits Content-Length)

    /// The model the user picked in Settings. Transcription uses it when
    /// installed and falls back to the best installed model otherwise.
    @Published var selected: WhisperModel {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: Self.selectedKey) }
    }

    private var downloader: FileDownloader?

    var isDownloading: Bool { downloadingModel != nil }

    /// The model transcription will actually use, nil when none is installed.
    var activeModel: WhisperModel? {
        if installed.contains(selected) { return selected }
        return WhisperModel.bestInstalled(from: installed)
    }

    var activeModelURL: URL? {
        activeModel.map(url(for:))
    }

    var isInstalled: Bool { activeModel != nil }

    func url(for model: WhisperModel) -> URL {
        Paths.models.appendingPathComponent(model.fileName)
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        installed.contains(model)
    }

    /// 0...1 while downloading, nil when the total size is unknown.
    var downloadFraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return Double(downloadedBytes) / Double(total)
    }

    var downloadStatusText: String {
        let written = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        if let total = totalBytes {
            return "\(written) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        if downloadedBytes > 0 { return "\(written) downloaded" }
        if let model = downloadingModel { return "Downloading… (~\(model.sizeLabel))" }
        return "Downloading…"
    }

    init() {
        installed = Self.scanInstalled()
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey)
        selected = saved.flatMap(WhisperModel.init(rawValue:)) ?? .largeV3Turbo
    }

    /// Downloads the user's selected model (the common "install first model" path).
    func download() async {
        await download(selected)
    }

    func download(_ model: WhisperModel) async {
        guard !isDownloading else { return }
        downloadingModel = model
        error = nil
        downloadedBytes = 0
        totalBytes = nil
        defer {
            downloadingModel = nil
            downloader = nil
        }

        do {
            try FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
            let downloader = FileDownloader { [weak self] written, total in
                Task { @MainActor in
                    self?.downloadedBytes = written
                    self?.totalBytes = total
                }
            }
            self.downloader = downloader
            let (tempURL, response) = try await downloader.download(from: model.downloadURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }
            let destination = url(for: model)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            installed.insert(model)
        } catch let error as NSError
            where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // User hit Cancel — reset quietly, no error banner.
            // (Matched via NSError: URLSession delegate errors don't bridge to URLError in catch.)
        } catch {
            self.error = "Model download failed: \(error.localizedDescription)"
        }
    }

    func delete(_ model: WhisperModel) {
        guard downloadingModel != model else { return }
        try? FileManager.default.removeItem(at: url(for: model))
        installed.remove(model)
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    func refresh() {
        installed = Self.scanInstalled()
    }

    private static func scanInstalled() -> Set<WhisperModel> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        return WhisperModel.installedModels(fileNames: names)
    }
}

/// Wraps URLSessionDownloadTask in async/await with throttled progress callbacks.
/// URLSession writes the file itself, so progress costs no CPU on the 1.6 GB body.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// (bytesWritten, totalBytes) — total is nil when the server sent no Content-Length.
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var lastUpdate = Date.distantPast
    private var lastFraction = 0.0

    init(onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> (URL, URLResponse) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        // A delegate-owning session retains its delegate until invalidated.
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    // Delegate callbacks arrive on the session's serial queue, so plain vars are safe.

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        // Throttle: SwiftUI doesn't need more than a few updates per second.
        guard Date().timeIntervalSince(lastUpdate) >= 0.15 || fraction - lastFraction >= 0.005 else {
            return
        }
        lastUpdate = Date()
        lastFraction = fraction
        let total = totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown
            ? nil : totalBytesExpectedToWrite as Int64?
        onProgress(totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted once this callback returns — move it out synchronously.
        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stableURL)
            continuation?.resume(returning: (stableURL, downloadTask.response ?? URLResponse()))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is resumed in didFinishDownloadingTo; this handles failure/cancel.
        if let error, let continuation {
            continuation.resume(throwing: error)
            self.continuation = nil
        }
    }
}
