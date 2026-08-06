//  ChunkUploader.swift
//  Signed-URL chunk upload state machine. Local media remains authoritative
//  until /complete confirms that the server has accepted the full manifest.

import Foundation
import AVFoundation
import CryptoKit
import UIKit

enum UploadActivity: String {
    case idle
    case reconciling
    case verifying
    case uploading
    case finalizing
    case retrying
    case completed
    case needsAttention
}

private struct LocalChunkInspection: Sendable {
    let fileSize: Int64
    let duration: TimeInterval
    let sha256: String
}

private struct UploadTaskIdentity: Hashable {
    let recordingId: String
    let chunkIndex: Int

    var taskDescription: String { "v2|\(recordingId)|\(chunkIndex)" }

    init(recordingId: String, chunkIndex: Int) {
        self.recordingId = recordingId
        self.chunkIndex = chunkIndex
    }

    init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v2", let index = Int(parts[2]) else { return nil }
        self.init(recordingId: String(parts[1]), chunkIndex: index)
    }
}

private struct SignedChunkURL: Codable {
    let index: Int
    let uploadUrl: URL
    let blobPath: String
    let headers: [String: String]
    var expiresAtMs: Int64? = nil
}

private struct SignedURLBatchResponse: Decodable {
    let recordingId: String
    let expiresAtMs: Int64
    let urls: [SignedChunkURL]
}

private struct SignedURLCache: Codable {
    let recordingId: String
    var urls: [SignedChunkURL]
}

private struct StartRecordingResponse: Decodable {
    let recordingId: String
    let serverEpochMs: Int64
    let uploadToken: String
    let chunkSeconds: Double
    let chunkUrlBatch: Int
    let maxChunks: Int
    let maxChunkBytes: Int64
}

private struct CompleteChunk: Encodable {
    let index: Int
    let startOffsetMs: Int64
    let durationMs: Int64
    let bytes: Int64?
}

private struct CompleteRequest: Encodable {
    let uploadToken: String
    let chunks: [CompleteChunk]
    let interruptedAtMs: Int64?
    let interruptedReason: String?
}

private struct CompleteResponse: Decodable {
    let recordingId: String
    let status: String
    let chunkCount: Int
    let uploadedCount: Int
    let missingIndexes: [Int]
    let merging: Bool
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: Int?
        let message: String?
    }
    let success: Bool?
    let error: APIError?
}

@MainActor
final class ChunkUploader: NSObject, ObservableObject {
    static let shared = ChunkUploader()

    @Published var isUploading = false
    @Published var chunksUploaded = 0
    @Published var chunksTotal = 0
    @Published var uploadError: String?
    @Published private(set) var activity: UploadActivity = .idle

    private static let bgSessionId = "com.satellica.recorder.upload"
    private static let signedURLSafetyWindowMs: Int64 = 30_000

    private var inFlightChunks = Set<UploadTaskIdentity>()
    private var hasReconciledBackgroundTasks = false
    private var isReconcilingBackgroundTasks = false
    private var uploadScanRequestedDuringReconciliation = false
    private var reconciliationGeneration = 0
    private var lifecycleGeneration = 0

