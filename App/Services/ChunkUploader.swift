//  ChunkUploader.swift
//  SatellicaRecorder — background upload service for recording chunks.
//  Uses URLSessionConfiguration.background so uploads survive app suspension / termination.

import Foundation

@MainActor
final class ChunkUploader: NSObject, ObservableObject {
    static let shared = ChunkUploader()

    @Published var isUploading = false
    @Published var chunksUploaded = 0
    @Published var chunksTotal = 0

    /// Upload endpoint.
    static var uploadURL: URL? = URL(string: "https://next-demo-rose-seven.vercel.app/api/recording/upload")

    private static let bgSessionId = "com.satellica.recorder.upload"

    /// Tracks chunk indices with in-flight upload tasks to prevent duplicates.
    private var inFlightChunks = Set<Int>()

    /// Guard against multiple completion triggers.
    private var didComplete = false

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.bgSessionId)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var systemCompletionHandler: (() -> Void)?

    /// Fired once when all chunks are uploaded and recording is stopped.
    var onAllUploaded: (() -> Void)?

    override init() {
        super.init()
        _ = backgroundSession
    }

    /// Called by AppDelegate when system relaunches for background session events.
    nonisolated func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.systemCompletionHandler = completionHandler
            _ = self.backgroundSession
        }
    }

    // MARK: - Public

    func uploadPendingChunks() {
        guard var manifest = RecordingManifest.load() else { return }

        // Recovery: reset stuck .uploading chunks that have no in-flight task
        var recovered = false
        for (i, chunk) in manifest.chunks.enumerated() {
            if chunk.status == .uploading && !inFlightChunks.contains(chunk.index) {
                manifest.chunks[i].status = .ready
                recovered = true
            }
        }
        if recovered { manifest.save() }

        let pending = manifest.chunks.filter {
            ($0.status == .ready || $0.status == .failed) && !inFlightChunks.contains($0.index)
        }

        if pending.isEmpty {
            refreshCounts(manifest)
            checkCompletion(&manifest)
            return
        }

        isUploading = true
        refreshCounts(manifest)

        for chunk in pending {
            let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(chunk.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                // File already deleted (previously uploaded) — mark as uploaded
                if let idx = manifest.chunks.firstIndex(where: { $0.index == chunk.index }) {
                    manifest.chunks[idx].status = .uploaded
                    manifest.save()
                    refreshCounts(manifest)
                }
                continue
            }
            enqueueUpload(chunk: chunk, fileURL: fileURL, manifest: &manifest)
        }

        // After loop, re-check in case all were already uploaded (missing files)
        checkCompletion(&manifest)
    }

    /// Reset state for a new recording session.
    func reset() {
        inFlightChunks.removeAll()
        didComplete = false
        isUploading = false
        chunksUploaded = 0
        chunksTotal = 0
    }

    // MARK: - Private

    private func enqueueUpload(chunk: ChunkInfo, fileURL: URL, manifest: inout RecordingManifest) {
        // Check uploadURL BEFORE modifying manifest
        guard let uploadURL = Self.uploadURL else {
            print("[ChunkUploader] uploadURL not set — skipping")
            return
        }

        inFlightChunks.insert(chunk.index)

        if let idx = manifest.chunks.firstIndex(where: { $0.index == chunk.index }) {
            manifest.chunks[idx].status = .uploading
            manifest.save()
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(manifest.sessionId, forHTTPHeaderField: "X-Session-Id")
        request.setValue("\(chunk.index)", forHTTPHeaderField: "X-Chunk-Index")
        // Only send accurate total after recording has stopped; otherwise mark as unknown
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        let isStopped = defaults?.string(forKey: RecorderConstants.broadcastStatusKey) == "stopped"
        request.setValue(isStopped ? "\(manifest.chunks.count)" : "?", forHTTPHeaderField: "X-Chunk-Total")

        let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = "\(chunk.index)"
        task.resume()
    }

    private func refreshCounts(_ manifest: RecordingManifest) {
        chunksTotal = manifest.chunks.count
        chunksUploaded = manifest.chunks.filter { $0.status == .uploaded }.count
    }

    private func checkCompletion(_ manifest: inout RecordingManifest) {
        guard !didComplete else { return }

        let allUploaded = manifest.chunks.allSatisfy { $0.status == .uploaded }
        guard allUploaded && !manifest.chunks.isEmpty else { return }

        // Read broadcast status from UserDefaults (cross-process reliable)
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        let broadcastStatus = defaults?.string(forKey: RecorderConstants.broadcastStatusKey) ?? "idle"
        guard broadcastStatus == "stopped" else { return }

        didComplete = true
        manifest.status = "completed"
        manifest.save()
        isUploading = false
        onAllUploaded?()
    }
}

// MARK: - URLSession delegates

extension ChunkUploader: URLSessionDelegate, URLSessionTaskDelegate {

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let indexStr = task.taskDescription
        let response = task.response
        Task { @MainActor in
            self.handleTaskCompletion(indexStr: indexStr, error: error, response: response)
        }
    }

    private func handleTaskCompletion(indexStr: String?, error: Error?, response: URLResponse?) {
        guard let indexStr, let chunkIndex = Int(indexStr) else { return }

        inFlightChunks.remove(chunkIndex)

        guard var manifest = RecordingManifest.load(),
              let idx = manifest.chunks.firstIndex(where: { $0.index == chunkIndex }) else { return }

        if let error {
            print("[ChunkUploader] chunk \(chunkIndex) failed: \(error.localizedDescription)")
            manifest.chunks[idx].status = .failed
            manifest.save()
            // Schedule retry after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.uploadPendingChunks()
            }
            return
        }

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(httpStatus) {
            // Save manifest FIRST, then delete file
            manifest.chunks[idx].status = .uploaded
            manifest.save()

            let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(manifest.chunks[idx].fileName)
            try? FileManager.default.removeItem(at: fileURL)

            refreshCounts(manifest)
            checkCompletion(&manifest)
        } else {
            print("[ChunkUploader] chunk \(chunkIndex) server error: \(httpStatus)")
            manifest.chunks[idx].status = .failed
            manifest.save()
            // Retry after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.uploadPendingChunks()
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}
