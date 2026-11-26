import Foundation
import os

// Written by download callbacks on background queues and polled by the Settings page.
nonisolated final class DownloadProgress: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0.0)

    var fraction: Double { storage.withLock { $0 } }

    func update(_ fraction: Double) {
        storage.withLock { $0 = min(max(fraction, 0), 1) }
    }
}

/// Downloads one file and reports byte progress.
/// The async `URLSession.download` APIs do not deliver `didWriteData`, so this wraps a delegate-based task.
nonisolated final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<(URL, URLResponse?), Error>?
        var file: URL?
    }

    private let expectedBytes: Int64
    private let progress: DownloadProgress
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(expectedBytes: Int64, progress: DownloadProgress) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    private static let filePrefix = "TalkAcrossDownload-"

    /// Removes files left behind by a download that was interrupted, such as by quitting the app.
    /// Callers run one download at a time, so nothing here belongs to a live download.
    private static func removeLeftovers() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    func download(from url: URL) async throws -> (URL, URLResponse?) {
        Self.removeLeftovers()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        progress.update(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns.
        let destination = FileManager.default.temporaryDirectory.appending(path: Self.filePrefix + UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: destination)
        state.withLock { $0.file = destination }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, file) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.file)
        }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: error)
        } else if let file {
            continuation?.resume(returning: (file, task.response))
        } else {
            continuation?.resume(throwing: URLError(.cannotCreateFile))
        }
    }
}
