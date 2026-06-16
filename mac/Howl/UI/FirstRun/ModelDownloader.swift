import Foundation
import Observation
import os

@MainActor
@Observable
public final class ModelDownloader {
    // Diagnostic logging. `.notice`+ persists to the unified-log store so it
    // can be retrieved after the fact with `log show`; `.info`/`.debug` would
    // only appear in a live `log stream`. Filter with:
    //   log stream --predicate 'subsystem == "com.howl.app" AND category == "ModelDownload"'
    private let log = Logger(subsystem: "com.howl.app", category: "ModelDownload")

    public enum State {
        case idle
        case downloading(Double) // 0...1
        case completed
        case failed(String)
    }

    public var state: State = .idle
    private var lastLoggedDecile = -1

    public init() {}

    public func download(size: String, to dest: URL) async {
        state = .downloading(0)
        lastLoggedDecile = -1
        let filename = ModelPaths.whisperModelFilename(size: size)
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
        log.notice("""
            download START size=\(size, privacy: .public) \
            filename=\(filename, privacy: .public) \
            url=\(url.absoluteString, privacy: .public) \
            dest=\(dest.path, privacy: .public)
            """)
        // A dedicated session with a SESSION-LEVEL delegate is required for
        // byte-progress: URLSession.shared ignores per-task download delegates,
        // so `didWriteData` never fires and the bar sticks at 0%. The delegate
        // drives a classic downloadTask, bridged to async via a continuation.
        let delegate = DownloadDelegate { [weak self] fraction in
            Task { @MainActor in self?.report(fraction) }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let (tempURL, response) = try await delegate.run(session: session, url: url)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            log.notice("""
                download RESPONSE status=\(status, privacy: .public) \
                finalHost=\(response.url?.host ?? "nil", privacy: .public) \
                expectedBytes=\(response.expectedContentLength, privacy: .public) \
                tempBytes=\(Self.fileSize(tempURL.path), privacy: .public)
                """)
            guard let http, (200..<300).contains(http.statusCode) else {
                log.error("download FAILED bad-status=\(status, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                state = .failed("HTTP \(status)")
                return
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                log.notice("download replacing existing file dest=\(dest.path, privacy: .public)")
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            log.notice("download COMPLETE dest=\(dest.path, privacy: .public) bytes=\(Self.fileSize(dest.path), privacy: .public)")
            state = .completed
        } catch {
            log.error("download ERROR \(String(describing: error), privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Apply a progress fraction and log at each 10% milestone (the delegate
    /// fires far too often to log every callback).
    private func report(_ fraction: Double) {
        // Ignore stray callbacks once we've left the downloading state.
        guard case .downloading = state else { return }
        state = .downloading(fraction)
        let decile = Int(fraction * 10)
        if decile > lastLoggedDecile {
            lastLoggedDecile = decile
            log.notice("download PROGRESS \(decile * 10, privacy: .public)%")
        }
    }

    /// On-disk size in bytes, or -1 if the file is missing / unreadable.
    private static func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? -1
    }
}

/// Session-level download delegate that forwards byte-progress and bridges the
/// callback-based downloadTask to async/await. Progress is throttled to ~0.5%
/// steps to avoid flooding the main actor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var lastReported = -1.0

    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func run(session: URLSession, url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Delegate callbacks for one task are serialized, so this is race-free.
        if fraction - lastReported >= 0.005 || fraction >= 1.0 {
            lastReported = fraction
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The system deletes `location` the instant this method returns, so the
        // file must be moved somewhere stable synchronously before resuming.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("howl-model-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: (stable, downloadTask.response ?? URLResponse()))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is resumed in didFinishDownloadingTo; this only catches the
        // failure path (network drop, etc.) where that method never fires.
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