    private var signedURLs: [Int: SignedChunkURL] = [:]
    private var signedURLRecordingId: String?
    private var fetchingBatches = Set<Int>()
    private var retryAttempts: [Int: Int] = [:]
    private var isRefreshingToken = false
    private var isCompleting = false
    private var didComplete = false
    private var terminalFailure = false
    private var isRepairingMetadata = false
    private var metadataRetryAttempts: [Int: Int] = [:]
    private var missingLocalFileAttempts: [Int: Int] = [:]
    private var chunkRetryWorkItems: [Int: DispatchWorkItem] = [:]
    private var metadataRetryWorkItem: DispatchWorkItem?
    private var generalRetryWorkItem: DispatchWorkItem?
    private var watchdogWorkItem: DispatchWorkItem?
    private var completionBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.bgSessionId)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var systemCompletionHandler: (() -> Void)?

    /// Fired only after /complete says merging/merged with no missing objects.
    var onAllUploaded: (() -> Void)?

    override init() {
        super.init()
        _ = backgroundSession
    }

    nonisolated func handleBackgroundSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            guard identifier == Self.bgSessionId else {
                completionHandler()
                return
            }
            self.systemCompletionHandler = completionHandler
            _ = self.backgroundSession
            self.reconcileBackgroundTasksIfNeeded()
        }
    }

    // MARK: - Public

    func uploadPendingChunks() {
        guard !didComplete, !terminalFailure else { return }
        if let completedManifest = RecordingManifest.load(), completedManifest.status == "completed" {
            didComplete = true
            isUploading = false
            activity = .completed
            refreshCounts(completedManifest)
            onAllUploaded?()
            return
        }
        guard hasReconciledBackgroundTasks else {
            uploadScanRequestedDuringReconciliation = true
            reconcileBackgroundTasksIfNeeded()
            return
        }
        guard var manifest = RecordingManifest.load(),
              let context = NativeUploadContextStore.load(),
              context.recordingId == manifest.sessionId,
              context.uploadAuthorized == true,
              UploadQueueStore.all().contains(context.recordingId) else {
            SessionDiagnostics.shared.record("upload_context_or_manifest_missing")
            return
        }

        // The shared broadcast flag is written independently by ReplayKit. If
        // the final manifest write was interrupted, use that durable state to
        // repair `recording` -> `stopped`, then continue the normal audit.
        let sharedBroadcastStatus = UserDefaults(suiteName: RecorderConstants.appGroup)?
            .string(forKey: RecorderConstants.broadcastStatusKey)
        if manifest.status == "recording", sharedBroadcastStatus == "stopped" {
            guard RecordingManifestStore.updateSessionStatus(
                sessionId: manifest.sessionId,
                status: "stopped"
            ), let repaired = RecordingManifest.load() else {
                scheduleGeneralRetry(reason: "recording_stopped_state_repair_failed")
                return
            }
            manifest = repaired
            SessionDiagnostics.shared.record("recording_stopped_state_repaired")
        }

        if reconcileChunkJournalIfNeeded(manifest: &manifest) {
            SessionDiagnostics.shared.record("manifest_reconciled_from_chunk_journal")
        }

        loadSignedURLCacheIfNeeded(for: context.recordingId)
        refreshCounts(manifest)
        if manifest.status == "stopped" {
            scheduleUploadWatchdog()
        }
        if beginMetadataRepairIfNeeded(manifest: manifest, context: context) {
            return
        }
        if deferForMissingLocalChunk(in: manifest) {
            return
        }
        let statusSummary = Dictionary(grouping: manifest.chunks, by: { $0.status.rawValue })
            .mapValues(\.count)
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        RecorderLog.write("uploader", "scan", [
            "recordingId": manifest.sessionId,
            "manifestStatus": manifest.status,
            "chunkCount": manifest.chunks.count,
            "inFlight": inFlightChunks.count,
            "statuses": statusSummary
        ])

        let pending = manifest.chunks.filter { chunk in
            let identity = UploadTaskIdentity(recordingId: manifest.sessionId, chunkIndex: chunk.index)
            return [.ready, .failed, .serverMissing].contains(chunk.status)
                && !inFlightChunks.contains(identity)
        }

        for chunk in pending {
            let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(chunk.fileName)
            let fileSize = fileSize(at: fileURL)
            guard fileSize > 0 else {
                updateChunk(chunk.index, in: &manifest, status: .dataLost)
                SessionDiagnostics.shared.record("chunk_local_data_lost index=\(chunk.index)")
                failTerminal("chunk_local_data_lost_\(chunk.index)")
                return
            }
            guard fileSize <= context.maxChunkBytes else {
                updateChunk(chunk.index, in: &manifest, status: .dataLost)
                SessionDiagnostics.shared.record("chunk_too_large index=\(chunk.index) bytes=\(fileSize)")
                failTerminal("chunk_too_large_\(chunk.index)")
                return
            }

            if let signedURL = validSignedURL(for: chunk.index) {
                enqueueUpload(chunk: chunk, fileURL: fileURL, signedURL: signedURL, manifest: &manifest)
                prefetchIfNeeded(after: chunk.index, context: context)
            } else {
                requestSignedURLs(containing: chunk.index, context: context)
            }
        }

        isUploading = !inFlightChunks.isEmpty || !pending.isEmpty || isCompleting
        if isCompleting || (manifest.status == "stopped" &&
            manifest.chunks.allSatisfy({ $0.status == .uploaded })) {
            activity = .finalizing
            isUploading = true
        } else if !inFlightChunks.isEmpty || !pending.isEmpty {
            activity = .uploading
        } else if activity != .retrying {
            activity = .idle
        }
        attemptCompleteIfReady(manifest: manifest, context: context)
    }

    /// Cancels tasks left by older app versions that uploaded continuously.
    /// A background URLSession can otherwise continue PUTs without the current
    /// process ever calling `uploadPendingChunks()`.
    func cancelUnauthorizedBackgroundTasks() {
        backgroundSession.getAllTasks { tasks in
            for task in tasks {
                guard let identity = UploadTaskIdentity(taskDescription: task.taskDescription) else {
                    task.cancel()
                    continue
                }
                let authorized = NativeUploadContextStore.load(recordingId: identity.recordingId)?
                    .uploadAuthorized == true && UploadQueueStore.all().contains(identity.recordingId)
                if !authorized { task.cancel() }
            }
        }
    }

    func cancelBackgroundTasks(recordingId: String) {
        backgroundSession.getAllTasks { tasks in
            for task in tasks where
                UploadTaskIdentity(taskDescription: task.taskDescription)?.recordingId == recordingId {
                task.cancel()
            }
        }
    }

    func reset() {
        cancelScheduledRetries()
        endCompletionBackgroundTask(completionBackgroundTask)
        lifecycleGeneration += 1
        inFlightChunks.removeAll()
        hasReconciledBackgroundTasks = false
        isReconcilingBackgroundTasks = false
        uploadScanRequestedDuringReconciliation = false
        reconciliationGeneration += 1
        signedURLs.removeAll()
        signedURLRecordingId = nil
        fetchingBatches.removeAll()
        retryAttempts.removeAll()
        isRefreshingToken = false
        isCompleting = false
        didComplete = false
        terminalFailure = false
        isRepairingMetadata = false
        metadataRetryAttempts.removeAll()
        missingLocalFileAttempts.removeAll()
        isUploading = false
        chunksUploaded = 0
        chunksTotal = 0
        uploadError = nil
        activity = .idle
    }

    // MARK: - Background task reconciliation

    private func reconcileBackgroundTasksIfNeeded() {
        guard !hasReconciledBackgroundTasks, !isReconcilingBackgroundTasks else { return }
        isReconcilingBackgroundTasks = true
        activity = .reconciling
        RecorderLog.write("uploader", "background_reconcile_started")
        let generation = reconciliationGeneration
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                self?.finishBackgroundTaskReconciliation(tasks, generation: generation)
            }
        }
    }

    private func finishBackgroundTaskReconciliation(_ tasks: [URLSessionTask], generation: Int) {
        guard generation == reconciliationGeneration else { return }
        var restored = Set<UploadTaskIdentity>()
        for task in tasks {
            guard let identity = UploadTaskIdentity(taskDescription: task.taskDescription) else {
                // Tasks from the retired fixed-endpoint uploader must not be
                // confused with signed-URL uploads.
                task.cancel()
                continue
            }
            restored.insert(identity)
        }
        inFlightChunks = restored

        if var manifest = RecordingManifest.load() {
            var changedIndexes: [Int] = []
            for chunk in manifest.chunks where chunk.status == .uploading {
                let identity = UploadTaskIdentity(recordingId: manifest.sessionId, chunkIndex: chunk.index)
                guard !restored.contains(identity) else { continue }
                let localURL = RecorderConstants.chunksDirectory.appendingPathComponent(chunk.fileName)
                let recoveredStatus: ChunkInfo.ChunkStatus = fileSize(at: localURL) > 0 ? .failed : .dataLost
                if RecordingManifestStore.updateChunk(
                    sessionId: manifest.sessionId,
                    index: chunk.index,
                    { $0.status = recoveredStatus }
                ) {
                    changedIndexes.append(chunk.index)
                }
            }
            if !changedIndexes.isEmpty, let latest = RecordingManifest.load() {
                manifest = latest
            }
            refreshCounts(manifest)
        }

        isReconcilingBackgroundTasks = false
        hasReconciledBackgroundTasks = true
        RecorderLog.write("uploader", "background_reconcile_finished", [
            "systemTaskCount": tasks.count,
            "restoredSignedUploads": restored.count
        ])
        let shouldScan = uploadScanRequestedDuringReconciliation
        uploadScanRequestedDuringReconciliation = false
        if shouldScan { uploadPendingChunks() }
    }

    // MARK: - Signed URLs

    private func requestSignedURLs(containing index: Int, context: NativeUploadContext) {
        let batchSize = max(1, min(context.chunkURLBatch, 20))
        let startIndex = (index / batchSize) * batchSize
        guard !fetchingBatches.contains(startIndex), !isRefreshingToken else { return }
        fetchingBatches.insert(startIndex)
        let generation = lifecycleGeneration
        let requestStartedAt = Date()
        RecorderLog.write("uploader", "chunk_urls_request", [
            "recordingId": context.recordingId,
            "startIndex": startIndex,
            "count": batchSize,
            "method": "POST",
            "endpointPath": context.chunkURLsEndpoint.path
        ])

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.lifecycleGeneration {
                    self.fetchingBatches.remove(startIndex)
                }
            }
            do {
                var request = URLRequest(url: context.chunkURLsEndpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "uploadToken": context.uploadToken,
                    "startIndex": startIndex,
                    "count": batchSize
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard generation == self.lifecycleGeneration else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                RecorderLog.write("uploader", "chunk_urls_response", [
                    "recordingId": context.recordingId,
                    "startIndex": startIndex,
                    "status": status,
                    "elapsedMs": Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                    "responseBytes": data.count,
                    "contentType": self.contentType(response)
                ])

                if status == 200 {
                    let batch = try JSONDecoder().decode(SignedURLBatchResponse.self, from: data)
                    guard batch.recordingId == context.recordingId else {
                        self.failTerminal("chunk_url_recording_mismatch")
                        return
                    }
                    self.accept(batch: batch)
                    self.logAcceptedSignedURLBatch(batch, requestedStartIndex: startIndex)
                    self.uploadPendingChunks()
                } else if status == 401, self.isExpiredTokenError(data) {
                    RecorderLog.write("uploader", "upload_token_rejected", [
                        "recordingId": context.recordingId,
                        "operation": "chunk_urls",
                        "classification": "expired",
                        "willRefresh": true
                    ])
                    await self.refreshUploadToken(reason: "chunk_urls_token_expired")
                } else if status == 401 {
                    self.logAPIError(
                        data: data,
                        status: status,
                        operation: "chunk_urls",
                        recordingId: context.recordingId
                    )
                    self.failTerminal("chunk_urls_invalid_token")
                } else if status == 500 || status == 502 || status == 0 {
                    self.scheduleGeneralRetry(reason: "chunk_urls_\(status)")
                } else {
                    self.logAPIError(
                        data: data,
                        status: status,
                        operation: "chunk_urls",
                        recordingId: context.recordingId
                    )
                    self.failTerminal("chunk_urls_terminal_\(status)")
                }
            } catch {
                guard generation == self.lifecycleGeneration else { return }
                self.logTransportError(
                    event: "chunk_urls_transport_or_decode_error",
                    recordingId: context.recordingId,
                    operation: "chunk_urls",
                    error: error,
                    elapsedMs: Int(Date().timeIntervalSince(requestStartedAt) * 1_000)
                )
                self.scheduleGeneralRetry(reason: "chunk_urls_network")
            }
        }
    }

    private func accept(batch: SignedURLBatchResponse) {
        signedURLRecordingId = batch.recordingId
        for var item in batch.urls {
            item.expiresAtMs = batch.expiresAtMs
            signedURLs[item.index] = item
        }
        persistSignedURLCache()
        RecorderLog.write("uploader", "chunk_urls_cached", [
            "recordingId": batch.recordingId,
            "urlCount": batch.urls.count,
            "expiresAtMs": batch.expiresAtMs
        ])
    }

    private func validSignedURL(for index: Int) -> SignedChunkURL? {
        let nowMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        guard let item = signedURLs[index],
              let expiresAtMs = item.expiresAtMs,
              expiresAtMs > nowMs + Self.signedURLSafetyWindowMs else {
            signedURLs[index] = nil
            return nil
        }
        return item
    }

    private func prefetchIfNeeded(after index: Int, context: NativeUploadContext) {
        let batchSize = max(1, min(context.chunkURLBatch, 20))
        let position = index % batchSize
        guard position >= max(0, batchSize - 5) else { return }
        let nextStart = ((index / batchSize) + 1) * batchSize
        if let maxChunks = context.maxChunks, nextStart >= maxChunks { return }
        guard validSignedURL(for: nextStart) == nil else { return }
        requestSignedURLs(containing: nextStart, context: context)
    }

    // MARK: - PUT uploads

    private func enqueueUpload(
        chunk: ChunkInfo,
        fileURL: URL,
        signedURL: SignedChunkURL,
        manifest: inout RecordingManifest
    ) {
        guard signedURL.index == chunk.index else {
            failTerminal("signed_url_index_mismatch")
            return
        }
        let identity = UploadTaskIdentity(recordingId: manifest.sessionId, chunkIndex: chunk.index)
        guard !inFlightChunks.contains(identity) else { return }
        inFlightChunks.insert(identity)
        guard updateChunk(chunk.index, in: &manifest, status: .uploading) else {
            inFlightChunks.remove(identity)
            scheduleGeneralRetry(reason: "chunk_uploading_state_persist_failed_\(chunk.index)")
            return
        }
        activity = .uploading

        var request = URLRequest(url: signedURL.uploadUrl)
        request.httpMethod = "PUT"
        for (name, value) in signedURL.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = identity.taskDescription
        RecorderLog.write("uploader", "chunk_put_enqueued", [
            "recordingId": manifest.sessionId,
            "index": chunk.index,
            "bytes": fileSize(at: fileURL),
            "headerNames": signedURL.headers.keys.sorted().joined(separator: ","),
            "backgroundTaskId": task.taskIdentifier,
            "destinationHost": signedURL.uploadUrl.host ?? "unknown",
            "urlExpiresInMs": max(0, (signedURL.expiresAtMs ?? 0) - nowEpochMs())
        ])
        task.resume()
    }

    private func handleTaskCompletion(
        taskDescription: String?,
        taskIdentifier: Int,
        bytesSent: Int64,
        bytesExpectedToSend: Int64,
        error: Error?,
        response: URLResponse?
    ) {
        guard let identity = UploadTaskIdentity(taskDescription: taskDescription) else { return }
        inFlightChunks.remove(identity)
        guard NativeUploadContextStore.load(recordingId: identity.recordingId)?.uploadAuthorized == true,
              UploadQueueStore.all().contains(identity.recordingId) else { return }
        guard var manifest = RecordingManifest.load(), manifest.sessionId == identity.recordingId,
              manifest.chunks.contains(where: { $0.index == identity.chunkIndex }) else { return }

        if let error {
            let nsError = error as NSError
            RecorderLog.write("uploader", "chunk_put_finished", [
                "recordingId": identity.recordingId,
                "index": identity.chunkIndex,
                "status": 0,
                "result": nsError.code == NSURLErrorCancelled ? "cancelled" : "transport_error",
                "errorDomain": nsError.domain,
                "errorCode": nsError.code,
                "errorDescription": error.localizedDescription,
                "backgroundTaskId": taskIdentifier,
                "bytesSent": bytesSent,
                "bytesExpectedToSend": bytesExpectedToSend
            ])
            _ = updateChunk(identity.chunkIndex, in: &manifest, status: .failed)
            scheduleChunkRetry(identity.chunkIndex)
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        RecorderLog.write("uploader", "chunk_put_finished", [
            "recordingId": identity.recordingId,
            "index": identity.chunkIndex,
            "status": status,
            "result": status == 200 ? "uploaded" : "http_error",
            "backgroundTaskId": taskIdentifier,
            "bytesSent": bytesSent,
            "bytesExpectedToSend": bytesExpectedToSend,
            "contentType": contentType(response)
        ])
        if status == 200 {
            guard updateChunk(identity.chunkIndex, in: &manifest, status: .uploaded) else {
                scheduleChunkRetry(identity.chunkIndex)
                return
            }
            retryAttempts[identity.chunkIndex] = nil
            chunkRetryWorkItems[identity.chunkIndex]?.cancel()
            chunkRetryWorkItems[identity.chunkIndex] = nil
            refreshCounts(manifest)
            // Keep the file until /complete confirms there are no missing objects.
            uploadPendingChunks()
        } else if status == 403 {
            invalidateSignedURLBatch(containing: identity.chunkIndex)
            persistSignedURLCache()
            _ = updateChunk(identity.chunkIndex, in: &manifest, status: .failed)
            SessionDiagnostics.shared.record("chunk_signed_url_expired index=\(identity.chunkIndex)")
            if let context = NativeUploadContextStore.load() {
                requestSignedURLs(containing: identity.chunkIndex, context: context)
            }
        } else {
            _ = updateChunk(identity.chunkIndex, in: &manifest, status: .failed)
            SessionDiagnostics.shared.record("chunk_upload_http_error index=\(identity.chunkIndex) status=\(status)")
            // The local file remains authoritative. A stale or rejected signed
            // request must never strand a chunk: discard its URL and retry with
            // a freshly-issued one. Repeated failures back off to 60 seconds.
            invalidateSignedURLBatch(containing: identity.chunkIndex)
            persistSignedURLCache()
            scheduleChunkRetry(identity.chunkIndex)
            if let context = NativeUploadContextStore.load(),
               status >= 400, status < 500, status != 408, status != 429 {
                requestSignedURLs(containing: identity.chunkIndex, context: context)
            }
        }
    }

    // MARK: - Token refresh

    private func refreshUploadToken(reason: String) async {
        guard !isRefreshingToken, var context = NativeUploadContextStore.load() else {
            scheduleGeneralRetry(reason: "token_refresh_already_running")
            return
        }
        let generation = lifecycleGeneration
        isRefreshingToken = true
        defer {
            if generation == lifecycleGeneration {
                isRefreshingToken = false
            }
        }
        let requestStartedAt = Date()
        RecorderLog.write("uploader", "token_refresh_request", [
            "recordingId": context.recordingId,
            "reason": reason
        ])

        do {
            var request = URLRequest(url: context.startEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "recordingId": context.recordingId,
                "interviewLink": context.interviewLink,
                "studyId": context.studyId,
                "deviceSendMs": Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard generation == lifecycleGeneration else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            RecorderLog.write("uploader", "token_refresh_response", [
                "recordingId": context.recordingId,
                "status": status,
                "elapsedMs": Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                "responseBytes": data.count,
                "contentType": contentType(response)
            ])
            guard status == 200 else {
                logAPIError(
                    data: data,
                    status: status,
                    operation: "recording_start_refresh",
                    recordingId: context.recordingId
                )
                if status == 500 || status == 502 || status == 0 {
                    scheduleGeneralRetry(reason: "token_refresh_\(status)")
                } else {
                    failTerminal("token_refresh_terminal_\(status)")
                }
                return
            }

            let refreshed = try JSONDecoder().decode(StartRecordingResponse.self, from: data)
            guard refreshed.recordingId == context.recordingId, !refreshed.uploadToken.isEmpty else {
                failTerminal("token_refresh_recording_mismatch")
                return
            }
            let tokenChanged = refreshed.uploadToken != context.uploadToken
            if abs(refreshed.chunkSeconds - context.chunkSeconds) > 0.001 {
                // Chunk duration is immutable once ReplayKit has started.
                SessionDiagnostics.shared.record(
                    "token_refresh_chunk_seconds_mismatch original=\(context.chunkSeconds) refreshed=\(refreshed.chunkSeconds)"
                )
            }
            context.uploadToken = refreshed.uploadToken
            context.serverEpochMs = refreshed.serverEpochMs
            context.chunkURLBatch = max(1, min(refreshed.chunkUrlBatch, 20))
            context.maxChunks = refreshed.maxChunks
            context.maxChunkBytes = refreshed.maxChunkBytes
            guard NativeUploadContextStore.save(context) else {
                failTerminal("token_refresh_persist_failed")
                return
            }
            clearSignedURLCache()
            RecorderLog.write("uploader", "token_refresh_succeeded", [
                "recordingId": context.recordingId,
                "reason": reason,
                "tokenChanged": tokenChanged,
                "contextPersisted": true,
                "chunkSeconds": context.chunkSeconds,
                "chunkUrlBatch": context.chunkURLBatch,
                "maxChunks": context.maxChunks ?? -1,
                "maxChunkBytes": context.maxChunkBytes,
                "serverClockOffsetMs": context.serverEpochMs - nowEpochMs()
            ])
            // Let the caller's defer blocks release its batch/completion guard
            // before the refreshed scan begins.
            DispatchQueue.main.async { [weak self] in self?.uploadPendingChunks() }
        } catch {
            guard generation == lifecycleGeneration else { return }
            logTransportError(
                event: "token_refresh_transport_or_decode_error",
                recordingId: context.recordingId,
                operation: "recording_start_refresh",
                error: error,
                elapsedMs: Int(Date().timeIntervalSince(requestStartedAt) * 1_000)
            )
            scheduleGeneralRetry(reason: "token_refresh_network")
        }
    }

    // MARK: - Complete manifest

    private func attemptCompleteIfReady(manifest: RecordingManifest, context: NativeUploadContext) {
        guard !isCompleting, !didComplete, !terminalFailure, manifest.status == "stopped" else { return }
        guard context.uploadAuthorized == true else { return }
        guard manifest.chunks.allSatisfy({ $0.status == .uploaded }) else { return }
        guard !manifest.chunks.isEmpty else {
            failTerminal("recording_has_no_valid_chunks")
            return
        }

        let orderedChunks = manifest.chunks.sorted(by: { $0.index < $1.index })
        let indexes = orderedChunks.map(\.index)
        let expectedIndexes = Array(0..<orderedChunks.count)
        guard indexes == expectedIndexes else {
            SessionDiagnostics.shared.record(
                "complete_manifest_index_gap actual=\(indexes) expectedCount=\(expectedIndexes.count)"
            )
            scheduleGeneralRetry(reason: "complete_manifest_index_gap")
            return
        }

        var completeChunks: [CompleteChunk] = []
        for chunk in orderedChunks {
            guard let startOffsetMs = chunk.startOffsetMs,
                  let duration = chunk.duration, duration > 0 else {
                SessionDiagnostics.shared.record(
                    "complete_manifest_repair_requested index=\(chunk.index)"
                )
                _ = beginMetadataRepairIfNeeded(
                    manifest: manifest,
                    context: context,
                    forcedIndexes: [chunk.index]
                )
                return
            }
            completeChunks.append(CompleteChunk(
                index: chunk.index,
                startOffsetMs: startOffsetMs,
                durationMs: max(1, Int64((duration * 1_000).rounded())),
                bytes: chunk.fileSize
            ))
        }

        isCompleting = true
        isUploading = true
        activity = .finalizing
        let backgroundTask = beginCompletionBackgroundTask()
        let requestStartedAt = Date()
        let generation = lifecycleGeneration
        RecorderLog.write("uploader", "complete_request", [
            "recordingId": context.recordingId,
            "chunkCount": completeChunks.count,
            "interrupted": manifest.interruptedAtMs != nil
        ])
        let payload = CompleteRequest(
            uploadToken: context.uploadToken,
            chunks: completeChunks,
            interruptedAtMs: manifest.interruptedAtMs,
            interruptedReason: manifest.interruptedReason
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.endCompletionBackgroundTask(backgroundTask)
                if generation == self.lifecycleGeneration {
                    self.isCompleting = false
                }
            }
            do {
                var request = URLRequest(url: context.completeEndpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(payload)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard generation == self.lifecycleGeneration else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                RecorderLog.write("uploader", "complete_http_response", [
                    "recordingId": context.recordingId,
                    "status": status,
                    "elapsedMs": Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                    "responseBytes": data.count,
                    "contentType": self.contentType(response)
                ])
                if status == 200 {
                    let result = try JSONDecoder().decode(CompleteResponse.self, from: data)
                    self.handleCompleteResponse(result)
                } else if status == 401, self.isExpiredTokenError(data) {
                    RecorderLog.write("uploader", "upload_token_rejected", [
                        "recordingId": context.recordingId,
                        "operation": "complete",
                        "classification": "expired",
                        "willRefresh": true
                    ])
                    await self.refreshUploadToken(reason: "complete_token_expired")
                } else if status == 401 {
                    self.logAPIError(
                        data: data,
                        status: status,
                        operation: "complete",
                        recordingId: context.recordingId
                    )
                    self.failTerminal("complete_invalid_token")
                } else if status == 500 || status == 502 || status == 0 {
                    self.scheduleGeneralRetry(reason: "complete_\(status)")
                } else {
                    self.logAPIError(
                        data: data,
                        status: status,
                        operation: "complete",
                        recordingId: context.recordingId
                    )
                    self.failTerminal("complete_terminal_\(status)")
                }
            } catch {
                guard generation == self.lifecycleGeneration else { return }
                self.logTransportError(
                    event: "complete_transport_or_decode_error",
                    recordingId: context.recordingId,
                    operation: "complete",
                    error: error,
                    elapsedMs: Int(Date().timeIntervalSince(requestStartedAt) * 1_000)
                )
                self.scheduleGeneralRetry(reason: "complete_network")
            }
        }
    }

    private func handleCompleteResponse(_ response: CompleteResponse) {
        guard let context = NativeUploadContextStore.load(), response.recordingId == context.recordingId else {
            failTerminal("complete_recording_mismatch")
            return
        }
        let normalizedStatus = response.status.lowercased()
        RecorderLog.write("uploader", "complete_result", [
            "recordingId": response.recordingId,
            "status": response.status,
            "declaredChunks": response.chunkCount,
            "uploadedCount": response.uploadedCount,
            "missingIndexes": response.missingIndexes.map(String.init).joined(separator: ","),
            "merging": response.merging
        ])

        if !response.missingIndexes.isEmpty || normalizedStatus == "uploading" {
            guard var manifest = RecordingManifest.load() else { return }
            for index in response.missingIndexes {
                guard updateChunk(index, in: &manifest, status: .serverMissing) else {
                    scheduleGeneralRetry(reason: "server_missing_state_persist_failed_\(index)")
                    return
                }
                signedURLs[index] = nil
            }
            persistSignedURLCache()
            SessionDiagnostics.shared.record(
                "complete_missing_objects count=\(response.missingIndexes.count)"
            )
            if response.missingIndexes.isEmpty {
                // A server may briefly report `uploading` before object
                // visibility catches up even though it has no concrete missing
                // indexes yet. Retry the same full manifest after a delay.
                scheduleGeneralRetry(reason: "complete_server_still_uploading")
            } else {
                uploadPendingChunks()
            }
            return
        }

        // The deployed proxy currently returns `complete` when it has accepted
        // the full manifest and queued the merge. Older/newer API versions use
        // `merging` or `merged`. `merging == true` is also an explicit success
        // signal, so do not turn a fully accepted HTTP 200 into a terminal error
        // merely because the status vocabulary differs between deployments.
        let acceptedStatuses = ["merging", "merged", "complete", "completed"]
        if response.missingIndexes.isEmpty &&
            (response.merging || acceptedStatuses.contains(normalizedStatus)) {
            finalizeServerAcceptedRecording()
        } else if normalizedStatus == "failed" {
            failTerminal("complete_failed_no_recording")
        } else {
            failTerminal("complete_unexpected_status_\(response.status)")
        }
    }

    private func finalizeServerAcceptedRecording() {
        finalizeRecordingLocally(logEvent: "recording_server_accepted")
    }

    private func finalizeRecordingLocally(logEvent: String) {
        guard var manifest = RecordingManifest.load() else { return }
        manifest.status = "completed"
        guard manifest.save(), RecordingManifest.load()?.status == "completed" else {
            scheduleGeneralRetry(reason: "complete_state_persist_failed")
            return
        }

        for chunk in manifest.chunks {
            let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(chunk.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        ChunkMetadataStore.clear()
        clearSignedURLCache()
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set("completed", forKey: RecorderConstants.broadcastStatusKey)
        defaults?.synchronize()
        didComplete = true
        isUploading = false
        activity = .completed
        cancelScheduledRetries()
        refreshCounts(manifest)
        RecorderLog.write("uploader", logEvent, [
            "recordingId": manifest.sessionId,
            "deletedLocalChunks": manifest.chunks.count
        ])
        onAllUploaded?()
    }

    // MARK: - Storage and retry helpers

    private func beginMetadataRepairIfNeeded(
        manifest: RecordingManifest,
        context: NativeUploadContext,
        forcedIndexes: Set<Int> = []
    ) -> Bool {
        guard !isRepairingMetadata else { return true }
        let highestIndex = manifest.chunks.map(\.index).max() ?? -1
        let candidates = manifest.chunks.filter { chunk in
            if forcedIndexes.contains(chunk.index) { return true }
            let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(chunk.fileName)
            let actualSize = fileSize(at: fileURL)
            guard actualSize > 0 else { return false }
            let staleRecording = chunk.status == .recording &&
                (manifest.status == "stopped" || chunk.index < highestIndex)
            let invalidMetadata = chunk.startOffsetMs == nil ||
                chunk.duration.map { !$0.isFinite || $0 <= 0 } ?? true ||
                chunk.fileSize != actualSize ||
                chunk.sha256?.count != 64
            return staleRecording || chunk.status == .dataLost || invalidMetadata
        }
        guard !candidates.isEmpty else { return false }

        isRepairingMetadata = true
        isUploading = true
        uploadError = nil
        activity = .verifying
        RecorderLog.write("uploader", "metadata_repair_started", [
            "recordingId": manifest.sessionId,
            "indexes": candidates.map(\.index).sorted().map(String.init).joined(separator: ",")
        ])
        let generation = lifecycleGeneration

        Task { @MainActor [weak self] in
            guard let self else { return }
            var invalidMediaIndexes: [Int] = []
            var metadataFailureIndexes: [Int] = []
            for original in candidates.sorted(by: { $0.index < $1.index }) {
                let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(original.fileName)
                let journal = ChunkMetadataStore.load(
                    sessionId: manifest.sessionId,
                    index: original.index
                )
                guard let inspection = await Self.inspectLocalChunk(at: fileURL),
                      inspection.fileSize <= context.maxChunkBytes else {
                    invalidMediaIndexes.append(original.index)
                    continue
                }
                guard let startOffsetMs = original.startOffsetMs ?? journal?.startOffsetMs,
                      startOffsetMs >= 0 else {
                    metadataFailureIndexes.append(original.index)
                    continue
                }
                guard generation == self.lifecycleGeneration else { return }

                var repaired = original
                repaired.startOffsetMs = startOffsetMs
                repaired.duration = inspection.duration
                repaired.fileSize = inspection.fileSize
                repaired.sha256 = inspection.sha256
                if repaired.status == .recording || repaired.status == .dataLost {
                    repaired.status = .ready
                }

                let journalSaved = ChunkMetadataStore.save(
                    sessionId: manifest.sessionId,
                    chunk: repaired
                )
                let manifestSaved = RecordingManifestStore.updateChunk(
                    sessionId: manifest.sessionId,
                    index: repaired.index
                ) { stored in
                    stored.status = repaired.status
                    stored.startOffsetMs = repaired.startOffsetMs
                    stored.duration = repaired.duration
                    stored.fileSize = repaired.fileSize
                    stored.sha256 = repaired.sha256
                }
                let verified = RecordingManifest.load()?.chunks.first(where: {
                    $0.index == repaired.index
                })
                let verifiedOK = verified?.startOffsetMs == repaired.startOffsetMs &&
                    verified?.duration == repaired.duration &&
                    verified?.fileSize == repaired.fileSize &&
                    verified?.sha256 == repaired.sha256
                guard journalSaved && manifestSaved && verifiedOK else {
                    metadataFailureIndexes.append(original.index)
                    continue
                }

                self.metadataRetryAttempts[original.index] = nil
                RecorderLog.write("uploader", "metadata_repair_succeeded", [
                    "recordingId": manifest.sessionId,
                    "index": repaired.index,
                    "durationMs": Int64((inspection.duration * 1_000).rounded()),
                    "bytes": inspection.fileSize
                ])
            }

            guard generation == self.lifecycleGeneration else { return }
            self.isRepairingMetadata = false
            if invalidMediaIndexes.isEmpty && metadataFailureIndexes.isEmpty {
                self.activity = .uploading
                self.uploadPendingChunks()
                return
            }

            // AVFoundation inspection can fail transiently immediately after
            // ReplayKit closes a file. Require three failed inspections before
            // classifying media as corrupt and deleting only a trailing run.
            let confirmedInvalidMedia = invalidMediaIndexes.filter {
                (self.metadataRetryAttempts[$0] ?? 0) >= 2
            }
            let mediaPendingRetry = invalidMediaIndexes.filter {
                !confirmedInvalidMedia.contains($0)
            }
            let invalidMiddleIndexes = self.discardInvalidTrailingChunks(
                confirmedInvalidIndexes: confirmedInvalidMedia,
                recordingId: manifest.sessionId
            )
            if !invalidMiddleIndexes.isEmpty {
                self.failTerminal("middle_chunk_invalid_\(invalidMiddleIndexes.sorted().first ?? -1)")
                return
            }
            if metadataFailureIndexes.contains(where: {
                (self.metadataRetryAttempts[$0] ?? 0) >= 2
            }) {
                self.failTerminal(
                    "chunk_metadata_persist_failed_\(metadataFailureIndexes.sorted().first ?? -1)"
                )
                return
            }
            guard RecordingManifestStore.load(recordingId: manifest.sessionId)?.chunks.isEmpty != true else {
                self.failTerminal("recording_has_no_valid_chunks")
                return
            }

            let retryIndexes = Array(Set(mediaPendingRetry + metadataFailureIndexes)).sorted()
            if retryIndexes.isEmpty {
                self.uploadPendingChunks()
            } else {
                self.scheduleMetadataRetry(indexes: retryIndexes)
            }
        }
        return true
    }

    /// Restores missing manifest entries and durable metadata from the
    /// per-chunk journal before making any upload or completion decision.
    @discardableResult
    private func reconcileChunkJournalIfNeeded(manifest: inout RecordingManifest) -> Bool {
        let journal = ChunkMetadataStore.loadAll(sessionId: manifest.sessionId)
        guard !journal.isEmpty else { return false }
        var changed = false

        for journalChunk in journal {
            let current = manifest.chunks.first(where: { $0.index == journalChunk.index })
            let needsMerge = current == nil ||
                current?.startOffsetMs == nil ||
                current?.duration == nil ||
                current?.fileSize == nil ||
                current?.sha256 == nil
            guard needsMerge else { continue }
            if RecordingManifestStore.upsertChunk(
                sessionId: manifest.sessionId,
                chunk: journalChunk
            ) {
                changed = true
            }
        }

        if changed, let latest = RecordingManifest.load(), latest.sessionId == manifest.sessionId {
            manifest = latest
        }
        return changed
    }

    private func discardInvalidTrailingChunks(
        confirmedInvalidIndexes: [Int],
        recordingId: String
    ) -> [Int] {
        guard var manifest = RecordingManifestStore.load(recordingId: recordingId),
              manifest.status == "stopped" else { return confirmedInvalidIndexes }
        var failed = Set(confirmedInvalidIndexes)
        var discarded: [Int] = []
        while let tail = manifest.chunks.max(by: { $0.index < $1.index }), failed.contains(tail.index) {
            try? FileManager.default.removeItem(
                at: RecorderConstants.chunksDirectory(for: recordingId).appendingPathComponent(tail.fileName)
            )
            ChunkMetadataStore.remove(sessionId: recordingId, index: tail.index)
            guard RecordingManifestStore.removeChunk(sessionId: recordingId, index: tail.index) else { break }
            discarded.append(tail.index)
            failed.remove(tail.index)
            manifest.chunks.removeAll { $0.index == tail.index }
        }
        if !discarded.isEmpty {
            _ = RecordingManifestStore.markPartialDataLoss(sessionId: recordingId)
            RecorderLog.write("uploader", "trailing_invalid_chunks_discarded", [
                "recordingId": recordingId,
                "indexes": discarded.sorted().map(String.init).joined(separator: ","),
                "partialDataLoss": true
            ])
        }
        return failed.sorted()
    }

    private nonisolated static func inspectLocalChunk(at fileURL: URL) async -> LocalChunkInspection? {
        await Task.detached(priority: .utility) {
            let fileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size])
                as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else { return nil }

            do {
                let durationTime = try await AVURLAsset(url: fileURL).load(.duration)
                let duration = CMTimeGetSeconds(durationTime)
                guard duration.isFinite, duration > 0 else { return nil }

                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    hasher.update(data: data)
                }
                let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return LocalChunkInspection(
                    fileSize: fileSize,
                    duration: duration,
                    sha256: checksum
                )
            } catch {
                return nil
            }
        }.value
    }

    private func scheduleMetadataRetry(indexes: [Int]) {
        let attempt = indexes.map { index -> Int in
            let next = min((metadataRetryAttempts[index] ?? 0) + 1, 8)
            metadataRetryAttempts[index] = next
            return next
        }.max() ?? 1
        let delay = min(pow(2.0, Double(attempt)), 60.0)
        activity = .retrying
        isUploading = true
        SessionDiagnostics.shared.record(
            "metadata_repair_retry_scheduled indexes=\(indexes.sorted()) delay=\(Int(delay))"
        )
        guard metadataRetryWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.metadataRetryWorkItem = nil
            self.uploadPendingChunks()
        }
        metadataRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleUploadWatchdog() {
        guard watchdogWorkItem == nil, !didComplete, !terminalFailure else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watchdogWorkItem = nil
            guard !self.didComplete, !self.terminalFailure else { return }
            RecorderLog.write("uploader", "upload_watchdog_audit")

            // Reconcile against URLSession again instead of trusting an old
            // in-memory inFlight set. If iOS discarded a task or its callback
            // was missed, reconciliation moves it back to `.failed` for retry.
            self.hasReconciledBackgroundTasks = false
            self.uploadScanRequestedDuringReconciliation = true
            self.reconcileBackgroundTasksIfNeeded()
        }
        watchdogWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
    }

    /// A just-finished ReplayKit writer can still be publishing its `.part.mp4`
    /// when the host receives the stopped notification. Never convert that
    /// short race into a terminal failure. Re-audit indefinitely; if the file
    /// appears, normal metadata repair/upload resumes automatically.
    private func deferForMissingLocalChunk(in manifest: RecordingManifest) -> Bool {
        guard manifest.status == "stopped" else { return false }
        let missing = manifest.chunks.filter { chunk in
            let fileURL = RecorderConstants.chunksDirectory.appendingPathComponent(chunk.fileName)
            let missingFile = fileSize(at: fileURL) <= 0
            let needsLocalFile = chunk.status != .uploaded ||
                chunk.startOffsetMs == nil ||
                chunk.duration.map { !$0.isFinite || $0 <= 0 } ?? true
            return missingFile && needsLocalFile
        }
        guard !missing.isEmpty else {
            missingLocalFileAttempts.removeAll()
            return false
        }


        // `.recording` can be a short cross-process publication race. Every
        // other state says a final file should already exist, so continuing to
        // claim that it can upload would be misleading. Keep all remaining
        // evidence on disk and surface an actionable failure.
        if let definitelyLost = missing.first(where: { $0.status != .recording }) {
            failTerminal("chunk_local_unrecoverable_\(definitelyLost.index)")
            return true
        }

        let indexes = missing.map(\.index).sorted()
        for index in indexes {
            missingLocalFileAttempts[index] = min((missingLocalFileAttempts[index] ?? 0) + 1, 1000)
        }
        activity = .retrying
        isUploading = true
        SessionDiagnostics.shared.record(
            "chunk_local_file_waiting indexes=\(indexes) attempts=\(indexes.map { missingLocalFileAttempts[$0] ?? 0 })"
        )
        scheduleGeneralRetry(reason: "chunk_local_file_not_yet_available")
        return true
    }

    private func loadSignedURLCacheIfNeeded(for recordingId: String) {
        guard signedURLRecordingId != recordingId else { return }
        signedURLs.removeAll()
        signedURLRecordingId = recordingId
        guard let data = try? Data(contentsOf: RecorderConstants.signedURLCacheURL),
              let cache = try? JSONDecoder().decode(SignedURLCache.self, from: data),
              cache.recordingId == recordingId else { return }
        signedURLs = Dictionary(uniqueKeysWithValues: cache.urls.map { ($0.index, $0) })
    }

    private func persistSignedURLCache() {
        guard let recordingId = signedURLRecordingId,
              let data = try? JSONEncoder().encode(SignedURLCache(
                recordingId: recordingId,
                urls: Array(signedURLs.values)
              )) else { return }
        try? data.write(
            to: RecorderConstants.signedURLCacheURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func clearSignedURLCache() {
        signedURLs.removeAll()
        try? FileManager.default.removeItem(at: RecorderConstants.signedURLCacheURL)
    }

    private func invalidateSignedURLBatch(containing index: Int) {
        guard let context = NativeUploadContextStore.load() else {
            signedURLs[index] = nil
            return
        }
        let batchSize = max(1, min(context.chunkURLBatch, 20))
        let start = (index / batchSize) * batchSize
        for itemIndex in start..<(start + batchSize) { signedURLs[itemIndex] = nil }
    }

    @discardableResult
    private func updateChunk(
        _ index: Int,
        in manifest: inout RecordingManifest,
        status: ChunkInfo.ChunkStatus
    ) -> Bool {
        let saved = RecordingManifestStore.updateChunk(
            sessionId: manifest.sessionId,
            index: index
        ) { $0.status = status }
        guard saved, let latest = RecordingManifest.load(), latest.sessionId == manifest.sessionId else {
            SessionDiagnostics.shared.record(
                "chunk_state_persist_failed index=\(index) status=\(status.rawValue)"
            )
            return false
        }
        manifest = latest
        return true
    }

    private func refreshCounts(_ manifest: RecordingManifest) {
        chunksTotal = manifest.chunks.count
        chunksUploaded = manifest.chunks.filter { $0.status == .uploaded }.count
    }

    private func fileSize(at url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private func scheduleChunkRetry(_ index: Int) {
        guard chunkRetryWorkItems[index] == nil else { return }
        let attempt = min((retryAttempts[index] ?? 0) + 1, 8)
        retryAttempts[index] = attempt
        let delay = min(pow(2.0, Double(attempt)), 60.0)
        RecorderLog.write("uploader", "chunk_retry_scheduled", [
            "recordingId": NativeUploadContextStore.load()?.recordingId ?? "unknown",
            "index": index,
            "attempt": attempt,
            "delayMs": Int(delay * 1_000)
        ])
        activity = .retrying
        isUploading = true
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.chunkRetryWorkItems[index] = nil
            self.uploadPendingChunks()
        }
        chunkRetryWorkItems[index] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleGeneralRetry(reason: String) {
        RecorderLog.write("uploader", "upload_retry_scheduled", [
            "recordingId": NativeUploadContextStore.load()?.recordingId ?? "unknown",
            "reason": reason,
            "delayMs": 10_000,
            "coalesced": generalRetryWorkItem != nil
        ])
        activity = .retrying
        isUploading = true
        guard generalRetryWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.generalRetryWorkItem = nil
            self.uploadPendingChunks()
        }
        generalRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    private func cancelScheduledRetries() {
        chunkRetryWorkItems.values.forEach { $0.cancel() }
        chunkRetryWorkItems.removeAll()
        metadataRetryWorkItem?.cancel()
        metadataRetryWorkItem = nil
        generalRetryWorkItem?.cancel()
        generalRetryWorkItem = nil
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
    }

    private func beginCompletionBackgroundTask() -> UIBackgroundTaskIdentifier {
        endCompletionBackgroundTask(completionBackgroundTask)
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Finalize recording manifest"
        ) { [weak self] in
            Task { @MainActor in
                SessionDiagnostics.shared.record("complete_background_time_expired")
                self?.endCompletionBackgroundTask(identifier)
            }
        }
        completionBackgroundTask = identifier
        return identifier
    }

    private func endCompletionBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid, completionBackgroundTask == identifier else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        completionBackgroundTask = .invalid
    }

    private func logAPIError(
        data: Data,
        status: Int,
        operation: String,
        recordingId: String
    ) {
        let apiError = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error
        RecorderLog.write("uploader", "api_error", [
            "operation": operation,
            "recordingId": recordingId,
            "status": status,
            "apiCode": apiError?.code ?? -1,
            "classification": apiErrorClassification(apiError?.message),
            "responseBytes": data.count
        ])
    }

    private func isExpiredTokenError(_ data: Data) -> Bool {
        let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?
            .error?.message?.lowercased() ?? ""
        return message.contains("token") && message.contains("expired")
    }

    private func apiErrorClassification(_ message: String?) -> String {
        let normalized = message?.lowercased() ?? ""
        if normalized.contains("token") && normalized.contains("expired") { return "token_expired" }
        if normalized.contains("token") { return "token_invalid" }
        if normalized.contains("missing") { return "missing_data" }
        return message == nil ? "no_error_body" : "server_rejected"
    }

    private func logAcceptedSignedURLBatch(
        _ batch: SignedURLBatchResponse,
        requestedStartIndex: Int
    ) {
        let indexes = batch.urls.map(\.index).sorted()
        let contiguous = indexes.isEmpty || indexes.enumerated().allSatisfy { offset, index in
            index == (indexes.first ?? 0) + offset
        }
        RecorderLog.write("uploader", "chunk_urls_accepted", [
            "recordingId": batch.recordingId,
            "requestedStartIndex": requestedStartIndex,
            "urlCount": indexes.count,
            "firstIndex": indexes.first ?? -1,
            "lastIndex": indexes.last ?? -1,
            "expiresInMs": max(0, batch.expiresAtMs - nowEpochMs()),
            "contiguous": contiguous
        ])
    }

    private func logTransportError(
        event: String,
        recordingId: String,
        operation: String,
        error: Error,
        elapsedMs: Int
    ) {
        let nsError = error as NSError
        RecorderLog.write("uploader", event, [
            "recordingId": recordingId,
            "operation": operation,
            "elapsedMs": elapsedMs,
            "errorDomain": nsError.domain,
            "errorCode": nsError.code,
            "errorDescription": error.localizedDescription
        ])
    }

    private func contentType(_ response: URLResponse?) -> String {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
    }

    private func nowEpochMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func failTerminal(_ reason: String) {
        terminalFailure = true
        isUploading = false
        uploadError = reason
        activity = .needsAttention
        cancelScheduledRetries()
        SessionDiagnostics.shared.record("upload_terminal_failure reason=\(reason)")
    }
}

extension ChunkUploader: URLSessionDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskDescription = task.taskDescription
        let response = task.response
        let taskIdentifier = task.taskIdentifier
        let bytesSent = task.countOfBytesSent
        let bytesExpectedToSend = task.countOfBytesExpectedToSend
        Task { @MainActor in
            self.handleTaskCompletion(
                taskDescription: taskDescription,
                taskIdentifier: taskIdentifier,
                bytesSent: bytesSent,
                bytesExpectedToSend: bytesExpectedToSend,
                error: error,
                response: response
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}
